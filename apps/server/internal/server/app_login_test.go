package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func appTestClient(f *fixture, id string) (AuthClientConfig, string) {
	secret := randomToken()
	c := AuthClientConfig{ID: id, Name: "iLinker", Origin: "https://notify.example.com", SecretHash: digest(secret), Enabled: true, CreatedAt: time.Now().Unix()}
	if err := f.s.store.update(func(st *state) error { st.AuthClients[id] = c; return nil }); err != nil {
		f.t.Fatal(err)
	}
	return c, secret
}

func appCall(f *fixture, c AuthClientConfig, secret, method, path, requestToken, sessionToken string, body any) *httptest.ResponseRecorder {
	data, _ := json.Marshal(body)
	r := httptest.NewRequest(method, f.s.config.PublicURL+"/api/v1/app-login"+path, bytes.NewReader(data))
	r.Header.Set("Authorization", "Bearer "+secret)
	r.Header.Set("X-Hako-Client", c.ID)
	r.Header.Set("X-Hako-Request", requestToken)
	r.Header.Set("X-Hako-Session", sessionToken)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	return w
}

type appStart struct {
	ID     string `json:"id"`
	Redeem string `json:"redeemToken"`
	QR     string `json:"qrPayload"`
}

func startApp(f *fixture, c AuthClientConfig, secret, purpose string) appStart {
	f.t.Helper()
	w := appCall(f, c, secret, "POST", "/requests", "", "", map[string]string{"purpose": purpose, "userAgent": "Firefox/1", "clientIP": "192.0.2.23"})
	var start appStart
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &start) != nil || !validLoginID(start.Redeem) || !strings.Contains(start.QR, "v=2") || strings.Contains(start.QR, start.Redeem) {
		f.t.Fatalf("invalid app QR: %d %s", w.Code, w.Body.String())
	}
	return start
}

func TestApplicationLoginAuthenticationIsolationAndSingleUse(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "ilinker")
	other, otherSecret := appTestClient(f, "other")
	if appCall(f, c, randomToken(), "POST", "/requests", "", "", map[string]string{"purpose": "login"}).Code != 401 {
		t.Fatal("invalid application secret accepted")
	}
	qr := startApp(f, c, secret, "login")
	if appCall(f, other, otherSecret, "GET", "/requests/"+qr.ID, qr.Redeem, "", nil).Code != 404 {
		t.Fatal("cross-client request access")
	}
	if appCall(f, c, secret, "GET", "/requests/"+qr.ID, "", "", nil).Code != 404 {
		t.Fatal("public QR ID substituted for private request credential")
	}
	if appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{}).Code != 409 {
		t.Fatal("unapproved request redeemed")
	}
	r := httptest.NewRequest("POST", f.s.config.PublicURL+"/api/v1/auth/web-login/requests/"+qr.ID+"/approve", strings.NewReader(`{}`))
	r.Header.Set("Authorization", "Bearer "+secret)
	r.Header.Set("X-Hako-Client", c.ID)
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	if w.Code == 200 {
		t.Fatal("application credential approved a login")
	}
	status, data := f.call("GET", "/api/v1/auth/web-login/requests/"+qr.ID, nil, f.tokens.AccessToken)
	var info map[string]string
	_ = json.Unmarshal(data, &info)
	if status != 200 || info["application"] != c.Name || info["applicationOrigin"] != c.Origin || info["purpose"] != "login" || info["clientIP"] != "192.0.2.23" {
		t.Fatalf("missing application confirmation: %s", data)
	}
	status, data = f.call("POST", "/api/v1/auth/web-login/requests/"+qr.ID+"/approve", map[string]string{"confirmationCode": info["confirmationCode"]}, f.tokens.AccessToken, info["nonce"])
	if status != 200 {
		t.Fatalf("approval: %d %s", status, data)
	}
	w = appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{})
	var grant map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &grant)
	if w.Code != 200 || !validLoginID(grant["subject"]) || !validLoginID(grant["sessionToken"]) || grant["issuer"] != f.s.config.PublicURL {
		t.Fatalf("bad grant: %s", w.Body.String())
	}
	if appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{}).Code != 404 {
		t.Fatal("grant replay accepted")
	}
	if appCall(f, other, otherSecret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("cross-client session access")
	}
	if appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 200 {
		t.Fatal("application session invalid")
	}
	// Provider tokens cannot be used as Hako admin cookies.
	r = httptest.NewRequest("GET", f.s.config.PublicURL+"/admin/api/session", nil)
	r.AddCookie(&http.Cookie{Name: f.s.adminCookieName(), Value: grant["sessionToken"]})
	w = httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("application session entered Hako admin")
	}
}

