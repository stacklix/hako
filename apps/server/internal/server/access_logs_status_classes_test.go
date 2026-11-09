package server

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hako/server/internal/accesslog"
)

func TestAccessLogsPartitionAllHTTPStatuses(t *testing.T) {
	dir := t.TempDir()
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	var data strings.Builder
	// Cover every valid HTTP status, including normal exceptions 101 and 304.
	for status := 100; status <= 599; status++ {
		data.WriteString(logTestLine(now, "a.test", "192.0.2.1", "mixed", "/mixed", status))
	}
	data.WriteString(logTestLine(now, "a.test", "192.0.2.2", "success", "/success", 200))
	data.WriteString(logTestLine(now, "b.test", "192.0.2.3", "foreign", "/foreign", 403))
	data.WriteString(logTestLine(now.Add(-2*time.Hour), "a.test", "192.0.2.4", "old", "/old", 429))
	logTestWrite(t, filepath.Join(dir, "access.log"), data.String())
	a := importTestAccessLogs(t, dir)
	s := &Server{accessLogs: a}
	query := url.Values{"domain": {"a.test"}, "rangeHours": {"1"},
		"from": {now.Add(-time.Minute).Format(time.RFC3339)}, "to": {now.Add(time.Second).Format(time.RFC3339)}}
	for _, domain := range []string{"", "a.test"} {
		query.Set("domain", domain)
		rec := httptest.NewRecorder()
		s.adminAccessLogs(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
		var summary struct{ Totals, Hours []accesslog.Hour }
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &summary) != nil {
			t.Fatal(rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), `"notFound"`) || strings.Contains(rec.Body.String(), `"non4xxURLs"`) {
			t.Fatal("legacy 4xx metrics must not be returned", rec.Body.String())
		}
		for _, rows := range [][]accesslog.Hour{summary.Totals, summary.Hours} {
			found := false
			for _, row := range rows {
				if row.Domain == "a.test" {
					found = true
					if row.Visits != 501 || row.Success != 103 || row.NonSuccess != 398 {
						t.Fatalf("abnormal summary includes 2xx or misses client errors: %+v", row)
					}
				}
			}
			if !found {
				t.Fatal("missing domain summary", rec.Body.String())
			}
		}
	}
	query.Set("domain", "a.test")
	for _, hourly := range []bool{false, true} {
		if hourly {
			query.Set("hour", time.Unix(testAccessHourStart(now, a.Location()), 0).In(a.Location()).Format(time.RFC3339))
		}
		rec := httptest.NewRecorder()
		s.adminAccessLogDetails(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil), hourly)
		var detail struct {
			Visits, Success, NonSuccess         int64
			TopClients                          []accesslog.Client
			SuccessURLs                         []accesslog.Rank
			NonSuccessPages                     []accesslog.Page
			NonSuccessIPs, NonSuccessUserAgents []accesslog.Rank
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || detail.Visits != 501 || detail.Success != 103 || detail.NonSuccess != 398 {
			t.Fatal("incorrect abnormal detail totals", rec.Code, rec.Body.String())
		}
		if len(detail.NonSuccessPages) != 1 || detail.NonSuccessPages[0].Value != "/mixed" || detail.NonSuccessPages[0].Count != 398 {
			t.Fatal("incorrect abnormal pages", rec.Body.String())
		}
		if len(detail.TopClients) != 2 {
			t.Fatal("incorrect clients", rec.Body.String())
		}
		if len(detail.SuccessURLs) != 2 || detail.SuccessURLs[0] != (accesslog.Rank{"/mixed", 102}) || detail.SuccessURLs[1] != (accesslog.Rank{"/success", 1}) {
			t.Fatal("domain normal URLs must exclude all abnormal requests", rec.Body.String())
		}
		client := detail.TopClients[0]
		if len(client.SuccessURLs) != 1 || client.SuccessURLs[0] != (accesslog.Rank{"/mixed", 102}) || len(client.NonSuccessURLs) != 1 || client.NonSuccessURLs[0] != (accesslog.Rank{"/mixed", 398}) {
			t.Fatal("same URL must count statuses separately, including redirects and server errors as abnormal", rec.Body.String())
		}
		if len(detail.TopClients[1].NonSuccessURLs) != 0 || len(detail.TopClients[1].SuccessURLs) != 1 {
			t.Fatal("client URL rankings leak across IPs", rec.Body.String())
		}
		for _, ranks := range [][]accesslog.Rank{detail.NonSuccessIPs, detail.NonSuccessUserAgents, detail.NonSuccessPages[0].IPs, detail.NonSuccessPages[0].UserAgents} {
			if len(ranks) != 1 || ranks[0].Count != 398 {
				t.Fatal("abnormal nested ranks must exclude other statuses/domains/windows", rec.Body.String())
			}
		}
	}
}

