package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

type qrStart struct {
	ID      string `json:"id"`
	Code    string `json:"confirmationCode"`
	Payload string `json:"qrPayload"`
	Expires string `json:"expiresAt"`
}
type qrInspection struct {
	ID               string `json:"id"`
	ConfirmationCode string `json:"confirmationCode"`
	Nonce            string `json:"nonce"`
	Origin           string `json:"origin"`
	ClientIP         string `json:"clientIP"`
	Browser          string `json:"browser"`
}

func ensureConsoleLogin(f *fixture) {
	f.t.Helper()
	if f.tokens.AccessToken != "" {
		return
	}
	status, data := f.call("POST", "/api/v1/auth/challenge", map[string]string{"username": "owner", "deviceId": f.deviceID}, "")
	if status != 200 {
		f.t.Fatalf("Console challenge: %d %s", status, data)
	}
	var ch struct {
		ID    string `json:"challengeId"`
		Nonce string `json:"nonce"`
	}
	_ = json.Unmarshal(data, &ch)
	status, data = f.call("POST", "/api/v1/auth/login", map[string]string{"username": "owner", "deviceId": f.deviceID, "challengeId": ch.ID}, "", ch.Nonce)
	if status != 200 {
		f.t.Fatalf("Console login: %d %s", status, data)
	}
	_ = json.Unmarshal(data, &f.tokens)
}

func startLogin(f *fixture) (*adminClient, qrStart) {
	f.t.Helper()
	a := &adminClient{f: f}
	status, data, res := a.request("POST", "/admin/api/login/requests", map[string]bool{}, f.s.config.PublicURL, "")
	if status != 201 {
		f.t.Fatalf("QR creation: %d %s", status, data)
	}
	for _, c := range res.Cookies() {
		if c.Name == f.s.pendingCookieName() {
			a.pendingCookie = c
		}
	}
	var qr qrStart
	if json.Unmarshal(data, &qr) != nil || a.pendingCookie == nil {
		f.t.Fatal("invalid QR response")
	}
	return a, qr
}

func inspectLogin(f *fixture, id string) qrInspection {
	f.t.Helper()
	status, data := f.call("GET", "/api/v1/admin-login/requests/"+id, nil, f.tokens.AccessToken)
	if status != 200 {
		f.t.Fatalf("inspect QR: %d %s", status, data)
	}
	var info qrInspection
	if json.Unmarshal(data, &info) != nil {
		f.t.Fatal("invalid QR details")
	}
	return info
}

