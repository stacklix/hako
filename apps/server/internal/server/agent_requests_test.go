package server

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func TestGenericAgentRequests(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	ws := f.connectAgent(false, agent.Capability{Name: "action.future.execute", Version: 7})
	f.s.config.RequestTimeout = 2 * time.Second
	params := json.RawMessage(`{"drive":"C:","nested":[true,null,{"bytes":9007199254740993}]}`)
	results := []string{
		`{"newMetric":{"gpu":42},"bytes":9007199254740993}`,
		`[1,"two",null,{"nested":true}]`, `null`, `false`, `42`, `"done"`,
	}
	for _, result := range results {
		for _, browser := range []bool{false, true} {
			agentDone := make(chan error, 1)
			go func() {
				var req agent.Message
				if err := ws.ReadJSON(&req); err != nil {
					agentDone <- err
					return
				}
				if req.Type != "request" || req.ID == "" || req.Method != "action.future.execute" || req.Version != 7 || !bytes.Equal(req.Params, params) {
					agentDone <- &requestMismatch{}
					return
				}
				agentDone <- ws.WriteJSON(agent.Message{Type: "response", ID: req.ID, Reply: agent.Reply{Result: json.RawMessage(result)}})
			}()
			body := agent.Request{Method: "action.future.execute", Version: 7, Params: params}
			var data []byte
			if browser {
				data = a.call("POST", "agents/PC/requests", body, 200)
			} else {
				status, response := f.call("POST", "/api/v1/agents/PC/requests", body, f.tokens.AccessToken)
				if status != 200 {
					t.Fatal(status, string(response))
				}
				data = response
			}
			if err := <-agentDone; err != nil {
				t.Fatal(err)
			}
			var reply agent.Reply
			if json.Unmarshal(data, &reply) != nil || string(reply.Result) != result || reply.Error != nil {
				t.Fatalf("result changed: %s", data)
			}
		}
	}
	for _, data := range [][]byte{
		a.call("GET", "agents", nil, 200),
		func() []byte {
			status, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
			if status != 200 {
				t.Fatal(status)
			}
			return data
		}(),
	} {
		var list struct {
			Agents []struct{ Capabilities []agent.Capability }
		}
		if json.Unmarshal(data, &list) != nil || len(list.Agents) != 1 || len(list.Agents[0].Capabilities) != 1 || list.Agents[0].Capabilities[0] != (agent.Capability{Name: "action.future.execute", Version: 7}) {
			t.Fatal("capabilities not exposed", string(data))
		}
	}
}

type requestMismatch struct{}

func (*requestMismatch) Error() string { return "method, params or request ID changed in transit" }

