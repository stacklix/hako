package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestGenericAgentRequests(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	ws := f.connectAgent(false, agentMethod{Name: "future.action", Version: 7})
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
				var req agentMessage
				if err := ws.ReadJSON(&req); err != nil {
					agentDone <- err
					return
				}
				if req.Type != "request" || req.ID == "" || req.Method != "future.action" || !bytes.Equal(req.Params, params) {
					agentDone <- &requestMismatch{}
					return
				}
				agentDone <- ws.WriteJSON(agentMessage{Type: "response", ID: req.ID, agentResult: agentResult{Result: json.RawMessage(result)}})
			}()
			body := agentRequest{Method: "future.action", Params: params}
			var data []byte
			if browser {
				data = a.call("POST", "agents/pc/requests", body, 200)
			} else {
				status, response := f.call("POST", "/api/v1/agents/pc/requests", body, f.tokens.AccessToken)
				if status != 200 {
					t.Fatal(status, string(response))
				}
				data = response
			}
			if err := <-agentDone; err != nil {
				t.Fatal(err)
			}
			var reply agentResult
			if json.Unmarshal(data, &reply) != nil || string(reply.Result) != result || reply.Error != nil {
				t.Fatalf("result changed: %s", data)
			}
		}
	}
	for _, data := range [][]byte{
		a.call("GET", "overview", nil, 200),
		func() []byte {
			status, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
			if status != 200 {
				t.Fatal(status)
			}
			return data
		}(),
	} {
		var list struct {
			Agents []struct{ Methods []agentMethod }
		}
		if json.Unmarshal(data, &list) != nil || len(list.Agents) != 1 || len(list.Agents[0].Methods) != 1 || list.Agents[0].Methods[0] != (agentMethod{Name: "future.action", Version: 7}) {
			t.Fatal("capabilities not exposed", string(data))
		}
	}
}

type requestMismatch struct{}

func (*requestMismatch) Error() string { return "method, params or request ID changed in transit" }

func TestAgentActionErrorAndValidation(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	body := agentRequest{Method: "system.metrics", Params: json.RawMessage(`{}`)}
	go func() {
		var req agentMessage
		if ws.ReadJSON(&req) == nil {
			_ = ws.WriteJSON(agentMessage{Type: "response", ID: req.ID, agentResult: agentResult{Error: &agentError{Code: "future_error", Message: "A new error from the agent"}}})
		}
	}()
	status, data := f.call("POST", "/api/v1/agents/pc/requests", body, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"code":"future_error"`)) || !bytes.Contains(data, []byte(`"message":"A new error from the agent"`)) || bytes.Contains(data, []byte(`"result"`)) {
		t.Fatal("agent error was lost", status, string(data))
	}
	for _, invalid := range []string{
		`{}`, `null`, `{"method":"system.metrics"}`, `{"method":"bad method","params":{}}`,
		`{"method":"system.metrics","params":null}`, `{"method":"system.metrics","params":[]}`,
		`{"method":"system.metrics","params":"{}"}`, `{"method":"system.metrics","params":{},"extra":true}`,
		`{"method":"future.unsupported","params":{}}`, `{"method":"system.metrics","params":{}} {}`,
	} {
		status, _ = f.call("POST", "/api/v1/agents/pc/requests", json.RawMessage(invalid), f.tokens.AccessToken)
		if status != 400 {
			t.Fatal("invalid request accepted", invalid, status)
		}
	}
	status, _ = f.call("POST", "/api/v1/agents/pc/requests", body, "")
	if status != 401 {
		t.Fatal("unsigned request accepted", status)
	}
	a := loginAdmin(f)
	status, _, _ = a.request("POST", "/admin/api/agents/pc/requests", body, f.s.config.PublicURL, "")
	if status != 403 {
		t.Fatal("request without CSRF accepted", status)
	}
	for _, path := range []string{"agents/pc/metrics/query"} {
		status, _ = f.call("POST", "/api/v1/"+path, nil, f.tokens.AccessToken)
		if status != 404 {
			t.Fatal("legacy Console route retained", status)
		}
		// The GET /admin/ subtree makes unknown POST paths return 405.
		a.call("POST", path, map[string]any{}, 405)
	}
}

func TestLateAgentReplyCannotCompleteNextRequest(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	body := agentRequest{Method: "system.metrics", Params: json.RawMessage(`{}`)}
	type response struct {
		status int
		data   []byte
	}
	done := make(chan response, 1)
	call := func() {
		status, data := f.call("POST", "/api/v1/agents/pc/requests", body, f.tokens.AccessToken)
		done <- response{status, data}
	}
	go call()
	var first, second agentMessage
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
	_ = ws.WriteJSON(agentMessage{Type: "response", ID: first.ID, agentResult: agentResult{Result: json.RawMessage(`"stale"`)}})
	_ = ws.WriteJSON(agentMessage{Type: "response", ID: second.ID, agentResult: agentResult{Result: json.RawMessage(`"fresh"`)}})
	if result := <-done; result.status != 200 || !bytes.Contains(result.data, []byte(`"fresh"`)) {
		t.Fatal(result.status, string(result.data))
	}
}

func TestInvalidAgentResponseDisconnects(t *testing.T) {
	for _, response := range []agentResult{
		{}, {Result: json.RawMessage(`null`), Error: &agentError{Code: "failed"}},
		{Error: &agentError{Code: ""}}, {Error: &agentError{Code: "failed", Message: strings.Repeat("x", 1025)}},
	} {
		f := newFixture(t, true)
		ws := f.connectAgent(false)
		go func() {
			var req agentMessage
			if ws.ReadJSON(&req) == nil {
				_ = ws.WriteJSON(agentMessage{Type: "response", ID: req.ID, agentResult: response})
			}
		}()
		status, _ := f.call("POST", "/api/v1/agents/pc/requests", agentRequest{Method: "system.metrics", Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
		if status != 409 {
			t.Fatal("invalid response accepted", status)
		}
	}
}

func TestAgentMethodManifestValidation(t *testing.T) {
	for _, methods := range [][]agentMethod{
		nil, {{Name: "bad method", Version: 1}}, {{Name: "system.metrics", Version: 0}},
		{{Name: "system.metrics", Version: 1}, {Name: "system.metrics", Version: 2}},
		{{Name: strings.Repeat("x", 101) + ".metrics", Version: 1}}, make([]agentMethod, 65),
	} {
		if validMethods(methods) {
			t.Fatal("invalid manifest accepted", methods)
		}
	}
	if !validMethods([]agentMethod{{Name: "future.action", Version: 7}}) {
		t.Fatal("future method rejected")
	}
}

func TestAgentConnectionReplacesCapabilities(t *testing.T) {
	f := newFixture(t, true)
	old := f.connectAgent(false)
	current := f.connectAgent(false, agentMethod{Name: "future.action", Version: 2})
	status, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"name":"future.action"`)) || bytes.Contains(data, []byte(`"name":"system.metrics"`)) {
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
		f.s.mu.Lock()
		offline := f.s.online["pc"] == nil
		f.s.mu.Unlock()
		if offline {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("agent stayed online")
		}
		time.Sleep(time.Millisecond)
	}
	status, data = f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if status != 200 || !bytes.Contains(data, []byte(`"methods":[]`)) || !bytes.Contains(data, []byte(`"online":false`)) {
		t.Fatal("offline capabilities retained", status, string(data))
	}
}

