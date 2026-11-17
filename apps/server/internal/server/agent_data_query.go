package server

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"time"

	"hako/server/internal/dbschema"
)

// Web and native Console administrators share the same persisted permission.
func (s *Server) adminAgentDataPermission(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Enabled *bool `json:"enabled"`
	}
	if !decode(w, r, &input) {
		return
	}
	if input.Enabled == nil {
		reject(w, 400, "enabled_required")
		return
	}
	s.saveAgentDataPermission(r.PathValue("id"), *input.Enabled).writeHTTP(w)
}

func (s *Server) saveAgentDataPermission(id string, enabled bool) agentAPIReply {
	s.registryMu.Lock()
	defer s.registryMu.Unlock()
	next := *s.registry.Load()
	next.Agents = append([]AgentConfig{}, next.Agents...)
	for i := range next.Agents {
		if next.Agents[i].ID != id {
			continue
		}
		next.Agents[i].DataQueryEnabled = enabled
		if err := s.saveRegistry(&next); err != nil {
			return agentAPIFailure(503, "storage_unavailable")
		}
		return agentAPIReply{200, map[string]bool{"dataQueryEnabled": enabled}}
	}
	return agentAPIFailure(404, "agent_not_found")
}

func (s *Server) agentDataQuery(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" {
		reject(w, 403, "native_agent_required")
		return
	}
	if !s.allow("agent-data-auth:"+s.loginClientIP(r), 60, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	var input struct {
		Username  string `json:"username"`
		KeyID     string `json:"keyId"`
		Payload   string `json:"payload"`
		Signature string `json:"signature"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 40*1024)
	if !decodeJSON(r.Body, &input) || !equal(input.Username, s.config.Username) {
		reject(w, 401, "invalid_agent_identity")
		return
	}
	var query struct {
		Operation string `json:"operation"`
		SQL       string `json:"sql"`
		Limit     int    `json:"limit"`
		Offset    int    `json:"offset"`
		IssuedAt  int64  `json:"issuedAt"`
		Nonce     string `json:"nonce"`
	}
	data, err := base64.StdEncoding.DecodeString(input.Payload)
	if err != nil || len(data) > 24*1024 || !decodeJSONBytes(data, &query) {
		reject(w, 400, "invalid_query_request")
		return
	}
	now := time.Now()
	if query.IssuedAt < now.Unix()-60 || query.IssuedAt > now.Unix()+15 || !validLoginID(query.Nonce) {
		reject(w, 401, "expired_or_invalid_proof")
		return
	}
	s.registryMu.Lock()
	var computer *AgentConfig
	for _, entry := range s.registry.Load().Agents {
		if equal(entry.keyID, input.KeyID) {
			copy := entry
			computer = &copy
			break
		}
	}
	if computer == nil {
		s.registryMu.Unlock()
		reject(w, 401, "invalid_agent_identity")
		return
	}
	hash := sha256.Sum256([]byte("hako-agent-data/v1\n" + s.config.PublicURL + "\n" + input.Username + "\n" + input.KeyID + "\n" + input.Payload))
	signature, err := base64.StdEncoding.DecodeString(input.Signature)
	if err != nil || rsa.VerifyPSS(computer.key, crypto.SHA256, hash[:], signature, &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash}) != nil {
		s.registryMu.Unlock()
		reject(w, 401, "invalid_agent_proof")
		return
	}
	if !computer.DataQueryEnabled {
		s.registryMu.Unlock()
		reject(w, 403, "agent_data_query_disabled")
		return
	}
	if !s.allow("agent-data:"+computer.ID, 30, time.Minute) {
		s.registryMu.Unlock()
		reject(w, 429, "rate_limited")
		return
	}
	err = s.store.update(func(st *state) error {
		return consumeProof(st, proof{Thumb: "agent-data:" + input.KeyID, JTI: query.Nonce}, now)
	})
	s.registryMu.Unlock()
	if err != nil {
		if errors.Is(err, errProofReplay) {
			reject(w, 401, "agent_proof_replayed")
		} else {
			reject(w, 503, "storage_unavailable")
		}
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	// The grant covers investment data only, never authentication or notification secrets.
	if query.Operation == "schema" {
		schema, err := dbschema.Inspect(ctx, s.investment)
		if err != nil {
			reject(w, 503, "database_unavailable")
			return
		}
		respond(w, 200, map[string]any{"database": "investment", "schema": schema})
		return
	}
	if query.Operation != "query" {
		reject(w, 400, "invalid_query_operation")
		return
	}
	if query.Limit == 0 {
		query.Limit = 100
	}
	result, err := dbschema.Query(ctx, s.investment, query.SQL, query.Limit, query.Offset)
	if err != nil {
		message := err.Error()
		if ctx.Err() != nil {
			message = "查询超过 5 秒或已取消，请缩小查询范围。"
		}
		respond(w, 400, map[string]string{"error": "database_query_failed", "message": message})
		return
	}
	respond(w, 200, result)
}
