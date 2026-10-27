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
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type fixture struct {
	t        *testing.T
	s        *Server
	http     *httptest.Server
	key      *ecdsa.PrivateKey
	agentKey *rsa.PrivateKey
	deviceID string
	tokens   tokens
}

func newFixture(t *testing.T, authenticated bool) *fixture {
	t.Helper()
	dir := t.TempDir()
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKIXPublicKey(&rsaKey.PublicKey)
	publicFile := filepath.Join(dir, "agent.public.pem")
	if err = os.WriteFile(publicFile, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	consoleDER, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	consoleFile := filepath.Join(dir, "console.public.pem")
	if err = os.WriteFile(consoleFile, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: consoleDER}), 0600); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewUnstartedServer(nil)
	master := make([]byte, 32)
	_, _ = rand.Read(master)
	app, err := New(Config{Database: filepath.Join(dir, "hako.db"), MasterKey: master, Username: "owner", PublicURL: "https://" + ts.Listener.Addr().String(), Agents: []AgentConfig{{ID: "pc", Name: "PC", PublicKeyFile: publicFile}}, Consoles: []ConsoleConfig{{Name: "iPhone", PublicKeyFile: consoleFile}}, RequestTimeout: 150 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	ts.Config.Handler = app
	ts.StartTLS()
	f := &fixture{t: t, s: app, http: ts, key: key, agentKey: rsaKey, deviceID: app.config.Consoles[0].thumb}
	t.Cleanup(func() { _ = app.Close(); ts.Close() })
	if authenticated {
		status, data := f.call("POST", "/api/v1/auth/challenge", map[string]string{"username": "owner", "deviceId": f.deviceID}, "")
		if status != 200 {
			t.Fatalf("challenge status %d", status)
		}
		var ch struct {
			ID    string `json:"challengeId"`
			Nonce string `json:"nonce"`
		}
		_ = json.Unmarshal(data, &ch)
		status, data = f.call("POST", "/api/v1/auth/login", map[string]string{"username": "owner", "deviceId": f.deviceID, "challengeId": ch.ID}, "", ch.Nonce)
		if status != 200 {
			t.Fatalf("login status %d: %s", status, data)
		}
		if json.Unmarshal(data, &f.tokens) != nil {
			t.Fatal("invalid tokens")
		}
	}
	return f
}

func makeProof(key *ecdsa.PrivateKey, method, url, token, jti string, nonce ...string) string {
	x := key.X.FillBytes(make([]byte, 32))
	y := key.Y.FillBytes(make([]byte, 32))
	header, _ := json.Marshal(map[string]any{"typ": "dpop+jwt", "alg": "ES256", "jwk": jwk{Crv: "P-256", Kty: "EC", X: raw64.EncodeToString(x), Y: raw64.EncodeToString(y)}})
	claims := map[string]any{"htm": method, "htu": url, "iat": time.Now().Unix(), "jti": jti}
	if len(nonce) > 0 {
		claims["nonce"] = nonce[0]
	}
	if token != "" {
		claims["ath"] = digest(token)
	}
	body, _ := json.Marshal(claims)
	input := raw64.EncodeToString(header) + "." + raw64.EncodeToString(body)
	hash := sha256.Sum256([]byte(input))
	r, s, _ := ecdsa.Sign(rand.Reader, key, hash[:])
	sig := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
	return input + "." + raw64.EncodeToString(sig)
}

func (f *fixture) call(method, path string, body any, token string, nonce ...string) (int, []byte) {
	f.t.Helper()
	data, _ := json.Marshal(body)
	r, _ := http.NewRequest(method, f.http.URL+path, bytes.NewReader(data))
	r.Header.Set("DPoP", makeProof(f.key, method, f.http.URL+path, token, randomToken(), nonce...))
	r.Header.Set("X-Hako-Device", f.deviceID)
	if token != "" {
		r.Header.Set("Authorization", "DPoP "+token)
	}
	response, err := f.http.Client().Do(r)
	if err != nil {
		f.t.Fatal(err)
	}
	defer response.Body.Close()
	result, _ := io.ReadAll(response.Body)
	return response.StatusCode, result
}

func TestConsoleRequiresConfiguredPublicKeyAndChallenge(t *testing.T) {
	f := newFixture(t, false)
	body := map[string]string{"username": "wrong", "deviceId": f.deviceID}
	status, _ := f.call("POST", "/api/v1/auth/challenge", body, "")
	if status != 401 {
		t.Fatal("wrong account accepted")
	}
	body["username"] = "owner"
	status, data := f.call("POST", "/api/v1/auth/challenge", body, "")
	if status != 200 {
		t.Fatal(status)
	}
	var ch struct {
		ID    string `json:"challengeId"`
		Nonce string `json:"nonce"`
	}
	_ = json.Unmarshal(data, &ch)
	body["challengeId"] = ch.ID
	status, _ = f.call("POST", "/api/v1/auth/login", body, "", "wrong-nonce")
	if status != 401 {
		t.Fatal("wrong nonce accepted")
	}
	status, _ = f.call("POST", "/api/v1/auth/login", body, "", ch.Nonce)
	if status != 200 {
		t.Fatal(status)
	}
	status, _ = f.call("POST", "/api/v1/auth/login", body, "", ch.Nonce)
	if status != 401 {
		t.Fatal("used challenge accepted")
	}
	f.key, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	delete(body, "challengeId")
	status, _ = f.call("POST", "/api/v1/auth/challenge", body, "")
	if status != 401 {
		t.Fatal("unregistered public key accepted")
	}
}

func TestExpiredLoginChallenge(t *testing.T) {
	f := newFixture(t, false)
	body := map[string]string{"username": "owner", "deviceId": f.deviceID}
	_, data := f.call("POST", "/api/v1/auth/challenge", body, "")
	var ch struct {
		ID    string `json:"challengeId"`
		Nonce string `json:"nonce"`
	}
	_ = json.Unmarshal(data, &ch)
	_ = f.s.store.update(func(st *state) error { c := st.Challenges[ch.ID]; c.Expires = 1; st.Challenges[ch.ID] = c; return nil })
	body["challengeId"] = ch.ID
	status, _ := f.call("POST", "/api/v1/auth/login", body, "", ch.Nonce)
	if status != 401 {
		t.Fatal("expired challenge accepted")
	}
}

func TestDeviceProofAndReplay(t *testing.T) {
	f := newFixture(t, true)
	url := f.http.URL + "/api/v1/agents"
	encoded := makeProof(f.key, "GET", url, f.tokens.AccessToken, randomToken())
	send := func() int {
		r, _ := http.NewRequest("GET", url, nil)
		r.Header.Set("DPoP", encoded)
		r.Header.Set("Authorization", "DPoP "+f.tokens.AccessToken)
		r.Header.Set("X-Hako-Device", f.deviceID)
		response, err := f.http.Client().Do(r)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		return response.StatusCode
	}
	if send() != 200 || send() != 401 {
		t.Fatal("proof replay not rejected")
	}
	originalDeviceID := f.deviceID
	f.deviceID = "copied-device-id"
	status, _ := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("wrong device accepted")
	}
	f.deviceID = originalDeviceID
	f.key, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	status, _ = f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("copied token accepted with different key")
	}
}

