package agent

import "testing"

func TestWorkshopOverflowRequiresCursorRecovery(t *testing.T) {
	sub := &WorkshopSubscription{ID: "stream", Updates: make(chan Reply, 2), Overflow: make(chan struct{})}
	c := &Connection{workshop: map[string]*WorkshopSubscription{"stream": sub}}
	c.publishWorkshop(Message{ID: "other"})
	if len(sub.Updates) != 0 {
		t.Fatal("Crossed subscription identity")
	}
	for i := 0; i < 4; i++ {
		c.publishWorkshop(Message{ID: "stream"})
	}
	select {
	case <-sub.Overflow:
	default:
		t.Fatal("Slow reader silently lost events")
	}
	if len(sub.Updates) != 2 {
		t.Fatal("Buffer is not bounded")
	}
}
