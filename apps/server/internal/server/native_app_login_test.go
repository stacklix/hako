package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"strings"
	"sync"
	"testing"
	"time"
)

type nativeStart struct {
	ID, RedeemToken, Issuer, ClientID, ApplicationOrigin, Nonce, CodeChallenge string
	ExpiresAt                                                                  string
}

func startNative(f *fixture, client AuthClientConfig, secret, verifier string) nativeStart {
	f.t.Helper()
	w := appCall(f, client, secret, "POST", "/native/requests", "", "", map[string]string{
		"codeChallenge": nativeChallenge(verifier), "codeChallengeMethod": "S256", "userAgent": "Hako iOS"})
	var start nativeStart
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &start) != nil || !validLoginID(start.ID) || !validLoginID(start.RedeemToken) {
		f.t.Fatalf("native start: %d %s", w.Code, w.Body.String())
	}
	return start
}

func authorizeNative(f *fixture, start nativeStart, consent bool) (int, map[string]string) {
	f.t.Helper()
	status, data := f.call("POST", "/api/v1/auth/native-app/requests/"+start.ID+"/authorize",
		map[string]any{"nonce": start.Nonce, "consent": consent}, f.tokens.AccessToken)
	var result map[string]string
	_ = json.Unmarshal(data, &result)
	return status, result
}

func nativeComplete(f *fixture, c AuthClientConfig, secret string, start nativeStart, code, verifier string) (int, map[string]string) {
	w := appCall(f, c, secret, "POST", "/native/requests/"+start.ID+"/complete", start.RedeemToken, "", map[string]string{"code": code, "codeVerifier": verifier})
	var result map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &result)
	return w.Code, result
}

func TestNativeApplicationConsentPKCEAndSingleUse(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	verifier := randomToken()
	start := startNative(f, c, secret, verifier)
	path := "/api/v1/auth/native-app/requests/" + start.ID
	if status, _ := f.call("GET", path, nil, ""); status != 401 {
		t.Fatal("unauthenticated inspection")
	}
	status, info := f.call("GET", path, nil, f.tokens.AccessToken)
	if status != 200 || strings.Contains(string(info), start.RedeemToken) || strings.Contains(string(info), "redeemToken") || !strings.Contains(string(info), c.Origin) {
		t.Fatalf("unsafe metadata: %d %s", status, info)
	}
	if status, _ := f.call("GET", "/api/v1/auth/web-login/requests/"+start.ID, nil, f.tokens.AccessToken); status != 404 {
		t.Fatal("native request entered QR path")
	}
	if status, result := authorizeNative(f, start, false); status != 409 || result["error"] != "native_consent_required" {
		t.Fatalf("missing consent bypassed: %d %v", status, result)
	}
	if status, _ := f.call("POST", path+"/authorize", map[string]any{"nonce": randomToken(), "consent": true}, f.tokens.AccessToken); status != 400 {
		t.Fatal("wrong nonce accepted")
	}
	status, code := authorizeNative(f, start, true)
	if status != 200 || !validLoginID(code["code"]) {
		t.Fatalf("authorize: %d %v", status, code)
	}
	if status, _ := authorizeNative(f, start, true); status != 409 {
		t.Fatal("authorization code minted twice")
	}
	if status, _ := nativeComplete(f, c, secret, start, code["code"], randomToken()); status != 400 {
		t.Fatal("wrong PKCE verifier accepted")
	}
	if status, _ := nativeComplete(f, c, secret, start, randomToken(), verifier); status != 400 {
		t.Fatal("wrong authorization code accepted")
	}
	status, grant := nativeComplete(f, c, secret, start, code["code"], verifier)
	if status != 200 || !validLoginID(grant["sessionToken"]) || !validLoginID(grant["subject"]) || grant["issuer"] != f.s.config.PublicURL || grant["clientId"] != c.ID || grant["purpose"] != "login" {
		t.Fatalf("native grant: %d %v", status, grant)
	}
	if status, _ := nativeComplete(f, c, secret, start, code["code"], verifier); status != 404 {
		t.Fatal("single-use grant replayed")
	}
	if w := appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil); w.Code != 200 {
		t.Fatalf("application validation: %d %s", w.Code, w.Body.String())
	}
	second := startNative(f, c, secret, randomToken())
	if status, _ := authorizeNative(f, second, false); status != 200 {
		t.Fatal("prior consent did not allow silent authorization")
	}
}

