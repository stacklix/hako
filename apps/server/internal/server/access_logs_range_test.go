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
	a := importTestAccessLogs(t, dir)
	s := &Server{accessLogs: a}
	for i, hours := range []int{1, 3, 6, 12, 24, 72, 168} {
		query := url.Values{"rangeHours": {fmt.Sprint(hours)}, "domain": {"a.test"}, "from": {now.Add(-time.Duration(hours) * time.Hour).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}}
		rec := httptest.NewRecorder()
		s.adminAccessLogs(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
		var list struct {
			RangeHours    int
			Totals, Hours []accesslog.Hour
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &list) != nil || len(list.Totals) != 1 {
			t.Fatal(rec.Code, rec.Body.String())
		}
		want := int64(i + 3)
		if hours == 1 {
			want = 2
		}
		if list.RangeHours != hours || list.Totals[0].Visits != want || list.Totals[0].NonSuccess != int64(i+1) {
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
			Visits, NonSuccess int64
			TopClients         []accesslog.Client
			TopURLs            []accesslog.Rank
			Hour               string
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &rank) != nil || rank.Visits != want || rank.NonSuccess != int64(i+1) || rank.Hour != "" {
			t.Fatal("incorrect range rankings", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "foreign") || (hours == 1 && strings.Contains(rec.Body.String(), "before-boundary")) {
			t.Fatal("ranking window leaked records", rec.Body.String())
		}
		// Hour details remain clipped to the exact selected interval.
		if hours == 1 {
			query.Set("hour", time.Unix(testAccessHourStart(now.Add(-time.Hour+time.Second), a.Location()), 0).Format(time.RFC3339))
			rec = httptest.NewRecorder()
			s.adminAccessLogHour(rec, httptest.NewRequest("GET", "/?"+query.Encode(), nil))
			if strings.Contains(rec.Body.String(), "before-boundary") || !strings.Contains(rec.Body.String(), "after-boundary") {
				t.Fatal("hour boundary not clipped", rec.Body.String())
			}
		}
	}
}
