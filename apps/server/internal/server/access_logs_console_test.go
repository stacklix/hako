package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"
	"time"
)

func TestConsoleAccessLogsRequireRegisteredSession(t *testing.T) {
	f := newFixture(t, true)
	for _, path := range []string{"/api/v1/access-logs", "/api/v1/access-logs/rankings", "/api/v1/access-logs/hour"} {
		for _, token := range []string{"", "invalid.token"} {
			status, _ := f.call("GET", path, nil, token)
			if status != http.StatusUnauthorized {
				t.Fatalf("%s accepted unauthorized client: %d", path, status)
			}
		}
		status, _ := f.call("POST", path, nil, f.tokens.AccessToken)
		if status != http.StatusMethodNotAllowed {
			t.Fatalf("%s accepted mutation: %d", path, status)
		}
	}
	status, data := f.call("GET", "/api/v1/access-logs", nil, f.tokens.AccessToken)
	var disabled struct{ Status accessLogStatus }
	if status != 200 || json.Unmarshal(data, &disabled) != nil || disabled.Status.Enabled {
		t.Fatal("disabled collector response", status, string(data))
	}
	// Revocation takes effect for statistics, too.
	if status, _ := f.call("POST", "/api/v1/auth/logout", nil, f.tokens.AccessToken); status != 200 {
		t.Fatal("logout failed", status)
	}
	status, _ = f.call("GET", "/api/v1/access-logs", nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("revoked session accepted", status)
	}
}

func TestConsoleAccessLogsReuseExactAdminQueries(t *testing.T) {
	f := newFixture(t, true)
	dir := t.TempDir()
	a := logTestService(t, filepath.Join(t.TempDir(), "logs"), dir, 86400)
	f.s.accessLogs = a
	t.Cleanup(func() { f.s.accessLogs = nil })
	now := time.Now().Add(-time.Minute).Truncate(time.Second)
	logTestWrite(t, filepath.Join(dir, "access.log"),
		logTestLine(now, "a.test", "192.0.2.1", "UA", "/missing?secret=hidden", 404)+
			logTestLine(now, "b.test", "192.0.2.2", "other", "/other", 200))
	a.scan()
	q := url.Values{"rangeHours": {"24"}, "domain": {"a.test"},
		"from": {now.Add(-time.Hour).Format(time.RFC3339)}, "to": {now.Add(time.Second).Format(time.RFC3339)}}
	for _, item := range []struct {
		suffix  string
		handler http.HandlerFunc
	}{
		{"", f.s.adminAccessLogs}, {"/rankings", f.s.adminAccessLogRankings}, {"/hour", f.s.adminAccessLogHour},
	} {
		query := q.Encode()
		if item.suffix == "/hour" {
			query += "&hour=" + url.QueryEscape(time.Unix(accessHourStart(now, a.location), 0).In(a.location).Format(time.RFC3339))
		}
		path := "/api/v1/access-logs" + item.suffix
		r, _ := http.NewRequest("GET", f.http.URL+path+"?"+query, nil)
		// DPoP htu excludes query and fragment, matching the native client.
		r.Header.Set("DPoP", makeProof(f.key, "GET", f.http.URL+path, f.tokens.AccessToken, randomToken()))
		r.Header.Set("X-Hako-Device", f.deviceID)
		r.Header.Set("Authorization", "DPoP "+f.tokens.AccessToken)
		response, err := f.http.Client().Do(r)
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(response.Body)
		response.Body.Close()
		admin := httptest.NewRecorder()
		item.handler(admin, httptest.NewRequest("GET", "/?"+query, nil))
		if response.StatusCode != 200 || string(data) != admin.Body.String() || response.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("%s differs from admin query: %d %s", path, response.StatusCode, data)
		}
	}
}