func TestAgentRejectsLegacyHelloAndInvalidManifest(t *testing.T) {
	f := newFixture(t, true)
	for _, hello := range []agentMessage{
		{Type: "hello", Version: 1, Username: "owner", KeyID: f.s.config.Agents[0].keyID, Methods: []agentMethod{{Name: "system.metrics", Version: 1}}},
		{Type: "hello", Version: 2, Username: "owner", KeyID: f.s.config.Agents[0].keyID},
	} {
		dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
		ws, _, err := dialer.Dial("wss"+strings.TrimPrefix(f.http.URL, "https")+"/ws/agent", nil)
		if err != nil {
			t.Fatal(err)
		}
		_ = ws.SetReadDeadline(time.Now().Add(time.Second))
		_ = ws.WriteJSON(hello)
		var response any
		err = ws.ReadJSON(&response)
		_ = ws.Close()
		if !websocket.IsCloseError(err, websocket.ClosePolicyViolation) {
			t.Fatal("invalid hello accepted", err)
		}
	}
}

func TestAgentRequestConcurrencyLimits(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	f.s.config.RequestTimeout = 5 * time.Second
	body := agentRequest{Method: "system.metrics", Params: json.RawMessage(`{}`)}
	completed := make(chan int, 4)
	requests := make([]agentMessage, 4)
	for i := range requests {
		go func() {
			status, _ := f.call("POST", "/api/v1/agents/pc/requests", body, f.tokens.AccessToken)
			completed <- status
		}()
		if err := ws.ReadJSON(&requests[i]); err != nil {
			t.Fatal(err)
		}
	}
	status, data := f.call("POST", "/api/v1/agents/pc/requests", body, f.tokens.AccessToken)
	if status != 429 || !bytes.Contains(data, []byte(`agent_busy`)) {
		t.Fatal("per-agent limit lost", status, string(data))
	}
	// Return out of order to verify that each pending request has its own ID.
	for i := len(requests) - 1; i >= 0; i-- {
		_ = ws.WriteJSON(agentMessage{Type: "response", ID: requests[i].ID, agentResult: agentResult{Result: json.RawMessage(`true`)}})
	}
	for range requests {
		if status := <-completed; status != 200 {
			t.Fatal(status)
		}
	}
	for i := 0; i < cap(f.s.requests); i++ {
		f.s.requests <- struct{}{}
	}
	status, data = f.call("POST", "/api/v1/agents/pc/requests", body, f.tokens.AccessToken)
	for i := 0; i < cap(f.s.requests); i++ {
		<-f.s.requests
	}
	if status != 429 || !bytes.Contains(data, []byte(`too_many_requests`)) {
		t.Fatal("global limit lost", status, string(data))
	}
}
