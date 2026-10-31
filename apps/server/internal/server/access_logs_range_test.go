package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAccessLogRangePresets(t *testing.T) {
	now := time.Date(2026, 10, 30, 14, 37, 25, 0, time.FixedZone("CST", 8*3600))
	for _, hours := range []int{1, 3, 6, 12, 24, 72, 168} {
		request := httptest.NewRequest("GET", fmt.Sprintf("/?rangeHours=%d", hours), nil)
		window, err := parseAccessLogWindow(request, now)
		if err != nil || window.hours != hours || !window.to.Equal(now) || !window.from.Equal(now.Add(-time.Duration(hours)*time.Hour)) {
			t.Fatalf("invalid rolling window %d: %+v %v", hours, window, err)
		}
	}
	window, err := parseAccessLogWindow(httptest.NewRequest("GET", "/", nil), now)
	if err != nil || window.hours != 24 {
		t.Fatal("default window must be 24 hours")
	}
	for _, query := range []string{"rangeHours=0", "rangeHours=2", "rangeHours=169", "rangeHours=-1", "rangeHours=bad", "date=2026-10-30", "from=bad", "to=bad"} {
		if _, err := parseAccessLogWindow(httptest.NewRequest("GET", "/?"+query, nil), now); err == nil {
			t.Fatal("invalid range accepted", query)
		}
	}
	for _, span := range []struct{ from, to time.Time }{{now, now.Add(time.Hour)}, {now.Add(-169 * time.Hour), now}, {now, now.Add(-time.Hour)}} {
		query := url.Values{"rangeHours": {"168"}, "from": {span.from.Format(time.RFC3339)}, "to": {span.to.Format(time.RFC3339)}}
		if _, err := parseAccessLogWindow(httptest.NewRequest("GET", "/?"+query.Encode(), nil), now); err == nil {
			t.Fatal("invalid explicit window accepted", span)
		}
	}
}

func TestAccessLogsRollingRangesAndRankings(t *testing.T) {
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "db"), dir, 86400)
	now := time.Now().Add(-10 * time.Second).Truncate(time.Second)
	var data strings.Builder
	// Each successive preset adds one older record. The 1-hour boundary shares an hour bucket.
	for i, age := range []time.Duration{30 * time.Minute, 2 * time.Hour, 4 * time.Hour, 8 * time.Hour, 18 * time.Hour, 48 * time.Hour, 120 * time.Hour} {
		data.WriteString(logTestLine(now.Add(-age), "a.test", fmt.Sprintf("192.0.2.%d", i+1), fmt.Sprintf("UA-%d", i), fmt.Sprintf("/page-%d", i), 404))
	}
	data.WriteString(logTestLine(now.Add(-time.Hour-time.Second), "a.test", "192.0.2.99", "excluded", "/before-boundary", 200))
	data.WriteString(logTestLine(now.Add(-time.Hour+time.Second), "a.test", "192.0.2.98", "included", "/after-boundary", 200))
	data.WriteString(logTestLine(now.Add(-30*time.Minute), "b.test", "192.0.2.88", "foreign", "/foreign", 404))
	logTestWrite(t, filepath.Join(dir, "access.log"), data.String())
	a.scan()
	s := &Server{accessLogs: a}
	for i, hours := range []int{1, 3, 6, 12, 24, 72, 168} {
		query := url.Values{"rangeHours": {fmt.Sprint(hours)}, "domain": {"a.test"}, "from": {now.Add(-time.Duration(hours) * time.Hour).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}}
		rec := httptest.NewRecorder()
		s.adminAccessLogs(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
		var list struct {
			RangeHours    int
			Totals, Hours []accessHour
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &list) != nil || len(list.Totals) != 1 {
			t.Fatal(rec.Code, rec.Body.String())
		}
		want := int64(i + 3)
		if hours == 1 {
			want = 2
		}
		if list.RangeHours != hours || list.Totals[0].Visits != want || list.Totals[0].NotFound != int64(i+1) {
			t.Fatalf("wrong %dh total: %s", hours, rec.Body.String())
		}
		var sum int64
		for _, hour := range list.Hours {
			sum += hour.Visits
		}
		if sum != want {
			t.Fatal("hour rows disagree with range total")
		}
		rec = httptest.NewRecorder()
		s.adminAccessLogRankings(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
		var rank struct {
			Visits, NotFound int64
			TopClients       []accessClient
			TopURLs          []accessRank
			Hour             string
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &rank) != nil || rank.Visits != want || rank.NotFound != int64(i+1) || rank.Hour != "" {
			t.Fatal("incorrect range rankings", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "foreign") || (hours == 1 && strings.Contains(rec.Body.String(), "before-boundary")) {
			t.Fatal("ranking window leaked records", rec.Body.String())
		}
		// Hour details remain clipped to the exact selected interval.
		if hours == 1 {
			query.Set("hour", time.Unix(accessHourStart(now.Add(-time.Hour+time.Second), a.location), 0).Format(time.RFC3339))
			rec = httptest.NewRecorder()
			s.adminAccessLogHour(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
			if strings.Contains(rec.Body.String(), "before-boundary") || !strings.Contains(rec.Body.String(), "after-boundary") {
				t.Fatal("hour boundary not clipped", rec.Body.String())
			}
		}
	}
}

func TestAccessLogsSevenDayCleanupAndLegacyMigration(t *testing.T) {
	dir := t.TempDir()
	database := filepath.Join(t.TempDir(), "db")
	legacy, err := sql.Open("sqlite", database+".access.db")
	if err != nil {
		t.Fatal(err)
	}
	_, err = legacy.Exec(`CREATE TABLE access_counts(hour INTEGER NOT NULL,domain TEXT NOT NULL,status INTEGER NOT NULL,ip TEXT NOT NULL,ua TEXT NOT NULL,url TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(hour,domain,status,ip,ua,url)) WITHOUT ROWID`)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Truncate(time.Second)
	for _, age := range []time.Duration{time.Hour, 8 * 24 * time.Hour} {
		if _, err = legacy.Exec("INSERT INTO access_counts VALUES(?,?,?,?,?,?,?)", now.Add(-age).Unix(), "a.test", 200, "192.0.2.1", "UA", "/", 10); err != nil {
			t.Fatal(err)
		}
	}
	legacy.Close()
	a := logTestService(t, database, dir, 86400)
	logTestCount(t, a, 10)
	if a.snapshot().Retention != 7 {
		t.Fatal("retention must always be seven days")
	}
	cutoff := now.Add(-accessLogRetention).Unix()
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
