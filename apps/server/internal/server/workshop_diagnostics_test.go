package server

import (
	"encoding/json"
	"testing"

	"hako/server/internal/workshop"
)

func TestWorkshopAuthenticatedDiagnosticReplay(t *testing.T) {
	f := newFixture(t, true)
	f.s.workshopDiagnostics.Append([]byte(`{"event":"fixture_report"}`))
	worker := connectWorkshopRole(t, f, false, 0)
	reply := readAgentFrame[struct {
		Kind    string
		Records []workshop.DiagnosticRecord
	}](t, worker)
	if reply.Kind != "diagnostics" || len(reply.Records) == 0 {
		t.Fatal("authenticated Agent did not receive diagnostics")
	}
	found := false
	for _, row := range reply.Records {
		var payload map[string]any
		_ = json.Unmarshal(row.Payload, &payload)
		if payload["event"] == "fixture_report" {
			found = true
		}
	}
	if !found {
		t.Fatal("queued diagnostic missing")
	}
	cursor := reply.Records[len(reply.Records)-1].Sequence
	worker.Close()
	replacement := connectWorkshopRole(t, f, false, cursor)
	replay := readAgentFrame[struct {
		Kind    string
		Records []workshop.DiagnosticRecord
	}](t, replacement)
	if replay.Kind != "diagnostics" {
		t.Fatal("reconnection lost diagnostics")
	}
	for _, row := range replay.Records {
		if row.Sequence <= cursor {
			t.Fatal("acknowledged diagnostics replayed")
		}
	}
}
