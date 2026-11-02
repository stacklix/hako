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

func TestAccessLogRecordsFiltersAndPagination(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	s := &Server{accessLogs: a}
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	var data strings.Builder
	for i := 0; i < 12; i++ {
		data.WriteString(logTestLine(now, "a.test", "192.0.2.1", "UA", fmt.Sprintf("/path/%02d?secret=hidden", i), 404))
	}
	data.WriteString(logTestLine(now, "a.test", "192.0.2.1", "UA", "/path/00", 404))
	data.WriteString(logTestLine(now, "a.test", "192.0.2.2", "Other", "/path/00", 200))
	data.WriteString(logTestLine(now, "b.test", "2001:db8::1", "IPv6", "/path/00", 503))
	data.WriteString(logTestLine(now.Add(-2*time.Hour), "a.test", "192.0.2.1", "old", "/old", 404))
	logTestWrite(t, filepath.Join(dir, "access.log"), data.String())
	a.scan()
	type result struct {
		Rows                []accessRecord
		TotalRows, Requests int64
		HasMore             bool
	}
	query := func(filters url.Values) result {
		t.Helper()
		filters.Set("from", now.Add(-time.Second).Format(time.RFC3339))
		filters.Set("to", now.Add(time.Second).Format(time.RFC3339))
		rec := httptest.NewRecorder()
		s.adminAccessLogRecords(rec, httptest.NewRequest("GET", "/?"+filters.Encode(), nil))
		var value result
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &value) != nil {
			t.Fatal(rec.Code, rec.Body.String())
		}
		return value
	}
	for _, item := range []struct {
		filters        url.Values
		rows, requests int64
	}{
		{url.Values{}, 14, 15},
		{url.Values{"domain": {"a.test"}}, 13, 14},
		{url.Values{"ip": {"192.0.2.1"}}, 12, 13},
		{url.Values{"path": {"/path/00"}}, 3, 4},
		{url.Values{"status": {"404"}}, 12, 13},
		{url.Values{"ip": {"2001:0db8::1"}}, 1, 1},
		{url.Values{"ip": {"192.0.2.1"}, "path": {"/path/00"}, "status": {"404"}, "domain": {"a.test"}}, 1, 2},
		{url.Values{"path": {"/path/00' OR 1=1 --"}}, 0, 0},
	} {
		value := query(item.filters)
		if value.TotalRows != item.rows || value.Requests != item.requests || int64(len(value.Rows)) != item.rows {
			t.Fatalf("filters %v: %+v", item.filters, value)
		}
	}
	seen := map[string]bool{}
	for offset := 0; offset < 12; offset += 5 {
		page := query(url.Values{"status": {"404"}, "limit": {"5"}, "offset": {fmt.Sprint(offset)}})
		if page.TotalRows != 12 || page.Requests != 13 || page.HasMore != (offset < 10) {
			t.Fatalf("pagination: %+v", page)
		}
		for _, row := range page.Rows {
			if seen[row.Path] || row.Status != 404 || row.IP != "192.0.2.1" || row.UserAgent != "UA" || row.Time != now.In(a.location).Format(time.RFC3339) {
				t.Fatalf("incorrect row: %+v", row)
			}
			seen[row.Path] = true
		}
	}
	if len(seen) != 12 {
		t.Fatal("results truncated to Top 10", seen)
	}
	for _, q := range []string{"status=4xx", "status=99", "status=600", "ip=invalid", "path=relative", "path=%2F%3Fx%3D1", "limit=0", "limit=501", "offset=-1", "from=bad&to=bad", "rangeHours=2"} {
		rec := httptest.NewRecorder()
		s.adminAccessLogRecords(rec, httptest.NewRequest("GET", "/?"+q, nil))
		if rec.Code != 400 {
			t.Fatal("invalid filter accepted", q, rec.Code)
		}
	}
}

func TestAccessLogRecordsTrailingSlashEquivalence(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	s := &Server{accessLogs: a}
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	var data strings.Builder
	for _, path := range []string{"/blog", "/blog/", "/blog//", "/blog/post", "/blogger", "/"} {
		status := 200
		if path == "/blog/" {
			status = 404
		}
		data.WriteString(logTestLine(now, "a.test", "192.0.2.1", "UA", path, status))
	}
	data.WriteString(logTestLine(now, "b.test", "192.0.2.1", "foreign", "/blog/", 404))
	logTestWrite(t, filepath.Join(dir, "access.log"), data.String())
	a.scan()
	type result struct {
		Rows                []accessRecord
		TotalRows, Requests int64
		HasMore             bool
	}
	read := func(path, status string, offset int) result {
		t.Helper()
		q := url.Values{"domain": {"a.test"}, "ip": {"192.0.2.1"}, "path": {path}, "status": {status}, "offset": {fmt.Sprint(offset)}, "limit": {"1"},
			"from": {now.Add(-time.Second).Format(time.RFC3339)}, "to": {now.Add(time.Second).Format(time.RFC3339)}}
		rec := httptest.NewRecorder()
		s.adminAccessLogRecords(rec, httptest.NewRequest("GET", "/?"+q.Encode(), nil))
		var value result
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &value) != nil {
			t.Fatal(rec.Code, rec.Body.String())
		}
		return value
	}
	for _, path := range []string{"/blog", "/blog/", "/blog//"} {
		seen := map[string]bool{}
		for offset := 0; offset < 3; offset++ {
			page := read(path, "", offset)
			if page.TotalRows != 3 || page.Requests != 3 || len(page.Rows) != 1 || page.HasMore != (offset < 2) {
				t.Fatalf("%s: %+v", path, page)
			}
			seen[page.Rows[0].Path] = true
		}
		if !seen["/blog"] || !seen["/blog/"] || !seen["/blog//"] {
			t.Fatal("original paths must remain distinct in results", seen)
		}
		filtered := read(path, "404", 0)
		if filtered.TotalRows != 1 || filtered.Rows[0].Path != "/blog/" {
			t.Fatal("status filter failed", filtered)
		}
	}
	root := read("/", "", 0)
	if root.TotalRows != 1 || root.Rows[0].Path != "/" {
		t.Fatal("root path matched non-root paths", root)
	}
}
