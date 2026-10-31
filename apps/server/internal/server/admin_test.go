package server

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type adminClient struct {
	f             *fixture
	cookie        *http.Cookie
	csrf          string
	pendingCookie *http.Cookie
}

func (a *adminClient) request(method, path string, body any, origin, csrf string) (int, []byte, *http.Response) {
	a.f.t.Helper()
	data, _ := json.Marshal(body)
	r, _ := http.NewRequest(method, a.f.http.URL+path, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	if csrf != "" {
		r.Header.Set("X-CSRF-Token", csrf)
	}
	if a.cookie != nil {
		r.AddCookie(a.cookie)
	}
	if a.pendingCookie != nil {
		r.AddCookie(a.pendingCookie)
	}
	res, err := a.f.http.Client().Do(r)
	if err != nil {
		a.f.t.Fatal(err)
	}
	defer res.Body.Close()
	out, _ := io.ReadAll(res.Body)
	return res.StatusCode, out, res
}
func (a *adminClient) call(method, path string, body any, expected int) []byte {
	a.f.t.Helper()
	status, data, _ := a.request(method, "/admin/api/"+path, body, a.f.s.config.PublicURL, a.csrf)
	if status != expected {
		a.f.t.Fatalf("%s %s: got %d want %d: %s", method, path, status, expected, data)
	}
	return data
}
func loginAdmin(f *fixture) *adminClient {
	f.t.Helper()
	a := &adminClient{f: f}
	ensureConsoleLogin(f)
	status, data, res := a.request("POST", "/admin/api/login/requests", map[string]bool{}, f.s.config.PublicURL, "")
	if status != 201 {
		f.t.Fatalf("create QR login: %d %s", status, data)
	}
	for _, c := range res.Cookies() {
		if c.Name == f.s.pendingCookieName() {
			a.pendingCookie = c
		}
	}
	var qr struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(data, &qr)
	info := inspectLogin(f, qr.ID)
	status, data = f.call("POST", "/api/v1/auth/web-login/requests/"+qr.ID+"/approve", map[string]string{"confirmationCode": info.ConfirmationCode}, f.tokens.AccessToken, info.Nonce)
	if status != 200 {
		f.t.Fatalf("approve QR login: %d %s", status, data)
	}
	status, data, res = a.request("POST", "/admin/api/login/requests/"+qr.ID+"/complete", map[string]bool{}, f.s.config.PublicURL, "")
	if status != 200 {
		f.t.Fatalf("admin login: %d %s", status, data)
	}
	for _, c := range res.Cookies() {
		if c.Name == f.s.adminCookieName() {
			a.cookie = c
		}
	}
	var value struct {
		CSRF string `json:"csrfToken"`
	}
	_ = json.Unmarshal(data, &value)
	a.csrf = value.CSRF
	if a.cookie == nil || a.csrf == "" {
		f.t.Fatal("login missing cookie or CSRF")
	}
	return a
}
func publicPEM(t *testing.T, key any) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
}

func TestAdminAuthenticationAndCSRF(t *testing.T) {
	f := newFixture(t, false)
	a := &adminClient{f: f}
	a.call("GET", "agents", nil, 401)
	status, _, _ := a.request("POST", "/admin/api/login/requests", map[string]string{}, "https://attacker.example", "")
	if status != 403 {
		t.Fatal("cross-origin login accepted")
	}
	a = loginAdmin(f)
	if !a.cookie.Secure || !a.cookie.HttpOnly || a.cookie.SameSite != http.SameSiteStrictMode || a.cookie.Path != "/" || a.cookie.Domain != "" || !strings.HasPrefix(a.cookie.Name, "__Host-") {
		t.Fatal("insecure admin cookie")
	}
	for _, test := range []struct{ origin, csrf string }{{"", a.csrf}, {"https://attacker.example", a.csrf}, {f.http.URL, ""}, {f.http.URL, "wrong"}} {
		status, _, _ = a.request("DELETE", "/admin/api/agents/PC", nil, test.origin, test.csrf)
		if status != 403 {
			t.Fatal("CSRF mutation accepted", test)
		}
	}
	a.call("GET", "session", nil, 200)
	a.call("POST", "logout", map[string]bool{}, 200)
	a.call("GET", "agents", nil, 401)
}

