package server

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func TestIndependentProxyAuthentication(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false)
	body := map[string]any{"version": 1, "request": map[string]string{"opaque": "payload"}}
	if status, _ := f.call("POST", "/api/v1/proxy/PC/requests", body, ""); status != 401 {
		t.Fatal("proxy missing Console authorization", status)
	}
	if status, _ := f.call("POST", "/api/v1/proxy/PC/requests", body, f.tokens.AccessToken); status != 409 {
		t.Fatal("proxy used monitoring connection", status)
	}
	f.connectChannelMetadata("PC", true, false, nil, 1, true)
	if peer, _ := f.s.proxyHub.Lookup("PC"); peer != nil {
		t.Fatal("untrusted proxy registered")
	}
}

func TestIndependentProxyOpaqueRelay(t *testing.T) {
	f := newFixture(t, true)
	f.s.config.RequestTimeout = 30 * time.Second
	monitor := f.connectAgent(false)
	normal, _ := f.s.agentHub.Lookup("PC")
	proxy := f.connectChannelMetadata("PC", false, true, []agent.Capability{{Name: "ignored.proxy.manifest", Version: 9}}, 1, true)
	if current, _ := f.s.agentHub.Lookup("PC"); current != normal {
		t.Fatal("proxy replaced monitoring peer")
	}
	for _, item := range f.s.agentItems(false) {
		if item["id"] == "PC" && !strings.Contains(string(item["capabilities"].(json.RawMessage)), "query.system.metrics") {
			t.Fatal("proxy overwrote command manifest")
		}
	}
	// Sora must not validate a proxy's business protocol or HTTP parameters.
	opaque := map[string]any{"version": "future", "unknown": map[string]string{"data": strings.Repeat("x", 720*1024)}}
	expected, _ := json.Marshal(opaque)
	reply := json.RawMessage(`{"result":{"opaque":"` + strings.Repeat("y", 11*1024*1024) + `"},"future":true}`)
	done := make(chan error, 1)
	go func() {
		var request map[string]json.RawMessage
		if err := proxy.ReadJSON(&request); err != nil {
			done <- err
			return
		}
		var id string
		_ = json.Unmarshal(request["id"], &id)
		delete(request, "type")
		delete(request, "id")
		got, _ := json.Marshal(request)
		if string(got) != string(expected) {
			done <- &requestMismatch{}
			return
		}
		var response map[string]json.RawMessage
		_ = json.Unmarshal(reply, &response)
		response["type"] = json.RawMessage(`"response"`)
		response["id"], _ = json.Marshal(id)
		done <- proxy.WriteJSON(response)
	}()
	// Saturated command slots must not block this independent service.
	for i := 0; i < cap(f.s.requests); i++ {
		f.s.requests <- struct{}{}
	}
	status, data := f.call("POST", "/api/v1/proxy/PC/requests", opaque, f.tokens.AccessToken)
	for i := 0; i < cap(f.s.requests); i++ {
		<-f.s.requests
	}
	if status != 200 {
		t.Fatalf("proxy relay rejected envelope: %d %s", status, data)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	var got, want any
	_ = json.Unmarshal(data, &got)
	_ = json.Unmarshal(reply, &want)
	gotJSON, _ := json.Marshal(got)
	wantJSON, _ := json.Marshal(want)
	if status != 200 || string(gotJSON) != string(wantJSON) {
		t.Fatal("proxy changed opaque reply", status, len(data))
	}
	// Closing the proxy leaves the normal command socket usable.
	_ = proxy.Close()
	go func() {
		for {
			var request agent.Message
			if monitor.ReadJSON(&request) != nil {
				return
			}
			if request.Type == "ping" {
				_ = monitor.WriteJSON(agent.Message{Type: "pong"})
				continue
			}
			_ = monitor.WriteJSON(agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: json.RawMessage(`{"monitor":true}`)}})
			return
		}
	}()
	status, data = f.call("POST", "/api/v1/agents/PC/requests", agent.Request{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)}, f.tokens.AccessToken)
	if status != 200 || !strings.Contains(string(data), `"monitor":true`) {
		t.Fatal("proxy disconnect interrupted commands", status)
	}
}

