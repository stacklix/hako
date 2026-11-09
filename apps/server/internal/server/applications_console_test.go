package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func consoleApplicationCall(f *fixture, method, path string, body any, token string) (int, []byte) {
	f.t.Helper()
	data, _ := json.Marshal(body)
	r := httptest.NewRequest(method, f.s.config.PublicURL+path, strings.NewReader(string(data)))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("DPoP", makeProof(f.key, method, f.s.config.PublicURL+path, token, randomToken()))
	r.Header.Set("X-Hako-Device", f.deviceID)
	if token != "" {
		r.Header.Set("Authorization", "DPoP "+token)
	}
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	return w.Code, w.Body.Bytes()
}

func TestConsoleApplicationManagementSharesWebRecords(t *testing.T) {
	f := newFixture(t, true)
	oidc := OIDCClient{Enabled: true, RedirectURIs: []string{"https://client.example/callback"}, Scopes: []string{"openid", "profile"}, RequirePKCE: true, AuthMethod: "client_secret_basic"}
	status, data := consoleApplicationCall(f, "POST", "/api/v1/applications", map[string]any{"name": "Phone-created", "origin": "https://client.example", "oidc": oidc}, f.tokens.AccessToken)
	var created createdApplication
	if status != 201 || json.Unmarshal(data, &created) != nil || !validLoginID(created.Secret) {
		t.Fatalf("Console create: %d", status)
	}
	admin := loginAdmin(f)
	list := admin.call("GET", "applications", nil, 200)
	if !strings.Contains(string(list), created.Application.ID) || strings.Contains(string(list), created.Secret) {
		t.Fatal("Console and Web applications differ or list leaks secret")
	}
	status, data = consoleApplicationCall(f, "GET", "/api/v1/applications", nil, f.tokens.AccessToken)
	var listed struct {
		Applications []applicationView `json:"applications"`
		Issuer       string            `json:"issuer"`
	}
	if status != 200 || json.Unmarshal(data, &listed) != nil || len(listed.Applications) != 1 || listed.Issuer != f.s.config.PublicURL || strings.Contains(string(data), created.Secret) || strings.Contains(string(data), "secretHash") {
		t.Fatal("invalid Console listing")
	}
	c, _ := f.s.authClient(created.Application.ID)
	pending := startApp(f, c, created.Secret, "login")
	status, data = consoleApplicationCall(f, "POST", "/api/v1/applications/"+c.ID+"/rotate", struct{}{}, f.tokens.AccessToken)
	var rotated createdApplication
	if status != 200 || json.Unmarshal(data, &rotated) != nil || rotated.Secret == created.Secret || !validLoginID(rotated.Secret) {
		t.Fatal("Console secret rotation failed")
	}
	if appCall(f, c, rotated.Secret, "GET", "/requests/"+pending.ID, pending.Redeem, "", nil).Code != 404 {
		t.Fatal("Console rotation failed to invalidate pending request")
	}
	// A Console update must invalidate the same OIDC grants as a Web update.
	c, _ = f.s.authClient(c.ID)
	_, code := approvedOIDCCode(f, c)
	status, _ = consoleApplicationCall(f, "PATCH", "/api/v1/applications/"+c.ID, map[string]any{"oidc": OIDCClient{Enabled: true, RedirectURIs: []string{"https://client.example/new-callback"}, Scopes: []string{"openid"}, RequirePKCE: true, AuthMethod: "client_secret_basic"}}, f.tokens.AccessToken)
	if status != 200 || exchangeOIDC(f, c, rotated.Secret, code).Code == 200 {
		t.Fatal("Console OIDC edit left old code usable")
	}
	status, _ = consoleApplicationCall(f, "PATCH", "/api/v1/applications/"+c.ID, map[string]bool{"enabled": false}, f.tokens.AccessToken)
	if status != 200 {
		t.Fatal("Console disable failed")
	}
	if _, ok := f.s.authClient(c.ID); ok {
		t.Fatal("disabled application authenticated")
	}
	admin.call("PATCH", "applications/"+c.ID, map[string]bool{"enabled": true}, 200)
	if _, ok := f.s.authClient(c.ID); !ok {
		t.Fatal("Web update not reflected for Console")
	}
}

