package agent

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var ErrBusy = errors.New("agent_busy")

const MaxConcurrentRequests = 16

type Connection struct {
	newID           func() string
	conn            *websocket.Conn
	writeMu         sync.Mutex
	mu              sync.Mutex
	pending         map[string]chan Message
	done            chan struct{}
	once            sync.Once
	capabilities    json.RawMessage
	sshTunnel       bool
	ssh             *agentSSH
	telemetryMu     sync.Mutex
	telemetryID     string
	subscribers     map[*Subscription]struct{}
	latestTelemetry map[string]TelemetryUpdate
}

func (c *Connection) Send(v any) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.conn.WriteJSON(v)
}
func (c *Connection) Close() { c.once.Do(func() { close(c.done); _ = c.conn.Close() }) }

func NewConnection(ws *websocket.Conn, capabilities json.RawMessage, sshTunnel bool, newID func() string) *Connection {
	return &Connection{
		conn: ws, pending: make(map[string]chan Message), done: make(chan struct{}),
		capabilities: append(json.RawMessage(nil), capabilities...), sshTunnel: sshTunnel, newID: newID,
	}
}

func (c *Connection) Capabilities() json.RawMessage { return c.capabilities }
func (c *Connection) HasSSHTunnel() bool            { return c.sshTunnel }
func (c *Connection) Done() <-chan struct{}         { return c.done }

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
		var fields map[string]json.RawMessage
		if c.conn.ReadJSON(&fields) != nil {
			return
		}
		var message Message
		if json.Unmarshal(fields["type"], &message.Type) != nil {
			return
		}
		_ = json.Unmarshal(fields["id"], &message.ID)
		if message.Type == "pong" {
			onPong()
			continue
		}
		if message.Type == "telemetry_update" {
			// The method is only a cache key. Its spelling, version and payload
			// belong to the device and Console, not to this relay.
			message.Method = string(fields["method"])
			fields["type"] = json.RawMessage(`"update"`)
			delete(fields, "id")
			message.Payload, _ = json.Marshal(fields)
			c.publishTelemetry(message)
			continue
		}
		if message.Type == "ssh_data" || message.Type == "ssh_closed" {
			data, _ := json.Marshal(fields)
			if json.Unmarshal(data, &message) != nil {
				return
			}
			c.publishSSH(message)
			continue
		}
		if message.Type != "response" || message.ID == "" {
			return
		}
		delete(fields, "type")
		delete(fields, "id")
		message.Payload, _ = json.Marshal(fields)
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

func (c *Connection) Request(ctx context.Context, request Request) (Message, error) {
	id := c.newID()
	ch := make(chan Message, 1)
	c.mu.Lock()
	// Device monitoring has its own sixteen request slots.
	if len(c.pending) >= MaxConcurrentRequests {
		c.mu.Unlock()
		return Message{}, ErrBusy
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}()
	if err := c.Send(request.envelope(id)); err != nil {
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
