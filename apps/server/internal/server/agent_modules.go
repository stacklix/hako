package server

import (
	"context"
	"errors"
	"hako/server/internal/agent"
)

// Module selection and versions are opaque metadata. The device decides what
// it supports; opening a transport never enters the business-command queue.
func (s *Server) callAgentModule(ctx context.Context, id string, request agent.Request) agentAPIReply {
	c, _ := s.agentHub.Lookup(id)
	if c == nil {
		return agentAPIFailure(409, "agent_offline")
	}
	ctx, cancel := context.WithTimeout(ctx, s.config.RequestTimeout)
	defer cancel()
	reply, err := c.OpenModule(ctx, request)
	if errors.Is(err, agent.ErrBusy) {
		return agentAPIFailure(429, "module_busy")
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return agentAPIFailure(504, "module_timeout")
	}
	if err != nil {
		return agentAPIFailure(409, "agent_disconnected")
	}
	return agentAPIReply{200, reply.Payload}
}
