package server

import (
	"bytes"
	"encoding/json"
	"testing"

	"hako/server/internal/agent"
)

func TestAuthenticatedCapabilitiesPersistAcrossRestart(t *testing.T) {
	f := newFixture(t, true)
	_, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if !bytes.Contains(data, []byte(`"capabilities":null`)) {
		t.Fatal("unseen manifest must be unknown", string(data))
	}
	f.connectAgent(false, agent.Capability{Name: "query.system.metrics", Version: 3})
	// A failed RSA authentication must never overwrite the last authenticated manifest.
	f.connectAgent(true, agent.Capability{Name: "action.future.execute", Version: 8})
	restarted, err := New(f.s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	items := restarted.agentItems(false)
	manifest, ok := items[0]["capabilities"].(json.RawMessage)
	if !ok || string(manifest) != `[{"name":"query.system.metrics","version":3}]` || items[0]["online"] != false {
		t.Fatal("authenticated offline manifest not persisted", items)
	}
}

func TestKnownEmptyCapabilitiesAreNotUnknown(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false, []agent.Capability{}...)
	_, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if !bytes.Contains(data, []byte(`"capabilities":[]`)) {
		t.Fatal("known empty manifest changed to unknown", string(data))
	}
	restarted, err := New(f.s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	manifest := restarted.agentItems(false)[0]["capabilities"].(json.RawMessage)
	if string(manifest) != "[]" {
		t.Fatal("empty manifest not preserved across restart")
	}
}
