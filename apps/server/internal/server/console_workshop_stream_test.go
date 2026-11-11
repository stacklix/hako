package server

import (
	"encoding/json"
	"hako/server/internal/agent"
	"testing"
)

func TestWorkshopPushResumeAndUnsubscribe(t *testing.T) {
	f := newFixture(t, true)
	peer := f.connectAgent(false, agent.Capability{Name: "query.codex.stream", Version: 1})
	const base = "/ws/console/agents/workshop/PC/11111111-1111-4111-8111-111111111111/"
	for _, cursor := range []string{"0", "12"} {
		console := openConsoleAgentSocket(t, f, base+cursor)
		start := readAgentFrame[agent.Message](t, peer)
		var params struct {
			OperationID string `json:"operationId"`
			Cursor      int64  `json:"cursor"`
		}
		if err := json.Unmarshal(start.Params, &params); err != nil {
			t.Fatal(err)
		}
		if start.Type != "workshop_start" || params.OperationID != "11111111-1111-4111-8111-111111111111" ||
			(cursor == "12" && params.Cursor != 12) {
			t.Fatalf("Invalid subscription: %+v", start)
		}
		// No query frame from the phone: the Agent sends both updates directly.
		for _, body := range []string{`{"cursor":12,"events":[{"text":"hello"}]}`, `{"cursor":24,"events":[{"text":"world"}]}`} {
			writeAgentFrame(t, peer, agent.Message{Type: "workshop_update", ID: start.ID, Reply: agent.Reply{Result: json.RawMessage(body)}})
			update := readAgentFrame[struct {
				Type string      `json:"type"`
				Body agent.Reply `json:"body"`
			}](t, console)
			if update.Type != "update" || string(update.Body.Result) != body {
				t.Fatalf("Push changed: %+v", update)
			}
		}
		console.Close()
		stop := readAgentFrame[agent.Message](t, peer)
		if stop.Type != "workshop_stop" || stop.ID != start.ID {
			t.Fatalf("Leaked subscription: %+v", stop)
		}
	}
}

func TestWorkshopStreamAuthAndValidation(t *testing.T) {
	f := newFixture(t, true)
	const path = "/ws/console/agents/workshop/PC/not-an-operation/0"
	ws, response, err := dialConsoleAgentSocket(f, path, false, "")
	if ws != nil {
		ws.Close()
	}
	if response != nil {
		defer response.Body.Close()
	}
	if err == nil || response == nil || response.StatusCode != 401 {
		t.Fatal("Unauthenticated stream accepted")
	}
	console := openConsoleAgentSocket(t, f, path)
	reply := readAgentFrame[consoleAgentReply](t, console)
	if reply.Type != "error" || reply.Status != 400 {
		t.Fatalf("Invalid cursor/operation accepted: %+v", reply)
	}
}
