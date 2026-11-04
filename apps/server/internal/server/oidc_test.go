package server

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	oidclib "github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

type oidcBrowserFlow struct {
	id, csrf string
	cookie   *http.Cookie
	query    url.Values
}

func oidcTestClient(f *fixture, id string) (AuthClientConfig, string) {
	c, secret := appTestClient(f, id)
	c.Name = "通用测试应用"
	c.Revision = randomToken()
	c.OIDC = &OIDCClient{Enabled: true, RedirectURIs: []string{"https://client.example/callback"}, Scopes: []string{"openid", "profile"}, RequirePKCE: true, AuthMethod: "client_secret_basic"}
	if e := f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil }); e != nil {
		f.t.Fatal(e)
	}
	return c, secret
}
func oidcRequest(f *fixture, method, path, body string, cookie *http.Cookie, basicID, basicSecret, bearer string) *httptest.ResponseRecorder {
	f.t.Helper()
	r := httptest.NewRequest(method, f.s.config.PublicURL+path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.Header.Set("Origin", f.s.config.PublicURL)
	if cookie != nil {
		r.AddCookie(cookie)
	}
	if basicID != "" {
		r.SetBasicAuth(basicID, basicSecret)
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	return w
}
func oidcQuery(c AuthClientConfig) url.Values {
	return url.Values{"client_id": {c.ID}, "redirect_uri": {c.OIDC.RedirectURIs[0]}, "response_type": {"code"}, "scope": {"openid profile"}, "state": {"opaque state & value"}, "nonce": {"client nonce"}, "code_challenge": {oauth2.S256ChallengeFromVerifier(strings.Repeat("x", 43))}, "code_challenge_method": {"S256"}}
}
func startOIDC(f *fixture, q url.Values) oidcBrowserFlow {
	f.t.Helper()
	w := oidcRequest(f, "GET", "/oidc/authorize?"+q.Encode(), "", nil, "", "", "")
	if w.Code != 303 || !strings.HasPrefix(w.Header().Get("Location"), "/oidc/requests/") {
		f.t.Fatalf("authorize: %d %s %s", w.Code, w.Body.String(), w.Header().Get("Location"))
	}
	flow := oidcBrowserFlow{id: strings.TrimPrefix(w.Header().Get("Location"), "/oidc/requests/"), query: q}
	for _, c := range w.Result().Cookies() {
		if c.Name == f.s.oidcCookieName() {
			flow.cookie = c
		}
	}
	if flow.cookie == nil || !flow.cookie.HttpOnly || !flow.cookie.Secure {
		f.t.Fatal("unsafe binding cookie")
	}
	page := oidcRequest(f, "GET", "/oidc/requests/"+flow.id, "", flow.cookie, "", "", "")
	m := regexp.MustCompile(`name="csrf" value="([^"]+)"`).FindStringSubmatch(page.Body.String())
	if page.Code != 200 || len(m) != 2 {
		f.t.Fatalf("consent page: %d %s", page.Code, page.Body.String())
	}
	flow.csrf = html.UnescapeString(m[1])
	if strings.Contains(page.Body.String(), flow.cookie.Value) || !strings.Contains(page.Body.String(), q.Get("scope")) {
		f.t.Fatal("page leaks cookie or lacks requested scope")
	}
	if !strings.Contains(page.Body.String(), "v%3d3") && !strings.Contains(html.UnescapeString(page.Body.String()), "v=3") {
		f.t.Fatalf("missing v3 same-device link: %s", page.Body.String())
	}
	return flow
}
func finishOIDC(f *fixture, b oidcBrowserFlow, action string) *httptest.ResponseRecorder {
	return oidcRequest(f, "POST", "/oidc/requests/"+b.id+"/complete", url.Values{"csrf": {b.csrf}, "action": {action}}.Encode(), b.cookie, "", "", "")
}
func approvedOIDCCode(f *fixture, c AuthClientConfig) (oidcBrowserFlow, string) {
	f.t.Helper()
	b := startOIDC(f, oidcQuery(c))
	approveLogin(f, qrStart{ID: b.id})
	w := finishOIDC(f, b, "continue")
	u, _ := url.Parse(w.Header().Get("Location"))
	if w.Code != 303 || u.Query().Get("code") == "" || u.Query().Get("state") != b.query.Get("state") {
		f.t.Fatalf("completion: %d %s %s", w.Code, w.Body.String(), w.Header().Get("Location"))
	}
	return b, u.Query().Get("code")
}
func tokenForm(c AuthClientConfig, code string) url.Values {
	return url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {c.OIDC.RedirectURIs[0]}, "code_verifier": {strings.Repeat("x", 43)}}
}
func exchangeOIDC(f *fixture, c AuthClientConfig, secret, code string) *httptest.ResponseRecorder {
	return oidcRequest(f, "POST", "/oidc/token", tokenForm(c, code).Encode(), nil, c.ID, secret, "")
}
func oidcAccess(f *fixture, w *httptest.ResponseRecorder) string {
	f.t.Helper()
	var v map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &v)
	if w.Code != 200 {
		f.t.Fatalf("token response %d %s", w.Code, w.Body.String())
	}
	return v["access_token"].(string)
}

