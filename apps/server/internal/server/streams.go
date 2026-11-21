package server

// Streams relay opaque binary messages. Device commands, codecs and encryption
// are exclusively the responsibility of the two endpoints.
import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type binaryStream struct {
	secret   string
	expires  time.Time
	producer chan *websocket.Conn
	valid    func() bool
	claimed  bool
	done     chan struct{}
}

func (s *Server) consumeStream(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" {
		reject(w, 403, "origin_not_allowed")
		return
	}
	sessionID, ok := s.authorized(w, r)
	if !ok {
		return
	}
	if !s.allow("streams:"+sessionID, 12, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	digestToken := digest(strings.TrimPrefix(r.Header.Get("Authorization"), "DPoP "))
	valid := func() bool {
		active := false
		s.store.inspect(func(st state) {
			ss := st.Sessions[sessionID]
			active = ss != nil && ss.Access[digestToken] > time.Now().Unix() && trustedConsoleState(&st, ss.Thumb)
		})
		return active
	}
	id := randomToken()
	entry := &binaryStream{secret: randomToken(), expires: time.Now().Add(30 * time.Second), producer: make(chan *websocket.Conn), valid: valid, done: make(chan struct{})}
	s.streamMu.Lock()
	if s.streams == nil {
		s.streams = map[string]*binaryStream{}
	}
	if len(s.streams) >= 8 {
		s.streamMu.Unlock()
		reject(w, 429, "too_many_streams")
		return
	}
	s.streams[id] = entry
	s.streamMu.Unlock()
	defer func() { s.streamMu.Lock(); delete(s.streams, id); s.streamMu.Unlock(); close(entry.done) }()
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second}
	consumer, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer consumer.Close()
	_ = consumer.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if consumer.WriteJSON(map[string]string{"id": id, "producerToken": entry.secret}) != nil {
		return
	}
	consumer.SetReadLimit(64 * 1024)
	_ = consumer.SetReadDeadline(time.Now().Add(45 * time.Second))
	consumer.SetPongHandler(func(string) error { return consumer.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	closed := make(chan struct{})
	peerReady := make(chan *websocket.Conn, 1)
	relayContext, cancelRelay := context.WithCancel(r.Context())
	go func() {
		defer close(closed)
		var peer *websocket.Conn
		for {
			kind, payload, err := consumer.ReadMessage()
			if err != nil || kind != websocket.BinaryMessage || len(payload) == 0 || !valid() {
				return
			}
			// At most one bounded frame waits for rendezvous. Keep one reader
			// per socket, and never interpret endpoint-specific payloads.
			if peer == nil {
				select {
				case peer = <-peerReady:
				case <-relayContext.Done():
					return
				}
			}
			if !valid() {
				return
			}
			_ = peer.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if peer.WriteMessage(kind, payload) != nil {
				return
			}
		}
	}()
	defer func() { cancelRelay(); consumer.Close(); <-closed }()
	wait := time.NewTimer(time.Until(entry.expires))
	defer wait.Stop()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	var producer *websocket.Conn
	for producer == nil {
		select {
		case <-closed:
			return
		case <-r.Context().Done():
			return
		case <-wait.C:
			return
		case <-ticker.C:
			if !valid() {
				return
			}
		case producer = <-entry.producer:
		}
	}
	defer producer.Close()
	peerReady <- producer
	done := make(chan struct{})
	go func() {
		defer close(done)
		producer.SetReadLimit(64 * 1024)
		_ = producer.SetReadDeadline(time.Now().Add(45 * time.Second))
		producer.SetPongHandler(func(string) error { return producer.SetReadDeadline(time.Now().Add(45 * time.Second)) })
		for {
			kind, payload, err := producer.ReadMessage()
			if err != nil || kind != websocket.BinaryMessage || len(payload) == 0 || !valid() {
				return
			}
			_ = consumer.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if consumer.WriteMessage(kind, payload) != nil {
				return
			}
		}
	}()
	defer func() { producer.Close(); <-done }()
	limit := time.NewTimer(time.Hour)
	defer limit.Stop()
	seconds := 0
	for {
		select {
		case <-closed:
			return
		case <-done:
			return
		case <-limit.C:
			return
		case <-r.Context().Done():
			return
		case <-ticker.C:
			if !valid() {
				return
			}
			seconds++
			if seconds%15 == 0 {
				for _, ws := range []*websocket.Conn{consumer, producer} {
					if ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) != nil {
						return
					}
				}
			}
		}
	}
}

func (s *Server) produceStream(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" {
		reject(w, 403, "origin_not_allowed")
		return
	}
	s.streamMu.Lock()
	entry := s.streams[r.PathValue("id")]
	// Claim before the upgrade, so concurrent requests cannot reuse a ticket.
	if entry == nil || entry.claimed || time.Now().After(entry.expires) || !equal(r.Header.Get("Authorization"), "Stream "+entry.secret) || !entry.valid() {
		s.streamMu.Unlock()
		reject(w, 403, "invalid_stream")
		return
	}
	entry.claimed = true
	s.streamMu.Unlock()
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	timer := time.NewTimer(time.Until(entry.expires))
	defer timer.Stop()
	select {
	case entry.producer <- ws:
	case <-timer.C:
		return
	case <-r.Context().Done():
		return
	}
	// Ownership is with the consumer handler. Keep this request alive until it closes.
	select {
	case <-entry.done:
	case <-r.Context().Done():
	}
}
