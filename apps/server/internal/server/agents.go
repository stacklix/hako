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
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type agentCapability struct {
	Name    string `json:"name"`
	Version int    `json:"version"`
}

var errAgentBusy = errors.New("agent_busy")
var methodName = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)

func validCapabilities(methods []agentCapability) bool {
	if methods == nil || len(methods) > 64 {
		return false
	}
	seen := map[string]bool{}
	for _, m := range methods {
		if len(m.Name) > 100 || !methodName.MatchString(m.Name) || (!strings.HasPrefix(m.Name, "query.") && !strings.HasPrefix(m.Name, "action.")) || m.Name == "query.all" || strings.Count(m.Name, ".") < 2 || m.Version < 1 || seen[m.Name] {
			return false
		}
		seen[m.Name] = true
	}
	return true
}

type agentError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type agentResult struct {
	Result json.RawMessage `json:"result,omitempty"`
	Error  *agentError     `json:"error,omitempty"`
}

func (m agentResult) valid() bool {
	if m.Error != nil {
		return len(m.Result) == 0 && identifier.MatchString(m.Error.Code) && len(m.Error.Message) <= 1024
	}
	return len(m.Result) != 0 && json.Valid(m.Result)
}

type agentRequest struct {
	Method  string          `json:"method"`
	Version int             `json:"version"`
	Params  json.RawMessage `json:"params"`
}

type agentMessage struct {
	agentResult
	Type         string            `json:"type"`
	ID           string            `json:"id,omitempty"`
	Method       string            `json:"method,omitempty"`
	Version      int               `json:"version,omitempty"`
	Username     string            `json:"username,omitempty"`
	KeyID        string            `json:"keyId,omitempty"`
	Signature    string            `json:"signature,omitempty"`
	Params       json.RawMessage   `json:"params,omitempty"`
	Capabilities []agentCapability `json:"capabilities,omitempty"`
}

type agentConnection struct {
	conn         *websocket.Conn
	writeMu      sync.Mutex
	mu           sync.Mutex
	pending      map[string]chan agentMessage
	done         chan struct{}
	once         sync.Once
	capabilities []agentCapability
}

func (c *agentConnection) send(v any) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.conn.WriteJSON(v)
}
func (c *agentConnection) close() { c.once.Do(func() { close(c.done); _ = c.conn.Close() }) }

