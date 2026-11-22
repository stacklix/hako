package server

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func TestLargeOpaqueAgentHTTPEnvelope(t *testing.T) {
	f := newFixture(t, true)
	// This tests envelope bounds, not latency. Race instrumentation and memory
	// pressure can make parsing an 11 MiB JSON reply substantially slower.
	f.s.config.RequestTimeout = 30 * time.Second
	ws := f.connectAgent(false)
	params, _ := json.Marshal(map[string]string{"opaque": strings.Repeat("x", 720*1024)})
	result, _ := json.Marshal(map[string]string{"opaque": strings.Repeat("y", 11*1024*1024)})
	done := make(chan error, 1)
	go func() {
		var request agent.Message
		if err := ws.ReadJSON(&request); err != nil {
			done <- err
			return
		}
		if string(request.Params) != string(params) {
			done <- &requestMismatch{}
			return
		}
		done <- ws.WriteJSON(agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: result}})
	}()
	status, data := f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "action.opaque.future", Version: 1, Params: params}, f.tokens.AccessToken)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	var reply agent.Reply
	if status != 200 || json.Unmarshal(data, &reply) != nil || string(reply.Result) != string(result) {
		t.Fatalf("opaque envelope truncated: status=%d bytes=%d", status, len(data))
	}
	oversized, _ := json.Marshal(map[string]string{"opaque": strings.Repeat("x", agent.MaxRequestBytes)})
	status, _ = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "action.opaque.future", Version: 1, Params: oversized}, f.tokens.AccessToken)
	if status != 400 {
		t.Fatalf("oversized envelope accepted: %d", status)
	}
}
