package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func TestAgentUnifiedModuleManifest(t *testing.T) {
	f := newFixture(t, true)
	manifest := json.RawMessage(`{"workshop":{"version":1,"lan":{"addresses":["192.168.0.10"],"port":8005}},"proxy":{"version":1},"future":{"opaque":true}}`)
	ws := f.connectChannelMetadata("PC", false, false, []agent.Capability{{Name: "query.fixture", Version: 7}}, 4, false, manifest)
	verify := func() {
		status, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
		var reply struct {
			Agents []struct {
				Capabilities []agent.Capability
				Modules      json.RawMessage
			}
		}
		if status != 200 || json.Unmarshal(data, &reply) != nil || len(reply.Agents) != 1 {
			t.Fatal("unified catalog unavailable", status)
		}
		if len(reply.Agents[0].Capabilities) != 1 || reply.Agents[0].Capabilities[0].Name != "query.fixture" ||
			!strings.Contains(string(reply.Agents[0].Modules), `"future"`) {
			t.Fatal("command and module metadata mixed or filtered")
		}
	}
	verify()
	// An unopened module must still be discoverable, including while offline.
	if proxy, _ := f.s.proxyHub.Lookup("PC"); proxy != nil {
		t.Fatal("discovery started a proxy")
	}
	_ = ws.Close()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		peer, _ := f.s.agentHub.Lookup("PC")
		if peer == nil {
			break
		}
		time.Sleep(time.Millisecond)
	}
	verify()
}

func TestModuleOpenIsOpaqueAndIndependentOfCommands(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false)
	body := json.RawMessage(`{"module":"future-module","version":"opaque","extra":{"x":1}}`)
	done := make(chan error, 1)
	go func() {
		var frame map[string]json.RawMessage
		if err := ws.ReadJSON(&frame); err != nil {
			done <- err
			return
		}
		if string(frame["type"]) != `"module_open"` || string(frame["module"]) != `"future-module"` || frame["method"] != nil {
			done <- &requestMismatch{}
			return
		}
		// A business-command response with this ID cannot satisfy a module request.
		var id string
		_ = json.Unmarshal(frame["id"], &id)
		if err := ws.WriteJSON(map[string]any{"type": "response", "id": id, "result": map[string]bool{"wrong": true}}); err != nil {
			done <- err
			return
		}
		done <- ws.WriteJSON(map[string]any{"type": "module_response", "id": id, "result": map[string]bool{"opened": true}})
	}()
	for i := 0; i < cap(f.s.requests); i++ {
		f.s.requests <- struct{}{}
	}
	reply := f.s.consoleAgentCall(context.Background(), consoleAgentCommand{Type: "module_open", AgentID: "PC", Body: body})
	for i := 0; i < cap(f.s.requests); i++ {
		<-f.s.requests
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(reply.Body)
	if reply.Status != 200 || !strings.Contains(string(data), `"opened":true`) || strings.Contains(string(data), `"wrong"`) {
		t.Fatal("module used business-command dispatch", reply.Status, string(data))
	}
}

func TestModuleOpenConsoleAndAdminTransport(t *testing.T) {
	f := newFixture(t, true)
	peer := f.connectAgent(false)
	console := openConsoleAgentSocket(t, f, "/ws/console/agents")
	body := json.RawMessage(`{"module":"opaque-module","version":9}`)
	writeAgentFrame(t, console, consoleAgentCommand{Type: "module_open", ID: "module-client", AgentID: "PC", Body: body})
	request := readAgentFrame[map[string]json.RawMessage](t, peer)
	var id string
	_ = json.Unmarshal(request["id"], &id)
	if string(request["type"]) != `"module_open"` || string(request["module"]) != `"opaque-module"` {
		t.Fatal("module not routed on control transport")
	}
	writeAgentFrame(t, peer, map[string]any{"type": "module_response", "id": id, "result": map[string]bool{"ready": true}})
	if reply := readAgentFrame[consoleAgentReply](t, console); reply.ID != "module-client" || reply.Status != 200 {
		t.Fatal("module reply not correlated")
	}
	unauthorized := &adminClient{f: f}
	unauthorized.call("POST", "agents/PC/modules/open", body, 401)
	a := loginAdmin(f)
	if status, _, _ := a.request("POST", "/consilium/api/agents/PC/modules/open", body, "https://attacker.example", a.csrf); status != 403 {
		t.Fatal("module open bypassed browser CSRF/origin checks")
	}
	done := make(chan []byte, 1)
	go func() { done <- a.call("POST", "agents/PC/modules/open", body, 200) }()
	request = readAgentFrame[map[string]json.RawMessage](t, peer)
	_ = json.Unmarshal(request["id"], &id)
	writeAgentFrame(t, peer, map[string]any{"type": "module_response", "id": id, "result": map[string]bool{"ready": true}})
	if !strings.Contains(string(<-done), `"ready":true`) {
		t.Fatal("browser module result lost")
	}
}