func TestAdminExpiryAndDisabledMode(t *testing.T) {
	f := newFixture(t, false)
	a := loginAdmin(f)
	f.s.adminMu.Lock()
	id := digest(a.cookie.Value)
	ss := f.s.adminSessions[id]
	ss.LastUsed = time.Now().Add(-31 * time.Minute)
	f.s.adminSessions[id] = ss
	f.s.adminMu.Unlock()
	a.call("GET", "agents", nil, 401)
	a = loginAdmin(f)
	f.s.adminMu.Lock()
	ss = f.s.adminSessions[digest(a.cookie.Value)]
	ss.Created = time.Now().Add(-13 * time.Hour)
	f.s.adminSessions[digest(a.cookie.Value)] = ss
	f.s.adminMu.Unlock()
	a.call("GET", "agents", nil, 401)
	a = loginAdmin(f)
	f.s.adminMu.Lock()
	before := f.s.adminSessions[digest(a.cookie.Value)].LastUsed
	f.s.adminMu.Unlock()
	a.call("GET", "agents", nil, 200)
	f.s.adminMu.Lock()
	after := f.s.adminSessions[digest(a.cookie.Value)].LastUsed
	f.s.adminMu.Unlock()
	if !before.Equal(after) {
		t.Fatal("passive polling extended idle session")
	}
	// Registration shares the list URL, but an active POST must renew idle time.
	f.s.adminMu.Lock()
	ss = f.s.adminSessions[digest(a.cookie.Value)]
	before = time.Now().Add(-5 * time.Minute)
	ss.LastUsed = before
	f.s.adminSessions[digest(a.cookie.Value)] = ss
	f.s.adminMu.Unlock()
	a.call("POST", "agents", map[string]string{}, http.StatusBadRequest)
	f.s.adminMu.Lock()
	after = f.s.adminSessions[digest(a.cookie.Value)].LastUsed
	f.s.adminMu.Unlock()
	if !after.After(before) {
		t.Fatal("active Agent registration did not renew idle session")
	}
	next, err := loadRegistry(f.s.registry.Load().Agents, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.s.saveRegistry(next); err != nil {
		t.Fatal(err)
	}
	a.call("GET", "session", nil, 503)
}

func TestAdminLoginRateLimit(t *testing.T) {
	f := newFixture(t, false)
	a := &adminClient{f: f}
	for i := 0; i < 8; i++ {
		a.call("POST", "login/requests", map[string]string{}, 201)
	}
	a.call("POST", "login/requests", map[string]string{}, 429)
}

func TestAdminEmbeddedPagesAndNoSecrets(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	for _, path := range []string{"/admin/", "/admin/agents", "/admin/access-logs", "/admin/app.js", "/admin/access-logs.js", "/admin/style.css"} {
		status, data, res := a.request("GET", path, nil, "", "")
		if status != 200 || len(data) == 0 || !strings.Contains(res.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") || res.Header.Get("Cache-Control") != "no-store" {
			t.Fatal("embedded page or headers missing", path)
		}
	}
	data := a.call("GET", "agents", nil, 200)
	var agentListing map[string]json.RawMessage
	if err := json.Unmarshal(data, &agentListing); err != nil {
		t.Fatal(err)
	}
	if len(agentListing) != 2 || agentListing["agents"] == nil || agentListing["updatedAt"] == nil {
		t.Fatalf("agent listing must contain only agents and updatedAt: %s", data)
	}
	a.call("GET", "overview", nil, http.StatusNotFound)
	if _, present := agentListing["sessions"]; present {
		t.Fatal("web agent listing still includes phone sessions")
	}
	if _, present := agentListing["consoles"]; present {
		t.Fatal("web agent listing still includes management clients")
	}
	for _, secret := range []string{f.tokens.AccessToken, f.tokens.RefreshToken, f.tokens.SessionID, "PRIVATE KEY"} {
		if bytes.Contains(data, []byte(secret)) {
			t.Fatal("agent listing exposes credentials")
		}
	}
	// Admin cookies cannot substitute for the device signature on the Console API.
	status, _, _ := a.request("GET", "/api/v1/agents", nil, "", "")
	if status != 401 {
		t.Fatal("admin cookie bypassed console authentication")
	}
}

func TestAdminAgentLifecycleMetricsAndPersistence(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	ws := f.connectAgent(false)
	go func() {
		var req agentMessage
		if ws.ReadJSON(&req) == nil {
			_ = ws.WriteJSON(agentMessage{Type: "response", ID: req.ID, agentResult: agentResult{Result: json.RawMessage(`{"cpuUsagePercent":25,"newMetric":{"value":42}}`)}})
		}
	}()
	data := a.call("POST", "agents/PC/requests", map[string]any{"method": "query.system.metrics", "version": 1, "params": map[string]any{}}, 200)
	var m struct {
		Result struct{ CPUUsagePercent float64 }
	}
	if json.Unmarshal(data, &m) != nil || m.Result.CPUUsagePercent != 25 {
		t.Fatal("admin metrics not forwarded")
	}
	a.call("DELETE", "agents/PC", nil, 200)
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	var msg any
	if ws.ReadJSON(&msg) == nil {
		t.Fatal("removed Agent remains connected")
	}
	a.call("POST", "agents/PC/requests", map[string]any{"method": "query.system.metrics", "version": 1, "params": map[string]any{}}, 409)
	a.call("DELETE", "agents/PC", nil, 404)
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	body := map[string]string{"id": "NEWPC", "name": "新电脑", "publicKeyPem": publicPEM(t, &key.PublicKey)}
	a.call("POST", "agents", body, 201)
	a.call("POST", "agents", body, 409)
	config := f.s.config
	// Invalid seed paths must not be loaded again once the registry is initialized.
	config.Agents = []AgentConfig{{PublicKeyFile: "missing.pem"}}
	restarted, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if len(restarted.registry.Load().Agents) != 1 || restarted.registry.Load().Agents[0].ID != "NEWPC" {
		t.Fatal("registry edits lost or seed reimported")
	}
}

func TestConsoleSessionRemovalIsUnavailableAndLogoutPreservesKeyTrust(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	// Even a valid browser cookie, origin and CSRF token grant no Console revocation route.
	a.call("DELETE", "sessions/"+f.tokens.SessionID, nil, http.StatusMethodNotAllowed)
	status, _, _ := a.request("DELETE", "/api/v1/sessions/"+f.tokens.SessionID, nil, f.s.config.PublicURL, a.csrf)
	if status != http.StatusNotFound {
		t.Fatal("removed Console revocation endpoint is still registered", status)
	}
	status, _ = f.call("GET", "/api/v1/auth/session", nil, f.tokens.AccessToken)
	if status != http.StatusOK {
		t.Fatal("browser removal attempt changed the phone session", status)
	}
	a.call("GET", "agents", nil, http.StatusOK)
	// Even a signed Console request cannot remotely remove a Console session.
	status, _ = f.call("DELETE", "/api/v1/sessions/"+f.tokens.SessionID, nil, f.tokens.AccessToken)
	if status != http.StatusNotFound {
		t.Fatal("signed Console request reached removed revocation endpoint", status)
	}
	// Local logout invalidates the current session and its browsers, not key trust.
	status, _ = f.call("POST", "/api/v1/auth/logout", nil, f.tokens.AccessToken)
	if status != http.StatusOK {
		t.Fatal("Console logout failed", status)
	}
	status, _ = f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("revoked Console session remains valid")
	}
	a.call("GET", "agents", nil, 401)
	f.tokens = tokens{}
	ensureConsoleLogin(f)
	status, _ = f.call("GET", "/api/v1/auth/session", nil, f.tokens.AccessToken)
	if status != http.StatusOK {
		t.Fatal("trusted key cannot log in again after logout", status)
	}
	a.call("GET", "agents", nil, 401)
}