func TestOIDCIndependentClientEndToEnd(t *testing.T) {
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "generic-client")
	ctx := oidclib.ClientContext(context.Background(), f.http.Client())
	provider, e := oidclib.NewProvider(ctx, f.s.config.PublicURL)
	if e != nil {
		t.Fatal(e)
	}
	config := oauth2.Config{ClientID: c.ID, ClientSecret: secret, RedirectURL: c.OIDC.RedirectURIs[0], Scopes: []string{"openid", "profile"}, Endpoint: provider.Endpoint()}
	config.Endpoint.AuthStyle = oauth2.AuthStyleInHeader
	verifier := oauth2.GenerateVerifier()
	authURL, e := url.Parse(config.AuthCodeURL("independent-state", oauth2.S256ChallengeOption(verifier), oidclib.Nonce("independent-nonce")))
	if e != nil {
		t.Fatal(e)
	}
	b := startOIDC(f, authURL.Query())
	if finishOIDC(f, b, "continue").Code != 409 {
		t.Fatal("implicit approval")
	}
	// Reading the request only marks scanned; it must not issue a code.
	info := inspectLogin(f, b.id)
	if finishOIDC(f, b, "continue").Code != 409 {
		t.Fatal("inspection approved")
	}
	status, data := f.call("POST", "/api/v1/auth/web-login/requests/"+b.id+"/approve", map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
	if status != 200 {
		t.Fatalf("approve %d %s", status, data)
	}
	callback := finishOIDC(f, b, "continue")
	u, _ := url.Parse(callback.Header().Get("Location"))
	if callback.Code != 303 || u.Query().Get("state") != "independent-state" {
		t.Fatal("state not preserved")
	}
	token, e := config.Exchange(ctx, u.Query().Get("code"), oauth2.VerifierOption(verifier))
	if e != nil {
		t.Fatal(e)
	}
	raw, _ := token.Extra("id_token").(string)
	verified, e := provider.Verifier(&oidclib.Config{ClientID: c.ID}).Verify(ctx, raw)
	if e != nil {
		t.Fatal(e)
	}
	var claims map[string]any
	if e = verified.Claims(&claims); e != nil {
		t.Fatal(e)
	}
	var sub string
	f.s.store.inspect(func(st state) { sub = st.Subject })
	if verified.Subject != sub || verified.Nonce != "independent-nonce" || claims["name"] != "owner" || claims["email"] != nil || claims["email_verified"] != nil || verified.Expiry.Sub(verified.IssuedAt) != 5*time.Minute {
		t.Fatalf("unexpected verified claims: %v", claims)
	}
	user, e := provider.UserInfo(ctx, oauth2.StaticTokenSource(token))
	if e != nil || user.Subject != sub {
		t.Fatalf("userinfo %v %v", user, e)
	}
	if _, e = provider.Verifier(&oidclib.Config{ClientID: "another-client"}).Verify(ctx, raw); e == nil {
		t.Fatal("wrong audience accepted")
	}
	parts := strings.Split(raw, ".")
	parts[1] = raw64.EncodeToString([]byte(`{"sub":"forged"}`))
	if _, e = provider.Verifier(&oidclib.Config{ClientID: c.ID}).Verify(ctx, strings.Join(parts, ".")); e == nil {
		t.Fatal("tampered JWT accepted")
	}
	if exchangeOIDC(f, c, secret, u.Query().Get("code")).Code != 400 {
		t.Fatal("code replay")
	}
	if oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", f.tokens.AccessToken).Code != 401 {
		t.Fatal("Console token accepted as OIDC access")
	}
	if appCall(f, c, secret, "GET", "/session", "", token.AccessToken, nil).Code != 401 {
		t.Fatal("OIDC token accepted as application session")
	}
	if oidcRequest(f, "GET", "/admin/api/agents", "", &http.Cookie{Name: f.s.adminCookieName(), Value: token.AccessToken}, "", "", "").Code != 401 {
		t.Fatal("OIDC token accepted as admin Cookie")
	}
}

