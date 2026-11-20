package server

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestConsoleAgentEditPreservesIdentityAndConnection(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false)
	connection, _ := f.s.agentHub.Lookup("PC")
	if reply := f.s.saveAgentDataPermission("PC", true); reply.Status != 200 {
		t.Fatal(reply)
	}
	before := f.s.registry.Load().Agents[0]
	ws := openConsoleAgentSocket(t, f, "/ws/console/agents")
	writeAgentFrame(t, ws, consoleAgentCommand{ID: "detail", Type: "detail", AgentID: "PC"})
	detail := readAgentFrame[consoleAgentReply](t, ws)
	body := detail.Body.(map[string]any)
	if detail.Status != 200 || body["publicKeyPem"] != before.PublicKeyPEM || body["id"] != "PC" {
		t.Fatal(detail)
	}
	request, _ := json.Marshal(agentUpdate{Name: " 新设备名 ", PublicKeyPEM: before.PublicKeyPEM, Revision: body["revision"].(string)})
	writeAgentFrame(t, ws, consoleAgentCommand{ID: "update", Type: "update", AgentID: "PC", Body: request})
	reply := readAgentFrame[consoleAgentReply](t, ws)
	after := f.s.registry.Load().Agents[0]
	if reply.Status != 200 || after.ID != before.ID || after.Name != "新设备名" || after.keyID != before.keyID ||
		!after.DataQueryEnabled || string(after.Capabilities) != string(before.Capabilities) {
		t.Fatal("rename changed identity, permission or capabilities", reply)
	}
	current, _ := f.s.agentHub.Lookup("PC")
	if current != connection {
		t.Fatal("rename disconnected the device")
	}
	select {
	case <-connection.Done():
		t.Fatal("rename closed the connection")
	default:
	}
	config := f.s.config
	config.Agents = nil
	restarted, err := New(config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	stored := restarted.registry.Load().Agents[0]
	if stored.ID != before.ID || stored.Name != after.Name || stored.keyID != before.keyID || !stored.DataQueryEnabled {
		t.Fatal("edit not persisted")
	}
}

func TestAgentEditKeyRotationRevokesOldConnection(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false)
	connection, _ := f.s.agentHub.Lookup("PC")
	previous := f.s.registry.Load().Agents[0]
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	reply := f.s.saveAgentUpdate("PC", agentUpdate{Name: previous.Name,
		PublicKeyPEM: publicPEM(t, &key.PublicKey), Revision: agentEditRevision(previous)})
	if reply.Status != 200 {
		t.Fatal(reply)
	}
	updated := f.s.registry.Load().Agents[0]
	if updated.ID != previous.ID || updated.keyID == previous.keyID || updated.Capabilities != nil {
		t.Fatal("key rotation did not preserve ID or clear old capabilities")
	}
	select {
	case <-connection.Done():
	case <-time.After(time.Second):
		t.Fatal("old-key connection remained active")
	}
	if current, _ := f.s.agentHub.Lookup("PC"); current != nil {
		t.Fatal("revoked device still online")
	}
	// The test handshake uses the configured fingerprint. Switch it to the new
	// public key and verify rejection of an untrusted signature, then reconnect.
	f.s.config.Agents[0] = updated
	f.connectAgent(true)
	f.agentKey = key
	f.connectAgent(false)
}

func TestAgentEditValidationAndConflictDoNotMutateRegistry(t *testing.T) {
	f := newFixture(t, true)
	old := f.s.registry.Load().Agents[0]
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	public := publicPEM(t, &key.PublicKey)
	if reply := f.s.saveAgentRegistration(agentRegistration{ID: "OTHER", Name: "other", PublicKeyPEM: public}); reply.Status != 201 {
		t.Fatal(reply)
	}
	private := string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	for _, tc := range []struct {
		id, name, key, revision string
		status                  int
	}{
		{"MISS", "name", old.PublicKeyPEM, agentEditRevision(old), 404},
		{"PC", "name", old.PublicKeyPEM, "", 409},
		{"PC", "name", old.PublicKeyPEM, "stale", 409},
		{"PC", " ", old.PublicKeyPEM, agentEditRevision(old), 400},
		{"PC", strings.Repeat("n", 101), old.PublicKeyPEM, agentEditRevision(old), 400},
		{"PC", "name", "invalid", agentEditRevision(old), 400},
		{"PC", "name", private, agentEditRevision(old), 400},
		{"PC", "name", public, agentEditRevision(old), 409},
	} {
		reply := f.s.saveAgentUpdate(tc.id, agentUpdate{Name: tc.name, PublicKeyPEM: tc.key, Revision: tc.revision})
		if reply.Status != tc.status {
			t.Fatalf("expected %d, got %+v", tc.status, reply)
		}
		current := f.s.registry.Load().Agents[0]
		if current.Name != old.Name || current.keyID != old.keyID {
			t.Fatal("failed edit mutated registry")
		}
	}
	if reply := f.s.agentDetail("MISS"); reply.Status != 404 {
		t.Fatal(reply)
	}
	// Updates cannot change IDs or permissions through extra JSON fields.
	for _, extra := range []string{`"id":"OTHER"`, `"dataQueryEnabled":true`} {
		body, _ := json.Marshal(agentUpdate{Name: "name", PublicKeyPEM: old.PublicKeyPEM, Revision: agentEditRevision(old)})
		body = []byte(strings.TrimSuffix(string(body), "}") + "," + extra + "}")
		reply := f.s.consoleAgentCall(context.Background(), consoleAgentCommand{Type: "update", AgentID: "PC", Body: body})
		if reply.Status != 400 {
			t.Fatal("extra edit fields accepted", reply)
		}
	}
}

func TestConcurrentAgentEditsRejectStaleRevision(t *testing.T) {
	f := newFixture(t, true)
	original := f.s.registry.Load().Agents[0]
	var wg sync.WaitGroup
	replies := make(chan agentAPIReply, 2)
	for _, name := range []string{"first", "second"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			replies <- f.s.saveAgentUpdate("PC", agentUpdate{Name: name, PublicKeyPEM: original.PublicKeyPEM, Revision: agentEditRevision(original)})
		}()
	}
	wg.Wait()
	close(replies)
	statuses := map[int]int{}
	for reply := range replies {
		statuses[reply.Status]++
	}
	if statuses[200] != 1 || statuses[409] != 1 {
		t.Fatal("concurrent edits overwrote one another", statuses)
	}
}
