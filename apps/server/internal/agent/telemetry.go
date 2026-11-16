package agent

import (
	"encoding/json"
	"sync"
)

type TelemetryUpdate struct {
	Reply
	Type    string          `json:"type"`
	Method  string          `json:"method"`
	Version int             `json:"version"`
	Payload json.RawMessage `json:"-"`
}

func (update TelemetryUpdate) MarshalJSON() ([]byte, error) {
	if update.Payload != nil {
		return update.Payload, nil
	}
	type fields TelemetryUpdate
	return json.Marshal(fields(update))
}

// Bound memory independently of the contents of device-provided metadata.
func makeRoom(items map[string]TelemetryUpdate, key string) {
	if _, exists := items[key]; !exists && len(items) >= 64 {
		for old := range items {
			delete(items, old)
			break
		}
	}
}

type Subscription struct {
	mu      sync.Mutex
	changed chan struct{}
	pending map[string]TelemetryUpdate
}

func (sub *Subscription) queue(update TelemetryUpdate) {
	sub.mu.Lock()
	defer sub.mu.Unlock()
	makeRoom(sub.pending, update.Method)
	sub.pending[update.Method] = update
	select {
	case sub.changed <- struct{}{}:
	default:
	}
}

func (sub *Subscription) Take() map[string]TelemetryUpdate {
	sub.mu.Lock()
	defer sub.mu.Unlock()
	pending := sub.pending
	sub.pending = make(map[string]TelemetryUpdate)
	return pending
}

func (c *Connection) Subscribe() (*Subscription, error) {
	c.telemetryMu.Lock()
	defer c.telemetryMu.Unlock()
	if len(c.subscribers) == 0 {
		c.telemetryID = c.newID()
		if err := c.Send(Message{Type: "telemetry_start", ID: c.telemetryID}); err != nil {
			c.Close()
			return nil, err
		}
		c.subscribers = make(map[*Subscription]struct{})
		c.latestTelemetry = make(map[string]TelemetryUpdate)
	}
	sub := &Subscription{
		changed: make(chan struct{}, 1),
		pending: make(map[string]TelemetryUpdate),
	}
	for _, update := range c.latestTelemetry {
		sub.queue(update)
	}
	c.subscribers[sub] = struct{}{}
	return sub, nil
}

func (c *Connection) Unsubscribe(sub *Subscription) {
	c.telemetryMu.Lock()
	defer c.telemetryMu.Unlock()
	delete(c.subscribers, sub)
	if len(c.subscribers) == 0 {
		c.latestTelemetry = nil
		select {
		case <-c.done:
		default:
			if c.Send(Message{Type: "telemetry_stop", ID: c.telemetryID}) != nil {
				c.Close()
			}
		}
		c.telemetryID = ""
	}
}

func (c *Connection) publishTelemetry(message Message) {
	c.telemetryMu.Lock()
	defer c.telemetryMu.Unlock()
	if message.ID != c.telemetryID || len(c.subscribers) == 0 {
		return
	}
	update := TelemetryUpdate{Reply: message.Reply, Type: "update", Method: message.Method, Version: message.Version, Payload: message.Payload}
	makeRoom(c.latestTelemetry, message.Method)
	c.latestTelemetry[message.Method] = update
	for sub := range c.subscribers {
		sub.queue(update)
	}
}

func (sub *Subscription) Changed() <-chan struct{} { return sub.changed }
