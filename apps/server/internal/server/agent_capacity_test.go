package server

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"
	"time"

	"hako/server/internal/agent"
)

func TestWorkshopReadsReserveMonitoringCapacity(t *testing.T) {
	f := newFixture(t, true)
	ws := f.connectAgent(false, agent.Capability{Name: "query.codex.history", Version: 1},
		agent.Capability{Name: "query.codex.usage", Version: 1})
	f.s.config.RequestTimeout = 5 * time.Second
	peer, _ := f.s.agentHub.Lookup("PC")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	workshop := agent.Request{Method: "query.codex.history", Version: 1, Params: json.RawMessage(`{}`)}
	done := make(chan error, agent.MaxWorkshopRequests)
	for range agent.MaxWorkshopRequests {
		go func() { _, err := peer.Request(ctx, workshop); done <- err }()
		var request agent.Message
		if err := ws.ReadJSON(&request); err != nil {
			t.Fatal(err)
		}
	}
	status, data := f.call("POST", "/api/v1/agents/PC/requests", workshop, f.tokens.AccessToken)
	if status != 429 || !bytes.Contains(data, []byte(`agent_busy`)) {
		t.Fatal("workshop consumed monitoring reserve", status, string(data))
	}
	monitoring := agent.Request{Method: "query.codex.usage", Version: 1, Params: json.RawMessage(`{}`)}
	monitorDone := make(chan int, 4)
	monitorRequests := make([]agent.Message, 4)
	for i := range monitorRequests {
		go func() {
			status, _ := f.call("POST", "/api/v1/agents/PC/requests", monitoring, f.tokens.AccessToken)
			monitorDone <- status
		}()
		if err := ws.ReadJSON(&monitorRequests[i]); err != nil || monitorRequests[i].Method != monitoring.Method {
			t.Fatal("monitoring did not reach the agent", err, monitorRequests[i].Method)
		}
	}
	status, data = f.call("POST", "/api/v1/agents/PC/requests", monitoring, f.tokens.AccessToken)
	if status != 429 || !bytes.Contains(data, []byte(`agent_busy`)) {
		t.Fatal("total request bound exceeded", status, string(data))
	}
	for _, request := range monitorRequests {
		if err := ws.WriteJSON(agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: json.RawMessage(`true`)}}); err != nil {
			t.Fatal(err)
		}
	}
	for range monitorRequests {
		if status := <-monitorDone; status != 200 {
			t.Fatal("monitoring failed while workshop was occupied", status)
		}
	}
	cancel()
	for range agent.MaxWorkshopRequests {
		if err := <-done; err != context.Canceled {
			t.Fatal("cancelled read did not release capacity", err)
		}
	}
	go func() {
		status, _ := f.call("POST", "/api/v1/agents/PC/requests", workshop, f.tokens.AccessToken)
		monitorDone <- status
	}()
	var request agent.Message
	if err := ws.ReadJSON(&request); err != nil || request.Method != workshop.Method {
		t.Fatal("cancelled workshop slots were not reusable", err)
	}
	if err := ws.WriteJSON(agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: json.RawMessage(`true`)}}); err != nil {
		t.Fatal(err)
	}
	if status := <-monitorDone; status != 200 {
		t.Fatal("workshop did not recover", status)
	}
}
