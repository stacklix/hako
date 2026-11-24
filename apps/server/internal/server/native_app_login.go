package server

import (
	"crypto/sha256"
	"net"
	"net/http"
	"strings"
	"time"
)

// Native requests never enter the browser/QR approval path. All maps are owned
// by adminMu, like application sessions, and are intentionally restart-scoped.
type nativeApplicationAuth struct {
	requests map[string]*nativeApplicationRequest
	consents map[string]nativeApplicationConsent
}

type nativeApplicationConsent struct {
	ID, ClientID, ClientKeyHash, SessionID, Thumb string
	Created, LastUsed                             time.Time
}

type nativeApplicationRequest struct {
	ClientID, ClientKeyHash, Challenge, RedeemHash, Nonce, Browser string
	Created, Expires, CodeExpires                                  time.Time
	CodeHash, ConsentID                                            string
}

func (s *Server) nativeAppLoginRoutes() {
	s.nativeApps = &nativeApplicationAuth{requests: map[string]*nativeApplicationRequest{}, consents: map[string]nativeApplicationConsent{}}
	s.mux.HandleFunc("POST /api/v1/app-login/native/requests", s.createNativeAppLogin)
	s.mux.HandleFunc("POST /api/v1/app-login/native/requests/{id}/complete", s.completeNativeAppLogin)
	s.mux.HandleFunc("GET /api/v1/auth/native-app/requests/{id}", s.inspectNativeAppLogin)
	s.mux.HandleFunc("POST /api/v1/auth/native-app/requests/{id}/authorize", s.authorizeNativeAppLogin)
}

func validNativeVerifier(value string) bool {
	if len(value) < 43 || len(value) > 128 {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-._~", c)) {
			return false
		}
	}
	return true
}

func nativeChallenge(verifier string) string {
	hash := sha256.Sum256([]byte(verifier))
	return raw64.EncodeToString(hash[:])
}

func (s *Server) cleanupNativeAppLogins(now time.Time) {
	for id, req := range s.nativeApps.requests {
		if !now.Before(req.Expires) {
			delete(s.nativeApps.requests, id)
		}
	}
	for id, consent := range s.nativeApps.consents {
		if !s.validNativeConsent(consent) {
			delete(s.nativeApps.consents, id)
		}
	}
}

func (s *Server) validNativeConsent(consent nativeApplicationConsent) bool {
	c, ok := s.authClient(consent.ClientID)
	return ok && c.SecretHash == consent.ClientKeyHash && s.validAdminApprover(consent.SessionID, consent.Thumb)
}

func (s *Server) nativeRequest(w http.ResponseWriter, id string) (*nativeApplicationRequest, AuthClientConfig) {
	req := s.nativeApps.requests[digest(id)]
	if !validLoginID(id) || req == nil {
		reject(w, 404, "native_request_not_found")
		return nil, AuthClientConfig{}
	}
	if !time.Now().Before(req.Expires) {
		delete(s.nativeApps.requests, digest(id))
		reject(w, 410, "native_request_expired")
		return nil, AuthClientConfig{}
	}
	c, ok := s.authClient(req.ClientID)
	if !ok || c.SecretHash != req.ClientKeyHash {
		reject(w, 401, "invalid_application")
		return nil, AuthClientConfig{}
	}
	return req, c
}

func (s *Server) nativeRequestInfo(id string, req *nativeApplicationRequest, c AuthClientConfig) map[string]any {
	return map[string]any{"id": id, "issuer": s.config.PublicURL, "clientId": c.ID, "application": c.Name,
		"applicationOrigin": c.Origin, "nonce": req.Nonce, "codeChallenge": req.Challenge,
		"codeChallengeMethod": "S256", "expiresAt": req.Expires.UTC().Format(time.RFC3339)}
}

func (s *Server) createNativeAppLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	if !s.hasAdminConsole() {
		reject(w, 503, "admin_not_configured")
		return
	}
	if !s.allow("native-create:"+c.ID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	var body struct{ CodeChallenge, CodeChallengeMethod, UserAgent, ClientIP string }
	if !decode(w, r, &body) {
		return
	}
	if !validLoginID(body.CodeChallenge) || body.CodeChallengeMethod != "S256" || len(body.UserAgent) > 512 || (body.ClientIP != "" && net.ParseIP(body.ClientIP) == nil) {
		reject(w, 400, "invalid_native_request")
		return
	}
	id, redeem := randomToken(), randomToken()
	now := time.Now()
	req := &nativeApplicationRequest{ClientID: c.ID, ClientKeyHash: c.SecretHash, Challenge: body.CodeChallenge,
		RedeemHash: digest(redeem), Nonce: randomToken(), Browser: "Hako iOS", Created: now, Expires: now.Add(90 * time.Second)}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	current, enabled := s.authClient(c.ID)
	if !enabled || current.SecretHash != c.SecretHash {
		reject(w, 401, "invalid_application")
		return
	}
	s.cleanupNativeAppLogins(now)
	if len(s.nativeApps.requests) >= 256 {
		reject(w, 429, "too_many_login_requests")
		return
	}
	s.nativeApps.requests[digest(id)] = req
	response := s.nativeRequestInfo(id, req, c)
	response["redeemToken"] = redeem
	respond(w, 201, response)
}

