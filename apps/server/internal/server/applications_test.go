package server

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestApplicationOriginsSupportLocalHTTP(t *testing.T) {
	for _, origin := range []string{"http://192.168.0.2:8001", "http://10.0.0.2", "http://172.16.0.1:3000", "http://172.31.255.254", "http://169.254.1.2", "http://localhost:8001", "http://nas.local:8001", "http://127.0.0.1", "http://[::1]:8001", "http://[fd12::2]:8001", "http://[fe80::1]", "http://[::ffff:192.168.0.2]:8001", "https://notify.example.com"} {
		if !validApplicationOrigin(origin) {
			t.Errorf("local origin rejected: %s", origin)
		}
	}
	for _, origin := range []string{"http://notify.example.com", "http://8.8.8.8", "http://172.32.0.1", "http://[2001:4860::1]", "http://0.0.0.0", "http://192.168.0.2/path", "http://user@192.168.0.2", "http://192.168.0.2?", "http://192.168.0.2#", "http://192.168.0.2:0", "http://192.168.0.2:65536", "ftp://192.168.0.2"} {
		if validApplicationOrigin(origin) {
			t.Errorf("invalid origin accepted: %s", origin)
		}
	}
}

func TestManagedLANApplicationCanApproveAndRedeem(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	data := a.call("POST", "applications", map[string]string{"name": "局域网 iLinker", "origin": "http://192.168.0.2:8001/"}, 201)
	var created createdApplication
	if json.Unmarshal(data, &created) != nil {
		t.Fatal("invalid application")
	}
	c, _ := f.s.authClient(created.Application.ID)
	qr := startApp(f, c, created.Secret, "login")
	status, details := f.call("GET", "/api/v1/auth/web-login/requests/"+qr.ID, nil, f.tokens.AccessToken)
	var info map[string]string
	_ = json.Unmarshal(details, &info)
	if status != 200 || info["applicationOrigin"] != "http://192.168.0.2:8001" {
		t.Fatal("LAN origin missing from phone confirmation")
	}
	approveLogin(f, qrStart{ID: qr.ID})
	if appCall(f, c, created.Secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{}).Code != 200 {
		t.Fatal("LAN application redemption failed")
	}
}

type createdApplication struct {
	Application   applicationView `json:"application"`
	Secret        string          `json:"clientSecret"`
	Configuration string          `json:"configuration"`
}

func createManagedApplication(f *fixture, a *adminClient) createdApplication {
	f.t.Helper()
	data := a.call("POST", "applications", map[string]string{"name": "iLinker", "origin": "https://notify.example.com/"}, 201)
	var result createdApplication
	if json.Unmarshal(data, &result) != nil || !validLoginID(result.Secret) || result.Application.ID == "" || !strings.Contains(result.Configuration, "HAKO_CLIENT_SECRET="+result.Secret) {
		f.t.Fatal("invalid application credential response")
	}
	return result
}

func TestManagedApplicationCreationPersistenceAndSecretRedaction(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	result := createManagedApplication(f, a)
	c, ok := f.s.authClient(result.Application.ID)
	if !ok || c.SecretHash != digest(result.Secret) || c.Origin != "https://notify.example.com" {
		t.Fatal("managed client not registered")
	}
	startApp(f, c, result.Secret, "login")
	listed := a.call("GET", "applications", nil, 200)
	if strings.Contains(string(listed), result.Secret) || strings.Contains(string(listed), c.SecretHash) || strings.Contains(string(listed), "secretHash") {
		t.Fatal("list leaked application credential")
	}
	persisted, err := openStore(f.s.config.Database, f.s.config.MasterKey)
	if err != nil {
		t.Fatal(err)
	}
	defer persisted.db.Close()
	persisted.inspect(func(st state) {
		client, ok := st.AuthClients[c.ID]
		if !ok || client.SecretHash != c.SecretHash || !client.Enabled {
			t.Fatal("client not persisted")
		}
	})
	// Same-origin native administrator authentication and CSRF remain mandatory.
	status, _, _ := a.request("POST", "/admin/api/applications", map[string]string{"name": "forbidden", "origin": c.Origin}, f.s.config.PublicURL, "")
	if status != 403 {
		t.Fatal("missing CSRF accepted")
	}
	r := httptest.NewRequest("POST", f.s.config.PublicURL+"/admin/api/applications", strings.NewReader(`{"name":"forbidden","origin":"https://notify.example.com"}`))
	r.Header.Set("Authorization", "Bearer "+result.Secret)
	r.Header.Set("X-Hako-Client", c.ID)
	r.Header.Set("Origin", f.s.config.PublicURL)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("application key entered application management")
	}
	a.call("POST", "applications", map[string]string{"name": "invalid", "origin": "http://unsafe.example.com"}, 400)
}

func TestManagedApplicationRotationAndDisablingRevokeOldRequestsAndGrants(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	created := createManagedApplication(f, a)
	c, _ := f.s.authClient(created.Application.ID)
	qr := startApp(f, c, created.Secret, "login")
	approveLogin(f, qrStart{ID: qr.ID})
	w := appCall(f, c, created.Secret, "POST", "/requests/"+qr.ID+"/complete", qr.Redeem, "", struct{}{})
	var grant map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &grant)
	pending := startApp(f, c, created.Secret, "login")
	rotatedBytes := a.call("POST", "applications/"+c.ID+"/rotate", struct{}{}, 200)
	var rotated createdApplication
	_ = json.Unmarshal(rotatedBytes, &rotated)
	if !validLoginID(rotated.Secret) || rotated.Secret == created.Secret {
		t.Fatal("SK did not rotate")
	}
	if appCall(f, c, created.Secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("old SK survived rotation")
	}
	if appCall(f, c, rotated.Secret, "GET", "/session", "", grant["sessionToken"], nil).Code != 401 {
		t.Fatal("old session survived rotation")
	}
	if appCall(f, c, rotated.Secret, "GET", "/requests/"+pending.ID, pending.Redeem, "", nil).Code != 404 {
		t.Fatal("pending request survived rotation")
	}
	fresh := startApp(f, c, rotated.Secret, "login")
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"enabled": false}, 200)
	if appCall(f, c, rotated.Secret, "GET", "/requests/"+fresh.ID, fresh.Redeem, "", nil).Code != 401 {
		t.Fatal("disabled application authenticated")
	}
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"enabled": true}, 200)
	if appCall(f, c, rotated.Secret, "GET", "/requests/"+fresh.ID, fresh.Redeem, "", nil).Code != 404 {
		t.Fatal("re-enable restored old request")
	}
	startApp(f, c, rotated.Secret, "login")
}
