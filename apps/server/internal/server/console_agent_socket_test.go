package server

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"hako/server/internal/agent"
)

func dialConsoleAgentSocket(f *fixture, path string, authorized bool, origin string) (*websocket.Conn, *http.Response, error) {
	headers := http.Header{}
	if authorized {
		headers.Set("Authorization", "DPoP "+f.tokens.AccessToken)
		headers.Set("X-Hako-Device", f.deviceID)
		headers.Set("DPoP", makeProof(f.key, "GET", f.http.URL+path, f.tokens.AccessToken, randomToken()))
	}
	if origin != "" {
		headers.Set("Origin", origin)
	}
	dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
	return dialer.Dial("ws"+strings.TrimPrefix(f.http.URL, "http")+path, headers)
}

func readAgentFrame[T any](t *testing.T, ws *websocket.Conn) T {
	t.Helper()
	_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	var frame T
	if err := ws.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	return frame
}

func writeAgentFrame(t *testing.T, ws *websocket.Conn, frame any) {
	t.Helper()
	_ = ws.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if err := ws.WriteJSON(frame); err != nil {
		t.Fatal(err)
	}
}

func openConsoleAgentSocket(t *testing.T, f *fixture, path string) *websocket.Conn {
	t.Helper()
	ws, _, err := dialConsoleAgentSocket(f, path, true, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	if frame := readAgentFrame[consoleAgentReply](t, ws); frame.Type != "ready" {
		t.Fatalf("unexpected opening frame: %+v", frame)
	}
	return ws
}

func TestConsoleAgentSocketRequestsAndAuthentication(t *testing.T) {
	f := newFixture(t, true)
	const path = "/ws/console/agents"
	for _, tc := range []struct {
		authorized bool
		origin     string
		status     int
	}{{false, "", 401}, {true, "https://example.org", 403}} {
		ws, response, err := dialConsoleAgentSocket(f, path, tc.authorized, tc.origin)
		if ws != nil {
			ws.Close()
		}
		if response != nil {
			defer response.Body.Close()
		}
		if err == nil || response == nil || response.StatusCode != tc.status {
			t.Fatalf("unexpected upgrade result: %v, %v", response, err)
		}
	}
	peer := f.connectAgent(false)
	console := openConsoleAgentSocket(t, f, path)
	writeAgentFrame(t, console, consoleAgentCommand{Type: "list", ID: "list"})
	list := readAgentFrame[consoleAgentReply](t, console)
	if list.ID != "list" || list.Status != 200 {
		t.Fatalf("list: %+v", list)
	}
	writeAgentFrame(t, console, consoleAgentCommand{Type: "request", ID: "query", AgentID: "PC",
		Body: json.RawMessage(`{"method":"query.all","version":1,"params":{}}`)})
	request := readAgentFrame[agent.Message](t, peer)
	if request.Type != "request" || request.Method != "query.all" {
		t.Fatalf("agent request: %+v", request)
	}
	writeAgentFrame(t, peer, agent.Message{Type: "response", ID: request.ID, Reply: agent.Reply{Result: json.RawMessage(`{"data":{}}`)}})
	reply := readAgentFrame[consoleAgentReply](t, console)
	body, ok := reply.Body.(map[string]any)
	if reply.ID != "query" || reply.Status != 200 || !ok || body["capabilities"] == nil || body["result"] == nil {
		t.Fatalf("query reply: %+v", reply)
	}
}

func TestConsoleAgentSocketSharesAndStopsTelemetry(t *testing.T) {
	f := newFixture(t, true)
	peer := f.connectAgent(false)
	const path = "/ws/console/agents/live/PC"
	first := openConsoleAgentSocket(t, f, path)
	if reply := readAgentFrame[consoleAgentReply](t, first); reply.Type != "subscribed" {
		t.Fatalf("first subscriber: %+v", reply)
	}
	start := readAgentFrame[agent.Message](t, peer)
	if start.Type != "telemetry_start" || start.ID == "" {
		t.Fatalf("telemetry start: %+v", start)
	}
	send := func(result string) {
		t.Helper()
		writeAgentFrame(t, peer, agent.Message{Type: "telemetry_update", ID: start.ID, Method: "query.system.metrics", Version: 1,
			Reply: agent.Reply{Result: json.RawMessage(result)}})
	}
	expect := func(ws *websocket.Conn, result string) {
		t.Helper()
		update := readAgentFrame[agent.TelemetryUpdate](t, ws)
		if update.Type != "update" || update.Method != "query.system.metrics" || string(update.Result) != result {
			t.Fatalf("telemetry update: %+v", update)
		}
	}
	send(`{"cpuUsagePercent":20}`)
	expect(first, `{"cpuUsagePercent":20}`)
	second := openConsoleAgentSocket(t, f, path)
	if reply := readAgentFrame[consoleAgentReply](t, second); reply.Type != "subscribed" {
		t.Fatalf("second subscriber: %+v", reply)
	}
	expect(second, `{"cpuUsagePercent":20}`)
	first.Close()
	send(`{"cpuUsagePercent":30}`)
	expect(second, `{"cpuUsagePercent":30}`)
	second.Close()
	stop := readAgentFrame[agent.Message](t, peer)
	if stop.Type != "telemetry_stop" || stop.ID != start.ID {
		t.Fatalf("telemetry stop: %+v", stop)
	}
}