func TestNativeApplicationBackendAndQRIsolation(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	other, otherSecret := appTestClient(f, "other")
	if w := appCall(f, c, secret, "POST", "/native/requests", "", "", map[string]string{"codeChallenge": randomToken(), "codeChallengeMethod": "plain"}); w.Code != 400 {
		t.Fatal("plain PKCE accepted")
	}
	start := startNative(f, c, secret, randomToken())
	_, code := authorizeNative(f, start, true)
	if status, _ := nativeComplete(f, other, otherSecret, start, code["code"], randomToken()); status != 404 {
		t.Fatal("cross-application redemption")
	}
	if w := appCall(f, c, secret, "POST", "/native/requests/"+start.ID+"/complete", "", "", map[string]string{"code": code["code"], "codeVerifier": randomToken()}); w.Code != 404 {
		t.Fatal("missing backend credential accepted")
	}
	if w := appCall(f, c, randomToken(), "POST", "/native/requests", "", "", map[string]string{"codeChallenge": randomToken(), "codeChallengeMethod": "S256"}); w.Code != 401 {
		t.Fatal("invalid application secret")
	}
	qr := startApp(f, c, secret, "login")
	if status, _ := f.call("GET", "/api/v1/auth/native-app/requests/"+qr.ID, nil, f.tokens.AccessToken); status != 404 {
		t.Fatal("QR request entered silent native path")
	}
}

func TestNativeApplicationRevocationRemovesSilentConsent(t *testing.T) {
	for _, backendLogout := range []bool{false, true} {
		t.Run(map[bool]string{false: "console-removal", true: "backend-logout"}[backendLogout], func(t *testing.T) {
			f := newFixture(t, true)
			c, secret := appTestClient(f, "stocktrade")
			// A browser grant for the same application is independent of native consent.
			qr := startApp(f, c, secret, "login")
			_, detail := f.call("GET", "/api/v1/auth/web-login/requests/"+qr.ID, nil, f.tokens.AccessToken)
			var qrInfo map[string]string
			_ = json.Unmarshal(detail, &qrInfo)
			_, _ = f.call("POST", "/api/v1/auth/web-login/requests/"+qr.ID+"/approve", map[string]string{"confirmationCode": qrInfo["confirmationCode"]}, f.tokens.AccessToken, qrInfo["nonce"])
			webResponse := appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{})
			var webGrant map[string]string
			if webResponse.Code != 200 || json.Unmarshal(webResponse.Body.Bytes(), &webGrant) != nil {
				t.Fatal("browser setup failed")
			}
			verifier := randomToken()
			start := startNative(f, c, secret, verifier)
			_, code := authorizeNative(f, start, true)
			_, grant := nativeComplete(f, c, secret, start, code["code"], verifier)
			verifier2 := randomToken()
			second := startNative(f, c, secret, verifier2)
			_, secondCode := authorizeNative(f, second, false)
			_, secondGrant := nativeComplete(f, c, secret, second, secondCode["code"], verifier2)
			pending := startNative(f, c, secret, randomToken())
			_, _ = authorizeNative(f, pending, false)
			if backendLogout {
				if w := appCall(f, c, secret, "DELETE", "/session", "", grant["sessionToken"], nil); w.Code != 200 {
					t.Fatal("logout failed")
				}
			} else {
				id := f.s.adminSessions[digest(grant["sessionToken"])].ID
				if status, _ := f.call("DELETE", "/api/v1/web-sessions/"+id, nil, f.tokens.AccessToken); status != 200 {
					t.Fatal("revoke failed")
				}
			}
			if w := appCall(f, c, secret, "GET", "/session", "", secondGrant["sessionToken"], nil); w.Code != 401 {
				t.Fatal("sibling native session survived revocation")
			}
			if w := appCall(f, c, secret, "GET", "/session", "", webGrant["sessionToken"], nil); w.Code != 200 {
				t.Fatal("native revocation invalidated an independent browser session")
			}
			if status, _ := f.call("GET", "/api/v1/auth/native-app/requests/"+pending.ID, nil, f.tokens.AccessToken); status != 404 {
				t.Fatal("issued code survived revocation")
			}
			retry := startNative(f, c, secret, randomToken())
			if status, result := authorizeNative(f, retry, false); status != 409 || result["error"] != "native_consent_required" {
				t.Fatal("revoked authorization silently recreated")
			}
			if status, _ := authorizeNative(f, retry, true); status != 200 {
				t.Fatal("explicit reauthorization failed")
			}
		})
	}
}

