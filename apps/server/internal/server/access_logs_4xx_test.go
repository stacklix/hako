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

func TestAccessLogsCountAll4xx(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	var data strings.Builder
	// Include both endpoints and every status in between, plus adjacent non-4xx.
	for status := 399; status <= 500; status++ {
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
		for _, rows := range [][]accessHour{summary.Totals, summary.Hours} {
			found := false
			for _, row := range rows {
				if row.Domain == "a.test" {
					found = true
					if row.Visits != 103 || row.NotFound != 100 {
						t.Fatalf("4xx summary includes non-4xx or misses client errors: %+v", row)
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
			Visits, NotFound                int64
			TopClients                      []accessClient
			Non4xxURLs                      []accessRank
			NotFoundPages                   []accessPage
			NotFoundIPs, NotFoundUserAgents []accessRank
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || detail.Visits != 103 || detail.NotFound != 100 {
			t.Fatal("incorrect 4xx detail totals", rec.Code, rec.Body.String())
		}
		if len(detail.NotFoundPages) != 1 || detail.NotFoundPages[0].Value != "/mixed" || detail.NotFoundPages[0].Count != 100 {
			t.Fatal("incorrect 4xx pages", rec.Body.String())
		}
		if len(detail.TopClients) != 2 {
			t.Fatal("incorrect clients", rec.Body.String())
		}
		if len(detail.Non4xxURLs) != 2 || detail.Non4xxURLs[0] != (accessRank{"/mixed", 2}) || detail.Non4xxURLs[1] != (accessRank{"/success", 1}) {
			t.Fatal("domain non-4xx URLs must exclude all 400–499 requests", rec.Body.String())
		}
		client := detail.TopClients[0]
		if len(client.Non4xxURLs) != 1 || client.Non4xxURLs[0] != (accessRank{"/mixed", 2}) || len(client.ClientErrorURLs) != 1 || client.ClientErrorURLs[0] != (accessRank{"/mixed", 100}) {
			t.Fatal("same URL must count statuses separately, including 399 and 500 as non-4xx", rec.Body.String())
		}
		if len(detail.TopClients[1].ClientErrorURLs) != 0 || len(detail.TopClients[1].Non4xxURLs) != 1 {
			t.Fatal("client URL rankings leak across IPs", rec.Body.String())
		}
		for _, ranks := range [][]accessRank{detail.NotFoundIPs, detail.NotFoundUserAgents, detail.NotFoundPages[0].IPs, detail.NotFoundPages[0].UserAgents} {
			if len(ranks) != 1 || ranks[0].Count != 100 {
				t.Fatal("4xx nested ranks must exclude other statuses/domains/windows", rec.Body.String())
			}
		}
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
			TopClients []accessClient
			Non4xxURLs []accessRank
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil || len(detail.TopClients) != 1 {
			t.Fatal(rec.Code, rec.Body.String())
		}
		client := detail.TopClients[0]
		if len(detail.Non4xxURLs) != 10 {
			t.Fatal("domain non-4xx URLs require an independent Top 10", rec.Body.String())
		}
		for i, row := range detail.Non4xxURLs {
			if row.Value != fmt.Sprintf("/200/%02d", 12-i) || row.Count != int64(12-i) {
				t.Fatal("domain non-4xx ranking or filter isolation is incorrect", rec.Body.String())
			}
		}
		for category, ranks := range map[int][]accessRank{200: client.Non4xxURLs, 403: client.ClientErrorURLs} {
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
