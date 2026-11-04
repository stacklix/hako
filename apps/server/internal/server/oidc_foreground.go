package server

import (
	"net/http"
	"slices"
	"time"
)

// Authenticated Console discovery intentionally omits the confirmation code and
// browser binding. Merely reading this list cannot approve or claim a login.
func (s *Server) pendingOIDCLogins(w http.ResponseWriter, r *http.Request) {
	sessionID, _, ok := s.consoleAdminApprover(w, r)
	if !ok {
		return
	}
	if !s.allow("oidc-console-poll:"+sessionID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	type prompt struct {
		ID                string `json:"id"`
		Origin            string `json:"origin"`
		Application       string `json:"application"`
		ApplicationOrigin string `json:"applicationOrigin"`
		Scopes            string `json:"scopes"`
		Browser           string `json:"browser"`
		ClientIP          string `json:"clientIP"`
		RequestedAt       string `json:"requestedAt"`
		ExpiresAt         string `json:"expiresAt"`
		Nonce             string `json:"nonce"`
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	now := time.Now()
	s.cleanupAdminLogins(now)
	items := []prompt{}
	for _, req := range s.adminLogins {
		// Requests already opened via QR/deep link are handled by that confirmation UI.
		if req.OIDC == nil || req.Status != "pending" || !validLoginID(req.RequestID) || !s.validApplicationRequest(req) {
			continue
		}
		items = append(items, prompt{req.RequestID, s.config.PublicURL, req.ClientName, req.ClientOrigin, req.OIDC.Scope, req.Browser, req.ClientIP, req.Created.UTC().Format(time.RFC3339), req.Expires.UTC().Format(time.RFC3339), req.Nonce})
	}
	slices.SortFunc(items, func(a, b prompt) int {
		if a.RequestedAt < b.RequestedAt {
			return -1
		}
		if a.RequestedAt > b.RequestedAt {
			return 1
		}
		if a.ID < b.ID {
			return -1
		}
		if a.ID > b.ID {
			return 1
		}
		return 0
	})
	if len(items) > 32 {
		items = items[:32]
	}
	w.Header().Set("Cache-Control", "no-store")
	respond(w, 200, map[string]any{"issuer": s.config.PublicURL, "requests": items})
}
