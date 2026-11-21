package server

import (
	"bytes"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestBinaryStreamAuthenticationAndOpaqueRelay(t *testing.T) {
	f := newFixture(t, true)
	for _, tc := range []struct {
		auth   bool
		origin string
		status int
	}{{false, "", 401}, {true, "https://evil.example", 403}} {
		ws, response, err := dialConsoleAgentSocket(f, "/ws/streams", tc.auth, tc.origin)
		if ws != nil {
			ws.Close()
		}
		if response != nil {
			response.Body.Close()
		}
		if err == nil || response == nil || response.StatusCode != tc.status {
			t.Fatalf("unexpected auth result: %v %v", response, err)
		}
	}
	consumer, _, err := dialConsoleAgentSocket(f, "/ws/streams", true, "")
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()
	hello := readAgentFrame[struct {
		ID            string
		ProducerToken string
	}](t, consumer)
	dialer := websocket.Dialer{TLSClientConfig: f.http.Client().Transport.(*http.Transport).TLSClientConfig}
	path := "ws" + strings.TrimPrefix(f.http.URL, "http") + "/ws/streams/" + hello.ID
	bad, response, err := dialer.Dial(path, http.Header{"Authorization": []string{"Stream wrong"}})
	if bad != nil {
		bad.Close()
	}
	if response != nil {
		response.Body.Close()
	}
	if err == nil || response == nil || response.StatusCode != 403 {
		t.Fatal("invalid producer ticket accepted")
	}
	producer, _, err := dialer.Dial(path, http.Header{"Authorization": []string{"Stream " + hello.ProducerToken}})
	if err != nil {
		t.Fatal(err)
	}
	defer producer.Close()
	for _, payload := range [][]byte{{0, 1, 255, 0, 8}, bytes.Repeat([]byte{41}, 32768)} {
		if producer.WriteMessage(websocket.BinaryMessage, payload) != nil {
			t.Fatal("write failed")
		}
		_ = consumer.SetReadDeadline(time.Now().Add(3 * time.Second))
		kind, got, err := consumer.ReadMessage()
		if err != nil || kind != websocket.BinaryMessage || !bytes.Equal(got, payload) {
			t.Fatalf("opaque bytes changed: %v", err)
		}
	}
	duplicate, response, err := dialer.Dial(path, http.Header{"Authorization": []string{"Stream " + hello.ProducerToken}})
	if duplicate != nil {
		duplicate.Close()
	}
	if response != nil {
		response.Body.Close()
	}
	if err == nil || response == nil || response.StatusCode != 403 {
		t.Fatal("producer ticket reused")
	}
	consumer.Close()
	_ = producer.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := producer.ReadMessage(); err == nil {
		t.Fatal("producer remained open after consumer closed")
	}
}

func TestBinaryStreamRevocation(t *testing.T) {
	f := newFixture(t, true)
	consumer, _, err := dialConsoleAgentSocket(f, "/ws/streams", true, "")
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()
	_ = readAgentFrame[map[string]string](t, consumer)
	f.s.store.update(func(st *state) error { st.Sessions = nil; return nil })
	_ = consumer.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := consumer.ReadMessage(); err == nil {
		t.Fatal("revoked consumer remained connected")
	}
}

func TestBinaryStreamResourceLimit(t *testing.T) {
	f := newFixture(t, true)
	for i := 0; i < 8; i++ {
		ws, _, err := dialConsoleAgentSocket(f, "/ws/streams", true, "")
		if err != nil {
			t.Fatal(err)
		}
		defer ws.Close()
		_ = readAgentFrame[map[string]string](t, ws)
	}
	ws, response, err := dialConsoleAgentSocket(f, "/ws/streams", true, "")
	if ws != nil {
		ws.Close()
	}
	if response != nil {
		response.Body.Close()
	}
	if err == nil || response == nil || response.StatusCode != 429 {
		t.Fatal("unbounded stream rendezvous accepted")
	}
}