func TestPersistentSessionRefreshAndRecovery(t *testing.T) {
	f := newFixture(t, true)
	// Simulate an arbitrarily old but explicitly unrevoked login and expired access token.
	_ = f.s.store.update(func(st *state) error {
		ss := st.Sessions[f.tokens.SessionID]
		ss.CreatedAt = time.Now().AddDate(-10, 0, 0).Unix()
		for k := range ss.Access {
			ss.Access[k] = 1
		}
		return nil
	})
	// Reload the database through a separate connection, representing a service restart.
	reloaded, err := openStore(f.s.config.Database, f.s.config.MasterKey)
	if err != nil {
		t.Fatal(err)
	}
	reloaded.inspect(func(st state) {
		if st.Sessions[f.tokens.SessionID] == nil {
			t.Error("session lost after restart")
		}
	})
	reloaded.db.Close()
	rotation := randomToken()
	body := map[string]string{"sessionId": f.tokens.SessionID, "deviceId": f.deviceID, "refreshToken": f.tokens.RefreshToken, "rotationId": rotation}
	status, data := f.call("POST", "/api/v1/auth/refresh", body, "")
	if status != 200 {
		t.Fatal(status, string(data))
	}
	var renewed tokens
	_ = json.Unmarshal(data, &renewed)
	status, data = f.call("POST", "/api/v1/auth/refresh", body, "")
	if status != 200 {
		t.Fatal("lost response recovery failed", status)
	}
	var recovered tokens
	_ = json.Unmarshal(data, &recovered)
	if renewed.RefreshToken != recovered.RefreshToken {
		t.Fatal("rotation recovery changed refresh token")
	}
	status, _ = f.call("GET", "/api/v1/agents", nil, recovered.AccessToken)
	if status != 200 {
		t.Fatal(status)
	}
	body["rotationId"] = randomToken()
	status, _ = f.call("POST", "/api/v1/auth/refresh", body, "")
	if status != 401 {
		t.Fatal("refresh reuse not rejected")
	}
	status, _ = f.call("GET", "/api/v1/agents", nil, recovered.AccessToken)
	if status != 401 {
		t.Fatal("reused refresh did not revoke access")
	}
}

