package server

import (
	"bufio"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"hako/server/internal/workshop"
)

func TestAdminWorkshopAuthenticationAndForwarding(t *testing.T) {
	f := newFixture(t, true)
	a := &adminClient{f: f}
	a.call("GET", "workshop/computers", nil, 401)
	a.call("POST", "workshop/calls", map[string]any{}, 401)
	a.call("GET", "workshop/events/PC/11111111-1111-4111-8111-111111111111/0", nil, 401)
	a = loginAdmin(f)
	worker := connectWorkshop(t, f)
	if data := a.call("GET", "workshop/computers", nil, 200); !strings.Contains(string(data), `"online":true`) {
		t.Fatal("workshop computer not discovered", string(data))
	}
	frame := workshop.Frame{Kind: "call", ID: "browser-request", ComputerID: "PC", Method: "turn.start", Params: json.RawMessage(`{"requestId":"11111111-1111-4111-8111-111111111111","applicationId":"demo","message":"hello","systemPrompt":"example"}`)}
	for _, check := range []struct{ origin, csrf string }{{"", a.csrf}, {"https://attacker.example", a.csrf}, {f.http.URL, "wrong"}} {
		status, _, _ := a.request("POST", "/consilium/api/workshop/calls", frame, check.origin, check.csrf)
		if status != http.StatusForbidden {
			t.Fatal("workshop mutation bypassed CSRF", status)
		}
	}
	done := make(chan []byte, 1)
	go func() { done <- a.call("POST", "workshop/calls", frame, 200) }()
	request := readAgentFrame[workshop.Frame](t, worker)
	if request.Method != frame.Method || string(request.Params) != string(frame.Params) {
		t.Fatal("browser request was interpreted or changed", request)
	}
	writeAgentFrame(t, worker, workshop.Frame{Kind: "result", ID: request.ID, Result: json.RawMessage(`{"id":"task","state":"starting"}`)})
	var reply workshop.Frame
	if json.Unmarshal(<-done, &reply) != nil || reply.ID != frame.ID || reply.Kind != "result" {
		t.Fatal("browser reply was not correlated", reply)
	}
	// Browser access never opens the native client endpoint to cookies or Origins.
	r, _ := http.NewRequest("GET", f.http.URL+"/ws/workshop/client", nil)
	r.Header.Set("Origin", f.http.URL)
	r.AddCookie(a.cookie)
	res, err := f.http.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 403 {
		t.Fatal("browser bypassed the dedicated admin routes", res.StatusCode)
	}
}

func TestAdminWorkshopEventsResumeRevokeAndUnsubscribe(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	worker := connectWorkshop(t, f)
	r, _ := http.NewRequest("GET", f.http.URL+"/consilium/api/workshop/events/PC/11111111-1111-4111-8111-111111111111/12", nil)
	r.AddCookie(a.cookie)
	response, err := f.http.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || response.Header.Get("Content-Type") != "text/event-stream" || response.Header.Get("X-Accel-Buffering") != "no" {
		t.Fatal("invalid event stream", response.StatusCode, response.Header)
	}
	watch := readAgentFrame[workshop.Frame](t, worker)
	if watch.Kind != "watch" || watch.Cursor != 12 {
		t.Fatal("resume cursor was lost", watch)
	}
	reader := bufio.NewReader(response.Body)
	writeAgentFrame(t, worker, workshop.Frame{Kind: "event", ID: watch.ID, Result: json.RawMessage(`{"cursor":24,"events":[{"text":"hello"}]}`)})
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasPrefix(line, "data: ") {
			if !strings.Contains(line, `"cursor":24`) || !strings.Contains(line, `"hello"`) {
				t.Fatal("event was not forwarded", line)
			}
			break
		}
	}
	// Logout/revocation must stop an already-open browser subscription before
	// another worker frame is disclosed, without waiting for a page refresh.
	a.call("POST", "logout", map[string]bool{}, 200)
	writeAgentFrame(t, worker, workshop.Frame{Kind: "event", ID: watch.ID, Result: json.RawMessage(`{"cursor":36,"events":[{"text":"private"}]}`)})
	for {
		line, err := reader.ReadString('\n')
		if strings.Contains(line, "private") {
			t.Fatal("revoked browser received a workshop event")
		}
		if err != nil {
			break
		}
	}
	if stop := readAgentFrame[workshop.Frame](t, worker); stop.Kind != "unwatch" || stop.ID != watch.ID {
		t.Fatal("browser subscription leaked after logout", stop)
	}
}

func TestAdminWorkshopPassiveReadsDoNotExtendIdleSession(t *testing.T) {
	f := newFixture(t, false)
	a := loginAdmin(f)
	id := digest(a.cookie.Value)
	f.s.adminMu.Lock()
	ss := f.s.adminSessions[id]
	ss.LastUsed = time.Now().Add(-20 * time.Minute)
	f.s.adminSessions[id] = ss
	f.s.adminMu.Unlock()
	a.call("GET", "workshop/computers", nil, 200)
	r, _ := http.NewRequest("POST", f.http.URL+"/consilium/api/workshop/calls", strings.NewReader(`{"kind":"call","id":"poll","method":"computers.list","params":{}}`))
	r.AddCookie(a.cookie)
	r.Header.Set("Origin", f.http.URL)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-CSRF-Token", a.csrf)
	r.Header.Set("X-Hako-Passive", "1")
	res, err := f.http.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatal(res.StatusCode)
	}
	f.s.adminMu.Lock()
	last := f.s.adminSessions[id].LastUsed
	f.s.adminMu.Unlock()
	if !last.Equal(ss.LastUsed) {
		t.Fatal("passive workshop polling extended the idle session")
	}
}