func TestConsoleApplicationDeletionRevokesLoginAndPersists(t *testing.T) {
	f := newFixture(t, true)
	admin := loginAdmin(f)
	c, secret := oidcTestClient(f, "to-delete")
	other, otherSecret := appTestClient(f, "other-app")
	pending := startApp(f, c, secret, "login")
	otherPending := startApp(f, other, otherSecret, "login")
	_, usedCode := approvedOIDCCode(f, c)
	access := oidcAccess(f, exchangeOIDC(f, c, secret, usedCode))
	_, unusedCode := approvedOIDCCode(f, c)

	path := "/api/v1/applications/" + c.ID
	for range 2 {
		status, data := consoleApplicationCall(f, "DELETE", path, struct{}{}, f.tokens.AccessToken)
		var result map[string]bool
		if status != 200 || json.Unmarshal(data, &result) != nil || !result["ok"] {
			t.Fatalf("Console delete: %d %s", status, data)
		}
	}
	list := string(admin.call("GET", "applications", nil, 200))
	if strings.Contains(list, c.ID) || !strings.Contains(list, other.ID) {
		t.Fatal("Web list did not reflect the deletion")
	}
	if status, _ := f.call("GET", "/api/v1/auth/web-login/requests/"+pending.ID, nil, f.tokens.AccessToken); status != 404 {
		t.Fatalf("deleted application's request survived: %d", status)
	}
	if appCall(f, other, otherSecret, "GET", "/requests/"+otherPending.ID, otherPending.Redeem, "", nil).Code != 200 {
		t.Fatal("unrelated application's request was affected")
	}
	if exchangeOIDC(f, c, secret, unusedCode).Code == 200 || oidcRequest(f, "GET", "/oidc/userinfo", "", nil, "", "", access).Code != 401 {
		t.Fatal("deleted application's OIDC grants survived")
	}
	persisted, err := openStore(f.s.config.Database, f.s.config.MasterKey)
	if err != nil {
		t.Fatal(err)
	}
	defer persisted.db.Close()
	persisted.inspect(func(st state) {
		if _, ok := st.AuthClients[c.ID]; ok {
			t.Fatal("deletion was not persisted")
		}
	})
}

func TestConsoleApplicationManagementCredentialIsolationAndReplay(t *testing.T) {
	f := newFixture(t, true)
	admin := loginAdmin(f)
	c, secret := appTestClient(f, "ordinary-app")
	for _, method := range []string{"GET", "POST", "PATCH", "DELETE"} {
		path := "/api/v1/applications"
		if method == "PATCH" || method == "DELETE" {
			path += "/" + c.ID
		}
		for _, credential := range []string{"", secret} {
			r := httptest.NewRequest(method, f.s.config.PublicURL+path, strings.NewReader(`{}`))
			r.Header.Set("Content-Type", "application/json")
			r.AddCookie(admin.cookie)
			r.Header.Set("X-Hako-CSRF", admin.csrf)
			if credential != "" {
				r.Header.Set("Authorization", "Bearer "+credential)
				r.Header.Set("X-Hako-Client", c.ID)
			}
			w := httptest.NewRecorder()
			f.s.ServeHTTP(w, r)
			if w.Code != 401 {
				t.Fatal("non-Console credentials managed applications")
			}
		}
	}
	path := "/api/v1/applications"
	body := `{"name":"replay-safe","origin":"https://example.com"}`
	proof := makeProof(f.key, "POST", f.s.config.PublicURL+path, f.tokens.AccessToken, randomToken())
	for attempt := 0; attempt < 2; attempt++ {
		r := httptest.NewRequest("POST", f.s.config.PublicURL+path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "DPoP "+f.tokens.AccessToken)
		r.Header.Set("DPoP", proof)
		r.Header.Set("X-Hako-Device", f.deviceID)
		w := httptest.NewRecorder()
		f.s.ServeHTTP(w, r)
		expected := 201
		if attempt == 1 {
			expected = 401
		}
		if w.Code != expected {
			t.Fatalf("replay attempt %d: %d", attempt, w.Code)
		}
	}
	for _, tc := range []struct {
		origin, media string
		status        int
	}{{"https://evil.example", "application/json", 403}, {f.s.config.PublicURL, "application/json", 403}, {"", "text/plain", 415}} {
		r := httptest.NewRequest("POST", f.s.config.PublicURL+path, strings.NewReader(body))
		r.Header.Set("Content-Type", tc.media)
		r.Header.Set("Origin", tc.origin)
		r.Header.Set("Authorization", "DPoP "+f.tokens.AccessToken)
		r.Header.Set("DPoP", makeProof(f.key, "POST", f.s.config.PublicURL+path, f.tokens.AccessToken, randomToken()))
		r.Header.Set("X-Hako-Device", f.deviceID)
		w := httptest.NewRecorder()
		f.s.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("native boundary: %d", w.Code)
		}
	}
	status, _ := consoleApplicationCall(f, "POST", "/api/v1/auth/logout", nil, f.tokens.AccessToken)
	if status != http.StatusOK {
		t.Fatal("logout failed")
	}
	status, _ = consoleApplicationCall(f, "GET", path, nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("revoked Console still manages applications")
	}
}
