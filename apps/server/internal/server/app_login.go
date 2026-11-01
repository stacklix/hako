package server

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// SecretHash is base64url(SHA256(secret)); raw application secrets are never stored.
type AuthClientConfig struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Origin     string `json:"origin"`
	SecretHash string `json:"secretHash"`
	Enabled    bool   `json:"enabled"`
	CreatedAt  int64  `json:"createdAt"`
}

func validateAuthClients(clients []AuthClientConfig) error {
	seen := map[string]bool{}
	for _, c := range clients {
		u, err := url.Parse(c.Origin)
		if !identifier.MatchString(c.ID) || seen[c.ID] || strings.TrimSpace(c.Name) == "" || len(c.Name) > 80 || !validLoginID(c.SecretHash) || err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || strings.ContainsAny(c.Name, "\r\n") {
			return fmt.Errorf("invalid authClients configuration (unique id, name, HTTPS origin and SHA256 base64url secretHash required)")
		}
		seen[c.ID] = true
	}
	return nil
}

func (s *Server) authClient(id string) (AuthClientConfig, bool) {
	var c AuthClientConfig
	var ok bool
	s.store.inspect(func(st state) { c, ok = st.AuthClients[id] })
	return c, ok && c.Enabled
}

func (s *Server) validApplicationRequest(req *adminLoginRequest) bool {
	if req.ClientID == "" {
		return true
	}
	c, ok := s.authClient(req.ClientID)
	return ok && c.SecretHash == req.ClientKeyHash
}

func (s *Server) appClient(w http.ResponseWriter, r *http.Request) (AuthClientConfig, bool) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !s.allow("app-auth:"+ip, 360, time.Minute) {
		reject(w, 429, "rate_limited")
		return AuthClientConfig{}, false
	}
	c, ok := s.authClient(r.Header.Get("X-Hako-Client"))
	secret := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || !validLoginID(secret) || !equal(digest(secret), c.SecretHash) || r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
		reject(w, 401, "invalid_application")
		return AuthClientConfig{}, false
	}
	return c, true
}

func (s *Server) appLoginRoutes() {
	s.mux.HandleFunc("POST /api/v1/app-login/requests", s.createAppLogin)
	s.mux.HandleFunc("GET /api/v1/app-login/requests/{id}", s.pollAppLogin)
	s.mux.HandleFunc("DELETE /api/v1/app-login/requests/{id}", s.cancelAppLogin)
	s.mux.HandleFunc("POST /api/v1/app-login/requests/{id}/complete", s.completeAppLogin)
	s.mux.HandleFunc("GET /api/v1/app-login/session", s.appSession)
	s.mux.HandleFunc("DELETE /api/v1/app-login/session", s.appSession)
}

func (s *Server) createAppLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	if !s.hasAdminConsole() {
		reject(w, 503, "admin_not_configured")
		return
	}
	if !s.allow("app-create:"+c.ID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	var body struct {
		Purpose   string `json:"purpose"`
		UserAgent string `json:"userAgent"`
		ClientIP  string `json:"clientIP"`
	}
	if !decode(w, r, &body) {
		return
	}
	if (body.Purpose != "login" && body.Purpose != "bind") || len(body.UserAgent) > 512 || (body.ClientIP != "" && net.ParseIP(body.ClientIP) == nil) {
		reject(w, 400, "invalid_request")
		return
	}
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		reject(w, 503, "login_unavailable")
		return
	}
	id, redeem := randomToken(), randomToken()
	now := time.Now()
	expires := now.Add(adminLoginLifetime)
	req := &adminLoginRequest{ClientID: c.ID, ClientName: c.Name, ClientOrigin: c.Origin, ClientKeyHash: c.SecretHash, Purpose: body.Purpose, RedeemHash: digest(redeem), Code: fmt.Sprintf("%06d", number.Int64()), Nonce: randomToken(), Browser: browserLabel(body.UserAgent), ClientIP: body.ClientIP, Status: "pending", Created: now, Expires: expires}
	s.adminMu.Lock()
	if !s.validApplicationRequest(req) {
		s.adminMu.Unlock()
		reject(w, 401, "invalid_application")
		return
	}
	s.cleanupAdminLogins(now)
	if len(s.adminLogins) >= 256 {
		s.adminMu.Unlock()
		reject(w, 429, "too_many_login_requests")
		return
	}
	s.adminLogins[digest(id)] = req
	s.adminMu.Unlock()
	// v2 prevents old mobile clients from approving without showing the target application.
	payload := "hako://web-login?" + url.Values{"v": {"2"}, "server": {s.config.PublicURL}, "request": {id}}.Encode()
	respond(w, 201, map[string]any{"id": id, "redeemToken": redeem, "confirmationCode": req.Code, "qrPayload": payload, "expiresAt": expires.UTC().Format(time.RFC3339), "pollIntervalMs": 2000})
}

