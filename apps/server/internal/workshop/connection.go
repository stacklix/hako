package workshop

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const Protocol = "hako.workshop/1"
const RequestLimit = 16

var ErrBusy = errors.New("workshop_busy")
var ErrClosed = errors.New("workshop_disconnected")

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Frame struct {
	Binary      []byte          `json:"-"`
	Kind        string          `json:"kind"`
	Protocol    string          `json:"protocol,omitempty"`
	ID          string          `json:"id,omitempty"`
	ComputerID  string          `json:"computerId,omitempty"`
	Method      string          `json:"method,omitempty"`
	Params      json.RawMessage `json:"params,omitempty"`
	OperationID string          `json:"operationId,omitempty"`
	QuestionID  string          `json:"questionId,omitempty"`
	Cursor      int64           `json:"cursor,omitempty"`
	Result      json.RawMessage `json:"result,omitempty"`
	Error       *Error          `json:"error,omitempty"`
	Account     string          `json:"account,omitempty"`
	KeyID       string          `json:"keyId,omitempty"`
	Signature   string          `json:"signature,omitempty"`
	Diagnostics bool            `json:"diagnostics,omitempty"`
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
	Terminal    func(Frame) bool
	Diagnostics *SocketLog
}

func New(ws *websocket.Conn, newID func() string) *Connection {
	return &Connection{ws: ws, newID: newID, pending: map[string]chan Frame{}, streams: map[string]*Subscription{}, done: make(chan struct{})}
}
func (c *Connection) Done() <-chan struct{} { return c.done }
func (c *Connection) Close() {
	c.once.Do(func() { c.Diagnostics.Event("closed", nil); close(c.done); _ = c.ws.Close() })
}
func (c *Connection) Send(frame any) error {
	c.write.Lock()
	defer c.write.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.ws.WriteJSON(frame)
}

// Binary frames contain only routing metadata here. Their body belongs to the Agent.
const MaximumBinaryFrame = 36 * 1024

func DecodeBinary(data []byte) (Frame, error) {
	if len(data) < 5 || len(data) > MaximumBinaryFrame {
		return Frame{}, fmt.Errorf("invalid binary frame size")
	}
	size := int(binary.BigEndian.Uint32(data[:4]))
	if size < 1 || size > 1024 || 4+size >= len(data) {
		return Frame{}, fmt.Errorf("invalid routing header")
	}
	var header struct {
		ID         string `json:"id"`
		ComputerID string `json:"computerId"`
	}
	if json.Unmarshal(data[4:4+size], &header) != nil || header.ID == "" || len(header.ID) > 80 {
		return Frame{}, fmt.Errorf("invalid routing identity")
	}
	return Frame{Kind: "call", ID: header.ID, ComputerID: header.ComputerID, Binary: append([]byte(nil), data[4+size:]...)}, nil
}
func EncodeBinary(id, computerID string, payload []byte) []byte {
	header, _ := json.Marshal(map[string]string{"id": id, "computerId": computerID})
	data := make([]byte, 4+len(header)+len(payload))
	binary.BigEndian.PutUint32(data[:4], uint32(len(header)))
	copy(data[4:], header)
	copy(data[4+len(header):], payload)
	return data
}
func (c *Connection) sendRequest(frame Frame) error {
	if frame.Binary == nil {
		return c.Send(frame)
	}
	c.write.Lock()
	defer c.write.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.ws.WriteMessage(websocket.BinaryMessage, EncodeBinary(frame.ID, "", frame.Binary))
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
				if err := c.Send(Frame{Kind: "keepalive"}); err != nil {
					c.Diagnostics.Event("keepalive_write_failed", err)
					c.Close()
					return
				}
			}
		}
	}()
	for {
		_ = c.ws.SetReadDeadline(time.Now().Add(60 * time.Second))
		var frame Frame
		if err := c.ws.ReadJSON(&frame); err != nil {
			c.Diagnostics.Event("read_failed", err)
			return
		}
		if frame.Kind == "alive" {
			seen()
			continue
		}
		if frame.Kind == "terminal" {
			if c.Terminal == nil || !c.Terminal(frame) || c.Send(Frame{Kind: "terminal_ack", OperationID: frame.OperationID, QuestionID: frame.QuestionID}) != nil {
				c.Diagnostics.Event("terminal_receipt_rejected", nil)
				return
			}
			continue
		}
		if frame.ID == "" || (frame.Kind != "result" && frame.Kind != "failure" && frame.Kind != "event") {
			c.Diagnostics.Event("invalid_frame", nil)
			return
		}
		if frame.Error == nil {
			if len(frame.Result) == 0 || !json.Valid(frame.Result) {
				c.Diagnostics.Event("invalid_result", nil)
				return
			}
		} else if frame.Error.Code == "" || len(frame.Error.Message) > 1024 || len(frame.Result) > 0 {
			c.Diagnostics.Event("invalid_error_frame", nil)
			return
		}
		c.mu.Lock()
		if sub := c.streams[frame.ID]; sub != nil {
			if !sub.failed {
				select {
				case sub.Updates <- frame:
				default:
					sub.failed = true
					c.Diagnostics.Event("subscription_overflow", nil)
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
	if err := c.sendRequest(request); err != nil {
		c.Diagnostics.Event("request_write_failed", err)
		c.Close()
		return Frame{}, err
	}
	select {
	case frame := <-ch:
		return frame, nil
	case <-c.done:
		return Frame{}, ErrClosed
	case <-ctx.Done():
		c.Diagnostics.Event("request_cancelled_or_timed_out", ctx.Err())
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
	// A new subscription starts at zero; the Agent requires the cursor field.
	// Frame omits zero cursors, so use an explicit watch envelope here.
	if err := c.Send(map[string]any{"kind": "watch", "id": sub.ID, "operationId": operation, "cursor": cursor}); err != nil {
		c.Diagnostics.Event("subscription_write_failed", err)
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
	if err := c.Send(Frame{Kind: "unwatch", ID: sub.ID}); err != nil {
		c.Diagnostics.Event("unsubscribe_write_failed", err)
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
