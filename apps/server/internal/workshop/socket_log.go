package workshop

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Never log error messages, URLs, frame payloads or credentials.
type SocketLog struct {
	mu       sync.Mutex
	id, role string
	started  time.Time
	closed   bool
	write    func([]byte)
}

func NewSocketLog(role, id string, sinks ...func([]byte)) *SocketLog {
	d := &SocketLog{id: id, role: role, started: time.Now(), write: func(data []byte) {
		log.Printf("workshop_socket %s", data)
		for _, sink := range sinks {
			sink(data)
		}
	}}
	d.Event("opened", nil)
	return d
}

func (d *SocketLog) Event(event string, err error) {
	if d == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return
	}
	if event == "closed" {
		d.closed = true
	}
	fields := map[string]any{"time": time.Now().UTC(), "connectionId": d.id, "role": d.role, "event": event, "elapsedMs": time.Since(d.started).Milliseconds()}
	if err != nil {
		fields["errorClass"] = "transport"
		var closeError *websocket.CloseError
		var networkError net.Error
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			fields["errorClass"] = "timeout"
		case errors.Is(err, context.Canceled):
			fields["errorClass"] = "cancelled"
		case errors.As(err, &closeError):
			fields["errorClass"] = "websocket_close"
			fields["closeCode"] = closeError.Code
		case errors.As(err, &networkError):
			fields["errorClass"] = "network"
			fields["timeout"] = networkError.Timeout()
		default:
			fields["errorClass"] = "read_or_protocol"
		}
	}
	data, _ := json.Marshal(fields)
	d.write(data)
}
