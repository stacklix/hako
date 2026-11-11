package server

import (
	"context"
	"regexp"
	"strconv"
	"time"
)

var workshopOperationID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Server) streamWorkshop(ctx context.Context, agentID, operationID, rawCursor string,
	heartbeat <-chan time.Time, ping, valid func() bool, write func(any) bool) {
	fail := func(status int, code string) {
		if ctx.Err() == nil && valid() {
			write(consoleAgentReply{"error", "", status, agentAPIFailure(status, code).Body})
		}
	}
	cursor, err := strconv.ParseInt(rawCursor, 10, 64)
	if err != nil || cursor < 0 || !workshopOperationID.MatchString(operationID) {
		fail(400, "invalid_request")
		return
	}
	c, _ := s.agentHub.Lookup(agentID)
	if c == nil {
		fail(409, "agent_offline")
		return
	}
	if !c.Supports("query.codex.stream", 1) {
		fail(409, "unsupported_method")
		return
	}
	sub, err := c.SubscribeWorkshop(operationID, cursor)
	if err != nil {
		fail(409, "stream_unavailable")
		return
	}
	defer c.UnsubscribeWorkshop(sub)
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.Done():
			fail(409, "agent_disconnected")
			return
		case <-sub.Overflow:
			fail(409, "stream_overflow")
			return
		case <-heartbeat:
			if !ping() {
				return
			}
		case update := <-sub.Updates:
			if !valid() || !write(map[string]any{"type": "update", "body": update}) {
				return
			}
			if update.Error != nil {
				return
			}
		}
	}
}
