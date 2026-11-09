package agent

import "sync"

type TelemetryUpdate struct {
	Reply
	Type    string `json:"type"`
	Method  string `json:"method"`
	Version int    `json:"version"`
}

type Subscription struct {
	mu      sync.Mutex
	changed chan struct{}
	pending map[string]TelemetryUpdate
}

func (sub *Subscription) queue(update TelemetryUpdate) {
	sub.mu.Lock()
	defer sub.mu.Unlock()
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
	update := TelemetryUpdate{message.Reply, "update", message.Method, message.Version}
	c.latestTelemetry[message.Method] = update
	for sub := range c.subscribers {
		sub.queue(update)
	}
}

func (sub *Subscription) Changed() <-chan struct{} { return sub.changed }
