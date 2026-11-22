package server

import (
	"context"
	"errors"
	"net/http"

	"hako/server/internal/agent"
)

// The request and reply bodies belong to the proxy endpoints, not to the
// server. No target URL, HTTP method, headers or device command is interpreted.
func (s *Server) requestProxy(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	var request agent.Request
	if !decode(w, r, &request) {
		return
	}
	s.callProxy(r.Context(), r.PathValue("id"), request).writeHTTP(w)
}

func (s *Server) callProxy(parent context.Context, id string, request agent.Request) agentAPIReply {
	select {
	case s.proxyRequests <- struct{}{}:
		defer func() { <-s.proxyRequests }()
	default:
		return agentAPIFailure(429, "proxy_busy")
	}
	c, _ := s.proxyHub.Lookup(id)
	if c == nil {
		return agentAPIFailure(409, "proxy_offline")
	}
	ctx, cancel := context.WithTimeout(parent, s.config.RequestTimeout)
	defer cancel()
	result, err := c.Request(ctx, request)
	if errors.Is(err, agent.ErrBusy) {
		return agentAPIFailure(429, "proxy_busy")
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return agentAPIFailure(504, "proxy_timeout")
	}
	if err != nil {
		return agentAPIFailure(409, "proxy_disconnected")
	}
	return agentAPIReply{200, result.Payload}
}