func (s *Server) inspectNativeAppLogin(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req, c := s.nativeRequest(w, r.PathValue("id"))
	if req == nil {
		return
	}
	respond(w, 200, s.nativeRequestInfo(r.PathValue("id"), req, c))
}

func (s *Server) authorizeNativeAppLogin(w http.ResponseWriter, r *http.Request) {
	sessionID, ok := s.authorized(w, r)
	if !ok {
		return
	}
	if r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
		reject(w, 403, "native_client_required")
		return
	}
	if !s.allow("native-authorize:"+sessionID, 30, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	var body struct {
		Nonce   string
		Consent bool
	}
	if !decode(w, r, &body) {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req, c := s.nativeRequest(w, r.PathValue("id"))
	if req == nil {
		return
	}
	if !validLoginID(body.Nonce) || !equal(body.Nonce, req.Nonce) {
		reject(w, 400, "invalid_native_nonce")
		return
	}
	if req.CodeHash != "" {
		reject(w, 409, "native_request_finished")
		return
	}
	thumb := ""
	s.store.inspect(func(st state) {
		if ss := st.Sessions[sessionID]; ss != nil {
			thumb = ss.Thumb
		}
	})
	if thumb == "" || !s.validAdminApprover(sessionID, thumb) {
		reject(w, 401, "approver_revoked")
		return
	}
	consent := nativeApplicationConsent{}
	for _, candidate := range s.nativeApps.consents {
		if candidate.SessionID == sessionID && candidate.ClientID == c.ID && candidate.ClientKeyHash == c.SecretHash && s.validNativeConsent(candidate) {
			consent = candidate
			break
		}
	}
	if consent.ID == "" {
		if !body.Consent {
			reject(w, 409, "native_consent_required")
			return
		}
		s.cleanupNativeAppLogins(time.Now())
		if len(s.nativeApps.consents) >= 256 {
			reject(w, 429, "too_many_native_authorizations")
			return
		}
		consent = nativeApplicationConsent{ID: randomToken(), ClientID: c.ID, ClientKeyHash: c.SecretHash, SessionID: sessionID, Thumb: thumb, Created: time.Now()}
	}
	consent.LastUsed = time.Now()
	s.nativeApps.consents[consent.ID] = consent
	code := randomToken()
	req.CodeHash, req.ConsentID = digest(code), consent.ID
	req.CodeExpires = time.Now().Add(time.Minute)
	if req.Expires.Before(req.CodeExpires) {
		req.CodeExpires = req.Expires
	}
	respond(w, 200, map[string]string{"code": code, "expiresAt": req.CodeExpires.UTC().Format(time.RFC3339)})
}

func (s *Server) completeNativeAppLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	var body struct{ Code, CodeVerifier string }
	if !decode(w, r, &body) {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req, _ := s.nativeRequest(w, r.PathValue("id"))
	if req == nil {
		return
	}
	if req.ClientID != c.ID || req.ClientKeyHash != c.SecretHash || !validLoginID(r.Header.Get("X-Hako-Request")) || !equal(req.RedeemHash, digest(r.Header.Get("X-Hako-Request"))) {
		reject(w, 404, "native_request_not_found")
		return
	}
	consent, allowed := s.nativeApps.consents[req.ConsentID]
	if !allowed || !s.validNativeConsent(consent) || req.CodeHash == "" || !time.Now().Before(req.CodeExpires) || !validLoginID(body.Code) || !equal(req.CodeHash, digest(body.Code)) || !validNativeVerifier(body.CodeVerifier) || !equal(req.Challenge, nativeChallenge(body.CodeVerifier)) {
		reject(w, 400, "invalid_native_grant")
		return
	}
	s.cleanupAdminLogins(time.Now())
	if len(s.adminSessions) >= 128 {
		reject(w, 429, "too_many_admin_sessions")
		return
	}
	token := randomToken()
	now := time.Now()
	s.adminSessions[digest(token)] = adminSession{ID: randomToken(), Browser: req.Browser, Created: now, LastUsed: now,
		ApproverSessionID: consent.SessionID, ApproverThumb: consent.Thumb, ClientID: c.ID, ClientName: c.Name,
		ClientOrigin: c.Origin, ClientKeyHash: c.SecretHash, NativeConsentID: consent.ID}
	delete(s.nativeApps.requests, digest(r.PathValue("id")))
	subject := ""
	s.store.inspect(func(st state) { subject = st.Subject })
	respond(w, 200, map[string]string{"issuer": s.config.PublicURL, "subject": subject, "username": s.config.Username,
		"clientId": c.ID, "purpose": "login", "sessionToken": token, "expiresAt": now.Add(12 * time.Hour).UTC().Format(time.RFC3339)})
}

// Revocation removes the silent authorization too. A retry cannot silently
// recreate this device's application session; a new explicit consent is needed.
func (s *Server) revokeNativeConsent(id string) {
	if id == "" || s.nativeApps == nil {
		return
	}
	delete(s.nativeApps.consents, id)
	for key, req := range s.nativeApps.requests {
		if req.ConsentID == id {
			delete(s.nativeApps.requests, key)
		}
	}
	for key, session := range s.adminSessions {
		if session.NativeConsentID == id {
			delete(s.adminSessions, key)
		}
	}
}
