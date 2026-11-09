package accesslog

import (
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
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

func logTestService(t *testing.T, database, directory string, interval int) *Service {
	t.Helper()
	a, err := Open(database, Config{Directory: directory, ScanIntervalSeconds: interval, Timezone: "Asia/Shanghai"})
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

func logTestWrite(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func logTestCount(t *testing.T, a *Service, want int64) {
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
	if a.Status().Skipped != 1 {
		t.Fatal("invalid lines not reported")
	}
	logTestWrite(t, path, first+"invalid json\n"+second)
	a.scan()
	logTestCount(t, a, 2)
	a.scan()
	logTestCount(t, a, 2)
	a.Close()
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
	if a.Status().Error != "" {
		t.Fatal(a.Status().Error)
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
	if a.Status().Error == "" || a.Status().Imported != 1000 {
		t.Fatal("failed batch must not report uncommitted imports", a.Status())
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
	if a.Status().Skipped != 1 {
		t.Fatal("oversized line should be skipped")
	}
	logTestWrite(t, path, first+"rewritten\n")
	a.scan()
	logTestCount(t, a, 2)
	if !strings.Contains(a.Status().Error, "rewritten or truncated") {
		t.Fatal("ambiguous truncation must be visible", a.Status())
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
	if missing.Status().Error == "" {
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

func TestAccessLogsConfiguration(t *testing.T) {
	for _, config := range []Config{{Directory: t.TempDir(), Timezone: "bad/zone"}, {Directory: t.TempDir(), ScanIntervalSeconds: -1}, {Directory: t.TempDir(), ScanIntervalSeconds: 86401}} {
		if a, err := Open(filepath.Join(t.TempDir(), "db"), config); err == nil {
			a.Close()
			t.Fatal("invalid config accepted")
		}
	}
	dir := t.TempDir()
	database := filepath.Join(t.TempDir(), "db")
	a := logTestService(t, database, dir, 86400)
	a.Close()
	if b, err := Open(database, Config{Directory: dir, Timezone: "UTC"}); err == nil {
		b.Close()
		t.Fatal("timezone change silently mixed bucket definitions")
	}
}
func TestAccessLogsSevenDayCleanup(t *testing.T) {
	dir := t.TempDir()
	database := filepath.Join(t.TempDir(), "db")
	db, err := openAccessLogDatabase(database + ".access.db")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Truncate(time.Second)
	for _, age := range []time.Duration{time.Hour, 8 * 24 * time.Hour} {
		stamp := now.Add(-age).Unix()
		if _, err = db.Exec("INSERT INTO access_counts VALUES(?,?,?,?,?,?,?,?)", stamp, stamp, "a.test", 200, "192.0.2.1", "UA", "/", 10); err != nil {
			db.Close()
			t.Fatal(err)
		}
	}
	db.Close()
	a := logTestService(t, database, dir, 86400)
	logTestCount(t, a, 10)
	if a.Status().Retention != 7 {
		t.Fatal("retention must always be seven days")
	}
	cutoff := now.Add(-Retention).Unix()
	for _, stamp := range []int64{cutoff - 1, cutoff, cutoff + 1} {
		if _, err = a.db.Exec("INSERT INTO access_counts VALUES(?,?,?,?,?,?,?,?)", accessHourStart(time.Unix(stamp, 0), a.location), stamp, "boundary.test", 404, "192.0.2.2", "UA", "/", 1); err != nil {
			t.Fatal(err)
		}
	}
	if err = pruneAccessLogs(context.Background(), a.db, now); err != nil {
		t.Fatal(err)
	}
	logTestCount(t, a, 12)
	var older int64
	if err = a.db.QueryRow("SELECT COUNT(*) FROM access_counts WHERE occurred_at<?", cutoff).Scan(&older); err != nil || older != 0 {
		t.Fatal("old records survived cleanup", err)
	}
	// Old source files are left intact and never reintroduced by later scans.
	oldPath := filepath.Join(dir, "old.log")
	logTestWrite(t, oldPath, logTestLine(now.Add(-8*24*time.Hour), "expired.test", "192.0.2.9", "old", "/old", 404))
	a.scan()
	a.scan()
	var expired int
	if err = a.db.QueryRow("SELECT COUNT(*) FROM access_counts WHERE domain='expired.test'").Scan(&expired); err != nil || expired != 0 {
		t.Fatal("expired source record reimported")
	}
}

func TestAccessLogsRejectUnmigratedDatabase(t *testing.T) {
	database := filepath.Join(t.TempDir(), "db")
	legacy, err := sql.Open("sqlite", database+".access.db")
	if err != nil {
		t.Fatal(err)
	}
	defer legacy.Close()
	if _, err := legacy.Exec("CREATE TABLE access_counts (hour INTEGER); INSERT INTO access_counts VALUES (123)"); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(database, Config{}); err == nil || !strings.Contains(err.Error(), "database has not been migrated") {
		t.Fatalf("expected an explicit migration error, got %v", err)
	}
	var hour int
	if err := legacy.QueryRow("SELECT hour FROM access_counts").Scan(&hour); err != nil || hour != 123 {
		t.Fatalf("legacy data changed: hour=%d, error=%v", hour, err)
	}
}