func TestAccessLogStatusClassesZeroRequests(t *testing.T) {
	dir := t.TempDir()
	a := importTestAccessLogs(t, dir)
	s := &Server{accessLogs: a}
	rec := httptest.NewRecorder()
	s.adminAccessLogRankings(rec, httptest.NewRequest("GET", "/?domain=empty.test", nil))
	var detail struct {
		Visits, Success, NonSuccess int64
		SuccessURLs                 []accesslog.Rank
		NonSuccessPages             []accesslog.Page
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || detail.Visits != 0 || detail.Success != 0 || detail.NonSuccess != 0 || len(detail.SuccessURLs) != 0 || len(detail.NonSuccessPages) != 0 {
		t.Fatal("empty response must contain zero counts and empty rankings", rec.Code, rec.Body.String())
	}
}

func TestAccessLogClientURLCategoriesHaveIndependentTopTen(t *testing.T) {
	dir := t.TempDir()
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	var data strings.Builder
	for i := 1; i <= 12; i++ {
		for _, status := range []int{200, 403} {
			path := fmt.Sprintf("/%d/%02d", status, i)
			data.WriteString(strings.Repeat(logTestLine(now, "a.test", "192.0.2.1", "UA", path, status), i))
		}
	}
	// Same IP, but outside the selected domain/hour, must never enter its rankings.
	data.WriteString(strings.Repeat(logTestLine(now, "b.test", "192.0.2.1", "UA", "/foreign", 403), 100))
	data.WriteString(strings.Repeat(logTestLine(now.Add(-2*time.Hour), "a.test", "192.0.2.1", "UA", "/old", 200), 100))
	logTestWrite(t, filepath.Join(dir, "access.log"), data.String())
	a := importTestAccessLogs(t, dir)
	s := &Server{accessLogs: a}
	query := url.Values{"domain": {"a.test"}, "rangeHours": {"24"},
		"from": {now.Add(-time.Minute).Format(time.RFC3339)}, "to": {now.Add(time.Second).Format(time.RFC3339)}}
	for _, hourly := range []bool{false, true} {
		if hourly {
			// Widen the window so only the hour filter excludes the old URL.
			query.Set("from", now.Add(-3*time.Hour).Format(time.RFC3339))
			query.Set("hour", time.Unix(testAccessHourStart(now, a.Location()), 0).In(a.Location()).Format(time.RFC3339))
		}
		rec := httptest.NewRecorder()
		s.adminAccessLogDetails(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil), hourly)
		var detail struct {
			TopClients  []accesslog.Client
			SuccessURLs []accesslog.Rank
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || len(detail.TopClients) != 1 {
			t.Fatal(rec.Code, rec.Body.String())
		}
		client := detail.TopClients[0]
		if len(detail.SuccessURLs) != 10 {
			t.Fatal("domain normal URLs require an independent Top 10", rec.Body.String())
		}
		for i, row := range detail.SuccessURLs {
			if row.Value != fmt.Sprintf("/200/%02d", 12-i) || row.Count != int64(12-i) {
				t.Fatal("domain normal ranking or filter isolation is incorrect", rec.Body.String())
			}
		}
		for category, ranks := range map[int][]accesslog.Rank{200: client.SuccessURLs, 403: client.NonSuccessURLs} {
			if len(ranks) != 10 {
				t.Fatal("each category must have its own Top 10", rec.Body.String())
			}
			for i, row := range ranks {
				if row.Value != fmt.Sprintf("/%d/%02d", category, 12-i) || row.Count != int64(12-i) {
					t.Fatal("incorrect independent ranking or filter isolation", rec.Body.String())
				}
			}
		}
	}
}

func TestAccessLogNormalStatusWhitelist(t *testing.T) {
	for _, tc := range []struct {
		status int
		normal bool
	}{
		{100, false}, {101, true}, {102, false}, {199, false}, {200, true}, {204, true}, {299, true},
		{300, false}, {301, false}, {302, false}, {303, false}, {304, true}, {305, false}, {307, false}, {308, false}, {400, false}, {404, false}, {500, false}, {599, false},
	} {
		t.Run(fmt.Sprint(tc.status), func(t *testing.T) {
			dir := t.TempDir()
			now := time.Now().Add(-time.Minute).Truncate(time.Second)
			logTestWrite(t, filepath.Join(dir, "access.log"), logTestLine(now, "a.test", "192.0.2.1", "UA", "/status", tc.status))
			a := importTestAccessLogs(t, dir)
			s := &Server{accessLogs: a}
			rec := httptest.NewRecorder()
			s.adminAccessLogRankings(rec, httptest.NewRequest("GET", "/?domain=a.test", nil))
			var detail struct {
				Visits, Success, NonSuccess int64
				SuccessURLs                 []accesslog.Rank
				NonSuccessPages             []accesslog.Page
				TopClients                  []accesslog.Client
			}
			if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil {
				t.Fatal(rec.Code, rec.Body.String())
			}
			var normal int64
			if tc.normal {
				normal = 1
			}
			if detail.Visits != 1 || detail.Success != normal || detail.NonSuccess != 1-normal || len(detail.SuccessURLs) != int(normal) || len(detail.NonSuccessPages) != int(1-normal) || len(detail.TopClients) != 1 {
				t.Fatal("incorrect whitelist classification", rec.Body.String())
			}
			client := detail.TopClients[0]
			if len(client.SuccessURLs) != int(normal) || len(client.NonSuccessURLs) != int(1-normal) {
				t.Fatal("incorrect IP URL classification", rec.Body.String())
			}
		})
	}
}
