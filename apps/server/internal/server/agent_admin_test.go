package server

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func TestDeviceCommandsAndResultsAreOpaque(t *testing.T) {
	f := newFixture(t, true)
	// An empty manifest is metadata, not permission to reject commands.
	peer := f.connectAgent(false, []agent.Capability{}...)
	console := openConsoleAgentSocket(t, f, "/ws/console/agents")
	for _, body := range []string{
		`{"method":"admin.services.status","version":1,"params":{}}`,
		`{"method":"admin.services.start","version":1,"params":{"requestId":"opaque"}}`,
		`{"method":"future:新命令","version":"next","params":[null,9007199254740993],"extension":{"keep":true}}`,
		`{"method":"query.all","version":-1,"params":null}`,
		`{"method":false,"params":"opaque","version":{"major":12}}`,
		`{}`,
	} {
		writeAgentFrame(t, console, consoleAgentCommand{Type: "request", ID: "opaque", AgentID: "PC", Body: json.RawMessage(body)})
		request := readAgentFrame[map[string]json.RawMessage](t, peer)
		var expected map[string]json.RawMessage
		_ = json.Unmarshal([]byte(body), &expected)
		for key, value := range expected {
			if !bytes.Equal(request[key], value) {
				t.Fatalf("request field %s changed: %s != %s", key, request[key], value)
			}
		}
		if len(request) != len(expected)+2 || string(request["type"]) != `"request"` {
			t.Fatal("unexpected request envelope", request)
		}
		response := map[string]json.RawMessage{
			"type": json.RawMessage(`"response"`), "id": request["id"],
			"result": json.RawMessage(`null`), "error": json.RawMessage(`"device-owned schema"`),
			"extension": json.RawMessage(`{"bytes":9007199254740993}`),
		}
		writeAgentFrame(t, peer, response)
		reply := readAgentFrame[struct {
			Status int
			Body   map[string]json.RawMessage
		}](t, console)
		if reply.Status != 200 || len(reply.Body) != 3 {
			t.Fatal("server added metadata or rejected device response", reply)
		}
		for _, key := range []string{"result", "error", "extension"} {
			if !bytes.Equal(reply.Body[key], response[key]) {
				t.Fatal("response field changed", key)
			}
		}
	}
	live := openConsoleAgentSocket(t, f, "/ws/console/agents/live/PC")
	if reply := readAgentFrame[consoleAgentReply](t, live); reply.Type != "subscribed" {
		t.Fatal(reply)
	}
	start := readAgentFrame[agent.Message](t, peer)
	if start.Type != "telemetry_start" {
		t.Fatal("subscription invoked a business command", start)
	}
	writeAgentFrame(t, peer, map[string]any{"type": "telemetry_update", "id": start.ID, "method": "future:stream", "version": "next", "opaque": []any{true, nil}})
	received := readAgentFrame[map[string]json.RawMessage](t, live)
	if string(received["type"]) != `"update"` || string(received["method"]) != `"future:stream"` || string(received["version"]) != `"next"` || string(received["opaque"]) != `[true,null]` {
		t.Fatal("telemetry was interpreted or dropped", received)
	}
	_ = peer.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	if _, _, err := peer.ReadMessage(); err == nil {
		t.Fatal("subscription invoked a business command")
	}
}

func TestDeviceMetadataIsOpaqueAndAuthenticated(t *testing.T) {
	for _, metadata := range []json.RawMessage{json.RawMessage(`null`), json.RawMessage(`[]`), json.RawMessage(`{"futureSchema":"v2"}`), json.RawMessage(`[{"name":"any prefix","version":0,"extension":true}]`)} {
		f := newFixture(t, true)
		f.connectAgentMetadata("PC", false, false, metadata, "device-owned-version")
		restarted, err := New(f.s.config)
		if err != nil {
			t.Fatal(err)
		}
		stored := restarted.agentItems(false)[0]["capabilities"].(json.RawMessage)
		restarted.Close()
		if !bytes.Equal(stored, metadata) {
			t.Fatalf("device metadata changed: %s != %s", stored, metadata)
		}
		f.connectAgentMetadata("PC", true, false, json.RawMessage(`{"untrusted":true}`), 0)
		stored = f.s.agentItems(false)[0]["capabilities"].(json.RawMessage)
		if !bytes.Equal(stored, metadata) {
			t.Fatal("unauthenticated metadata replaced the trusted manifest")
		}
	}
}
