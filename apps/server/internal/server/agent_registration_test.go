package server

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestConsoleAddAgentLifecycleAndPersistence(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	a.call("DELETE", "agents/pc", nil, 200)
	public := publicPEM(t, &f.agentKey.PublicKey)
	status, data := f.call("POST", "/api/v1/agents", map[string]string{"id": "pc", "name": " 我的电脑 ", "publicKeyPem": public}, f.tokens.AccessToken)
	var created struct{ ID, KeyID string }
	if status != 201 || json.Unmarshal(data, &created) != nil || created.ID != "pc" || created.KeyID != f.s.registry.Load().Agents[0].keyID {
		t.Fatalf("Console registration failed: %d %s", status, data)
	}
	if created.KeyID == "" || f.s.registry.Load().Agents[0].Name != "我的电脑" {
		t.Fatal("registration did not normalize the device or compute its fingerprint")
	}
	// Enrollment is immediately shared with the Web UI and the Agent handshake.
	data = a.call("GET", "overview", nil, 200)
	if !bytes.Contains(data, []byte(created.KeyID)) {
		t.Fatal("Console enrollment is absent from Web overview")
	}
	f.connectAgent(false)
	status, data = f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"online":true`)) || bytes.Contains(data, []byte("publicKeyPem")) {
		t.Fatalf("newly registered Agent could not connect: %d %s", status, data)
	}
	config := f.s.config
	config.Agents = nil // The durable registry, rather than the seed, must retain enrollment.
	restarted, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	registered := restarted.registry.Load().Agents
	if len(registered) != 1 || registered[0].ID != "pc" || registered[0].keyID != created.KeyID || registered[0].PublicKeyPEM != public {
		t.Fatal("Console enrollment did not survive server restart")
	}
}

func TestConsoleAddAgentRequiresSessionAndFreshDeviceProof(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]string{"id": "new-pc", "name": "New PC", "publicKeyPem": publicPEM(t, &key.PublicKey)}
	for _, token := range []string{"", "invalid.token"} {
		status, data := f.call("POST", "/api/v1/agents", body, token)
		if status != 401 {
			t.Fatalf("untrusted session enrolled an Agent: %d %s", status, data)
		}
	}
	status, _, _ := a.request("POST", "/api/v1/agents", body, f.s.config.PublicURL, a.csrf)
	if status != 401 {
		t.Fatal("Web cookie substituted for Console proof")
	}
	encoded, _ := json.Marshal(body)
	proof := makeProof(f.key, "POST", f.http.URL+"/api/v1/agents", f.tokens.AccessToken, randomToken())
	send := func(withProof bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", f.http.URL+"/api/v1/agents", bytes.NewReader(encoded))
		r.Header.Set("Authorization", "DPoP "+f.tokens.AccessToken)
		r.Header.Set("X-Hako-Device", f.deviceID)
		if withProof {
			r.Header.Set("DPoP", proof)
		}
		w := httptest.NewRecorder()
		f.s.ServeHTTP(w, r)
		return w
	}
	if send(false).Code != 401 || len(f.s.registry.Load().Agents) != 1 {
		t.Fatal("access token without a device signature enrolled an Agent")
	}
	if reply := send(true); reply.Code != 201 {
		t.Fatalf("signed enrollment failed: %d %s", reply.Code, reply.Body.String())
	}
	if send(true).Code != 401 || len(f.s.registry.Load().Agents) != 2 {
		t.Fatal("replayed enrollment proof accepted")
	}
	if err := f.s.store.update(func(st *state) error { delete(st.Sessions, f.tokens.SessionID); return nil }); err != nil {
		t.Fatal(err)
	}
	status, _ = f.call("POST", "/api/v1/agents", body, f.tokens.AccessToken)
	if status != 401 {
		t.Fatal("revoked Console enrolled an Agent")
	}
}

func TestConsoleAddAgentRejectsInvalidKeysAndDuplicates(t *testing.T) {
	f := newFixture(t, true)
	ec, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	weak, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatal(err)
	}
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	public := publicPEM(t, &f.agentKey.PublicKey)
	private := string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(f.agentKey)}))
	for _, test := range []struct {
		name string
		body map[string]string
		code int
	}{
		{"private key", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": private}, 400},
		{"wrong algorithm", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": publicPEM(t, &ec.PublicKey)}, 400},
		{"weak RSA", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": publicPEM(t, &weak.PublicKey)}, 400},
		{"unsafe ID", map[string]string{"id": "../pc", "name": "PC", "publicKeyPem": public}, 400},
		{"blank name", map[string]string{"id": "pc2", "name": "  ", "publicKeyPem": public}, 400},
		{"long name", map[string]string{"id": "pc2", "name": strings.Repeat("中", 34), "publicKeyPem": public}, 400},
		{"malformed PEM", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": "invalid"}, 400},
		{"file access", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": public, "publicKeyFile": "server.json"}, 400},
		{"oversized request", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": strings.Repeat("A", 17*1024)}, 400},
		{"duplicate ID", map[string]string{"id": "pc", "name": "PC", "publicKeyPem": publicPEM(t, &other.PublicKey)}, 409},
		{"duplicate key", map[string]string{"id": "pc2", "name": "PC", "publicKeyPem": public}, 409},
	} {
		t.Run(test.name, func(t *testing.T) {
			status, data := f.call("POST", "/api/v1/agents", test.body, f.tokens.AccessToken)
			if status != test.code || len(f.s.registry.Load().Agents) != 1 {
				t.Fatalf("unexpected registration result: %d %s", status, data)
			}
			if bytes.Contains(data, []byte("PRIVATE KEY")) {
				t.Fatal("error response echoed private key material")
			}
		})
	}
}

func TestConsoleAndWebConcurrentEnrollmentKeepBothAgents(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	var requests [2]map[string]string
	for index, id := range []string{"from-phone", "from-browser"} {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatal(err)
		}
		requests[index] = map[string]string{"id": id, "name": id, "publicKeyPem": publicPEM(t, &key.PublicKey)}
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		status, data := f.call("POST", "/api/v1/agents", requests[0], f.tokens.AccessToken)
		if status != http.StatusCreated {
			t.Errorf("Console enrollment: %d %s", status, data)
		}
	}()
	go func() { defer wg.Done(); a.call("POST", "agents", requests[1], 201) }()
	wg.Wait()
	if len(f.s.registry.Load().Agents) != 3 {
		t.Fatal("concurrent Console and Web enrollment lost an Agent")
	}
}
