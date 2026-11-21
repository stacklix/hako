package server

import (
	"encoding/json"
	"hako/server/internal/workshop"
	"strings"
	"testing"
	"time"
)

func TestWorkshopDiscoveryRequiresRegistrationAndPreservesOfflineLAN(t *testing.T) {
	f := newFixture(t, true)
	path := "/api/v1/workshop/computers"
	if status, _ := f.call("GET", path, nil, ""); status != 401 {
		t.Fatal("Discovery is not authenticated", status)
	}
	status, data := f.call("GET", path, nil, f.tokens.AccessToken)
	if status != 200 || string(data) != "{\"computers\":[]}\n" {
		t.Fatal("Unregistered Agents leaked into discovery", status, string(data))
	}
	worker := connectWorkshop(t, f)
	status, data = f.call("GET", path, nil, f.tokens.AccessToken)
	if status != 200 || !strings.Contains(string(data), `"online":true`) || !strings.Contains(string(data), `"addresses":["192.168.0.10"]`) || !strings.Contains(string(data), `"port":8005`) {
		t.Fatal("Registration/LAN metadata missing", status, string(data))
	}
	writeAgentFrame(t, worker, workshop.Frame{Kind: "register", Registration: &workshop.Registration{ProtocolVersion: 1, Addresses: []string{"10.0.0.9"}, Port: 8010}})
	deadline := time.Now().Add(time.Second)
	for {
		_, data = f.call("GET", path, nil, f.tokens.AccessToken)
		if strings.Contains(string(data), `"port":8010`) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Address update not published", string(data))
		}
		time.Sleep(time.Millisecond)
	}
	worker.Close()
	deadline = time.Now().Add(time.Second)
	for {
		_, data = f.call("GET", path, nil, f.tokens.AccessToken)
		if strings.Contains(string(data), `"online":false`) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Disconnected computer remained online", string(data))
		}
		time.Sleep(time.Millisecond)
	}
	if !strings.Contains(string(data), `"10.0.0.9"`) {
		t.Fatal("Offline computer lost its LAN metadata", string(data))
	}
	f.s.store.inspect(func(st state) {
		value := st.WorkshopComputers["PC"]
		if value.Port != 8010 || len(value.Addresses) != 1 {
			t.Fatal("Registration was not persisted", value)
		}
	})
	reopened, err := openStore(f.s.config.Database, f.s.config.MasterKey)
	if err != nil {
		t.Fatal(err)
	}
	reopened.inspect(func(st state) {
		if st.WorkshopComputers["PC"].Port != 8010 {
			t.Fatal("Registration lost after loading encrypted persistent state")
		}
	})
	reopened.db.Close()
	// Capability metadata is unrelated to registration.
	f.s.registryMu.Lock()
	next := *f.s.registry.Load()
	next.Agents = append([]AgentConfig(nil), next.Agents...)
	next.Agents[0].Capabilities = json.RawMessage(`[{"name":"query.device.status","version":1}]`)
	err = f.s.saveRegistry(&next)
	f.s.registryMu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	_, data = f.call("GET", path, nil, f.tokens.AccessToken)
	if !strings.Contains(string(data), `"id":"PC"`) {
		t.Fatal("Capability changes removed independent Workshop registration")
	}
	f.s.registryMu.Lock()
	next.Agents = nil
	err = f.s.saveRegistry(&next)
	f.s.registryMu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	_, data = f.call("GET", path, nil, f.tokens.AccessToken)
	if strings.Contains(string(data), `"id":"PC"`) {
		t.Fatal("Revoked Agent retained Workshop discovery")
	}
	f.s.store.inspect(func(st state) {
		if len(st.WorkshopComputers) != 0 {
			t.Fatal("Revoked registration remained persisted")
		}
	})

}

func TestWorkshopRegistrationRejectsInvalidAddresses(t *testing.T) {
	f := newFixture(t, false)
	for _, registration := range []*workshop.Registration{
		nil, {ProtocolVersion: 0}, {ProtocolVersion: 1, Port: -1}, {ProtocolVersion: 1, Port: 65536},
		{ProtocolVersion: 1, Port: 0, Addresses: []string{"192.168.0.1"}},
		{ProtocolVersion: 1, Port: 8005, Addresses: []string{"8.8.8.8"}},
		{ProtocolVersion: 1, Port: 8005, Addresses: []string{"127.0.0.1"}},
		{ProtocolVersion: 1, Port: 8005, Addresses: []string{"host.local"}},
	} {
		f.s.registryMu.Lock()
		accepted := f.s.registerWorkshopComputer(f.s.config.Agents[0], registration)
		f.s.registryMu.Unlock()
		if accepted {
			t.Fatal("Invalid registration accepted", registration)
		}
	}
}
