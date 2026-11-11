package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"hako/server/internal/agent"
)

type agentAPIReply struct {
	Status int
	Body   any
}

func agentAPIFailure(status int, code string) agentAPIReply {
	return agentAPIReply{status, map[string]string{"error": code}}
}

func (reply agentAPIReply) writeHTTP(w http.ResponseWriter) {
	respond(w, reply.Status, reply.Body)
}

type consoleAgentCommand struct {
	ID      string          `json:"id"`
	Type    string          `json:"type"`
	AgentID string          `json:"agentId"`
	Body    json.RawMessage `json:"body"`
}

type consoleAgentReply struct {
	Type   string `json:"type"`
	ID     string `json:"id,omitempty"`
	Status int    `json:"status"`
	Body   any    `json:"body"`
}

func (s *Server) consoleAgentSocket(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" {
		reject(w, 403, "origin_not_allowed")
		return
	}
	sessionID, ok := s.authorized(w, r)
	if !ok {
		return
	}
	if !s.allow("console-agents:"+sessionID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	tokenDigest := digest(strings.TrimPrefix(r.Header.Get("Authorization"), "DPoP "))
	valid := func() bool {
		active := false
		s.store.inspect(func(st state) {
			ss := st.Sessions[sessionID]
			active = ss != nil && ss.Access[tokenDigest] > time.Now().Unix() && trustedConsoleState(&st, ss.Thumb)
		})
		return active
	}
	write := func(value any) bool {
		_ = ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
		return ws.WriteJSON(value) == nil
	}
	if id := r.PathValue("terminalID"); id != "" {
		s.streamSSH(ctx, id, ws, valid)
		return
	}
	if !valid() || !write(map[string]string{"type": "ready"}) {
		return
	}

	liveID := r.PathValue("id")
	workshopID := r.PathValue("workshopAgentID")
	commands := make(chan consoleAgentCommand, agent.MaxConcurrentRequests)
	ws.SetReadLimit(17 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(45 * time.Second))
	ws.SetPongHandler(func(string) error { return ws.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	go func() {
		defer cancel()
		for {
			kind, data, err := ws.ReadMessage()
			if err != nil || liveID != "" || workshopID != "" || kind != websocket.TextMessage {
				return
			}
			var command consoleAgentCommand
			if !decodeJSON(bytes.NewReader(data), &command) || !identifier.MatchString(command.ID) {
				return
			}
			select {
			case commands <- command:
			default:
				return
			}
		}
	}()
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	ping := func() bool {
		return valid() && ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) == nil
	}
	if liveID != "" {
		s.streamAgentTelemetry(ctx, liveID, heartbeat.C, ping, valid, write)
		return
	}
	if workshopID != "" {
		s.streamWorkshop(ctx, workshopID, r.PathValue("operationID"), r.PathValue("cursor"), heartbeat.C, ping, valid, write)
		return
	}

	replies := make(chan consoleAgentReply, agent.MaxConcurrentRequests)
	inFlight := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-heartbeat.C:
			if !ping() {
				return
			}
		case command := <-commands:
			if !valid() {
				return
			}
			if inFlight == cap(replies) || !s.allow("api", 600, time.Minute) {
				reply := agentAPIFailure(429, "too_many_requests")
				if !write(consoleAgentReply{"reply", command.ID, reply.Status, reply.Body}) {
					return
				}
				continue
			}
			inFlight++
			go func() {
				reply := s.consoleAgentCall(ctx, command)
				replies <- consoleAgentReply{"reply", command.ID, reply.Status, reply.Body}
			}()
		case reply := <-replies:
			inFlight--
			if !valid() || !write(reply) {
				return
			}
		}
	}
}

func (s *Server) consoleAgentCall(ctx context.Context, command consoleAgentCommand) agentAPIReply {
	if len(command.Body) > 16*1024 {
		return agentAPIFailure(400, "invalid_request")
	}
	switch command.Type {
	case "list":
		return agentAPIReply{200, map[string]any{"agents": s.agentItems(false)}}
	case "register":
		var request agentRegistration
		if decodeJSON(bytes.NewReader(command.Body), &request) {
			return s.saveAgentRegistration(request)
		}
	case "request":
		var request agent.Request
		if decodeJSON(bytes.NewReader(command.Body), &request) {
			return s.callAgent(ctx, command.AgentID, request)
		}
	}
	return agentAPIFailure(400, "invalid_request")
}

func (s *Server) streamAgentTelemetry(ctx context.Context, id string, heartbeat <-chan time.Time, ping, valid func() bool, write func(any) bool) {
	c, _ := s.agentHub.Lookup(id)
	fail := func(status int, code string) {
		if ctx.Err() == nil && valid() {
			write(consoleAgentReply{"error", "", status, agentAPIFailure(status, code).Body})
		}
	}
	if c == nil {
		fail(409, "agent_offline")
		return
	}
	if ctx.Err() != nil || !valid() {
		return
	}
	sub, err := c.Subscribe()
	if err != nil {
		fail(409, "agent_disconnected")
		return
	}
	defer c.Unsubscribe(sub)
	if ctx.Err() != nil || !valid() || !write(map[string]string{"type": "subscribed"}) {
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.Done():
			fail(409, "agent_disconnected")
			return
		case <-heartbeat:
			if !ping() {
				return
			}
		case <-sub.Changed():
			for _, update := range sub.Take() {
				if !valid() || !write(update) {
					return
				}
			}
		}
	}
}
