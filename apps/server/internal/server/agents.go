package server

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/gorilla/websocket"

	"hako/server/internal/agent"
)

func (s *Server) agentSocket(w http.ResponseWriter, r *http.Request) {
	s.deviceSocket(w, r, &s.agentHub, false)
}

func (s *Server) proxySocket(w http.ResponseWriter, r *http.Request) {
	s.deviceSocket(w, r, &s.proxyHub, true)
}

// Proxy and device commands share trust, but have separate sockets, hubs,
// request budgets and challenge domains. Payloads remain opaque to Sora.
func (s *Server) deviceSocket(w http.ResponseWriter, r *http.Request, hub *agent.Hub, proxy bool) {
	if !s.allow("ws:"+r.URL.Path, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	// Native agents never send Origin. Reject browser cross-origin websocket attempts.
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second, CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" }}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	ws.SetReadLimit(64 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	authFail := func() {
		_ = ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "authentication failed"), time.Now().Add(time.Second))
	}
	var hello struct {
		Type         string          `json:"type"`
		Username     string          `json:"username"`
		KeyID        string          `json:"keyId"`
		Capabilities json.RawMessage `json:"capabilities"`
		Modules      json.RawMessage `json:"modules"`
		SSHTunnel    bool            `json:"sshTunnel"`
	}
	if ws.ReadJSON(&hello) != nil || hello.Type != "hello" {
		authFail()
		return
	}
	username := s.config.Username
	var configured *AgentConfig
	for _, value := range s.registry.Load().Agents {
		a := value
		if equal(hello.KeyID, a.keyID) {
			configured = &a
			break
		}
	}
	if username == "" || !equal(hello.Username, username) || configured == nil {
		authFail()
		return
	}
	domain := "hako-agent-auth/v4\n"
	if proxy {
		domain = "hako-proxy-auth/v1\n"
		hello.Capabilities = nil
		hello.SSHTunnel = false
	}
	c := agent.NewConnection(ws, hello.Capabilities, hello.SSHTunnel, randomToken)
	if !proxy {
		c.SetModules(hello.Modules)
	}
	payload := []byte(domain + s.config.PublicURL + "\n" + hello.Username + "\n" + hello.KeyID + "\n" + randomToken())
	if c.Send(map[string]any{"type": "challenge", "payload": base64.StdEncoding.EncodeToString(payload)}) != nil {
		return
	}
	var auth agent.Message
	if ws.ReadJSON(&auth) != nil || auth.Type != "authenticate" {
		authFail()
		return
	}
	signature, err := base64.StdEncoding.DecodeString(auth.Signature)
	hash := sha256.Sum256(payload)
	if err != nil || rsa.VerifyPSS(configured.key, crypto.SHA256, hash[:], signature, &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash}) != nil {
		authFail()
		return
	}
	// Serialize the final trust check and online registration with key deletion.
	s.registryMu.Lock()
	stillTrusted := false
	for _, a := range s.registry.Load().Agents {
		if a.ID == configured.ID && a.keyID == configured.keyID {
			stillTrusted = true
			break
		}
	}
	if !stillTrusted {
		s.registryMu.Unlock()
		authFail()
		return
	}
	// Persist only authenticated manifests, under the same lock as registration/deletion.
	next := *s.registry.Load()
	next.Agents = append([]AgentConfig{}, next.Agents...)
	for i := range next.Agents {
		if !proxy && next.Agents[i].ID == configured.ID {
			next.Agents[i].Capabilities = c.Capabilities()
			next.Agents[i].Modules = c.Modules()
		}
	}
	if !proxy && s.saveRegistry(&next) != nil {
		s.registryMu.Unlock()
		return
	}
	if c.Send(map[string]string{"type": "authenticated", "agentId": configured.ID, "name": configured.Name}) != nil {
		s.registryMu.Unlock()
		return
	}
	old := hub.Register(configured.ID, c)
	ws.SetReadLimit(agent.MaxReplyBytes)
	s.registryMu.Unlock()
	if old != nil {
		old.Close()
	}
	hub.Run(configured.ID, c)
}

func (s *Server) agents(w http.ResponseWriter, r *http.Request) {
	_, ok := s.authorized(w, r)
	if !ok {
		return
	}
	respond(w, 200, map[string]any{"agents": s.agentItems(false)})
}

func (s *Server) addAgent(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	s.registerAgent(w, r)
}

func (s *Server) agentItems(includeKey bool) []map[string]any {
	items := []map[string]any{}
	for _, a := range s.registry.Load().Agents {
		c, lastSeen := s.agentHub.Lookup(a.ID)
		online := c != nil
		if online {
			select {
			case <-c.Done():
				online = false
			default:
			}
		}
		capabilities := a.Capabilities
		if online {
			capabilities = c.Capabilities()
		}
		modules := a.Modules
		if online {
			modules = c.Modules()
		}
		item := map[string]any{"id": a.ID, "name": a.Name, "online": online, "lastSeen": lastSeen, "capabilities": capabilities, "modules": modules, "dataQueryEnabled": a.DataQueryEnabled}
		if includeKey {
			item["keyId"] = a.keyID
			item["publicKeyPem"] = a.PublicKeyPEM
		}
		items = append(items, item)
	}
	return items
}

func (s *Server) requestAgent(w http.ResponseWriter, r *http.Request) {
	_, ok := s.authorized(w, r)
	if !ok {
		return
	}
	s.forwardAgentRequest(w, r)
}

func (s *Server) forwardAgentRequest(w http.ResponseWriter, r *http.Request) {
	var request agent.Request
	if !decode(w, r, &request) {
		return
	}
	s.callAgent(r.Context(), r.PathValue("id"), request).writeHTTP(w)
}

func (s *Server) callAgent(ctx context.Context, id string, request agent.Request) agentAPIReply {
	select {
	case s.requests <- struct{}{}:
		defer func() { <-s.requests }()
	default:
		return agentAPIFailure(429, "too_many_requests")
	}
	c, _ := s.agentHub.Lookup(id)
	if c == nil {
		return agentAPIFailure(409, "agent_offline")
	}
	ctx, cancel := context.WithTimeout(ctx, s.config.RequestTimeout)
	defer cancel()
	result, err := c.Request(ctx, request)
	if err != nil {
		if errors.Is(err, agent.ErrBusy) {
			return agentAPIFailure(429, "agent_busy")
		} else if errors.Is(err, context.DeadlineExceeded) {
			return agentAPIFailure(504, "agent_timeout")
		} else {
			return agentAPIFailure(409, "agent_disconnected")
		}
	}
	return agentAPIReply{200, result.Payload}
}
