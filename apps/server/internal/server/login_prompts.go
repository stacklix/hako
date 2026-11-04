package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// Authenticated Console discovery intentionally omits the confirmation code and
// browser binding. Merely reading this list cannot approve or claim a login.
func (s *Server) pendingLoginPrompts(w http.ResponseWriter, r *http.Request) {
	sessionID, _, ok := s.consoleAdminApprover(w, r)
	if !ok {
		return
	}
	if !s.allow("oidc-console-poll:"+sessionID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	respond(w, 200, s.loginPromptSnapshot(r.URL.Path == "/api/v1/auth/oidc/requests"))
}

type loginPrompt struct {
	Purpose           string `json:"purpose"`
	ID                string `json:"id"`
	Origin            string `json:"origin"`
	Application       string `json:"application"`
	ApplicationOrigin string `json:"applicationOrigin"`
	Scopes            string `json:"scopes"`
	Browser           string `json:"browser"`
	ClientIP          string `json:"clientIP"`
	RequestedAt       string `json:"requestedAt"`
	ExpiresAt         string `json:"expiresAt"`
	Nonce             string `json:"nonce"`
}

type loginPromptList struct {
	Issuer   string        `json:"issuer"`
	Requests []loginPrompt `json:"requests"`
}

func (s *Server) loginPromptSnapshot(oidcOnly bool) loginPromptList {
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	now := time.Now()
	s.cleanupAdminLogins(now)
	items := []loginPrompt{}
	for _, req := range s.adminLogins {
		// The legacy OIDC notifier omits opened requests. The inbox includes all
		// still-actionable requests, including those inspected by another device.
		actionable := req.Status == "pending" || (!oidcOnly && req.Status == "scanned")
		if !req.Expires.UTC().Truncate(time.Second).After(now) || (oidcOnly && req.OIDC == nil) || !actionable || !validLoginID(req.RequestID) || !s.validApplicationRequest(req) {
			continue
		}
		items = append(items, loginPrompt{req.Purpose, req.RequestID, s.config.PublicURL, req.ClientName, req.ClientOrigin, oidcScopes(req), req.Browser, req.ClientIP, req.Created.UTC().Format(time.RFC3339), req.Expires.UTC().Format(time.RFC3339), req.Nonce})
	}
	slices.SortFunc(items, func(a, b loginPrompt) int {
		if a.RequestedAt < b.RequestedAt {
			return -1
		}
		if a.RequestedAt > b.RequestedAt {
			return 1
		}
		if a.ID < b.ID {
			return -1
		}
		if a.ID > b.ID {
			return 1
		}
		return 0
	})
	if oidcOnly && len(items) > 32 {
		items = items[:32]
	}
	return loginPromptList{Issuer: s.config.PublicURL, Requests: items}
}

// Called with adminMu held after a login mutation. Coalesce bursts without
// blocking the writer; each subscriber receives a complete current snapshot.
func (s *Server) unlockAdminAndNotifyLoginPrompts() {
	for _, changed := range s.loginPromptStreams {
		select {
		case changed <- struct{}{}:
		default:
		}
	}
	s.adminMu.Unlock()
}

func (s *Server) loginPromptStream(w http.ResponseWriter, r *http.Request) {
	sessionID, _, ok := s.consoleAdminApprover(w, r)
	if !ok {
		return
	}
	if !s.allow("login-prompt-stream:"+sessionID, 10, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	// Native Console only; never allow browser cookies or query credentials.
	if r.Header.Get("Origin") != "" {
		reject(w, 403, "origin_not_allowed")
		return
	}
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second, CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" }}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	changed := make(chan struct{}, 1)
	s.adminMu.Lock()
	if s.loginPromptStreams == nil {
		s.loginPromptStreams = map[string]chan struct{}{}
	}
	if previous := s.loginPromptStreams[sessionID]; previous != nil {
		close(previous)
	}
	s.loginPromptStreams[sessionID] = changed
	s.adminMu.Unlock()
	defer func() {
		s.adminMu.Lock()
		if s.loginPromptStreams[sessionID] == changed {
			delete(s.loginPromptStreams, sessionID)
		}
		s.adminMu.Unlock()
	}()
	// A reader processes pong/close frames and notices a disconnected phone.
	closed := make(chan struct{})
	ws.SetReadLimit(1024)
	_ = ws.SetReadDeadline(time.Now().Add(45 * time.Second))
	ws.SetPongHandler(func(string) error { return ws.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	go func() {
		defer close(closed)
		for {
			if _, _, err := ws.ReadMessage(); err != nil {
				return
			}
		}
	}()
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	// Reauthenticate periodically even if a token has an unusually long lifetime.
	lifetime := time.NewTimer(5 * time.Minute)
	defer lifetime.Stop()
	expiry := time.NewTimer(time.Hour)
	defer expiry.Stop()
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "DPoP ")
	var previous []byte
	for {
		valid := false
		s.store.inspect(func(st state) {
			ss := st.Sessions[sessionID]
			valid = ss != nil && ss.Access[digest(token)] > time.Now().Unix() && trustedConsoleState(&st, ss.Thumb)
		})
		if !valid {
			return
		}
		snapshot := s.loginPromptSnapshot(false)
		data, err := json.Marshal(snapshot)
		if err != nil {
			return
		}
		if !bytes.Equal(previous, data) {
			_ = ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if ws.WriteMessage(websocket.TextMessage, data) != nil {
				return
			}
			previous = data
		}
		// Expiration needs no mutation event. Wake exactly when the next row expires.
		next := time.Hour
		for _, item := range snapshot.Requests {
			if deadline, err := time.Parse(time.RFC3339, item.ExpiresAt); err == nil {
				if delay := time.Until(deadline); delay < next {
					next = max(delay, time.Millisecond)
				}
			}
		}
		if !expiry.Stop() {
			select {
			case <-expiry.C:
			default:
			}
		}
		expiry.Reset(next)
		select {
		case _, open := <-changed:
			if !open {
				return
			}
		case <-expiry.C:
		case <-heartbeat.C:
			if ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) != nil {
				return
			}
		case <-lifetime.C:
			return
		case <-closed:
			return
		case <-r.Context().Done():
			return
		}
	}
}
