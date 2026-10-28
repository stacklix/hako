package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

func listedSessions(f *fixture) ([]sessionSummary, []byte) {
	f.t.Helper()
	status, data := f.call("GET", "/api/v1/sessions", nil, f.tokens.AccessToken)
	if status != 200 {
		f.t.Fatalf("list sessions: %d %s", status, data)
	}
	var result struct {
		Sessions []sessionSummary `json:"sessions"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		f.t.Fatal(err)
	}
	return result.Sessions, data
}

func TestConsoleListsAndIndependentlyRevokesWebSessions(t *testing.T) {
	f := newFixture(t, true)
	first, second := loginAdmin(f), loginAdmin(f)
	f.s.adminMu.Lock()
	firstSession := f.s.adminSessions[digest(first.cookie.Value)]
	secondSession := f.s.adminSessions[digest(second.cookie.Value)]
	f.s.adminMu.Unlock()
	items, data := listedSessions(f)
	if len(items) != 3 || !items[0].Current || items[0].Type != "console" || items[0].DeviceID != f.deviceID {
		t.Fatalf("expected current Console and two browsers: %s", data)
	}
	for _, secret := range []string{first.cookie.Value, digest(first.cookie.Value), first.csrf, second.cookie.Value, second.csrf, f.tokens.AccessToken, f.tokens.RefreshToken} {
		if strings.Contains(string(data), secret) {
			t.Fatal("session listing exposed credentials")
		}
	}
	webCount := 0
	for _, item := range items {
		if item.Type != "web" {
			continue
		}
		webCount++
		if !validLoginID(item.ID) || item.Current || item.DeviceID != "" || item.Browser == "" || item.LastUsedAt == "" || item.CreatedAt == "" {
			t.Fatalf("incomplete web session metadata: %+v", item)
		}
		if item.ID != firstSession.ID && item.ID != secondSession.ID {
			t.Fatal("unknown web session returned")
		}
	}
	if webCount != 2 || firstSession.ID == secondSession.ID {
		t.Fatal("browsers must have distinct management IDs")
	}
	// A management ID cannot be substituted for the private session cookie.
	stranger := &adminClient{f: f, cookie: &http.Cookie{Name: first.cookie.Name, Value: firstSession.ID}}
	stranger.call("GET", "overview", nil, 401)
	// Console and browser revocation use separate namespaces.
	for _, path := range []string{"/api/v1/sessions/" + firstSession.ID, "/api/v1/web-sessions/" + f.tokens.SessionID} {
		status, body := f.call("DELETE", path, nil, f.tokens.AccessToken)
		if status != 200 {
			t.Fatalf("idempotent removal: %d %s", status, body)
		}
	}
	first.call("GET", "overview", nil, 200)
	for range 2 {
		status, body := f.call("DELETE", "/api/v1/web-sessions/"+firstSession.ID, nil, f.tokens.AccessToken)
		if status != 200 {
			t.Fatalf("revoke browser: %d %s", status, body)
		}
	}
	first.call("GET", "overview", nil, 401)
	second.call("GET", "overview", nil, 200)
	items, data = listedSessions(f)
	if len(items) != 2 || !items[0].Current || items[1].ID != secondSession.ID {
		t.Fatalf("revocation affected unrelated sessions: %s", data)
	}
}

func TestWebSessionManagementRequiresConsoleProof(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	f.s.adminMu.Lock()
	id := f.s.adminSessions[digest(a.cookie.Value)].ID
	f.s.adminMu.Unlock()
	for _, method := range []string{"GET", "DELETE"} {
		path := "/api/v1/sessions"
		if method == "DELETE" {
			path = "/api/v1/web-sessions/" + id
		}
		status, _ := f.call(method, path, nil, "")
		if status != 401 {
			t.Fatal("unauthenticated session management accepted")
		}
		status, _, _ = a.request(method, path, nil, f.s.config.PublicURL, a.csrf)
		if status != 401 {
			t.Fatal("browser credentials granted Console session management")
		}
	}
	originalKey := f.key
	f.key, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	status, _ := f.call("DELETE", "/api/v1/web-sessions/"+id, nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("invalid device proof revoked a browser")
	}
	f.key = originalKey
	a.call("GET", "overview", nil, 200)
}

func TestSessionListingHidesExpiredAndOrphanedBrowsersWithoutRenewingThem(t *testing.T) {
	for _, expiry := range []string{"idle", "absolute", "approver"} {
		t.Run(expiry, func(t *testing.T) {
			f := newFixture(t, true)
			a := loginAdmin(f)
			key := digest(a.cookie.Value)
			f.s.adminMu.Lock()
			before := f.s.adminSessions[key].LastUsed
			f.s.adminMu.Unlock()
			listedSessions(f)
			f.s.adminMu.Lock()
			ss := f.s.adminSessions[key]
			renewed := !ss.LastUsed.Equal(before)
			switch expiry {
			case "idle":
				ss.LastUsed = time.Now().Add(-31 * time.Minute)
			case "absolute":
				ss.Created = time.Now().Add(-13 * time.Hour)
			case "approver":
				ss.ApproverSessionID = randomToken()
			}
			f.s.adminSessions[key] = ss
			f.s.adminMu.Unlock()
			if renewed {
				t.Fatal("listing renewed a browser's idle lifetime")
			}
			items, data := listedSessions(f)
			if len(items) != 1 || !items[0].Current {
				t.Fatalf("inactive browser was listed: %s", data)
			}
			a.call("GET", "overview", nil, 401)
		})
	}
}
