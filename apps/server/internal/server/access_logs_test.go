package server

import (
	"bytes"
	"compress/gzip"
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
)

func logTestLine(timestamp time.Time, domain, ip, ua, uri string, status int) string {
	data, _ := json.Marshal(map[string]any{"ts": float64(timestamp.Unix()) + 0.25, "status": status, "request": map[string]any{"host": domain, "client_ip": ip, "remote_ip": "192.0.2.99", "uri": uri, "headers": map[string][]string{"User-Agent": {ua}}}})
	return string(data) + "\n"
}

func logTestService(t *testing.T, database, directory string, interval int) *accessLogService {
	t.Helper()
	a, err := newAccessLogService(database, AccessLogConfig{Directory: directory, ScanIntervalSeconds: interval, Timezone: "Asia/Shanghai"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.close)
	deadline := time.Now().Add(5 * time.Second)
	for a.snapshot().LastScan == "" {
		if time.Now().After(deadline) {
			t.Fatal("initial log scan did not finish")
		}
		time.Sleep(time.Millisecond * 10)
	}
	return a
}

func logTestWrite(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func logTestCount(t *testing.T, a *accessLogService, want int64) {
	t.Helper()
	var count int64
	if err := a.db.QueryRow("SELECT COALESCE(SUM(count),0) FROM access_counts").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != want {
		t.Fatalf("visits=%d want %d", count, want)
	}
}

func TestAccessLogsIncrementalRestartAndRotation(t *testing.T) {
	dir := t.TempDir()
	database := filepath.Join(t.TempDir(), "hako.db")
	a := logTestService(t, database, dir, 86400)
	now := time.Now().Add(-2 * time.Hour)
	first := logTestLine(now, "EXAMPLE.COM:443", "203.0.113.1", "Browser/1", "/one?q=secret", 200)
	second := logTestLine(now, "example.com", "203.0.113.1", "Browser/2", "/missing", 404)
	path := filepath.Join(dir, "access.log")
	logTestWrite(t, path, first+"invalid json\n"+second[:len(second)/2])
	a.scan()
	logTestCount(t, a, 1)
	var anchor []byte
	if err := a.db.QueryRow("SELECT anchor FROM access_cursors LIMIT 1").Scan(&anchor); err != nil || len(anchor) != 32 {
		t.Fatal("checkpoint must contain only a SHA-256 digest", err)
	}
	if a.snapshot().Skipped != 1 {
		t.Fatal("invalid lines not reported")
	}
	logTestWrite(t, path, first+"invalid json\n"+second)
	a.scan()
	logTestCount(t, a, 2)
	a.scan()
	logTestCount(t, a, 2)
	a.close()
	a = logTestService(t, database, dir, 86400)
	logTestCount(t, a, 2)
	// Archive includes an unread tail written after the previous scan.
	third := logTestLine(now, "example.com", "2001:db8::1", "Bot", "/tail", 200)
	archive := filepath.Join(dir, "access-2026-10-30.log.gz")
	f, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(f)
	_, err = gz.Write([]byte(first + "invalid json\n" + second + third))
	if err != nil {
		t.Fatal(err)
	}
	if err = gz.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	logTestWrite(t, path, logTestLine(now.Add(time.Second), "other.example", "", "", "/new", 200))
	a.scan()
	logTestCount(t, a, 4)
	a.scan()
	logTestCount(t, a, 4)
	if a.snapshot().Error != "" {
		t.Fatal(a.snapshot().Error)
	}
	var domain, uri string
	if err = a.db.QueryRow("SELECT domain,url FROM access_counts WHERE url='/one'").Scan(&domain, &uri); err != nil || domain != "example.com" {
		t.Fatal("domain/path normalization failed", domain, uri, err)
	}
	// Rewriting a file with a different first record starts a new file generation.
	logTestWrite(t, path, logTestLine(now.Add(2*time.Second), "other.example", "203.0.113.2", "Bot", "/newer", 200))
	a.scan()
	logTestCount(t, a, 5)
}

func TestAccessLogsShortCheckpointGzipAndRetention(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	now := time.Now().Add(-time.Hour)
	first := logTestLine(now, "a.test", "192.0.2.1", "a", "/", 200)
	path := filepath.Join(dir, "a.jsonl")
	logTestWrite(t, path, first)
	a.scan()
	logTestCount(t, a, 1)
	// The 256-byte anchor can overlap the first line when decompressing a small file.
	archive := filepath.Join(dir, "a.jsonl.1.gz")
	f, _ := os.Create(archive)
	gz := gzip.NewWriter(f)
	gz.Write([]byte(first + logTestLine(now, "a.test", "192.0.2.2", "b", "/later", 200)))
	gz.Close()
	f.Close()
	os.Remove(path)
	a.scan()
	logTestCount(t, a, 2)
	logTestWrite(t, filepath.Join(dir, "old.log"), logTestLine(now.AddDate(0, 0, -60), "old.test", "192.0.2.1", "old", "/", 200))
	logTestWrite(t, filepath.Join(dir, "ignore.txt"), logTestLine(now, "ignore.test", "192.0.2.1", "old", "/", 200))
	os.Mkdir(filepath.Join(dir, "nested"), 0700)
	logTestWrite(t, filepath.Join(dir, "nested", "b.log.1"), logTestLine(now, "nested.test", "192.0.2.3", "c", "/", 200))
	a.scan()
	logTestCount(t, a, 3)
	_, err := a.db.Exec("INSERT INTO access_counts VALUES(?,?,?,?,?,?,?,?)", now.AddDate(0, 0, -60).Unix(), now.AddDate(0, 0, -60).Unix(), "expired.test", 200, "ip", "ua", "/", 20)
	if err != nil {
		t.Fatal(err)
	}
	a.scan()
	logTestCount(t, a, 3)
}

func TestAccessLogsBatchFailureResumesWithoutLossOrDuplication(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	line := logTestLine(time.Now().Add(-time.Hour), "a.test", "192.0.2.1", "Browser", "/", 200)
	path := filepath.Join(dir, "access.log")
	logTestWrite(t, path, strings.Repeat(line, 2105))
	_, err := a.db.Exec(fmt.Sprintf(`CREATE TRIGGER fail_second_batch BEFORE UPDATE ON access_cursors WHEN NEW.offset>%d BEGIN SELECT RAISE(ABORT,'simulated failure'); END`, len(line)*1000))
	if err != nil {
		t.Fatal(err)
	}
	a.scan()
	logTestCount(t, a, 1000)
	if a.snapshot().Error == "" || a.snapshot().Imported != 1000 {
		t.Fatal("failed batch must not report uncommitted imports", a.snapshot())
	}
	if _, err = a.db.Exec("DROP TRIGGER fail_second_batch"); err != nil {
		t.Fatal(err)
	}
	a.scan()
	logTestCount(t, a, 2105)
	a.scan()
	logTestCount(t, a, 2105)
}

func TestAccessLogsOversizedLineAndRewrite(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	first := logTestLine(time.Now().Add(-time.Hour), "a.test", "192.0.2.1", "Browser", "/", 200)
	path := filepath.Join(dir, "access.log")
	logTestWrite(t, path, first+strings.Repeat("x", maxAccessLine+10)+"\n"+first)
	a.scan()
	logTestCount(t, a, 2)
	if a.snapshot().Skipped != 1 {
		t.Fatal("oversized line should be skipped")
	}
	logTestWrite(t, path, first+"rewritten\n")
	a.scan()
	logTestCount(t, a, 2)
	if !strings.Contains(a.snapshot().Error, "rewritten or truncated") {
		t.Fatal("ambiguous truncation must be visible", a.snapshot())
	}
}

func TestAccessLogsPeriodicScanAndMissingDirectory(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 1)
	logTestWrite(t, filepath.Join(dir, "access.log"), logTestLine(time.Now(), "a.test", "192.0.2.1", "Browser", "/", 200))
	deadline := time.Now().Add(5 * time.Second)
	for {
		var count int64
		a.db.QueryRow("SELECT COALESCE(SUM(count),0) FROM access_counts").Scan(&count)
		if count == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("scheduled scan did not import log")
		}
		time.Sleep(20 * time.Millisecond)
	}
	missing := logTestService(t, filepath.Join(t.TempDir(), "db"), filepath.Join(t.TempDir(), "missing"), 86400)
	if missing.snapshot().Error == "" {
		t.Fatal("missing directory must be reported")
	}
}

