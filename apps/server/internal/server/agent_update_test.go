package server

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestAgentUpdateAuthenticationAndConnectionIsolation(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false)
	before, _ := f.s.agentHub.Lookup("PC")
	makeRequest := func(event map[string]any) map[string]string {
		data, _ := json.Marshal(event)
		payload := base64.StdEncoding.EncodeToString(data)
		keyID := f.s.config.Agents[0].keyID
		hash := sha256.Sum256([]byte("hako-agent-update/v1\n" + f.s.config.PublicURL + "\nowner\n" + keyID + "\n" + payload))
		signature, err := rsa.SignPSS(rand.Reader, f.agentKey, crypto.SHA256, hash[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
		if err != nil {
			t.Fatal(err)
		}
		return map[string]string{"username": "owner", "keyId": keyID, "payload": payload, "signature": base64.StdEncoding.EncodeToString(signature)}
	}
	event := map[string]any{"updateId": "11111111-1111-4111-8111-111111111111", "stage": "started", "fromVersion": "1.4.3", "toVersion": "1.4.4", "occurredAt": time.Now().UnixMilli(), "running": false}
	request := makeRequest(event)
	if code, _ := f.call("POST", "/api/v1/agents/update-notifications", map[string]any{}, ""); code != 401 {
		t.Fatal("unauthenticated", code)
	}
	request["payload"] = base64.StdEncoding.EncodeToString([]byte(`{}`))
	if code, _ := f.call("POST", "/api/v1/agents/update-notifications", request, ""); code != 401 {
		t.Fatal("tampered proof", code)
	}
	event["computerId"] = "other"
	if code, _ := f.call("POST", "/api/v1/agents/update-notifications", makeRequest(event), ""); code != 400 {
		t.Fatal("forged identity", code)
	}
	delete(event, "computerId")
	for i := 0; i < 2; i++ {
		if code, body := f.call("POST", "/api/v1/agents/update-notifications", makeRequest(event), ""); code != 200 || !strings.Contains(string(body), `"status":"skipped"`) {
			t.Fatal(code, string(body))
		}
	}
	after, _ := f.s.agentHub.Lookup("PC")
	if before != after {
		t.Fatal("notification replaced the live Agent connection")
	}
	select {
	case <-after.Done():
		t.Fatal("notification closed the live Agent")
	default:
	}
}
