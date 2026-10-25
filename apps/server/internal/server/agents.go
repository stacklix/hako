package server

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"math"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Metrics struct {
	CPUUsagePercent    float64 `json:"cpuUsagePercent"`
	MemoryUsagePercent float64 `json:"memoryUsagePercent"`
	MemoryUsedBytes    uint64  `json:"memoryUsedBytes"`
	MemoryTotalBytes   uint64  `json:"memoryTotalBytes"`
	SampledAt          string  `json:"sampledAt"`
	SampleWindowMS     int     `json:"sampleWindowMs"`
}

var errAgentBusy = errors.New("agent_busy")

func (m Metrics) valid() bool {
	_, err := time.Parse(time.RFC3339Nano, m.SampledAt)
	return err == nil && !math.IsNaN(m.CPUUsagePercent) && !math.IsInf(m.CPUUsagePercent, 0) && m.CPUUsagePercent >= 0 && m.CPUUsagePercent <= 100 && m.MemoryUsagePercent >= 0 && m.MemoryUsagePercent <= 100 && m.MemoryTotalBytes > 0 && m.MemoryUsedBytes <= m.MemoryTotalBytes && m.SampleWindowMS >= 500 && m.SampleWindowMS <= 5000 && math.Abs(m.MemoryUsagePercent-float64(m.MemoryUsedBytes)/float64(m.MemoryTotalBytes)*100) < 0.1
}

type agentMessage struct {
	Type      string   `json:"type"`
	ID        string   `json:"id,omitempty"`
	Method    string   `json:"method,omitempty"`
	Version   int      `json:"version,omitempty"`
	Username  string   `json:"username,omitempty"`
	KeyID     string   `json:"keyId,omitempty"`
	Signature string   `json:"signature,omitempty"`
	Result    *Metrics `json:"result,omitempty"`
	Error     string   `json:"error,omitempty"`
}

type agentConnection struct {
	conn    *websocket.Conn
	writeMu sync.Mutex
	mu      sync.Mutex
	pending map[string]chan agentMessage
	done    chan struct{}
	once    sync.Once
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
	if ws.ReadJSON(&hello) != nil || hello.Type != "hello" || hello.Version != 1 {
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
	payload := []byte("hako-agent-auth/v1\n" + s.config.PublicURL + "\n" + hello.Username + "\n" + hello.KeyID + "\n" + randomToken())
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
		if message.Error == "" && (message.Result == nil || !message.Result.valid()) {
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
		item := map[string]any{"id": a.ID, "name": a.Name, "platform": "windows", "online": online, "lastSeen": s.lastSeen[a.ID]}
		if includeKey {
			item["keyId"] = a.keyID
			item["publicKeyPem"] = a.PublicKeyPEM
		}
		items = append(items, item)
	}
	s.mu.Unlock()
	return items
}

func (s *Server) query(w http.ResponseWriter, r *http.Request) {
	_, ok := s.authorized(w, r)
	if !ok {
		return
	}
	s.queryMetrics(w, r)
}

func (s *Server) queryMetrics(w http.ResponseWriter, r *http.Request) {
	select {
	case s.queries <- struct{}{}:
		defer func() { <-s.queries }()
	default:
		reject(w, 429, "too_many_queries")
		return
	}
	s.mu.Lock()
	c := s.online[r.PathValue("id")]
	s.mu.Unlock()
	if c == nil {
		reject(w, 409, "agent_offline")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.config.QueryTimeout)
	defer cancel()
	result, err := c.query(ctx)
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
	if result.Error != "" {
		reject(w, 502, "agent_sample_failed")
		return
	}
	respond(w, 200, result.Result)
}

func (c *agentConnection) query(ctx context.Context) (agentMessage, error) {
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
	if err := c.send(agentMessage{Type: "request", ID: id, Method: "system.metrics"}); err != nil {
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