// adminMu must be held. A public QR ID cannot poll or redeem an application request.
func (s *Server) applicationLogin(w http.ResponseWriter, r *http.Request, c AuthClientConfig) *adminLoginRequest {
	id := r.PathValue("id")
	req := s.adminLogins[digest(id)]
	secret := r.Header.Get("X-Hako-Request")
	if !validLoginID(id) || !validLoginID(secret) || req == nil || req.ClientID != c.ID || req.ClientKeyHash != c.SecretHash || !s.validApplicationRequest(req) || !equal(req.RedeemHash, digest(secret)) {
		reject(w, 404, "login_request_not_found")
		return nil
	}
	if !time.Now().Before(req.Expires) {
		delete(s.adminLogins, digest(id))
		reject(w, 410, "login_request_expired")
		return nil
	}
	if req.Status == "approved" && !s.validAdminApprover(req.ApproverSessionID, req.ApproverThumb) {
		req.Status = "denied"
	}
	return req
}

func (s *Server) pollAppLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.applicationLogin(w, r, c)
	if req == nil {
		return
	}
	respond(w, 200, map[string]string{"status": req.Status, "expiresAt": req.Expires.UTC().Format(time.RFC3339)})
}

func (s *Server) cancelAppLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	if s.applicationLogin(w, r, c) == nil {
		return
	}
	delete(s.adminLogins, digest(r.PathValue("id")))
	respond(w, 200, map[string]bool{"ok": true})
}

func (s *Server) completeAppLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	var body struct{}
	if !decode(w, r, &body) {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.applicationLogin(w, r, c)
	if req == nil {
		return
	}
	if req.Status != "approved" {
		reject(w, 409, "login_not_approved")
		return
	}
	s.cleanupAdminLogins(time.Now())
	subject := ""
	s.store.inspect(func(st state) { subject = st.Subject })
	result := map[string]any{"issuer": s.config.PublicURL, "subject": subject, "username": s.config.Username, "clientId": c.ID, "purpose": req.Purpose}
	if req.Purpose == "login" {
		if len(s.adminSessions) >= 128 {
			reject(w, 429, "too_many_admin_sessions")
			return
		}
		token := randomToken()
		now := time.Now()
		s.adminSessions[digest(token)] = adminSession{ID: randomToken(), Browser: req.Browser, Created: now, LastUsed: now, ApproverSessionID: req.ApproverSessionID, ApproverThumb: req.ApproverThumb, ClientID: c.ID, ClientName: c.Name, ClientOrigin: c.Origin, ClientKeyHash: c.SecretHash}
		result["sessionToken"] = token
		result["expiresAt"] = now.Add(12 * time.Hour).UTC().Format(time.RFC3339)
	}
	delete(s.adminLogins, digest(r.PathValue("id")))
	respond(w, 200, result)
}

func (s *Server) appSession(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	token := r.Header.Get("X-Hako-Session")
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	key := digest(token)
	ss, ok := s.adminSessions[key]
	current, enabled := s.authClient(c.ID)
	if !validLoginID(token) || !ok || ss.ClientID != c.ID || !enabled || current.SecretHash != c.SecretHash || ss.ClientKeyHash != c.SecretHash {
		reject(w, 401, "invalid_session")
		return
	}
	if r.Method == "DELETE" {
		delete(s.adminSessions, key)
		respond(w, 200, map[string]bool{"ok": true})
		return
	}
	if adminExpired(ss, time.Now()) || !s.validAdminApprover(ss.ApproverSessionID, ss.ApproverThumb) {
		delete(s.adminSessions, key)
		reject(w, 401, "invalid_session")
		return
	}
	ss.LastUsed = time.Now()
	s.adminSessions[key] = ss
	subject := ""
	s.store.inspect(func(st state) { subject = st.Subject })
	respond(w, 200, map[string]any{"active": true, "issuer": s.config.PublicURL, "subject": subject, "clientId": c.ID})
}