func approveLogin(f *fixture, qr qrStart) {
	f.t.Helper()
	info := inspectLogin(f, qr.ID)
	status, data := f.call("POST", "/api/v1/admin-login/requests/"+qr.ID+"/approve", map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
	if status != 200 {
		f.t.Fatalf("approve QR: %d %s", status, data)
	}
}

func TestQRInspectionShowsCreatingBrowserSourceIP(t *testing.T) {
	for _, forwarded := range []bool{false, true} {
		t.Run(map[bool]string{false: "direct", true: "proxy"}[forwarded], func(t *testing.T) {
			f := newFixture(t, true)
			r := httptest.NewRequest("POST", f.s.config.PublicURL+"/admin/api/login/requests", strings.NewReader("{}"))
			r.Header.Set("Origin", f.s.config.PublicURL)
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("User-Agent", "Mozilla/5.0 (iPhone) CriOS/130.0 Mobile/15E148 Safari/604.1")
			r.RemoteAddr = "198.51.100.12:54321"
			if forwarded {
				f.s.trustedProxies, _ = parseTrustedProxies("127.0.0.1")
				r.RemoteAddr = "127.0.0.1:1234"
				r.Header.Set("X-Forwarded-For", "198.51.100.12")
			}
			w := httptest.NewRecorder()
			f.s.ServeHTTP(w, r)
			if w.Code != 201 {
				t.Fatalf("create QR: %d %s", w.Code, w.Body.String())
			}
			var qr qrStart
			if err := json.Unmarshal(w.Body.Bytes(), &qr); err != nil {
				t.Fatal(err)
			}
			info := inspectLogin(f, qr.ID)
			if info.ClientIP != "198.51.100.12" || info.Browser != "Chrome" {
				t.Fatalf("inspection must use creating browser metadata: %+v", info)
			}
			if strings.Contains(w.Body.String(), "clientIP") {
				t.Fatal("unauthenticated creation response exposes source IP")
			}
		})
	}
}

func TestQRLoginBindsBrowserAndDoesNotExposeApprovalNonce(t *testing.T) {
	f := newFixture(t, true)
	a, qr := startLogin(f)
	u, err := url.Parse(qr.Payload)
	if err != nil || u.Scheme != "hako" || u.Host != "admin-login" || u.Query().Get("server") != f.s.config.PublicURL || u.Query().Get("request") != qr.ID || !validLoginID(qr.ID) || len(qr.Code) != 6 {
		t.Fatal("QR payload is invalid")
	}
	if strings.Contains(qr.Payload, a.pendingCookie.Value) || strings.Contains(qr.Payload, f.tokens.AccessToken) {
		t.Fatal("QR leaks browser or Console credentials")
	}
	if !a.pendingCookie.HttpOnly || !a.pendingCookie.Secure || a.pendingCookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("insecure pre-login cookie")
	}
	stranger := &adminClient{f: f}
	stranger.call("GET", "login/requests/"+qr.ID, nil, 404)
	stranger.call("GET", "login/requests/"+qr.ID+"/qr", nil, 404)
	stranger.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 404)
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 409)
	data := a.call("GET", "login/requests/"+qr.ID, nil, 200)
	if strings.Contains(string(data), "nonce") || strings.Contains(string(data), "confirmationCode") || strings.Contains(string(data), "clientIP") {
		t.Fatal("poll response exposes Console approval data")
	}
	status, png, res := a.request("GET", "/admin/api/login/requests/"+qr.ID+"/qr", nil, "", "")
	if status != 200 || res.Header.Get("Content-Type") != "image/png" || len(png) < 8 || string(png[1:4]) != "PNG" {
		t.Fatal("QR PNG not served")
	}
}

func TestQRLoginApprovalAndRedemptionAreSingleUse(t *testing.T) {
	f := newFixture(t, true)
	a, qr := startLogin(f)
	info := inspectLogin(f, qr.ID)
	path := "/api/v1/admin-login/requests/" + qr.ID + "/approve"
	for _, body := range []map[string]string{{"confirmationCode": "wrong"}} {
		status, _ := f.call("POST", path, body, f.tokens.AccessToken, info.Nonce)
		if status != 400 {
			t.Fatal("wrong confirmation accepted")
		}
	}
	status, _ := f.call("POST", path, map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, "wrong-nonce")
	if status != 400 {
		t.Fatal("unsigned challenge accepted")
	}
	status, _ = f.call("POST", path, map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
	if status != 200 {
		t.Fatal("approval failed")
	}
	status, _ = f.call("POST", path, map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
	if status != 409 {
		t.Fatal("approval reused")
	}
	stranger := &adminClient{f: f}
	stranger.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 404)
	data := a.call("GET", "login/requests/"+qr.ID, nil, 200)
	if !strings.Contains(string(data), "approved") {
		t.Fatal("approval not visible")
	}
	_, _, response := a.request("GET", "/admin/api/login/requests/"+qr.ID, nil, "", "")
	for _, c := range response.Cookies() {
		if c.Name == f.s.adminCookieName() {
			t.Fatal("GET polling issued a session")
		}
	}
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 200)
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 404)
}