func TestIndependentProxyTimeoutAndLimits(t *testing.T) {
	f := newFixture(t, true)
	proxy := f.connectChannelMetadata("PC", false, false, nil, 1, true)
	received := make(chan bool, 1)
	go func() { var request agent.Message; received <- proxy.ReadJSON(&request) == nil }()
	status, _ := f.call("POST", "/api/v1/proxy/PC/requests", map[string]int{"version": 1}, f.tokens.AccessToken)
	if status != 504 || !<-received {
		t.Fatal("proxy timeout result changed", status)
	}
	for i := 0; i < cap(f.s.proxyRequests); i++ {
		f.s.proxyRequests <- struct{}{}
	}
	status, _ = f.call("POST", "/api/v1/proxy/PC/requests", map[string]int{"version": 1}, f.tokens.AccessToken)
	for i := 0; i < cap(f.s.proxyRequests); i++ {
		<-f.s.proxyRequests
	}
	if status != 429 {
		t.Fatal("unbounded proxy requests", status)
	}
	status, _ = f.call("POST", "/api/v1/proxy/PC/requests", map[string]string{"large": strings.Repeat("x", agent.MaxRequestBytes)}, f.tokens.AccessToken)
	if status != 400 {
		t.Fatal("unbounded proxy request body", status)
	}
}

func TestProxyKeyRotationClosesBothServices(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false)
	f.connectChannelMetadata("PC", false, false, nil, 1, true)
	monitor, _ := f.s.agentHub.Lookup("PC")
	proxy, _ := f.s.proxyHub.Lookup("PC")
	prior := f.s.registry.Load().Agents[0]
	replacement := newFixture(t, false).s.registry.Load().Agents[0].PublicKeyPEM
	reply := f.s.saveAgentUpdate("PC", agentUpdate{Name: prior.Name, PublicKeyPEM: replacement, Revision: agentEditRevision(prior)})
	if reply.Status != 200 {
		t.Fatal("key rotation failed", reply.Status)
	}
	for _, connection := range []*agent.Connection{monitor, proxy} {
		select {
		case <-connection.Done():
		default:
			t.Fatal("revoked key retained a live service")
		}
	}
	if connection, _ := f.s.proxyHub.Lookup("PC"); connection != nil {
		t.Fatal("revoked proxy remained discoverable")
	}
}

func TestIndependentProxyClientSocketIsolation(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false)
	proxy := f.connectChannelMetadata("PC", false, false, nil, 1, true)
	const path = "/ws/proxy/client/PC"
	for _, tc := range []struct {
		auth   bool
		origin string
		status int
	}{{false, "", 401}, {true, "https://attacker.example", 403}} {
		ws, response, err := dialConsoleAgentSocket(f, path, tc.auth, tc.origin)
		if ws != nil {
			_ = ws.Close()
		}
		if response != nil {
			_ = response.Body.Close()
		}
		if err == nil || response == nil || response.StatusCode != tc.status {
			t.Fatal("proxy client bypassed authentication/origin checks")
		}
	}
	client := openConsoleAgentSocket(t, f, path)
	writeAgentFrame(t, client, consoleAgentCommand{Type: "list", ID: "no-catalog"})
	if reply := readAgentFrame[consoleAgentReply](t, client); reply.Status != 400 {
		t.Fatal("proxy socket executed control-plane operation")
	}
	writeAgentFrame(t, client, consoleAgentCommand{Type: "request", ID: "proxy-request", AgentID: "untrusted-other-device", Body: json.RawMessage(`{"version":"future","opaque":true}`)})
	request := readAgentFrame[map[string]json.RawMessage](t, proxy)
	if string(request["opaque"]) != "true" || request["method"] != nil {
		t.Fatal("proxy body entered Agent command framing")
	}
	var id string
	_ = json.Unmarshal(request["id"], &id)
	writeAgentFrame(t, proxy, map[string]any{"type": "response", "id": id, "result": map[string]bool{"proxy": true}})
	if reply := readAgentFrame[consoleAgentReply](t, client); reply.ID != "proxy-request" || reply.Status != 200 {
		t.Fatal("proxy reply correlation failed")
	}
	_ = proxy.Close()
	_ = client.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := client.ReadMessage(); err == nil {
		t.Fatal("proxy client stayed attached to a lost backend")
	}
	if peer, _ := f.s.agentHub.Lookup("PC"); peer == nil {
		t.Fatal("proxy loss closed the command connection")
	}
}