func TestNativeApplicationExpirationAndConsoleLogout(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	verifier := randomToken()
	start := startNative(f, c, secret, verifier)
	_, code := authorizeNative(f, start, true)
	f.s.nativeApps.requests[digest(start.ID)].CodeExpires = time.Now().Add(-time.Second)
	if status, _ := nativeComplete(f, c, secret, start, code["code"], verifier); status != 400 {
		t.Fatal("expired code redeemed")
	}
	f.s.nativeApps.requests[digest(start.ID)].Expires = time.Now().Add(-time.Second)
	if status, _ := f.call("GET", "/api/v1/auth/native-app/requests/"+start.ID, nil, f.tokens.AccessToken); status != 410 {
		t.Fatal("expired request accepted")
	}
	start = startNative(f, c, secret, verifier)
	_, code = authorizeNative(f, start, false)
	if status, _ := f.call("POST", "/api/v1/auth/logout", nil, f.tokens.AccessToken); status != 200 {
		t.Fatal("Console logout failed")
	}
	if status, _ := nativeComplete(f, c, secret, start, code["code"], verifier); status != 400 {
		t.Fatal("logged-out Console grant redeemed")
	}
}

func TestNativeApplicationRotationInvalidatesConsentAndCodes(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	start := startNative(f, c, secret, randomToken())
	_, _ = authorizeNative(f, start, true)
	newSecret := randomToken()
	c.SecretHash = digest(newSecret)
	if err := f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil }); err != nil {
		t.Fatal(err)
	}
	f.s.invalidateApplication(c.ID)
	retry := startNative(f, c, newSecret, randomToken())
	if status, result := authorizeNative(f, retry, false); status != 409 || result["error"] != "native_consent_required" {
		t.Fatal("key rotation preserved silent consent")
	}
}

func TestNativeApplicationConcurrentCodeRedemption(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	verifier := randomToken()
	start := startNative(f, c, secret, verifier)
	_, code := authorizeNative(f, start, true)
	var group sync.WaitGroup
	statuses := make(chan int, 6)
	for i := 0; i < 6; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			status, _ := nativeComplete(f, c, secret, start, code["code"], verifier)
			statuses <- status
		}()
	}
	group.Wait()
	close(statuses)
	success := 0
	for status := range statuses {
		if status == 200 {
			success++
		} else if status != 404 {
			t.Fatalf("unexpected concurrent status %d", status)
		}
	}
	if success != 1 {
		t.Fatalf("code redeemed %d times", success)
	}
}

