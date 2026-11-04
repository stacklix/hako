package server

import (
	"errors"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func promptSocket(f *fixture, origin string) (*websocket.Conn, *http.Response, error) {
	path := "/api/v1/auth/login-prompts/stream"
	header := http.Header{}
	header.Set("Authorization", "DPoP "+f.tokens.AccessToken)
	header.Set("X-Hako-Device", f.deviceID)
	header.Set("DPoP", makeProof(f.key, "GET", f.http.URL+path, f.tokens.AccessToken, randomToken()))
	if origin != "" {
		header.Set("Origin", origin)
	}
	dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
	return dialer.Dial("wss"+strings.TrimPrefix(f.http.URL, "https")+path, header)
}

func readPrompts(t *testing.T, ws *websocket.Conn, count int) loginPromptList {
	t.Helper()
	_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	var list loginPromptList
	if err := ws.ReadJSON(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Requests) != count {
		t.Fatalf("got %d prompts, want %d", len(list.Requests), count)
	}
	return list
}

func TestLoginPromptStreamPushesWithoutPolling(t *testing.T) {
	f := newFixture(t, true)
	ws, _, err := promptSocket(f, "")
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	readPrompts(t, ws, 0)
	_, request := startLogin(f)
	list := readPrompts(t, ws, 1)
	if list.Issuer != f.http.URL || list.Requests[0].ID != request.ID {
		t.Fatal("wrong initial notification")
	}
	f.s.adminMu.Lock()
	req := f.s.adminLogins[digest(request.ID)]
	code, nonce := req.Code, req.Nonce
	f.s.adminMu.Unlock()
	status, data := f.call("POST", "/api/v1/auth/login-prompts/"+request.ID+"/approve", map[string]string{"confirmationCode": code}, f.tokens.AccessToken, nonce)
	if status != 200 {
		t.Fatalf("approve: %d %s", status, data)
	}
	readPrompts(t, ws, 0)
	// These changes happen through the application API, not a list read.
	c, secret := appTestClient(f, "push-app")
	app := startApp(f, c, secret, "login")
	list = readPrompts(t, ws, 1)
	if list.Requests[0].ID != app.ID {
		t.Fatal("application login was not pushed")
	}
	status, data = f.call("POST", "/api/v1/auth/login-prompts/"+app.ID+"/deny", map[string]string{}, f.tokens.AccessToken, list.Requests[0].Nonce)
	if status != 200 {
		t.Fatalf("deny: %d %s", status, data)
	}
	readPrompts(t, ws, 0)
	client, _ := oidcTestClient(f, "push-oidc")
	browser := startOIDC(f, oidcQuery(client))
	list = readPrompts(t, ws, 1)
	if list.Requests[0].ID != browser.id {
		t.Fatal("OIDC login was not pushed")
	}
	// An expiration timer must remove the row with no subsequent HTTP request.
	f.s.adminMu.Lock()
	f.s.adminLogins[digest(browser.id)].Expires = time.Now().Add(1500 * time.Millisecond)
	f.s.unlockAdminAndNotifyLoginPrompts()
	readPrompts(t, ws, 1)
	readPrompts(t, ws, 0)
}

func TestLoginPromptStreamAuthenticationAndReplacement(t *testing.T) {
	f := newFixture(t, true)
	ws, response, err := promptSocket(f, "https://attacker.example")
	if ws != nil {
		ws.Close()
	}
	if err == nil || response == nil || response.StatusCode != 403 {
		t.Fatal("browser origin accepted")
	}
	status, _ := f.call("GET", "/api/v1/auth/login-prompts/stream", nil, "")
	if status != 401 {
		t.Fatal("unauthenticated stream accepted")
	}
	first, _, err := promptSocket(f, "")
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	readPrompts(t, first, 0)
	_, request := startLogin(f)
	readPrompts(t, first, 1)
	second, _, err := promptSocket(f, "")
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if readPrompts(t, second, 1).Requests[0].ID != request.ID {
		t.Fatal("reconnect lost current snapshot")
	}
	_ = first.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := first.ReadMessage(); err == nil {
		t.Fatal("superseded connection remained open")
	} else {
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() {
			t.Fatal("superseded connection did not close before deadline")
		}
	}
	// A revoked session must never receive the next notification.
	if err := f.s.store.update(func(st *state) error {
		delete(st.Sessions, f.tokens.SessionID)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	f.s.adminMu.Lock()
	f.s.unlockAdminAndNotifyLoginPrompts()
	_ = second.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := second.ReadMessage(); err == nil {
		t.Fatal("revoked session received notification")
	} else {
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() {
			t.Fatal("revoked connection did not close before deadline")
		}
	}
}

func TestLoginPromptStreamDoesNotRepeatUnchangedSnapshot(t *testing.T) {
	f := newFixture(t, true)
	ws, _, err := promptSocket(f, "")
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	readPrompts(t, ws, 0)
	f.s.adminMu.Lock()
	f.s.unlockAdminAndNotifyLoginPrompts()
	_ = ws.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	_, _, err = ws.ReadMessage()
	var timeout net.Error
	if !errors.As(err, &timeout) || !timeout.Timeout() {
		t.Fatalf("unchanged list should stay silent until read deadline: %v", err)
	}
}