func TestAgentActionErrorAndValidation(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	body := agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}
	go func() {
		var req agent.Message
		if ws.ReadJSON(&req) == nil {
			_ = ws.WriteJSON(agent.Message{Type: "response", ID: req.ID, Reply: agent.Reply{Error: &agent.Error{Code: "future_error", Message: "A new error from the agent"}}})
		}
	}()
	status, data := f.call("POST", "/api/v1/agents/PC/requests", body, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"future_error"`)) || !bytes.Contains(data, []byte(`"message":"A new error from the agent"`)) || bytes.Contains(data, []byte(`"result"`)) {
		t.Fatal("agent error was lost", status, string(data))
	}
	for _, malformed := range []string{`null`, `[]`, `{"method":"x"} {}`} {
		status, _ = f.call("POST", "/api/v1/agents/PC/requests", json.RawMessage(malformed), f.tokens.AccessToken)
		if status != 400 {
			t.Fatal("malformed transport envelope accepted", status)
		}
	}
	status, _ = f.call("POST", "/api/v1/agents/PC/requests", body, "")
	if status != 401 {
		t.Fatal("unsigned request accepted", status)
	}
	a := loginAdmin(f)
	status, _, _ = a.request("POST", "/consilium/api/agents/PC/requests", body, f.s.config.PublicURL, "")
	if status != 403 {
		t.Fatal("request without CSRF accepted", status)
	}
	for _, path := range []string{"agents/PC/metrics/query"} {
		status, _ = f.call("POST", "/api/v1/"+path, nil, f.tokens.AccessToken)
		if status != 404 {
			t.Fatal("legacy Console route retained", status)
		}
		// The GET /consilium/ subtree makes unknown POST paths return 405.
		a.call("POST", path, map[string]any{}, 405)
	}
}

func TestLateAgentReplyCannotCompleteNextRequest(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	body := agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}
	type response struct {
		status int
		data   []byte
	}
	done := make(chan response, 1)
	call := func() {
		status, data := f.call("POST", "/api/v1/agents/PC/requests", body, f.tokens.AccessToken)
		done <- response{status, data}
	}
	go call()
	var first, second agent.Message
	if err := ws.ReadJSON(&first); err != nil {
		t.Fatal(err)
	}
	if result := <-done; result.status != 504 {
		t.Fatal(result.status)
	}
	go call()
	if err := ws.ReadJSON(&second); err != nil {
		t.Fatal(err)
	}
	_ = ws.WriteJSON(agent.Message{Type: "response", ID: first.ID, Reply: agent.Reply{Result: json.RawMessage(`"stale"`)}})
	_ = ws.WriteJSON(agent.Message{Type: "response", ID: second.ID, Reply: agent.Reply{Result: json.RawMessage(`"fresh"`)}})
	if result := <-done; result.status != 200 || !bytes.Contains(result.data, []byte(`"fresh"`)) {
		t.Fatal(result.status, string(result.data))
	}
}

func TestAgentResponseSemanticsAreNotValidated(t *testing.T) {
	for _, response := range []agent.Reply{
		{}, {Result: json.RawMessage(`null`), Error: &agent.Error{Code: "failed"}},
		{Error: &agent.Error{Code: ""}}, {Error: &agent.Error{Code: "failed", Message: strings.Repeat("x", 1025)}},
	} {
		f := newFixture(t, true)
		ws := f.connectAgent(false)
		go func() {
			var req agent.Message
			if ws.ReadJSON(&req) == nil {
				_ = ws.WriteJSON(agent.Message{Type: "response", ID: req.ID, Reply: response})
			}
		}()
		status, _ := f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
		if status != 200 {
			t.Fatal("server interpreted an opaque response", status)
		}
	}
}

func TestAgentConnectionReplacesCapabilities(t *testing.T) {
	f := newFixture(t, true)
	old := f.connectAgent(false)
	current := f.connectAgent(false, agent.Capability{Name: "action.future.execute", Version: 2})
	status, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"name":"action.future.execute"`)) || bytes.Contains(data, []byte(`"name":"query.system.metrics"`)) {
		t.Fatal("old capabilities retained", status, string(data))
	}
	_ = old.SetReadDeadline(time.Now().Add(time.Second))
	var message any
	if old.ReadJSON(&message) == nil {
		t.Fatal("previous connection retained")
	}
	_ = current.Close()
	deadline := time.Now().Add(time.Second)
	for {
		peer, _ := f.s.agentHub.Lookup("PC")
		offline := peer == nil
		if offline {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("agent stayed online")
		}
		time.Sleep(time.Millisecond)
	}
	status, data = f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"capabilities":[{"name":"action.future.execute","version":2}]`)) || !bytes.Contains(data, []byte(`"online":false`)) {
		t.Fatal("offline capabilities lost", status, string(data))
	}
}

func TestAgentRequestConcurrencyLimits(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	f.s.config.RequestTimeout = 5 * time.Second
	body := agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}
	completed := make(chan int, agent.MaxConcurrentRequests)
	requests := make([]agent.Message, agent.MaxConcurrentRequests)
	for i := range requests {
		go func() {
			status, _ := f.call("POST", "/api/v1/agents/PC/requests", body, f.tokens.AccessToken)
			completed <- status
		}()
		if err := ws.ReadJSON(&requests[i]); err != nil {
			t.Fatal(err)
		}
	}
	status, data := f.call("POST", "/api/v1/agents/PC/requests", body, f.tokens.AccessToken)
	if status != 429 || !bytes.Contains(data, []byte(`agent_busy`)) {
		t.Fatal("per-agent limit lost", status, string(data))
	}
	// Return out of order to verify that each pending request has its own ID.
	for i := len(requests) - 1; i >= 0; i-- {
		_ = ws.WriteJSON(agent.Message{Type: "response", ID: requests[i].ID, Reply: agent.Reply{Result: json.RawMessage(`true`)}})
	}
	for range requests {
		if status := <-completed; status != 200 {
			t.Fatal(status)
		}
	}
	for i := 0; i < cap(f.s.requests); i++ {
		f.s.requests <- struct{}{}
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", body, f.tokens.AccessToken)
	for i := 0; i < cap(f.s.requests); i++ {
		<-f.s.requests
	}
	if status != 429 || !bytes.Contains(data, []byte(`too_many_requests`)) {
		t.Fatal("global limit lost", status, string(data))
	}
}