func TestNativeApplicationConsentVisibleAndRevocableWithoutSession(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	start := startNative(f, c, secret, randomToken())
	if status, _ := authorizeNative(f, start, true); status != 200 {
		t.Fatal("initial consent failed")
	}
	if len(f.s.adminSessions) != 0 {
		t.Fatal("authorization must not create a backend session before exchange")
	}
	f.s.nativeApps.requests[digest(start.ID)].Expires = time.Now().Add(-time.Second)
	status, data := f.call("GET", "/api/v1/sessions", nil, f.tokens.AccessToken)
	var result struct {
		Sessions []sessionSummary `json:"sessions"`
	}
	if status != 200 || json.Unmarshal(data, &result) != nil {
		t.Fatalf("sessions: %d %s", status, data)
	}
	consentID := ""
	for _, entry := range result.Sessions {
		if entry.Type == "application" && entry.Application == c.Name && entry.Browser == "Hako iOS 自动登录授权" {
			consentID = entry.ID
		}
	}
	if consentID == "" {
		t.Fatal("silent consent became invisible without a backend session")
	}
	if status, _ := f.call("DELETE", "/api/v1/web-sessions/"+consentID, nil, f.tokens.AccessToken); status != 200 {
		t.Fatal("consent group revocation failed")
	}
	retry := startNative(f, c, secret, randomToken())
	if status, body := authorizeNative(f, retry, false); status != 409 || body["error"] != "native_consent_required" {
		t.Fatal("revoked orphan consent silently recreated")
	}
}

func TestNativeApplicationConsentSurvivesNaturalSessionExpiryVisibly(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	verifier := randomToken()
	start := startNative(f, c, secret, verifier)
	_, code := authorizeNative(f, start, true)
	_, grant := nativeComplete(f, c, secret, start, code["code"], verifier)
	key := digest(grant["sessionToken"])
	session := f.s.adminSessions[key]
	consentID := session.NativeConsentID
	session.Created = time.Now().Add(-13 * time.Hour)
	f.s.adminSessions[key] = session
	status, data := f.call("GET", "/api/v1/sessions", nil, f.tokens.AccessToken)
	if status != 200 || !strings.Contains(string(data), consentID) {
		t.Fatal("natural expiry hid the silent authorization")
	}
	if _, exists := f.s.adminSessions[key]; exists {
		t.Fatal("expired native backend session was not pruned")
	}
	if status, _ := f.call("DELETE", "/api/v1/web-sessions/"+consentID, nil, f.tokens.AccessToken); status != 200 {
		t.Fatal("expired session's consent could not be revoked")
	}
	if status, _ := authorizeNative(f, startNative(f, c, secret, randomToken()), false); status != 409 {
		t.Fatal("expired revoked authorization recreated silently")
	}
}

func TestNativeApplicationConsentIsolatedBetweenConsoles(t *testing.T) {
	f := newFixture(t, true)
	c, secret := appTestClient(f, "stocktrade")
	first := startNative(f, c, secret, randomToken())
	if status, _ := authorizeNative(f, first, true); status != 200 {
		t.Fatal("first Console consent failed")
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	console, err := parseConsole(ConsoleConfig{Name: "second iPhone", PublicKeyPEM: string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))}, false)
	if err != nil {
		t.Fatal(err)
	}
	second := &fixture{t: t, s: f.s, http: f.http, key: key, deviceID: console.thumb}
	if err := f.s.store.update(func(st *state) error {
		st.Registry.Consoles = append(st.Registry.Consoles, console)
		second.tokens = f.s.newSession(st, device{ID: console.thumb, Thumb: console.thumb})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	secondStart := startNative(f, c, secret, randomToken())
	if status, _ := authorizeNative(second, secondStart, false); status != 409 {
		t.Fatal("second Console inherited first Console consent")
	}
	if status, _ := authorizeNative(second, secondStart, true); status != 200 {
		t.Fatal("second Console explicit consent failed")
	}
	firstID := ""
	for _, consent := range f.s.nativeApps.consents {
		if consent.SessionID == f.tokens.SessionID {
			firstID = consent.ID
		}
	}
	if firstID == "" {
		t.Fatal("first Console authorization missing")
	}
	if status, _ := f.call("DELETE", "/api/v1/web-sessions/"+firstID, nil, f.tokens.AccessToken); status != 200 {
		t.Fatal("first authorization revoke failed")
	}
	if status, _ := authorizeNative(f, startNative(f, c, secret, randomToken()), false); status != 409 {
		t.Fatal("first Console recreated revoked consent")
	}
	if status, _ := authorizeNative(second, startNative(f, c, secret, randomToken()), false); status != 200 {
		t.Fatal("revocation incorrectly affected other Console")
	}
}