func TestAdminRejectsPrivateKeysWrongAlgorithmsAndUnsafeIDs(t *testing.T) {
	f := newFixture(t, false)
	a := loginAdmin(f)
	private := string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(f.agentKey)}))
	a.call("POST", "agents", map[string]string{"id": "PC2", "name": "PC", "publicKeyPem": private}, 400)
	ec, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	a.call("POST", "agents", map[string]string{"id": "PC2", "name": "PC", "publicKeyPem": publicPEM(t, &ec.PublicKey)}, 400)
	status, _, _ := a.request("POST", "/admin/api/consoles", map[string]string{"name": "Phone", "publicKeyPem": publicPEM(t, &ec.PublicKey)}, f.s.config.PublicURL, a.csrf)
	if status != 405 && status != 404 {
		t.Fatal("Console configuration is writable through Web API")
	}
	a.call("POST", "agents", map[string]string{"id": "../bad", "name": "PC", "publicKeyPem": publicPEM(t, &f.agentKey.PublicKey)}, 400)
	a.call("POST", "agents", map[string]string{"id": "PC2", "name": "PC", "publicKeyPem": publicPEM(t, &f.agentKey.PublicKey), "publicKeyFile": "/etc/passwd"}, 400)
}

func TestAdminConcurrentEditsKeepBothKeys(t *testing.T) {
	f := newFixture(t, false)
	a := loginAdmin(f)
	var wg sync.WaitGroup
	for _, name := range []string{"PCA", "PCB"} {
		key, _ := rsa.GenerateKey(rand.Reader, 2048)
		text := publicPEM(t, &key.PublicKey)
		wg.Add(1)
		go func() {
			defer wg.Done()
			a.call("POST", "agents", map[string]string{"id": name, "name": name, "publicKeyPem": text}, 201)
		}()
	}
	wg.Wait()
	if len(f.s.registry.Load().Agents) != 3 {
		t.Fatal("concurrent edit lost a key")
	}
}

