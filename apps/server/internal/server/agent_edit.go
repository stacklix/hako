package server

// Registry edits belong to Console management, not to device business commands.
type agentUpdate struct {
	Name         string `json:"name"`
	PublicKeyPEM string `json:"publicKeyPem"`
	Revision     string `json:"revision"`
}

func agentEditRevision(a AgentConfig) string {
	return digest(a.ID + "\x00" + a.Name + "\x00" + a.keyID)
}

func agentDetailReply(a AgentConfig) agentAPIReply {
	return agentAPIReply{200, map[string]string{
		"id": a.ID, "name": a.Name, "publicKeyPem": a.PublicKeyPEM,
		"keyId": a.keyID, "revision": agentEditRevision(a),
	}}
}

func (s *Server) agentDetail(id string) agentAPIReply {
	for _, a := range s.registry.Load().Agents {
		if a.ID == id {
			return agentDetailReply(a)
		}
	}
	return agentAPIFailure(404, "agent_not_found")
}

func (s *Server) saveAgentUpdate(id string, request agentUpdate) agentAPIReply {
	s.registryMu.Lock()
	defer s.registryMu.Unlock()
	old := s.registry.Load()
	index := -1
	for i, a := range old.Agents {
		if a.ID == id {
			index = i
			break
		}
	}
	if index < 0 {
		return agentAPIFailure(404, "agent_not_found")
	}
	previous := old.Agents[index]
	if request.Revision == "" || request.Revision != agentEditRevision(previous) {
		return agentAPIFailure(409, "agent_changed")
	}
	updated := previous
	updated.Name, updated.PublicKeyPEM = request.Name, request.PublicKeyPEM
	updated, err := parseAgent(updated, false)
	if err != nil {
		return agentAPIFailure(400, "invalid_public_key_or_device")
	}
	for i, a := range old.Agents {
		if i != index && a.keyID == updated.keyID {
			return agentAPIFailure(409, "duplicate_agent")
		}
	}
	keyChanged := previous.keyID != updated.keyID
	if keyChanged {
		// Capabilities authenticated by the previous key are no longer authoritative.
		updated.Capabilities = nil
		updated.Modules = nil
	}
	next := *old
	next.Agents = append([]AgentConfig{}, old.Agents...)
	next.Agents[index] = updated
	if err = s.saveRegistry(&next); err != nil {
		return agentAPIFailure(503, "storage_unavailable")
	}
	if keyChanged {
		// Hold registryMu until old connections are removed so a newly authenticated
		// connection cannot be mistaken for one using the revoked key.
		s.agentHub.Remove(id)
		s.proxyHub.Remove(id)
		s.workshopHub.Remove(id)
	}
	return agentDetailReply(updated)
}
