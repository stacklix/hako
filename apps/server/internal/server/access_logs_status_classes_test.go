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
)

func TestAccessLogsPartitionAllHTTPStatuses(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	var data strings.Builder
	// Cover every valid HTTP status, including both boundaries of the 2xx range.
	for status := 100; status <= 599; status++ {
		data.WriteString(logTestLine(now, "a.test", "192.0.2.1", "mixed", "/mixed", status))
	}
	data.WriteString(logTestLine(now, "a.test", "192.0.2.2", "success", "/success", 200))
	data.WriteString(logTestLine(now, "b.test", "192.0.2.3", "foreign", "/foreign", 403))
	data.WriteString(logTestLine(now.Add(-2*time.Hour), "a.test", "192.0.2.4", "old", "/old", 429))
	logTestWrite(t, filepath.Join(dir, "access.log"), data.String())
	a.scan()
	s := &Server{accessLogs: a}
	query := url.Values{"domain": {"a.test"}, "rangeHours": {"1"},
		"from": {now.Add(-time.Minute).Format(time.RFC3339)}, "to": {now.Add(time.Second).Format(time.RFC3339)}}
	for _, domain := range []string{"", "a.test"} {
		query.Set("domain", domain)
		rec := httptest.NewRecorder()
		s.adminAccessLogs(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
		var summary struct{ Totals, Hours []accessHour }
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &summary) != nil {
			t.Fatal(rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), `"notFound"`) || strings.Contains(rec.Body.String(), `"non4xxURLs"`) {
			t.Fatal("legacy 4xx metrics must not be returned", rec.Body.String())
		}
		for _, rows := range [][]accessHour{summary.Totals, summary.Hours} {
			found := false
			for _, row := range rows {
				if row.Domain == "a.test" {
					found = true
					if row.Visits != 501 || row.Success != 101 || row.NonSuccess != 400 {
						t.Fatalf("non-2xx summary includes 2xx or misses client errors: %+v", row)
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
			query.Set("hour", time.Unix(accessHourStart(now, a.location), 0).In(a.location).Format(time.RFC3339))
		}
		rec := httptest.NewRecorder()
		s.adminAccessLogDetails(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil), hourly)
		var detail struct {
			Visits, Success, NonSuccess         int64
			TopClients                          []accessClient
			SuccessURLs                         []accessRank
			NonSuccessPages                     []accessPage
			NonSuccessIPs, NonSuccessUserAgents []accessRank
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || detail.Visits != 501 || detail.Success != 101 || detail.NonSuccess != 400 {
			t.Fatal("incorrect non-2xx detail totals", rec.Code, rec.Body.String())
		}
		if len(detail.NonSuccessPages) != 1 || detail.NonSuccessPages[0].Value != "/mixed" || detail.NonSuccessPages[0].Count != 400 {
			t.Fatal("incorrect non-2xx pages", rec.Body.String())
		}
		if len(detail.TopClients) != 2 {
			t.Fatal("incorrect clients", rec.Body.String())
		}
		if len(detail.SuccessURLs) != 2 || detail.SuccessURLs[0] != (accessRank{"/mixed", 100}) || detail.SuccessURLs[1] != (accessRank{"/success", 1}) {
			t.Fatal("domain 2xx URLs must exclude all non-2xx requests", rec.Body.String())
		}
		client := detail.TopClients[0]
		if len(client.SuccessURLs) != 1 || client.SuccessURLs[0] != (accessRank{"/mixed", 100}) || len(client.NonSuccessURLs) != 1 || client.NonSuccessURLs[0] != (accessRank{"/mixed", 400}) {
			t.Fatal("same URL must count statuses separately, including redirects and server errors as non-2xx", rec.Body.String())
		}
		if len(detail.TopClients[1].NonSuccessURLs) != 0 || len(detail.TopClients[1].SuccessURLs) != 1 {
			t.Fatal("client URL rankings leak across IPs", rec.Body.String())
		}
		for _, ranks := range [][]accessRank{detail.NonSuccessIPs, detail.NonSuccessUserAgents, detail.NonSuccessPages[0].IPs, detail.NonSuccessPages[0].UserAgents} {
			if len(ranks) != 1 || ranks[0].Count != 400 {
				t.Fatal("non-2xx nested ranks must exclude other statuses/domains/windows", rec.Body.String())
			}
		}
	}
}

func TestAccessLogStatusClassesZeroRequests(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	s := &Server{accessLogs: a}
	rec := httptest.NewRecorder()
	s.adminAccessLogRankings(rec, httptest.NewRequest("GET", "/?domain=empty.test", nil))
	var detail struct {
		Visits, Success, NonSuccess int64
		SuccessURLs                 []accessRank
		NonSuccessPages             []accessPage
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || detail.Visits != 0 || detail.Success != 0 || detail.NonSuccess != 0 || len(detail.SuccessURLs) != 0 || len(detail.NonSuccessPages) != 0 {
		t.Fatal("empty response must contain zero counts and empty rankings", rec.Code, rec.Body.String())
	}
}

func TestAccessLogClientURLCategoriesHaveIndependentTopTen(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
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
	a.scan()
	s := &Server{accessLogs: a}
	query := url.Values{"domain": {"a.test"}, "rangeHours": {"24"},
		"from": {now.Add(-time.Minute).Format(time.RFC3339)}, "to": {now.Add(time.Second).Format(time.RFC3339)}}
	for _, hourly := range []bool{false, true} {
		if hourly {
			// Widen the window so only the hour filter excludes the old URL.
			query.Set("from", now.Add(-3*time.Hour).Format(time.RFC3339))
			query.Set("hour", time.Unix(accessHourStart(now, a.location), 0).In(a.location).Format(time.RFC3339))
		}
		rec := httptest.NewRecorder()
		s.adminAccessLogDetails(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil), hourly)
		var detail struct {
			TopClients  []accessClient
			SuccessURLs []accessRank
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || len(detail.TopClients) != 1 {
			t.Fatal(rec.Code, rec.Body.String())
		}
		client := detail.TopClients[0]
		if len(detail.SuccessURLs) != 10 {
			t.Fatal("domain 2xx URLs require an independent Top 10", rec.Body.String())
		}
		for i, row := range detail.SuccessURLs {
			if row.Value != fmt.Sprintf("/200/%02d", 12-i) || row.Count != int64(12-i) {
				t.Fatal("domain 2xx ranking or filter isolation is incorrect", rec.Body.String())
			}
		}
		for category, ranks := range map[int][]accessRank{200: client.SuccessURLs, 403: client.NonSuccessURLs} {
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