func TestLogoutRevokesImmediately(t *testing.T) {
	f := newFixture(t, true)
	status, _ := f.call("POST", "/api/v1/auth/logout", nil, f.tokens.AccessToken)
	if status != 200 {
		t.Fatal(status)
	}
	status, _ = f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("logged-out access remains valid")
	}
	status, _ = f.call("POST", "/api/v1/auth/refresh", map[string]string{"sessionId": f.tokens.SessionID, "deviceId": f.deviceID, "refreshToken": f.tokens.RefreshToken, "rotationId": randomToken()}, "")
	if status != 401 {
		t.Fatal("logged-out refresh remains valid")
	}
}

func TestManualConsoleRemovalAndReadditionDoNotReviveSessions(t *testing.T) {
	f := newFixture(t, true)
	config := f.s.config
	config.Consoles = nil
	restarted, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	restarted.store.inspect(func(st state) {
		if len(st.Registry.Consoles) != 0 {
			t.Error("removed key reimported from seed config")
		}
		if len(st.Sessions) != 0 {
			t.Error("removed public key retained sessions")
		}
	})
	if err = restarted.Close(); err != nil {
		t.Fatal(err)
	}
	config.Consoles = f.s.config.Consoles
	readded, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	defer readded.Close()
	readded.store.inspect(func(st state) {
		if len(st.Sessions) != 0 {
			t.Error("readding a public key revived revoked sessions")
		}
	})
}

func TestRefreshProofReplayDoesNotDestroyRecoverableSession(t *testing.T) {
	f := newFixture(t, true)
	body, _ := json.Marshal(map[string]string{"sessionId": f.tokens.SessionID, "deviceId": f.deviceID, "refreshToken": f.tokens.RefreshToken, "rotationId": randomToken()})
	endpoint := f.http.URL + "/api/v1/auth/refresh"
	encoded := makeProof(f.key, "POST", endpoint, "", randomToken())
	send := func() (int, []byte) {
		r, _ := http.NewRequest("POST", endpoint, bytes.NewReader(body))
		r.Header.Set("DPoP", encoded)
		response, err := f.http.Client().Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, _ := io.ReadAll(response.Body)
		return response.StatusCode, data
	}
	status, data := send()
	if status != 200 {
		t.Fatal(status)
	}
	var renewed tokens
	_ = json.Unmarshal(data, &renewed)
	status, data = send()
	if status != 401 || !bytes.Contains(data, []byte("invalid_device_proof")) {
		t.Fatal("replayed request should fail without claiming session revocation", status)
	}
	status, _ = f.call("GET", "/api/v1/agents", nil, renewed.AccessToken)
	if status != 200 {
		t.Fatal("proof replay destroyed legitimate session")
	}
}

