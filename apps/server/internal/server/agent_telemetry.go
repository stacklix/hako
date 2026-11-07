package server

import "sync"

type agentTelemetryUpdate struct {
	agentResult
	Type    string `json:"type"`
	Method  string `json:"method"`
	Version int    `json:"version"`
}

type agentSubscription struct {
	mu      sync.Mutex
	changed chan struct{}
	pending map[string]agentTelemetryUpdate
}

func (sub *agentSubscription) queue(update agentTelemetryUpdate) {
	sub.mu.Lock()
	defer sub.mu.Unlock()
	sub.pending[update.Method] = update
	select {
	case sub.changed <- struct{}{}:
	default:
	}
}

func (sub *agentSubscription) take() map[string]agentTelemetryUpdate {
	sub.mu.Lock()
	defer sub.mu.Unlock()
	pending := sub.pending
	sub.pending = make(map[string]agentTelemetryUpdate)
	return pending
}

func (c *agentConnection) subscribe() (*agentSubscription, error) {
	c.telemetryMu.Lock()
	defer c.telemetryMu.Unlock()
	if len(c.subscribers) == 0 {
		c.telemetryID = randomToken()
		if err := c.send(agentMessage{Type: "telemetry_start", ID: c.telemetryID}); err != nil {
			c.close()
			return nil, err
		}
		c.subscribers = make(map[*agentSubscription]struct{})
		c.latestTelemetry = make(map[string]agentTelemetryUpdate)
	}
	sub := &agentSubscription{
		changed: make(chan struct{}, 1),
		pending: make(map[string]agentTelemetryUpdate),
	}
	for _, update := range c.latestTelemetry {
		sub.queue(update)
	}
	c.subscribers[sub] = struct{}{}
	return sub, nil
}

func (c *agentConnection) unsubscribe(sub *agentSubscription) {
	c.telemetryMu.Lock()
	defer c.telemetryMu.Unlock()
	delete(c.subscribers, sub)
	if len(c.subscribers) == 0 {
		c.latestTelemetry = nil
		select {
		case <-c.done:
		default:
			if c.send(agentMessage{Type: "telemetry_stop", ID: c.telemetryID}) != nil {
				c.close()
			}
		}
		c.telemetryID = ""
	}
}

func (c *agentConnection) publishTelemetry(message agentMessage) {
	c.telemetryMu.Lock()
	defer c.telemetryMu.Unlock()
	if message.ID != c.telemetryID || len(c.subscribers) == 0 {
		return
	}
	update := agentTelemetryUpdate{message.agentResult, "update", message.Method, message.Version}
	c.latestTelemetry[message.Method] = update
	for sub := range c.subscribers {
		sub.queue(update)
	}
}