func TestAdminRemovalDuringAgentAuthentication(t *testing.T) {
	f := newFixture(t, false)
	a := loginAdmin(f)
	dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
	ws, _, err := dialer.Dial("wss"+strings.TrimPrefix(f.http.URL, "https")+"/ws/agent", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	_ = ws.WriteJSON(agentMessage{Type: "hello", Version: 3, Username: "owner", KeyID: f.s.registry.Load().Agents[0].keyID, Capabilities: []agentCapability{{Name: "query.system.metrics", Version: 1}}})
	var challenge struct {
		Payload string `json:"payload"`
	}
	if err = ws.ReadJSON(&challenge); err != nil {
		t.Fatal(err)
	}
	a.call("DELETE", "agents/PC", nil, 200)
	payload, _ := base64.StdEncoding.DecodeString(challenge.Payload)
	hash := sha256.Sum256(payload)
	signature, _ := rsa.SignPSS(rand.Reader, f.agentKey, crypto.SHA256, hash[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
	_ = ws.WriteJSON(agentMessage{Type: "authenticate", Signature: base64.StdEncoding.EncodeToString(signature)})
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	var ack any
	if ws.ReadJSON(&ack) == nil {
		t.Fatal("revoked key completed in-flight authentication")
	}
	f.s.mu.Lock()
	defer f.s.mu.Unlock()
	if f.s.online["PC"] != nil {
		t.Fatal("revoked Agent registered online")
	}
}

func TestLegacyStateMigrationPreservesTrustedConsoleSession(t *testing.T) {
	f := newFixture(t, true)
	if err := f.s.store.update(func(st *state) error { st.Registry = nil; return nil }); err != nil {
		t.Fatal(err)
	}
	restarted, err := New(f.s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	restarted.store.inspect(func(st state) {
		if st.Registry == nil || len(st.Registry.Agents) != 1 || len(st.Registry.Consoles) != 1 {
			t.Error("legacy keys not imported")
		}
		if st.Sessions[f.tokens.SessionID] == nil {
			t.Error("upgrade revoked a trusted Console session")
		}
	})
}
