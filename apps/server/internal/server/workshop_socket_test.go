package server

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"hako/server/internal/agent"
	"hako/server/internal/workshop"
)

func connectWorkshop(t *testing.T, f *fixture) *websocket.Conn {
	return connectWorkshopRole(t, f, false)
}

func connectWorkshopRole(t *testing.T, f *fixture, commands bool) *websocket.Conn {
	t.Helper()
	path := "/ws/workshop/agent"
	hub := &f.s.workshopHub
	if commands {
		path = "/ws/workshop/command-agent"
		hub = &f.s.commandHub
	}
	dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
	ws, _, err := dialer.Dial("wss"+strings.TrimPrefix(f.http.URL, "https")+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	writeAgentFrame(t, ws, workshop.Frame{Kind: "hello", Protocol: workshop.Protocol, Account: "owner", KeyID: f.s.config.Agents[0].keyID})
	challenge := readAgentFrame[struct{ Kind, Protocol, Payload string }](t, ws)
	payload, err := base64.StdEncoding.DecodeString(challenge.Payload)
	if err != nil || challenge.Kind != "challenge" || challenge.Protocol != workshop.Protocol || !strings.HasPrefix(string(payload), "hako-workshop-auth/v1\n") {
		t.Fatal("wrong workshop challenge", err)
	}
	hash := sha256.Sum256(payload)
	signature, err := rsa.SignPSS(rand.Reader, f.agentKey, crypto.SHA256, hash[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
	if err != nil {
		t.Fatal(err)
	}
	writeAgentFrame(t, ws, workshop.Frame{Kind: "proof", Signature: base64.StdEncoding.EncodeToString(signature)})
	welcome := readAgentFrame[workshop.Frame](t, ws)
	if welcome.Kind != "welcome" || welcome.Protocol != workshop.Protocol || welcome.ComputerID != "PC" {
		t.Fatal("workshop auth failed", welcome)
	}
	deadline := time.Now().Add(time.Second)
	for {
		if c, _ := hub.Lookup("PC"); c != nil {
			return ws
		}
		if time.Now().After(deadline) {
			t.Fatal("workshop never online")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestCommandWorkerSurvivesWorkshopAgentDisconnect(t *testing.T) {
	f := newFixture(t, true)
	primary := connectWorkshop(t, f)
	commands := connectWorkshopRole(t, f, true)
	client := openWorkshopClient(t, f, "/ws/workshop/client")
	primary.Close()
	deadline := time.Now().Add(time.Second)
	for {
		if peer, _ := f.s.workshopHub.Lookup("PC"); peer == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("primary Agent did not disconnect")
		}
		time.Sleep(time.Millisecond)
	}
	writeAgentFrame(t, client, workshop.Frame{Kind: "call", ID: "command-read", ComputerID: "PC", Method: "commands.read", Params: json.RawMessage(`{"taskId":"11111111-1111-4111-8111-111111111111","cursor":0}`)})
	request := readAgentFrame[workshop.Frame](t, commands)
	if request.Method != "commands.read" {
		t.Fatal("command request reached the wrong worker", request)
	}
	writeAgentFrame(t, commands, workshop.Frame{Kind: "result", ID: request.ID, Result: json.RawMessage(`{"output":"still running","cursor":13}`)})
	if reply := readAgentFrame[workshop.Frame](t, client); reply.ID != "command-read" || !strings.Contains(string(reply.Result), "still running") {
		t.Fatal("Agent exit interrupted the command connection", reply)
	}
	connectWorkshop(t, f)
	if peer, _ := f.s.commandHub.Lookup("PC"); peer == nil {
		t.Fatal("new Agent replaced the independent command worker")
	}
}

func openWorkshopClient(t *testing.T, f *fixture, path string) *websocket.Conn {
	t.Helper()
	ws, _, err := dialConsoleAgentSocket(f, path, true, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	if frame := readAgentFrame[workshop.Frame](t, ws); frame.Kind != "welcome" || frame.Protocol != workshop.Protocol {
		t.Fatal("not a workshop connection", frame)
	}
	return ws
}

func TestWorkshopCapacityIsIndependentOfDeviceMonitoring(t *testing.T) {
	f := newFixture(t, true)
	device := f.connectAgent(false)
	worker := connectWorkshop(t, f)
	c, _ := f.s.workshopHub.Lookup("PC")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 16)
	for range 16 {
		go func() {
			_, err := c.Call(ctx, workshop.Frame{Method: "history.read", Params: json.RawMessage(`{}`)})
			done <- err
		}()
		if frame := readAgentFrame[workshop.Frame](t, worker); frame.Kind != "call" || frame.Method != "history.read" {
			t.Fatal(frame)
		}
	}
	if _, err := c.Call(ctx, workshop.Frame{Method: "history.read", Params: json.RawMessage(`{}`)}); err != workshop.ErrBusy {
		t.Fatal("missing workshop bound", err)
	}
	monitor := make(chan agentAPIReply, 1)
	go func() {
		monitor <- f.s.callAgent(context.Background(), "PC", agent.Request{Method: "query.all", Version: 1, Params: json.RawMessage(`{}`)})
	}()
	request := readAgentFrame[agent.Message](t, device)
	writeAgentFrame(t, device, agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: json.RawMessage(`{"data":{}}`)}})
	if reply := <-monitor; reply.Status != 200 {
		t.Fatal("device blocked by workshop", reply)
	}
	cancel()
	for range 16 {
		if err := <-done; err != context.Canceled {
			t.Fatal(err)
		}
	}
	client := openWorkshopClient(t, f, "/ws/workshop/client")
	writeAgentFrame(t, client, workshop.Frame{Kind: "call", ID: "computers", Method: "computers.list", Params: json.RawMessage(`{}`)})
	list := readAgentFrame[workshop.Frame](t, client)
	if list.Kind != "result" || !strings.Contains(string(list.Result), `"protocolVersion":1`) {
		t.Fatal("workshop discovery failed", list)
	}
	// Closing the device connection cannot close the independent workshop peer.
	device.Close()
	writeAgentFrame(t, client, workshop.Frame{Kind: "call", ID: "query", ComputerID: "PC", Method: "operation.read", Params: json.RawMessage(`{}`)})
	work := readAgentFrame[workshop.Frame](t, worker)
	writeAgentFrame(t, worker, workshop.Frame{Kind: "result", ID: work.ID, Result: json.RawMessage(`{"cursor":0}`)})
	if reply := readAgentFrame[workshop.Frame](t, client); reply.Kind != "result" || reply.ID != "query" {
		t.Fatal("device disconnect interrupted workshop", reply)
	}
}

func TestWorkshopPushResumeAndUnsubscribe(t *testing.T) {
	f := newFixture(t, true)
	worker := connectWorkshop(t, f)
	for _, cursor := range []string{"0", "12"} {
		client := openWorkshopClient(t, f, "/ws/workshop/events/PC/11111111-1111-4111-8111-111111111111/"+cursor)
		start := readAgentFrame[workshop.Frame](t, worker)
		if start.Kind != "watch" || start.OperationID != "11111111-1111-4111-8111-111111111111" || (cursor == "12" && start.Cursor != 12) {
			t.Fatal(start)
		}
		for _, body := range []string{`{"cursor":12,"events":["first"]}`, `{"cursor":24,"events":["second"]}`} {
			writeAgentFrame(t, worker, workshop.Frame{Kind: "event", ID: start.ID, Result: json.RawMessage(body)})
			if frame := readAgentFrame[workshop.Frame](t, client); frame.Kind != "event" || string(frame.Result) != body {
				t.Fatal(frame)
			}
		}
		client.Close()
		if stop := readAgentFrame[workshop.Frame](t, worker); stop.Kind != "unwatch" || stop.ID != start.ID {
			t.Fatal(stop)
		}
	}
}

func TestWorkshopAuthenticationAndDeviceProtocolIsolation(t *testing.T) {
	f := newFixture(t, true)
	ws, response, err := dialConsoleAgentSocket(f, "/ws/workshop/client", false, "")
	if ws != nil {
		ws.Close()
	}
	if response != nil {
		response.Body.Close()
	}
	if err == nil || response == nil || response.StatusCode != 401 {
		t.Fatal("unauthenticated workshop accepted")
	}
	device := f.connectAgent(false, agent.Capability{Name: "action.codex.turn.start", Version: 1})
	if reply := f.s.callAgent(context.Background(), "PC", agent.Request{Method: "action.codex.turn.start", Version: 1, Params: json.RawMessage(`{}`)}); reply.Status != 400 {
		t.Fatal("device channel accepted workshop operation", reply)
	}
	worker := connectWorkshop(t, f)
	peer, _ := f.s.workshopHub.Lookup("PC")
	peer.Close()
	worker.Close()
	go func() {
		request := readAgentFrame[agent.Message](t, device)
		writeAgentFrame(t, device, agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: json.RawMessage(`{"data":{}}`)}})
	}()
	if reply := f.s.callAgent(context.Background(), "PC", agent.Request{Method: "query.all", Version: 1, Params: json.RawMessage(`{}`)}); reply.Status != 200 {
		t.Fatal("workshop disconnect interrupted device", reply)
	}
	client := openWorkshopClient(t, f, "/ws/workshop/client")
	writeAgentFrame(t, client, map[string]any{"type": "request", "id": "device-frame", "agentId": "PC", "body": map[string]any{"method": "query.all", "version": 1, "params": map[string]any{}}})
	_ = client.SetReadDeadline(time.Now().Add(time.Second))
	var ignored any
	if err := client.ReadJSON(&ignored); err == nil {
		t.Fatal("device wire format accepted by workshop")
	}
}
