package agent

import "encoding/json"

// Never discard a delta silently: a slow consumer is disconnected and resumes
// from its last applied byte cursor on the next connection.
type WorkshopSubscription struct {
	ID       string
	Updates  chan Reply
	Overflow chan struct{}
	failed   bool
}

func (c *Connection) SubscribeWorkshop(operation string, cursor int64) (*WorkshopSubscription, error) {
	c.workshopMu.Lock()
	defer c.workshopMu.Unlock()
	if len(c.workshop) >= 16 {
		return nil, ErrBusy
	}
	if c.workshop == nil {
		c.workshop = make(map[string]*WorkshopSubscription)
	}
	sub := &WorkshopSubscription{ID: c.newID(), Updates: make(chan Reply, 8), Overflow: make(chan struct{})}
	c.workshop[sub.ID] = sub
	params, _ := json.Marshal(map[string]any{"operationId": operation, "cursor": cursor})
	if err := c.Send(Message{Type: "workshop_start", ID: sub.ID, Params: params}); err != nil {
		delete(c.workshop, sub.ID)
		c.Close()
		return nil, err
	}
	return sub, nil
}

func (c *Connection) UnsubscribeWorkshop(sub *WorkshopSubscription) {
	c.workshopMu.Lock()
	delete(c.workshop, sub.ID)
	c.workshopMu.Unlock()
	select {
	case <-c.done:
		return
	default:
	}
	if c.Send(Message{Type: "workshop_stop", ID: sub.ID}) != nil {
		c.Close()
	}
}

func (c *Connection) publishWorkshop(message Message) {
	c.workshopMu.Lock()
	defer c.workshopMu.Unlock()
	sub := c.workshop[message.ID]
	if sub == nil || sub.failed {
		return
	}
	select {
	case sub.Updates <- message.Reply:
	default:
		sub.failed = true
		close(sub.Overflow)
	}
}