func (s *Server) agentSocket(w http.ResponseWriter, r *http.Request) {
	if !s.allow("ws", 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	// Native agents never send Origin. Reject browser cross-origin websocket attempts.
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second, CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" }}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &agentConnection{conn: ws, pending: map[string]chan agentMessage{}, done: make(chan struct{})}
	defer c.close()
	ws.SetReadLimit(64 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	authFail := func() {
		_ = ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "authentication failed"), time.Now().Add(time.Second))
	}
	var hello agentMessage
	if ws.ReadJSON(&hello) != nil || hello.Type != "hello" || hello.Version != 3 || !validCapabilities(hello.Capabilities) {
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
	c.capabilities = append([]agentCapability{}, hello.Capabilities...)
	payload := []byte("hako-agent-auth/v3\n" + s.config.PublicURL + "\n" + hello.Username + "\n" + hello.KeyID + "\n" + randomToken())
	if c.send(map[string]any{"type": "challenge", "payload": base64.StdEncoding.EncodeToString(payload)}) != nil {
		return
	}
	var auth agentMessage
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
		if next.Agents[i].ID == configured.ID {
			next.Agents[i].Capabilities = c.capabilities
		}
	}
	if s.saveRegistry(&next) != nil {
		s.registryMu.Unlock()
		return
	}
	if c.send(map[string]string{"type": "authenticated", "agentId": configured.ID, "name": configured.Name}) != nil {
		s.registryMu.Unlock()
		return
	}
	s.mu.Lock()
	old := s.online[configured.ID]
	s.online[configured.ID] = c
	s.lastSeen[configured.ID] = time.Now().UTC().Format(time.RFC3339)
	s.mu.Unlock()
	s.registryMu.Unlock()
	if old != nil {
		old.close()
	}
	defer func() {
		s.mu.Lock()
		if s.online[configured.ID] == c {
			delete(s.online, configured.ID)
			s.lastSeen[configured.ID] = time.Now().UTC().Format(time.RFC3339)
		}
		s.mu.Unlock()
	}()
	go func() {
		ticker := time.NewTicker(20 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if c.send(map[string]string{"type": "ping"}) != nil {
					c.close()
					return
				}
			case <-c.done:
				return
			}
		}
	}()
	for {
		_ = ws.SetReadDeadline(time.Now().Add(60 * time.Second))
		var message agentMessage
		if ws.ReadJSON(&message) != nil {
			return
		}
		if message.Type == "pong" {
			s.mu.Lock()
			s.lastSeen[configured.ID] = time.Now().UTC().Format(time.RFC3339)
			s.mu.Unlock()
			continue
		}
		if message.Type != "response" || message.ID == "" {
			return
		}
		if !message.agentResult.valid() {
			return
		}
		c.mu.Lock()
		ch := c.pending[message.ID]
		c.mu.Unlock()
		if ch != nil {
			select {
			case ch <- message:
			default:
			}
		}
	}
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
	s.mu.Lock()
	for _, a := range s.registry.Load().Agents {
		c := s.online[a.ID]
		online := c != nil
		if online {
			select {
			case <-c.done:
				online = false
			default:
			}
		}
		capabilities := a.Capabilities
		if online {
			capabilities = c.capabilities
		}
		item := map[string]any{"id": a.ID, "name": a.Name, "online": online, "lastSeen": s.lastSeen[a.ID], "capabilities": capabilities}
		if includeKey {
			item["keyId"] = a.keyID
			item["publicKeyPem"] = a.PublicKeyPEM
		}
		items = append(items, item)
	}
	s.mu.Unlock()
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
	var request agentRequest
	if !decode(w, r, &request) {
		return
	}
	if len(request.Method) > 100 || !methodName.MatchString(request.Method) || request.Version < 1 || len(request.Params) == 0 || request.Params[0] != '{' {
		reject(w, 400, "invalid_request")
		return
	}
	select {
	case s.requests <- struct{}{}:
		defer func() { <-s.requests }()
	default:
		reject(w, 429, "too_many_requests")
		return
	}
	s.mu.Lock()
	c := s.online[r.PathValue("id")]
	s.mu.Unlock()
	if c == nil {
		reject(w, 409, "agent_offline")
		return
	}
	supported := request.Method == "query.all" && request.Version == 1
	for _, m := range c.capabilities {
		if m.Name == request.Method && m.Version == request.Version {
			supported = true
			break
		}
	}
	if !supported {
		reject(w, 400, "unsupported_method")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.config.RequestTimeout)
	defer cancel()
	result, err := c.request(ctx, request)
	if err != nil {
		if errors.Is(err, errAgentBusy) {
			reject(w, 429, "agent_busy")
		} else if errors.Is(err, context.DeadlineExceeded) {
			reject(w, 504, "agent_timeout")
		} else {
			reject(w, 409, "agent_disconnected")
		}
		return
	}
	if request.Method == "query.all" {
		respond(w, 200, struct {
			agentResult
			Capabilities []agentCapability `json:"capabilities"`
		}{result.agentResult, c.capabilities})
	} else {
		respond(w, 200, result.agentResult)
	}
}

func (c *agentConnection) request(ctx context.Context, request agentRequest) (agentMessage, error) {
	id := randomToken()
	ch := make(chan agentMessage, 1)
	c.mu.Lock()
	if len(c.pending) >= 4 {
		c.mu.Unlock()
		return agentMessage{}, errAgentBusy
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() { c.mu.Lock(); delete(c.pending, id); c.mu.Unlock() }()
	if err := c.send(agentMessage{Type: "request", ID: id, Method: request.Method, Version: request.Version, Params: request.Params}); err != nil {
		c.close()
		return agentMessage{}, err
	}
	select {
	case result := <-ch:
		return result, nil
	case <-c.done:
		return agentMessage{}, errors.New("agent_disconnected")
	case <-ctx.Done():
		return agentMessage{}, ctx.Err()
	}
}
