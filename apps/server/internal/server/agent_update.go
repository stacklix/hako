package server

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"time"

	"hako/server/internal/notify"
)

// This endpoint authenticates only upgrade receipts. It never registers a peer
// or replaces the live Agent connection during a program update.
func (s *Server) agentUpdateNotification(w http.ResponseWriter, r *http.Request) {
	if !s.allow("agent-update-auth:"+s.loginClientIP(r), 60, time.Minute) {
		reject(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	var input struct {
		Username  string `json:"username"`
		KeyID     string `json:"keyId"`
		Payload   string `json:"payload"`
		Signature string `json:"signature"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 12*1024)
	if !decodeJSON(r.Body, &input) || !equal(input.Username, s.config.Username) {
		reject(w, http.StatusUnauthorized, "invalid_agent_identity")
		return
	}
	s.registryMu.Lock()
	defer s.registryMu.Unlock()
	var computer *AgentConfig
	for _, entry := range s.registry.Load().Agents {
		if equal(entry.keyID, input.KeyID) {
			copy := entry
			computer = &copy
			break
		}
	}
	if computer == nil {
		reject(w, http.StatusUnauthorized, "invalid_agent_identity")
		return
	}
	proof := []byte("hako-agent-update/v1\n" + s.config.PublicURL + "\n" + input.Username + "\n" + input.KeyID + "\n" + input.Payload)
	hash := sha256.Sum256(proof)
	signature, err := base64.StdEncoding.DecodeString(input.Signature)
	if err != nil || rsa.VerifyPSS(computer.key, crypto.SHA256, hash[:], signature, &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash}) != nil {
		reject(w, http.StatusUnauthorized, "invalid_agent_proof")
		return
	}
	data, err := base64.StdEncoding.DecodeString(input.Payload)
	var event notify.AgentUpdate
	if err != nil || len(data) > 4096 || !decodeJSONBytes(data, &event) || !event.Valid() {
		reject(w, http.StatusBadRequest, "invalid_update_event")
		return
	}
	event.ComputerID, event.ComputerName = computer.ID, computer.Name
	if s.notifications == nil {
		respond(w, http.StatusOK, map[string]string{"status": "skipped", "reason": "notifications_unavailable"})
		return
	}
	status, err := s.notifications.EnqueueAgentUpdate(event)
	if err != nil {
		reject(w, http.StatusInternalServerError, "notification_enqueue_failed")
		return
	}
	respond(w, http.StatusOK, map[string]string{"status": status})
}
