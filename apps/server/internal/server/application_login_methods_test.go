package server

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestApplicationLoginMethodsAreExplicitAndIndependent(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	var created createdApplication
	data := a.call("POST", "applications", map[string]any{"name": "Cerno", "origin": "https://cerno.example.com"}, 201)
	if err := json.Unmarshal(data, &created); err != nil {
		t.Fatal(err)
	}
	c, _ := f.s.authClient(created.Application.ID)
	if c.QREnabled || c.NativeEnabled || c.OIDC != nil || created.Application.QREnabled || created.Application.NativeEnabled {
		t.Fatal("login methods must require explicit enablement")
	}
	oidc := &OIDCClient{RedirectURIs: []string{"https://client.example/callback"}, Scopes: []string{"openid"}, RequirePKCE: true, AuthMethod: "client_secret_basic"}
	for mask := 0; mask < 8; mask++ {
		t.Run(fmt.Sprint(mask), func(t *testing.T) {
			qr, native := mask&1 != 0, mask&2 != 0
			oidc.Enabled = mask&4 != 0
			a.call("PATCH", "applications/"+c.ID, map[string]any{"qrEnabled": qr, "nativeEnabled": native, "oidc": oidc}, 200)
			current, _ := f.s.authClient(c.ID)
			if current.QREnabled != qr || current.NativeEnabled != native || current.OIDC.Enabled != oidc.Enabled {
				t.Fatal("login method flags were coupled")
			}
			q := appCall(f, c, created.Secret, "POST", "/requests", "", "", map[string]string{"purpose": "login"})
			want := 403
			if qr {
				want = 201
			}
			if q.Code != want {
				t.Fatalf("QR: got %d, want %d", q.Code, want)
			}
			n := appCall(f, c, created.Secret, "POST", "/native/requests", "", "", map[string]string{"codeChallenge": nativeChallenge(randomToken()), "codeChallengeMethod": "S256"})
			want = 403
			if native {
				want = 201
			}
			if n.Code != want {
				t.Fatalf("native: got %d, want %d", n.Code, want)
			}
			o := oidcRequest(f, "GET", "/oidc/authorize?"+oidcQuery(current).Encode(), "", nil, "", "", "")
			if (o.Code == 303) != oidc.Enabled {
				t.Fatalf("OIDC flag ignored: %d", o.Code)
			}
		})
	}
	persisted, err := openStore(f.s.config.Database, f.s.config.MasterKey)
	if err != nil {
		t.Fatal(err)
	}
	defer persisted.db.Close()
	persisted.inspect(func(st state) {
		client := st.AuthClients[c.ID]
		if !client.QREnabled || !client.NativeEnabled || !client.OIDC.Enabled {
			t.Fatal("method flags were not persisted")
		}
	})
	// Partial updates preserve the other two independently selected methods.
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"nativeEnabled": false}, 200)
	current, _ := f.s.authClient(c.ID)
	if !current.QREnabled || current.NativeEnabled || !current.OIDC.Enabled {
		t.Fatal("partial update changed another method")
	}
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"enabled": false}, 200)
	if appCall(f, c, created.Secret, "POST", "/requests", "", "", map[string]string{"purpose": "login"}).Code != 401 {
		t.Fatal("master switch ignored")
	}
}

func TestDisablingNativeAuthorizationRevokesGrantsAndCannotRestoreThem(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	c, secret := nativeTestClient(f, "cerno")
	verifier := randomToken()
	start := startNative(f, c, secret, verifier)
	_, code := authorizeNative(f, start, true)
	status, grant := nativeComplete(f, c, secret, start, code["code"], verifier)
	if status != 200 {
		t.Fatal("initial native grant failed")
	}
	pending := startNative(f, c, secret, randomToken())
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"nativeEnabled": false}, 200)
	if appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("native session survived disabling")
	}
	if status, _ := f.call("GET", "/api/v1/auth/native-app/requests/"+pending.ID, nil, f.tokens.AccessToken); status != 404 {
		t.Fatal("pending authorization survived disabling")
	}
	// The unrelated QR method stays enabled and can start a fresh flow.
	startApp(f, c, secret, "login")
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"nativeEnabled": true}, 200)
	if appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("reenabling restored a revoked session")
	}
	fresh := startNative(f, c, secret, randomToken())
	if status, body := authorizeNative(f, fresh, false); status != 409 || body["error"] != "native_consent_required" {
		t.Fatal("reenabling restored silent consent")
	}
}

func TestNativeEndpointsRecheckCurrentMethodPolicy(t *testing.T) {
	f := newFixture(t, true)
	c, secret := nativeTestClient(f, "cerno")
	verifier := randomToken()
	start := startNative(f, c, secret, verifier)
	_, code := authorizeNative(f, start, true)
	// Simulate a policy change before request invalidation has acquired adminMu.
	if err := f.s.store.update(func(st *state) error {
		client := st.AuthClients[c.ID]
		client.NativeEnabled = false
		st.AuthClients[c.ID] = client
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if status, _ := f.call("GET", "/api/v1/auth/native-app/requests/"+start.ID, nil, f.tokens.AccessToken); status != 403 {
		t.Fatal("inspection ignored current policy")
	}
	if status, _ := authorizeNative(f, start, true); status != 403 {
		t.Fatal("authorization ignored current policy")
	}
	if status, _ := nativeComplete(f, c, secret, start, code["code"], verifier); status != 403 {
		t.Fatal("redemption ignored current policy")
	}
}

func TestDisablingQRLoginRevokesRequestsAndGrants(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	c, secret := nativeTestClient(f, "cerno")
	qr := startApp(f, c, secret, "login")
	approveLogin(f, qrStart{ID: qr.ID})
	w := appCall(f, c, secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{})
	var grant map[string]string
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &grant) != nil {
		t.Fatal("initial QR grant failed")
	}
	pending := startApp(f, c, secret, "login")
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"qrEnabled": false}, 200)
	if appCall(f, c, secret, "POST", "/requests", "", "", map[string]string{"purpose": "login"}).Code != 403 {
		t.Fatal("disabled QR method accepted a new request")
	}
	if appCall(f, c, secret, "GET", "/requests/"+pending.ID, pending.Redeem, "", nil).Code != 404 {
		t.Fatal("pending QR request survived disabling")
	}
	if status, _ := f.call("GET", "/api/v1/auth/web-login/requests/"+pending.ID, nil, f.tokens.AccessToken); status != 404 {
		t.Fatal("disabled QR request remained inspectable on Console")
	}
	if appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("QR session survived disabling")
	}
	startNative(f, c, secret, randomToken())
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"qrEnabled": true}, 200)
	if appCall(f, c, secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("reenabling restored the QR session")
	}
}
