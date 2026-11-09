package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hako/server/internal/accesslog"
)

func logTestLine(timestamp time.Time, domain, ip, ua, uri string, status int) string {
	data, _ := json.Marshal(map[string]any{"ts": float64(timestamp.Unix()) + 0.25, "status": status, "request": map[string]any{"host": domain, "client_ip": ip, "remote_ip": "192.0.2.99", "uri": uri, "headers": map[string][]string{"User-Agent": {ua}}}})
	return string(data) + "\n"
}

func importTestAccessLogs(t *testing.T, directory string) *accesslog.Service {
	t.Helper()
	a, err := accesslog.Open(filepath.Join(t.TempDir(), "access"), accesslog.Config{Directory: directory, ScanIntervalSeconds: 86400, Timezone: "Asia/Shanghai"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	deadline := time.Now().Add(5 * time.Second)
	for a.Status().LastScan == "" {
		if time.Now().After(deadline) {
			t.Fatal("initial log scan did not finish")
		}
		time.Sleep(time.Millisecond * 10)
	}
	return a
}

func testAccessHourStart(timestamp time.Time, location *time.Location) int64 {
	return timestamp.In(location).Truncate(time.Hour).Unix()
}

func logTestWrite(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestAccessLogsAdminRankingsAndAuthentication(t *testing.T) {
	f := newFixture(t, false)
	admin := loginAdmin(f)
	// Disabled state is still behind the existing administrator authentication.
	anonymous := &adminClient{f: f}
	anonymous.call("GET", "access-logs", nil, 401)
	admin.call("GET", "access-logs", nil, 200)
	admin.call("GET", "access-logs/hour?domain=a&hour=bad", nil, 409)
	dir := t.TempDir()
	ts := time.Now().Add(-2 * time.Hour)
	var log strings.Builder
	for i := 0; i < 12; i++ {
		log.WriteString(strings.Repeat(logTestLine(ts, "a.test", fmt.Sprintf("192.0.2.%d", i+1), fmt.Sprintf("Browser/%02d", i), fmt.Sprintf("/missing/%02d", i), 404), i+1))
	}
	log.WriteString(strings.Repeat(logTestLine(ts, "a.test", "192.0.2.12", "Browser/ok", "/ok?private=1", 200), 5))
	log.WriteString(strings.Repeat(logTestLine(ts, "b.test", "192.0.2.12", "OtherDomain", "/foreign", 404), 100))
	log.WriteString(strings.Repeat(logTestLine(ts.Add(-time.Hour), "a.test", "192.0.2.12", "OtherHour", "/old", 404), 100))
	logTestWrite(t, filepath.Join(dir, "access.log"), log.String())
	a := importTestAccessLogs(t, dir)
	// Compare authenticated routes with direct handler results for the same imported data.
	s := &Server{accessLogs: a}
	query := url.Values{"domain": {"a.test"}, "hour": {time.Unix(testAccessHourStart(ts, a.Location()), 0).Format(time.RFC3339)}, "from": {ts.Add(-4 * time.Hour).UTC().Format(time.RFC3339)}, "to": {ts.Add(time.Hour).UTC().Format(time.RFC3339)}}
	f.s.accessLogs = a
	data := admin.call("GET", "access-logs/hour?"+query.Encode(), nil, 200)
	anonymous.call("GET", "access-logs/hour?"+query.Encode(), nil, 401)
	f.s.adminMu.Lock()
	previousActivity := f.s.adminSessions[digest(admin.cookie.Value)].LastUsed
	f.s.adminMu.Unlock()
	admin.call("GET", "access-logs", nil, 200)
	f.s.adminMu.Lock()
	currentActivity := f.s.adminSessions[digest(admin.cookie.Value)].LastUsed
	f.s.adminMu.Unlock()
	if !previousActivity.Equal(currentActivity) {
		t.Fatal("passive log polling extended idle session")
	}
	rec := httptest.NewRecorder()
	s.adminAccessLogHour(rec, httptest.NewRequest("GET", "/admin/api/access-logs/hour?"+query.Encode(), nil))
	var detail struct {
		Visits, NonSuccess                  int64
		TopClients                          []accesslog.Client
		TopURLs                             []accesslog.Rank
		NonSuccessPages                     []accesslog.Page
		NonSuccessIPs, NonSuccessUserAgents []accesslog.Rank
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if !bytes.Equal(bytes.TrimSpace(data), bytes.TrimSpace(rec.Body.Bytes())) {
		t.Fatal("authenticated route and handler disagree")
	}
	if detail.Visits != 83 || detail.NonSuccess != 78 || len(detail.TopClients) != 10 || detail.TopClients[0].Value != "192.0.2.12" || detail.TopClients[0].Count != 17 {
		t.Fatalf("incorrect hour totals/rankings: %+v", detail)
	}
	if detail.TopClients[0].UserAgents[0].Value != "Browser/11" || detail.TopClients[0].URLs[0].Value != "/missing/11" || len(detail.NonSuccessPages) != 10 || detail.NonSuccessPages[0].IPs[0].Value != "192.0.2.12" || detail.NonSuccessPages[0].UserAgents[0].Value != "Browser/11" {
		t.Fatalf("incorrect nested rankings: %+v", detail)
	}
	if bytes.Contains(rec.Body.Bytes(), []byte("private")) || bytes.Contains(rec.Body.Bytes(), []byte("OtherDomain")) || bytes.Contains(rec.Body.Bytes(), []byte("OtherHour")) {
		t.Fatal("filter isolation failed", rec.Body.String())
	}
	if detail.NonSuccessIPs[0].Count != 12 || detail.NonSuccessUserAgents[0].Count != 12 {
		t.Fatal("non-2xx rankings include successful visits")
	}
	for _, path := range []string{"?date=bad", "?date=2026-02-31"} {
		rec = httptest.NewRecorder()
		s.adminAccessLogs(rec, httptest.NewRequest("GET", "/"+path, nil))
		if rec.Code != 400 {
			t.Fatal("invalid date accepted")
		}
	}
	rec = httptest.NewRecorder()
	s.adminAccessLogs(rec, httptest.NewRequest("GET", "/?rangeHours=24&domain=a.test", nil))
	var overview struct {
		Hours   []accesslog.Hour
		Domains []string
	}
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &overview) != nil || len(overview.Domains) != 2 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	for _, hour := range overview.Hours {
		if hour.Domain != "a.test" {
			t.Fatal("domain filter ignored")
		}
	}
	admin.call("GET", "access-logs/hour?domain=a&hour=bad", nil, 400)
}