func TestOIDCParameterAndRedirectValidation(t *testing.T) {
	cases := []struct {
		name, key, value, expected string
		local                      bool
	}{
		{"unknown-client", "client_id", "missing", "", true}, {"redirect-prefix", "redirect_uri", "https://client.example/callback/evil", "", true}, {"redirect-query", "redirect_uri", "https://client.example/callback?next=evil", "", true}, {"open-redirect", "redirect_uri", "https://evil.example/callback", "", true},
		{"response-type", "response_type", "token", "unsupported_response_type", false}, {"email-scope", "scope", "openid email", "invalid_scope", false}, {"no-openid", "scope", "profile", "invalid_scope", false}, {"duplicate-scope", "scope", "openid openid", "invalid_scope", false}, {"plain-pkce", "code_challenge_method", "plain", "invalid_request", false}, {"missing-pkce", "code_challenge", "", "invalid_request", false}, {"mode", "response_mode", "fragment", "invalid_request", false}, {"prompt", "prompt", "select_account", "invalid_request", false}, {"none", "prompt", "none", "interaction_required", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t, true)
			c, _ := oidcTestClient(f, "client")
			q := oidcQuery(c)
			q.Set(tc.key, tc.value)
			w := oidcRequest(f, "GET", "/oidc/authorize?"+q.Encode(), "", nil, "", "", "")
			u, _ := url.Parse(w.Header().Get("Location"))
			if tc.local {
				if w.Code != 400 || w.Header().Get("Location") != "" {
					t.Fatal("unsafe error redirect")
				}
			} else if w.Code != 303 || u.Query().Get("error") != tc.expected || u.Query().Get("state") != q.Get("state") {
				t.Fatalf("invalid error: %d %s", w.Code, w.Header().Get("Location"))
			}
		})
	}
	f := newFixture(t, true)
	c, _ := oidcTestClient(f, "client")
	for _, suffix := range []string{"&client_id=client", "&scope=openid", "&claims=%7B%7D", "&request_uri=https://evil.example", "&max_age=0", "&bad=%ZZ", "&nonce=" + strings.Repeat("a", 2049), "&state=%00"} {
		w := oidcRequest(f, "GET", "/oidc/authorize?"+oidcQuery(c).Encode()+suffix, "", nil, "", "", "")
		if w.Code != 400 || w.Header().Get("Location") != "" {
			t.Fatalf("malformed request accepted: %s", suffix)
		}
	}
	ordinary, _ := appTestClient(f, "qr-only")
	q := oidcQuery(c)
	q.Set("client_id", ordinary.ID)
	if oidcRequest(f, "GET", "/oidc/authorize?"+q.Encode(), "", nil, "", "", "").Code != 400 {
		t.Fatal("QR-only client used OIDC")
	}
	for _, uri := range []string{"http://localhost:3311/callback", "http://127.0.0.1:1/cb", "http://[::1]:3000/cb", "https://app.example/cb?fixed=1"} {
		v := *c.OIDC
		v.RedirectURIs = []string{uri}
		if validateOIDCClient(&v) != nil {
			t.Errorf("valid redirect rejected: %s", uri)
		}
	}
	for _, uri := range []string{"http://192.168.0.2/cb", "http://app.local/cb", "https://app.example/*", "https://app.example/cb#", "https://user@app.example/cb", "https://app.example/cb?code=x", "https://app.example:0/cb"} {
		v := *c.OIDC
		v.RedirectURIs = []string{uri}
		if validateOIDCClient(&v) == nil {
			t.Errorf("unsafe redirect accepted: %s", uri)
		}
	}
}
func TestOIDCBrowserBindingCSRFAndLifecycle(t *testing.T) {
	for _, scenario := range []string{"deny", "cancel", "expiry", "approver", "client-disable", "client-rotate", "client-redirect"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t, true)
			c, _ := oidcTestClient(f, "client")
			b := startOIDC(f, oidcQuery(c))
			path := "/oidc/requests/" + b.id
			for _, suffix := range []string{"", "/qr", "/status"} {
				if oidcRequest(f, "GET", path+suffix, "", nil, "", "", "").Code != 404 {
					t.Fatal("public request ID bypassed browser cookie")
				}
			}
			if finishOIDC(f, oidcBrowserFlow{id: b.id, csrf: b.csrf, cookie: &http.Cookie{Name: b.cookie.Name, Value: randomToken()}}, "continue").Code != 404 {
				t.Fatal("cross-browser redemption")
			}
			saved := b.csrf
			b.csrf = randomToken()
			if finishOIDC(f, b, "cancel").Code != 400 {
				t.Fatal("CSRF bypass")
			}
			b.csrf = saved
			info := inspectLogin(f, b.id)
			action := "continue"
			if scenario == "deny" {
				status, _ := f.call("POST", "/api/v1/auth/web-login/requests/"+b.id+"/deny", map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
				if status != 200 {
					t.Fatal("denial failed")
				}
			} else {
				approveLogin(f, qrStart{ID: b.id})
			}
			switch scenario {
			case "cancel":
				action = "cancel"
			case "expiry":
				f.s.adminMu.Lock()
				f.s.adminLogins[digest(b.id)].Expires = time.Now().Add(-time.Second)
				f.s.adminMu.Unlock()
			case "approver":
				f.s.store.update(func(st *state) error { delete(st.Sessions, f.tokens.SessionID); return nil })
			case "client-disable", "client-rotate", "client-redirect":
				f.s.store.update(func(st *state) error {
					x := st.AuthClients[c.ID]
					x.Revision = randomToken()
					if scenario == "client-disable" {
						x.Enabled = false
					}
					if scenario == "client-rotate" {
						x.SecretHash = digest(randomToken())
					}
					st.AuthClients[c.ID] = x
					return nil
				})
			}
			w := finishOIDC(f, b, action)
			u, _ := url.Parse(w.Header().Get("Location"))
			if w.Code != 303 || u.Query().Get("error") != "access_denied" || u.Query().Get("code") != "" {
				t.Fatalf("lifecycle %d %s", w.Code, w.Header().Get("Location"))
			}
		})
	}
}
func TestOIDCCodeAndClientAuthentication(t *testing.T) {
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "client")
	other, otherSecret := oidcTestClient(f, "other")
	_, code := approvedOIDCCode(f, c)
	if exchangeOIDC(f, other, otherSecret, code).Code != 400 {
		t.Fatal("cross-client exchange")
	}
	malformed := httptest.NewRequest("POST", f.s.config.PublicURL+"/oidc/token", strings.NewReader(tokenForm(c, code).Encode()))
	malformed.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	malformed.Header.Set("Authorization", "Basic !!!")
	badAuth := httptest.NewRecorder()
	f.s.ServeHTTP(badAuth, malformed)
	if badAuth.Code != 401 || badAuth.Header().Get("WWW-Authenticate") == "" {
		t.Fatal("malformed Basic authentication lacks standard challenge")
	}
	if exchangeOIDC(f, c, randomToken(), code).Code != 401 {
		t.Fatal("bad client secret")
	}
	q := tokenForm(c, code)
	q.Set("code_verifier", strings.Repeat("z", 43))
	if oidcRequest(f, "POST", "/oidc/token", q.Encode(), nil, c.ID, secret, "").Code != 400 {
		t.Fatal("wrong verifier")
	}
	q = tokenForm(c, code)
	q.Set("redirect_uri", c.OIDC.RedirectURIs[0]+"/")
	if oidcRequest(f, "POST", "/oidc/token", q.Encode(), nil, c.ID, secret, "").Code != 400 {
		t.Fatal("wrong redirect")
	}
	q = tokenForm(c, code)
	q.Set("grant_type", "refresh_token")
	if oidcRequest(f, "POST", "/oidc/token", q.Encode(), nil, c.ID, secret, "").Code != 400 {
		t.Fatal("unsupported grant")
	}
	q = tokenForm(c, code)
	q.Set("client_secret", secret)
	if oidcRequest(f, "POST", "/oidc/token", q.Encode(), nil, c.ID, secret, "").Code != 400 {
		t.Fatal("mixed authentication")
	}
	if oidcRequest(f, "POST", "/oidc/token", tokenForm(c, code).Encode()+"&code=duplicate", nil, c.ID, secret, "").Code != 400 {
		t.Fatal("duplicate token parameter")
	}
	access := oidcAccess(f, exchangeOIDC(f, c, secret, code))
	if exchangeOIDC(f, c, secret, code).Code != 400 {
		t.Fatal("replay")
	}
	if oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", access).Code != 200 {
		t.Fatal("valid access rejected")
	}
	// Independently registered post client; no implicit fallback from basic.
	c.OIDC.AuthMethod = "client_secret_post"
	f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
	_, code = approvedOIDCCode(f, c)
	if exchangeOIDC(f, c, secret, code).Code != 401 {
		t.Fatal("authentication downgrade")
	}
	q = tokenForm(c, code)
	q.Set("client_id", c.ID)
	q.Set("client_secret", secret)
	oidcAccess(f, oidcRequest(f, "POST", "/oidc/token", q.Encode(), nil, "", "", ""))
	_, code = approvedOIDCCode(f, other)
	f.s.adminMu.Lock()
	g := f.s.oidc.codes[digest(code)]
	g.Expires = time.Now().Add(-time.Second)
	f.s.oidc.codes[digest(code)] = g
	f.s.adminMu.Unlock()
	if exchangeOIDC(f, other, otherSecret, code).Code != 400 {
		t.Fatal("expired code")
	}
}
func TestOIDCGrantRevocationAndConcurrentExchange(t *testing.T) {
	for _, scenario := range []string{"console", "device", "disable", "rotate", "redirect", "revoke", "expiry"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t, true)
			c, secret := oidcTestClient(f, "client")
			_, code := approvedOIDCCode(f, c)
			access := oidcAccess(f, exchangeOIDC(f, c, secret, code))
			_, pending := approvedOIDCCode(f, c)
			switch scenario {
			case "console":
				f.s.store.update(func(st *state) error { delete(st.Sessions, f.tokens.SessionID); return nil })
			case "device":
				f.s.store.update(func(st *state) error { st.Registry.Consoles = nil; return nil })
			case "disable", "rotate", "redirect":
				a := loginAdmin(f)
				if scenario == "disable" {
					a.call("PATCH", "applications/"+c.ID, map[string]bool{"enabled": false}, 200)
				} else if scenario == "rotate" {
					a.call("POST", "applications/"+c.ID+"/rotate", struct{}{}, 200)
				} else {
					v := *c.OIDC
					v.RedirectURIs = []string{"https://client.example/new-callback"}
					a.call("PATCH", "applications/"+c.ID, map[string]any{"oidc": v}, 200)
				}
			case "revoke":
				f.s.adminMu.Lock()
				id := f.s.oidc.access[digest(access)].ID
				f.s.adminMu.Unlock()
				status, _ := f.call("DELETE", "/api/v1/web-sessions/"+id, nil, f.tokens.AccessToken)
				if status != 200 {
					t.Fatal("revoke failed")
				}
			case "expiry":
				f.s.adminMu.Lock()
				g := f.s.oidc.access[digest(access)]
				g.Expires = time.Now().Add(-time.Second)
				f.s.oidc.access[digest(access)] = g
				f.s.adminMu.Unlock()
			}
			if oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", access).Code != 401 {
				t.Fatal("revoked access used")
			}
			if scenario != "revoke" && scenario != "expiry" && exchangeOIDC(f, c, secret, pending).Code == 200 {
				t.Fatal("revoked code exchanged")
			}
		})
	}
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "client")
	_, code := approvedOIDCCode(f, c)
	var wg sync.WaitGroup
	responses := make(chan int, 8)
	for range 8 {
		wg.Go(func() { responses <- exchangeOIDC(f, c, secret, code).Code })
	}
	wg.Wait()
	close(responses)
	success := 0
	for status := range responses {
		if status == 200 {
			success++
		}
	}
	if success != 1 {
		t.Fatalf("concurrent code use: %d", success)
	}
}
func TestOIDCSigningKeyAndSubjectRestartRecovery(t *testing.T) {
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "client")
	_, code := approvedOIDCCode(f, c)
	w := exchangeOIDC(f, c, secret, code)
	access := oidcAccess(f, w)
	var result map[string]any
	json.Unmarshal(w.Body.Bytes(), &result)
	keyID := f.s.oidc.jwk.KeyID
	var subject, key string
	f.s.store.inspect(func(st state) { subject = st.Subject; key = st.OIDCKey })
	config := f.s.config
	if e := f.s.Close(); e != nil {
		t.Fatal(e)
	}
	config.Username = "renamed"
	restarted, e := New(config)
	if e != nil {
		t.Fatal(e)
	}
	defer restarted.Close()
	if restarted.oidc.jwk.KeyID != keyID {
		t.Fatal("key changed on restart")
	}
	restarted.store.inspect(func(st state) {
		if st.Subject != subject || st.OIDCKey != key {
			t.Fatal("stable identity/key changed")
		}
	})
	restoredHTTP := httptest.NewTLSServer(restarted)
	defer restoredHTTP.Close()
	ctx := oidclib.ClientContext(context.Background(), restoredHTTP.Client())
	set := oidclib.NewRemoteKeySet(ctx, restoredHTTP.URL+"/oidc/jwks")
	verifier := oidclib.NewVerifier(config.PublicURL, set, &oidclib.Config{ClientID: c.ID, SupportedSigningAlgs: []string{"RS256"}})
	if _, e := verifier.Verify(ctx, result["id_token"].(string)); e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("GET", config.PublicURL+"/oidc/userinfo", nil)
	r.Header.Set("Authorization", "Bearer "+access)
	out := httptest.NewRecorder()
	restarted.ServeHTTP(out, r)
	if out.Code != 401 {
		t.Fatal("access survived restart")
	}
	encrypted, e := os.ReadFile(config.Database)
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(string(encrypted), key) {
		t.Fatal("plaintext signing key on disk")
	}
}
func TestOIDCDiscoveryAndJWKSAdvertiseOnlyImplementedCapabilities(t *testing.T) {
	f := newFixture(t, true)
	r := httptest.NewRequest("GET", "https://untrusted.example/.well-known/openid-configuration", nil)
	r.Header.Set("X-Forwarded-Host", "evil.example")
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	var doc map[string]any
	json.Unmarshal(w.Body.Bytes(), &doc)
	if w.Code != 200 || doc["issuer"] != f.s.config.PublicURL || doc["end_session_endpoint"] != nil || doc["registration_endpoint"] != nil || strings.Contains(w.Body.String(), "refresh_token") || strings.Contains(w.Body.String(), "email") {
		t.Fatalf("incorrect discovery %s", w.Body.String())
	}
	w = oidcRequest(f, "GET", "/oidc/jwks", "", nil, "", "", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), `"d":`) || !strings.Contains(w.Body.String(), `"kid":`) || !strings.Contains(w.Body.String(), `"alg":"RS256"`) {
		t.Fatalf("unsafe JWKS: %s", w.Body.String())
	}
}
func TestOIDCPendingCodeCanBeIndependentlyRevoked(t *testing.T) {
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "client")
	_, code := approvedOIDCCode(f, c)
	items, _ := listedSessions(f)
	var id string
	for _, item := range items {
		if item.Type == "application" {
			id = item.ID
		}
	}
	if id == "" {
		t.Fatal("approved grant missing from Console session management")
	}
	status, _ := f.call("DELETE", "/api/v1/web-sessions/"+id, nil, f.tokens.AccessToken)
	if status != 200 || exchangeOIDC(f, c, secret, code).Code != 400 {
		t.Fatal("revoked grant exchanged")
	}
}
func TestOIDCConcurrentInvalidationCannotRestoreGrant(t *testing.T) {
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "client")
	admin := loginAdmin(f)
	_, code := approvedOIDCCode(f, c)
	var wg sync.WaitGroup
	var token string
	wg.Go(func() {
		w := exchangeOIDC(f, c, secret, code)
		if w.Code == 200 {
			var body map[string]any
			json.Unmarshal(w.Body.Bytes(), &body)
			token, _ = body["access_token"].(string)
		}
	})
	wg.Go(func() { admin.call("POST", "applications/"+c.ID+"/rotate", struct{}{}, 200) })
	wg.Wait()
	if token != "" && oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", token).Code != 401 {
		t.Fatal("concurrent rotation restored an old access grant")
	}
}
func TestOIDCOptionalPKCEAndMinimalIdentity(t *testing.T) {
	f := newFixture(t, true)
	c, secret := oidcTestClient(f, "client")
	c.OIDC.RequirePKCE = false
	c.OIDC.Scopes = []string{"openid"}
	f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
	q := oidcQuery(c)
	q.Del("code_challenge")
	q.Del("code_challenge_method")
	q.Del("nonce")
	q.Set("scope", "openid")
	b := startOIDC(f, q)
	approveLogin(f, qrStart{ID: b.id})
	done := finishOIDC(f, b, "continue")
	u, _ := url.Parse(done.Header().Get("Location"))
	form := tokenForm(c, u.Query().Get("code"))
	form.Del("code_verifier")
	w := oidcRequest(f, "POST", "/oidc/token", form.Encode(), nil, c.ID, secret, "")
	token := oidcAccess(f, w)
	info := oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", token)
	var body map[string]any
	json.Unmarshal(info.Body.Bytes(), &body)
	if len(body) != 1 || body["sub"] == nil {
		t.Fatalf("profile escaped scope: %s", info.Body.String())
	}
	q.Set("scope", "openid profile")
	out := oidcRequest(f, "GET", "/oidc/authorize?"+q.Encode(), "", nil, "", "", "")
	u, _ = url.Parse(out.Header().Get("Location"))
	if u.Query().Get("error") != "invalid_scope" {
		t.Fatal("client scope restriction ignored")
	}
}
func TestOIDCCallbackRegistrationPolicy(t *testing.T) {
	f := newFixture(t, true)
	c, _ := oidcTestClient(f, "client")
	config := *c.OIDC
	config.RedirectURIs = []string{"http://127.0.0.1:3000/callback"}
	a := loginAdmin(f)
	a.call("PATCH", "applications/"+c.ID, map[string]any{"oidc": config}, 400)
	dev := &Server{config: Config{PublicURL: "http://localhost:8080"}}
	if dev.validateOIDCRegistration(&config) != nil {
		t.Fatal("loopback development callback rejected")
	}
	config.RedirectURIs = []string{"http://192.168.0.1:3000/callback"}
	if dev.validateOIDCRegistration(&config) == nil {
		t.Fatal("LAN HTTP callback accepted")
	}
}
func TestOIDCBrowserReplacementOriginAndBoundedState(t *testing.T) {
	f := newFixture(t, true)
	c, _ := oidcTestClient(f, "client")
	b := startOIDC(f, oidcQuery(c))
	// A forged form from another site cannot cancel or finish the flow.
	r := httptest.NewRequest("POST", f.s.config.PublicURL+"/oidc/requests/"+b.id+"/complete", strings.NewReader(url.Values{"csrf": {b.csrf}, "action": {"cancel"}}.Encode()))
	r.AddCookie(b.cookie)
	r.Header.Set("Origin", "https://evil.example")
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	out := httptest.NewRecorder()
	f.s.ServeHTTP(out, r)
	if out.Code != 403 {
		t.Fatal("foreign origin accepted")
	}
	replacement := oidcRequest(f, "GET", "/oidc/authorize?"+oidcQuery(c).Encode(), "", b.cookie, "", "", "")
	if replacement.Code != 303 || finishOIDC(f, b, "continue").Code != 404 {
		t.Fatal("old browser request survived replacement")
	}
	f.s.adminMu.Lock()
	for i := 0; i < 256; i++ {
		f.s.oidc.codes[fmt.Sprint(i)] = oidcGrant{Expires: time.Now().Add(time.Minute)}
	}
	f.s.adminMu.Unlock()
	b = startOIDC(f, oidcQuery(c))
	approveLogin(f, qrStart{ID: b.id})
	if finishOIDC(f, b, "continue").Code != 429 {
		t.Fatal("code capacity exceeded")
	}
	f.s.adminMu.Lock()
	for k, g := range f.s.oidc.codes {
		g.Expires = time.Now().Add(-time.Second)
		f.s.oidc.codes[k] = g
	}
	f.s.adminMu.Unlock()
	if finishOIDC(f, b, "continue").Code != 303 {
		t.Fatal("expired codes were not cleaned")
	}
}
