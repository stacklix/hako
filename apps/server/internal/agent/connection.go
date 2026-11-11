package agent

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var ErrBusy = errors.New("agent_busy")

type Connection struct {
	newID           func() string
	conn            *websocket.Conn
	writeMu         sync.Mutex
	mu              sync.Mutex
	pending         map[string]chan Message
	done            chan struct{}
	once            sync.Once
	capabilities    []Capability
	sshTunnel       bool
	ssh             *agentSSH
	telemetryMu     sync.Mutex
	telemetryID     string
	subscribers     map[*Subscription]struct{}
	latestTelemetry map[string]TelemetryUpdate
	workshopMu      sync.Mutex
	workshop        map[string]*WorkshopSubscription
}

func (c *Connection) Send(v any) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.conn.WriteJSON(v)
}
func (c *Connection) Close() { c.once.Do(func() { close(c.done); _ = c.conn.Close() }) }

func NewConnection(ws *websocket.Conn, capabilities []Capability, sshTunnel bool, newID func() string) *Connection {
	return &Connection{
		conn: ws, pending: make(map[string]chan Message), done: make(chan struct{}),
		capabilities: append([]Capability{}, capabilities...), sshTunnel: sshTunnel, newID: newID,
	}
}

func (c *Connection) Capabilities() []Capability { return c.capabilities }
func (c *Connection) HasSSHTunnel() bool         { return c.sshTunnel }
func (c *Connection) Done() <-chan struct{}      { return c.done }

func (c *Connection) run(onPong func()) {
	go func() {
		ticker := time.NewTicker(20 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if c.Send(map[string]string{"type": "ping"}) != nil {
					c.Close()
					return
				}
			case <-c.done:
				return
			}
		}
	}()
	for {
		_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		var message Message
		if c.conn.ReadJSON(&message) != nil {
			return
		}
		if message.Type == "pong" {
			onPong()
			continue
		}
		if message.Type == "telemetry_update" {
			if !message.Reply.valid() || !strings.HasPrefix(message.Method, "query.") || !c.Supports(message.Method, message.Version) || message.Method == "query.all" {
				return
			}
			c.publishTelemetry(message)
			continue
		}
		if message.Type == "ssh_data" || message.Type == "ssh_closed" {
			c.publishSSH(message)
			continue
		}
		if message.Type == "workshop_update" {
			if !message.Reply.valid() || message.ID == "" || !c.Supports("query.codex.stream", 1) {
				return
			}
			c.publishWorkshop(message)
			continue
		}
		if message.Type != "response" || message.ID == "" {
			return
		}
		if !message.Reply.valid() {
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

func (c *Connection) Supports(method string, version int) bool {
	if method == "query.all" && version == 1 {
		return true
	}
	for _, capability := range c.capabilities {
		if capability.Name == method && capability.Version == version {
			return true
		}
	}
	return false
}

func (c *Connection) Request(ctx context.Context, request Request) (Message, error) {
	id := c.newID()
	ch := make(chan Message, 1)
	c.mu.Lock()
	if len(c.pending) >= 4 {
		c.mu.Unlock()
		return Message{}, ErrBusy
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() { c.mu.Lock(); delete(c.pending, id); c.mu.Unlock() }()
	if err := c.Send(Message{Type: "request", ID: id, Method: request.Method, Version: request.Version, Params: request.Params}); err != nil {
		c.Close()
		return Message{}, err
	}
	select {
	case result := <-ch:
		return result, nil
	case <-c.done:
		return Message{}, errors.New("agent_disconnected")
	case <-ctx.Done():
		return Message{}, ctx.Err()
	}
}
