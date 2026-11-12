package workshop

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const Protocol = "hako.workshop/1"
const RequestLimit = 16

func ValidMethod(method string) bool {
	switch method {
	case "applications.list", "models.list", "history.read", "operation.read", "artifact.read", "image.read",
		"turn.start", "turn.stop", "thread.archive", "image.upload", "message.queue", "message.update", "message.cancel", "message.steer", "approval.reply":
		return true
	}
	return false
}

var ErrBusy = errors.New("workshop_busy")
var ErrClosed = errors.New("workshop_disconnected")

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Frame struct {
	Kind        string          `json:"kind"`
	Protocol    string          `json:"protocol,omitempty"`
	ID          string          `json:"id,omitempty"`
	ComputerID  string          `json:"computerId,omitempty"`
	Method      string          `json:"method,omitempty"`
	Params      json.RawMessage `json:"params,omitempty"`
	OperationID string          `json:"operationId,omitempty"`
	Cursor      int64           `json:"cursor,omitempty"`
	Result      json.RawMessage `json:"result,omitempty"`
	Error       *Error          `json:"error,omitempty"`
	Account     string          `json:"account,omitempty"`
	KeyID       string          `json:"keyId,omitempty"`
	Signature   string          `json:"signature,omitempty"`
}

type Subscription struct {
	ID       string
	Updates  chan Frame
	Overflow chan struct{}
	failed   bool
}

type Connection struct {
	ws      *websocket.Conn
	newID   func() string
	write   sync.Mutex
	mu      sync.Mutex
	pending map[string]chan Frame
	streams map[string]*Subscription
	done    chan struct{}
	once    sync.Once
	// Called only for unsolicited terminal receipts on an authenticated Agent socket.
	Terminal func(Frame) bool
}

func New(ws *websocket.Conn, newID func() string) *Connection {
	return &Connection{ws: ws, newID: newID, pending: map[string]chan Frame{}, streams: map[string]*Subscription{}, done: make(chan struct{})}
}
func (c *Connection) Done() <-chan struct{} { return c.done }
func (c *Connection) Close()                { c.once.Do(func() { close(c.done); _ = c.ws.Close() }) }
func (c *Connection) Send(frame any) error {
	c.write.Lock()
	defer c.write.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.ws.WriteJSON(frame)
}
func (c *Connection) Run(seen func()) {
	defer c.Close()
	go func() {
		tick := time.NewTicker(20 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-c.done:
				return
			case <-tick.C:
				if c.Send(Frame{Kind: "keepalive"}) != nil {
					c.Close()
					return
				}
			}
		}
	}()
	for {
		_ = c.ws.SetReadDeadline(time.Now().Add(60 * time.Second))
		var frame Frame
		if c.ws.ReadJSON(&frame) != nil {
			return
		}
		if frame.Kind == "alive" {
			seen()
			continue
		}
		if frame.Kind == "terminal" {
			if c.Terminal == nil || !c.Terminal(frame) || c.Send(Frame{Kind: "terminal_ack", OperationID: frame.OperationID}) != nil {
				return
			}
			continue
		}
		if frame.ID == "" || (frame.Kind != "result" && frame.Kind != "failure" && frame.Kind != "event") {
			return
		}
		if frame.Error == nil {
			if len(frame.Result) == 0 || !json.Valid(frame.Result) {
				return
			}
		} else if frame.Error.Code == "" || len(frame.Error.Message) > 1024 || len(frame.Result) > 0 {
			return
		}
		c.mu.Lock()
		if sub := c.streams[frame.ID]; sub != nil {
			if !sub.failed {
				select {
				case sub.Updates <- frame:
				default:
					sub.failed = true
					close(sub.Overflow)
				}
			}
		} else if ch := c.pending[frame.ID]; ch != nil {
			select {
			case ch <- frame:
			default:
			}
		}
		c.mu.Unlock()
	}
}
func (c *Connection) Call(ctx context.Context, request Frame) (Frame, error) {
	if err := ctx.Err(); err != nil {
		return Frame{}, err
	}
	id := c.newID()
	ch := make(chan Frame, 1)
	c.mu.Lock()
	if len(c.pending) >= RequestLimit {
		c.mu.Unlock()
		return Frame{}, ErrBusy
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() { c.mu.Lock(); delete(c.pending, id); c.mu.Unlock() }()
	request.Kind = "call"
	request.ID = id
	if err := c.Send(request); err != nil {
		c.Close()
		return Frame{}, err
	}
	select {
	case frame := <-ch:
		return frame, nil
	case <-c.done:
		return Frame{}, ErrClosed
	case <-ctx.Done():
		return Frame{}, ctx.Err()
	}
}
func (c *Connection) Subscribe(operation string, cursor int64) (*Subscription, error) {
	c.mu.Lock()
	if len(c.streams) >= 16 {
		c.mu.Unlock()
		return nil, ErrBusy
	}
	sub := &Subscription{ID: c.newID(), Updates: make(chan Frame, 8), Overflow: make(chan struct{})}
	c.streams[sub.ID] = sub
	c.mu.Unlock()
	if err := c.Send(Frame{Kind: "watch", ID: sub.ID, OperationID: operation, Cursor: cursor}); err != nil {
		c.Unsubscribe(sub)
		c.Close()
		return nil, err
	}
	return sub, nil
}
func (c *Connection) Unsubscribe(sub *Subscription) {
	c.mu.Lock()
	delete(c.streams, sub.ID)
	c.mu.Unlock()
	select {
	case <-c.done:
		return
	default:
	}
	if c.Send(Frame{Kind: "unwatch", ID: sub.ID}) != nil {
		c.Close()
	}
}

type peer struct {
	connection *Connection
	seen       string
}
type Hub struct {
	mu    sync.Mutex
	peers map[string]peer
}

func (h *Hub) Lookup(id string) (*Connection, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	p := h.peers[id]
	return p.connection, p.seen
}
func (h *Hub) Register(id string, c *Connection) *Connection {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.peers == nil {
		h.peers = map[string]peer{}
	}
	old := h.peers[id].connection
	h.peers[id] = peer{c, time.Now().UTC().Format(time.RFC3339)}
	return old
}
func (h *Hub) Run(id string, c *Connection) {
	update := func(current *Connection) {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.peers[id].connection == c {
			h.peers[id] = peer{current, time.Now().UTC().Format(time.RFC3339)}
		}
	}
	defer update(nil)
	c.Run(func() { update(c) })
}
func (h *Hub) Remove(id string) {
	h.mu.Lock()
	c := h.peers[id].connection
	delete(h.peers, id)
	h.mu.Unlock()
	if c != nil {
		c.Close()
	}
}
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.peers {
		if p.connection != nil {
			p.connection.Close()
		}
	}
}