func TestQRLoginExpiryDenialAndRefresh(t *testing.T) {
	f := newFixture(t, true)
	a, qr := startLogin(f)
	info := inspectLogin(f, qr.ID)
	status, _ := f.call("POST", "/api/v1/admin-login/requests/"+qr.ID+"/deny", map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
	if status != 200 {
		t.Fatal("denial failed")
	}
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 409)
	data := a.call("GET", "login/requests/"+qr.ID, nil, 200)
	if !strings.Contains(string(data), "denied") {
		t.Fatal("denial not visible")
	}
	a.call("POST", "login/requests", map[string]bool{}, 201)
	a.call("GET", "login/requests/"+qr.ID, nil, 404)
	a, qr = startLogin(f)
	f.s.adminMu.Lock()
	f.s.adminLogins[digest(qr.ID)].Expires = time.Now().Add(-time.Second)
	f.s.adminMu.Unlock()
	status, _ = f.call("GET", "/api/v1/admin-login/requests/"+qr.ID, nil, f.tokens.AccessToken)
	if status != 410 {
		t.Fatal("expired QR inspected")
	}
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 410)
}

func TestQRLoginApproverRevocationBeforeRedemption(t *testing.T) {
	f := newFixture(t, true)
	a, qr := startLogin(f)
	approveLogin(f, qr)
	status, _ := f.call("POST", "/api/v1/auth/logout", nil, f.tokens.AccessToken)
	if status != 200 {
		t.Fatal(status)
	}
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 403)
}

func TestQRLoginRequiresRegisteredConsole(t *testing.T) {
	f := newFixture(t, true)
	a, qr := startLogin(f)
	next, err := loadRegistry(f.s.registry.Load().Agents, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.s.saveRegistry(next); err != nil {
		t.Fatal(err)
	}
	status, _ := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("removed Console retained monitoring access")
	}
	status, _ = f.call("GET", "/api/v1/admin-login/requests/"+qr.ID, nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("removed Console inspected login")
	}
	status, _ = f.call("POST", "/api/v1/admin-login/requests/"+qr.ID+"/approve", map[string]string{"confirmationCode": qr.Code}, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("removed Console approved login")
	}
	a.call("POST", "login/requests", map[string]bool{}, 503)
}

func TestRemovedAdminKeyLoginAndConsoleMutationEndpoints(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	for _, path := range []string{"/admin/api/login", "/admin/api/consoles"} {
		status, _, _ := a.request("POST", path, map[string]string{"key": "old-admin-key"}, f.s.config.PublicURL, a.csrf)
		if status != 404 && status != 405 {
			t.Fatal("removed authentication/configuration endpoint is still active", path, status)
		}
	}
	status, _, _ := a.request("DELETE", "/admin/api/consoles/"+f.deviceID, nil, f.s.config.PublicURL, a.csrf)
	if status != 404 && status != 405 {
		t.Fatal("Console key can be removed in browser")
	}
}

func TestEveryConfiguredConsoleIsAdministrator(t *testing.T) {
	f := newFixture(t, true)
	secondKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	second, err := parseConsole(ConsoleConfig{Name: "第二台 Console", PublicKeyPEM: publicPEM(t, &secondKey.PublicKey)}, false)
	if err != nil {
		t.Fatal(err)
	}
	consoles := append(append([]ConsoleConfig{}, f.s.registry.Load().Consoles...), second)
	next, err := loadRegistry(f.s.registry.Load().Agents, consoles, false)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.s.saveRegistry(next); err != nil {
		t.Fatal(err)
	}
	first := loginAdmin(f)
	first.call("GET", "overview", nil, 200)
	f.key = secondKey
	f.deviceID = second.thumb
	f.tokens = tokens{}
	secondAdmin := loginAdmin(f)
	secondAdmin.call("GET", "overview", nil, 200)
}

func TestUnknownQRRequestsCannotFillSharedRateLimiter(t *testing.T) {
	f := newFixture(t, true)
	stranger := &adminClient{f: f}
	f.s.mu.Lock()
	before := len(f.s.limits)
	f.s.mu.Unlock()
	for i := 0; i < 40; i++ {
		stranger.call("GET", "login/requests/"+randomToken(), nil, 404)
	}
	f.s.mu.Lock()
	after := len(f.s.limits)
	f.s.mu.Unlock()
	if after != before {
		t.Fatal("unbound QR IDs allocated shared limiter entries")
	}
}