func TestApplicationSessionsAreVisibleRevocableAndBoundToApprover(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "ilinker")
	for _, revokePhone := range []bool{false, true} {
		qr := startApp(f, c, secret, "login")
		approveLogin(f, qrStart{ID: qr.ID})
		w := appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{})
		var grant map[string]string
		_ = json.Unmarshal(w.Body.Bytes(), &grant)
		status, data := f.call("GET", "/api/v1/sessions", nil, f.tokens.AccessToken)
		var list struct {
			Sessions []sessionSummary `json:"sessions"`
		}
		_ = json.Unmarshal(data, &list)
		id := ""
		for _, ss := range list.Sessions {
			if ss.Type == "application" && ss.Application == "iLinker" {
				id = ss.ID
			}
		}
		if status != 200 || id == "" || strings.Contains(string(data), grant["sessionToken"]) {
			t.Fatalf("bad session listing: %s", data)
		}
		if revokePhone {
			f.s.store.update(func(st *state) error { st.Sessions = map[string]*session{}; return nil })
		} else {
			status, _ = f.call("DELETE", "/api/v1/web-sessions/"+id, nil, f.tokens.AccessToken)
			if status != 200 {
				t.Fatal("revoke failed")
			}
		}
		if appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
			t.Fatal("revoked application session survived")
		}
	}
}

func TestApplicationBindingExpiryAndStableSubject(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "ilinker")
	qr := startApp(f, c, secret, "bind")
	approveLogin(f, qrStart{ID: qr.ID})
	w := appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{})
	var grant map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &grant)
	if w.Code != 200 || grant["sessionToken"] != "" || !validLoginID(grant["subject"]) {
		t.Fatal("binding unexpectedly issued a session")
	}
	next, err := openStore(f.s.config.Database, f.s.config.MasterKey)
	if err != nil {
		t.Fatal(err)
	}
	defer next.db.Close()
	next.inspect(func(st state) {
		if st.Subject != grant["subject"] {
			t.Fatal("subject was not persisted")
		}
	})
	qr = startApp(f, c, secret, "login")
	f.s.adminMu.Lock()
	f.s.adminLogins[digest(qr.ID)].Expires = time.Now().Add(-time.Second)
	f.s.adminMu.Unlock()
	if appCall(f, c, secret, "GET", "/requests/"+qr.ID, qr.Redeem, "", nil).Code != 410 {
		t.Fatal("expired request survived")
	}
	c.Origin = "http://unsafe.example.com"
	if validateAuthClients([]AuthClientConfig{c}) == nil {
		t.Fatal("insecure application origin accepted")
	}
}

func TestApplicationSessionsDoNotConsumeHakoAdminLoginQuota(t *testing.T) {
	f := newFixture(t, true)
	appTestClient(f, "ilinker")
	for i := 0; i < 32; i++ {
		f.s.adminSessions[randomToken()] = adminSession{ID: randomToken(), ClientID: "ilinker", Created: time.Now(), LastUsed: time.Now()}
	}
	a, qr := startLogin(f)
	approveLogin(f, qr)
	a.call("POST", "login/requests/"+qr.ID+"/complete", map[string]bool{}, 200)
}