func (f *fixture) connectAgent(wrongKey bool, methods ...agentMethod) *websocket.Conn {
	if len(methods) == 0 {
		methods = []agentMethod{{Name: "system.metrics", Version: 1}}
	}
	f.t.Helper()
	f.s.mu.Lock()
	previous := f.s.online["pc"]
	f.s.mu.Unlock()
	dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
	ws, _, err := dialer.Dial("wss"+strings.TrimPrefix(f.http.URL, "https")+"/ws/agent", nil)
	if err != nil {
		f.t.Fatal(err)
	}
	f.t.Cleanup(func() { ws.Close() })
	_ = ws.WriteJSON(agentMessage{Type: "hello", Version: 2, Username: "owner", KeyID: f.s.config.Agents[0].keyID, Methods: methods})
	var challenge struct {
		Type    string `json:"type"`
		Payload string `json:"payload"`
	}
	if err = ws.ReadJSON(&challenge); err != nil {
		f.t.Fatal(err)
	}
	payload, _ := base64.StdEncoding.DecodeString(challenge.Payload)
	hash := sha256.Sum256(payload)
	key := f.agentKey
	if wrongKey {
		key, _ = rsa.GenerateKey(rand.Reader, 2048)
	}
	sig, _ := rsa.SignPSS(rand.Reader, key, crypto.SHA256, hash[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
	_ = ws.WriteJSON(agentMessage{Type: "authenticate", Signature: base64.StdEncoding.EncodeToString(sig)})
	var ack map[string]any
	err = ws.ReadJSON(&ack)
	if wrongKey {
		if err == nil {
			f.t.Fatal("wrong RSA key accepted")
		}
		return ws
	}
	if err != nil || ack["type"] != "authenticated" {
		f.t.Fatal("agent authentication failed", err)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		f.s.mu.Lock()
		online := f.s.online["pc"] != nil && f.s.online["pc"] != previous
		f.s.mu.Unlock()
		if online {
			return ws
		}
		time.Sleep(time.Millisecond)
	}
	f.t.Fatal("agent never online")
	return nil
}

func TestAgentRejectsWrongRSAKey(t *testing.T) { f := newFixture(t, true); f.connectAgent(true) }

func TestAgentQueryForwarding(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	go func() {
		var req agentMessage
		if ws.ReadJSON(&req) != nil {
			return
		}
		m := json.RawMessage(`{"cpuUsagePercent":25,"memoryUsagePercent":50,"memoryUsedBytes":4294967296,"memoryTotalBytes":8589934592,"sampledAt":"2026-10-25T10:00:00Z","sampleWindowMs":1000,"gpu":{"usage":42}}`)
		_ = ws.WriteJSON(agentMessage{Type: "response", ID: req.ID, agentResult: agentResult{Result: m}})
	}()
	status, data := f.call("POST", "/api/v1/agents/pc/requests", map[string]any{"method": "system.metrics", "params": map[string]any{}}, f.tokens.AccessToken)
	if status != 200 {
		t.Fatal(status, string(data))
	}
	var reply struct {
		Result struct {
			CPUUsagePercent float64
			MemoryUsedBytes uint64
			GPU             struct{ Usage int }
		}
	}
	if json.Unmarshal(data, &reply) != nil || reply.Result.CPUUsagePercent != 25 || reply.Result.MemoryUsedBytes != 4<<30 || reply.Result.GPU.Usage != 42 {
		t.Fatal("metrics mismatch")
	}
}

func TestAgentOfflineAndTimeout(t *testing.T) {
	f := newFixture(t, true)
	status, _ := f.call("POST", "/api/v1/agents/pc/requests", map[string]any{"method": "system.metrics", "params": map[string]any{}}, f.tokens.AccessToken)
	if status != 409 {
		t.Fatal(status)
	}
	f.connectAgent(false)
	status, _ = f.call("POST", "/api/v1/agents/pc/requests", map[string]any{"method": "system.metrics", "params": map[string]any{}}, f.tokens.AccessToken)
	if status != 504 {
		t.Fatal(status)
	}
}

func TestDatabaseEncrypted(t *testing.T) {
	f := newFixture(t, true)
	var blob []byte
	if err := f.s.store.db.QueryRow("SELECT value FROM state WHERE id=1").Scan(&blob); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(blob, []byte(f.tokens.SessionID)) || bytes.Contains(blob, []byte(f.tokens.RefreshToken)) {
		t.Fatal("secret stored in plaintext")
	}
	wrong := make([]byte, 32)
	if st, err := openStore(f.s.config.Database, wrong); err == nil {
		st.db.Close()
		t.Fatal("wrong database key accepted")
	}
}