func TestAccessLogsTimezoneAndParsing(t *testing.T) {
	for _, zone := range []string{"Asia/Shanghai", "Asia/Kathmandu", "America/New_York"} {
		location, _ := time.LoadLocation(zone)
		for _, text := range []string{"2026-10-30T13:22:41.123+08:00", "2026-11-01T01:15:00-04:00", "2026-11-01T01:15:00-05:00"} {
			ts, _ := time.Parse(time.RFC3339Nano, text)
			line := strings.Replace(logTestLine(ts, "EXAMPLE.COM.", "2001:0db8::1", "a", "/page?q=private", 404), fmt.Sprintf("%.2f", float64(ts.Unix())+0.25), fmt.Sprintf("%q", text), 1)
			key, ok := parseAccessLine([]byte(line), location)
			if !ok || time.Unix(key.Hour, 0).In(location).Minute() != 0 || key.Domain != "example.com" || key.IP != "2001:db8::1" || key.URL != "/page" {
				t.Fatalf("bad parsed line %s %s: %+v %v", zone, line, key, ok)
			}
		}
	}
	for _, line := range []string{`{}`, `{"ts":1,"status":200,"request":{"host":"a","uri":"/","headers":{"User-Agent":"bad"}}}`, `{"ts":1e40,"status":200,"request":{"host":"a","uri":"/"}}`} {
		if _, ok := parseAccessLine([]byte(line), time.UTC); ok {
			t.Fatal("invalid record accepted", line)
		}
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
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	// Compare authenticated routes with direct handler results for the same imported data.
	s := &Server{accessLogs: a}
	ts := time.Now().Add(-2 * time.Hour)
	var log strings.Builder
	for i := 0; i < 12; i++ {
		log.WriteString(strings.Repeat(logTestLine(ts, "a.test", fmt.Sprintf("192.0.2.%d", i+1), fmt.Sprintf("Browser/%02d", i), fmt.Sprintf("/missing/%02d", i), 404), i+1))
	}
	log.WriteString(strings.Repeat(logTestLine(ts, "a.test", "192.0.2.12", "Browser/ok", "/ok?private=1", 200), 5))
	log.WriteString(strings.Repeat(logTestLine(ts, "b.test", "192.0.2.12", "OtherDomain", "/foreign", 404), 100))
	log.WriteString(strings.Repeat(logTestLine(ts.Add(-time.Hour), "a.test", "192.0.2.12", "OtherHour", "/old", 404), 100))
	logTestWrite(t, filepath.Join(dir, "access.log"), log.String())
	a.scan()
	query := url.Values{"domain": {"a.test"}, "hour": {time.Unix(accessHourStart(ts, a.location), 0).Format(time.RFC3339)}, "from": {ts.Add(-4 * time.Hour).UTC().Format(time.RFC3339)}, "to": {ts.Add(time.Hour).UTC().Format(time.RFC3339)}}
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
		Visits, NotFound                int64
		TopClients                      []accessClient
		TopURLs                         []accessRank
		NotFoundPages                   []accessPage
		NotFoundIPs, NotFoundUserAgents []accessRank
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &detail) != nil {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if !bytes.Equal(bytes.TrimSpace(data), bytes.TrimSpace(rec.Body.Bytes())) {
		t.Fatal("authenticated route and handler disagree")
	}
	if detail.Visits != 83 || detail.NotFound != 78 || len(detail.TopClients) != 10 || detail.TopClients[0].Value != "192.0.2.12" || detail.TopClients[0].Count != 17 {
		t.Fatalf("incorrect hour totals/rankings: %+v", detail)
	}
	if detail.TopClients[0].UserAgents[0].Value != "Browser/11" || detail.TopClients[0].URLs[0].Value != "/missing/11" || len(detail.NotFoundPages) != 10 || detail.NotFoundPages[0].IPs[0].Value != "192.0.2.12" || detail.NotFoundPages[0].UserAgents[0].Value != "Browser/11" {
		t.Fatalf("incorrect nested rankings: %+v", detail)
	}
	if bytes.Contains(rec.Body.Bytes(), []byte("private")) || bytes.Contains(rec.Body.Bytes(), []byte("OtherDomain")) || bytes.Contains(rec.Body.Bytes(), []byte("OtherHour")) {
		t.Fatal("filter isolation failed", rec.Body.String())
	}
	if detail.NotFoundIPs[0].Count != 12 || detail.NotFoundUserAgents[0].Count != 12 {
		t.Fatal("404 rankings include successful visits")
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
		Hours   []accessHour
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

func TestAccessLogsConfiguration(t *testing.T) {
	for _, config := range []AccessLogConfig{{Directory: t.TempDir(), Timezone: "bad/zone"}, {Directory: t.TempDir(), ScanIntervalSeconds: -1}, {Directory: t.TempDir(), ScanIntervalSeconds: 86401}} {
		if a, err := newAccessLogService(filepath.Join(t.TempDir(), "db"), config); err == nil {
			a.close()
			t.Fatal("invalid config accepted")
		}
	}
	dir := t.TempDir()
	database := filepath.Join(t.TempDir(), "db")
	a := logTestService(t, database, dir, 86400)
	a.close()
	if b, err := newAccessLogService(database, AccessLogConfig{Directory: dir, Timezone: "UTC"}); err == nil {
		b.close()
		t.Fatal("timezone change silently mixed bucket definitions")
	}
}
