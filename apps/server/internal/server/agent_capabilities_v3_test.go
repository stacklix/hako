package server

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestV3CapabilityRules(t *testing.T) {
	for _, name := range []string{"system.metrics", "query.all", "query.cpu", "action.network", "Query.system.metrics", "query.system.1bad"} {
		if validCapabilities([]agentCapability{{Name: name, Version: 1}}) {
			t.Fatal("invalid capability accepted", name)
		}
	}
	if !validCapabilities([]agentCapability{}) {
		t.Fatal("known empty manifest rejected")
	}
	f := newFixture(t, true)
	ws := f.connectAgent(false, agentCapability{Name: "query.system.metrics", Version: 1}, agentCapability{Name: "action.network.http.check", Version: 2})
	for _, request := range []agentRequest{
		{Method: "query.all", Version: 2, Params: json.RawMessage(`{}`)},
		{Method: "query.system.metrics", Version: 2, Params: json.RawMessage(`{}`)},
		{Method: "action.network.http.check", Version: 1, Params: json.RawMessage(`{}`)},
		{Method: "action.unknown.execute", Version: 1, Params: json.RawMessage(`{}`)},
	} {
		status, data := f.call("POST", "/api/v1/agents/PC/requests", request, f.tokens.AccessToken)
		if status != 400 || !bytes.Contains(data, []byte("unsupported_method")) {
			t.Fatal("version/name mismatch accepted", status, string(data))
		}
	}
	// Both a single query and an operation use exact declared versions.
	for _, method := range []agentRequest{
		{Method: "query.system.metrics", Version: 1, Params: json.RawMessage(`{}`)},
		{Method: "action.network.http.check", Version: 2, Params: json.RawMessage(`{"url":"http://localhost"}`)},
		{Method: "query.all", Version: 1, Params: json.RawMessage(`{}`)},
	} {
		done := make(chan bool, 1)
		go func() {
			var message agentMessage
			ok := ws.ReadJSON(&message) == nil && message.Method == method.Method && message.Version == method.Version && bytes.Equal(message.Params, method.Params)
			if ok {
				ok = ws.WriteJSON(agentMessage{Type: "response", ID: message.ID, agentResult: agentResult{Result: json.RawMessage(`{"data":{"query.system.metrics":{"version":1,"error":{"code":"sample_failed","message":"采样失败"}}}}`)}}) == nil
			}
			done <- ok
		}()
		status, data := f.call("POST", "/api/v1/agents/PC/requests", method, f.tokens.AccessToken)
		if status != 200 || !<-done {
			t.Fatal("request changed", status, string(data))
		}
		hasManifest := bytes.Contains(data, []byte(`"capabilities":[{"name":"query.system.metrics","version":1},{"name":"action.network.http.check","version":2}]`))
		if hasManifest != (method.Method == "query.all") {
			t.Fatal("aggregate connection manifest missing or leaking into single reply", string(data))
		}
	}
}

func TestAuthenticatedCapabilitiesPersistAcrossRestart(t *testing.T) {
	f := newFixture(t, true)
	_, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if !bytes.Contains(data, []byte(`"capabilities":null`)) {
		t.Fatal("unseen manifest must be unknown", string(data))
	}
	f.connectAgent(false, agentCapability{Name: "query.system.metrics", Version: 3})
	// A failed RSA authentication must never overwrite the last authenticated manifest.
	f.connectAgent(true, agentCapability{Name: "action.future.execute", Version: 8})
	restarted, err := New(f.s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	items := restarted.agentItems(false)
	manifest, ok := items[0]["capabilities"].([]agentCapability)
	if !ok || len(manifest) != 1 || manifest[0].Name != "query.system.metrics" || manifest[0].Version != 3 || items[0]["online"] != false {
		t.Fatal("authenticated offline manifest not persisted", items)
	}
}

func TestKnownEmptyCapabilitiesAreNotUnknown(t *testing.T) {
	f := newFixture(t, true)
	f.connectAgent(false, []agentCapability{}...)
	_, data := f.call("GET", "/api/v1/agents", nil, f.tokens.AccessToken)
	if !bytes.Contains(data, []byte(`"capabilities":[]`)) {
		t.Fatal("known empty manifest changed to unknown", string(data))
	}
	restarted, err := New(f.s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	manifest := restarted.agentItems(false)[0]["capabilities"].([]agentCapability)
	if manifest == nil || len(manifest) != 0 {
		t.Fatal("empty manifest not preserved across restart")
	}
}
