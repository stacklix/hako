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

	qrcode "github.com/skip2/go-qrcode"
)

const adminLoginLifetime = 90 * time.Second

type adminLoginRequest struct {
	BrowserHash, Code, Nonce, Browser, Status, ClientIP string
	Created, Expires                                    time.Time
	ApproverSessionID, ApproverThumb                    string
	QR                                                  []byte
}

func (s *Server) qrLoginRoutes() {
	s.mux.HandleFunc("POST /admin/api/login/requests", s.createAdminLogin)
	s.mux.HandleFunc("GET /admin/api/login/requests/{id}", s.pollAdminLogin)
	s.mux.HandleFunc("GET /admin/api/login/requests/{id}/qr", s.adminLoginQR)
	s.mux.HandleFunc("POST /admin/api/login/requests/{id}/complete", s.completeAdminLogin)
	s.mux.HandleFunc("GET /api/v1/admin-login/requests/{id}", s.inspectAdminLogin)
	s.mux.HandleFunc("POST /api/v1/admin-login/requests/{id}/approve", s.approveAdminLogin)
	s.mux.HandleFunc("POST /api/v1/admin-login/requests/{id}/deny", s.approveAdminLogin)
}

func (s *Server) hasAdminConsole() bool {
	return len(s.registry.Load().Consoles) > 0
}

func (s *Server) validAdminApprover(sessionID, thumb string) bool {
	valid := false
	s.store.inspect(func(st state) {
		ss := st.Sessions[sessionID]
		valid = ss != nil && equal(ss.Thumb, thumb) && trustedConsoleState(&st, thumb)
	})
	return valid
}

func (s *Server) pendingCookieName() string {
	if strings.HasPrefix(s.config.PublicURL, "https://") {
		return "__Host-hako_pending"
	}
	return "hako_pending"
}

func (s *Server) pendingCookie(w http.ResponseWriter, value string, maxAge int) {
	http.SetCookie(w, &http.Cookie{Name: s.pendingCookieName(), Value: value, Path: "/", Secure: strings.HasPrefix(s.config.PublicURL, "https://"), HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: maxAge})
}

func browserLabel(ua string) string {
	for _, item := range []struct{ match, name string }{{"Edg/", "Edge"}, {"EdgiOS/", "Edge"}, {"EdgA/", "Edge"}, {"Firefox/", "Firefox"}, {"FxiOS/", "Firefox"}, {"Chrome/", "Chrome"}, {"CriOS/", "Chrome"}, {"Safari/", "Safari"}} {
		if strings.Contains(ua, item.match) {
			return item.name
		}
	}
	return "网页浏览器"
}

func validLoginID(id string) bool {
	b, err := raw64.DecodeString(id)
	return err == nil && len(b) == 32 && len(id) == 43
}

// adminMu must be held. Expired and superseded browser requests cannot be redeemed.
func (s *Server) cleanupAdminLogins(now time.Time) {
	for id, req := range s.adminLogins {
		if !now.Before(req.Expires) {
			delete(s.adminLogins, id)
		}
	}
	for id, ss := range s.adminSessions {
		if adminExpired(ss, now) {
			delete(s.adminSessions, id)
		}
	}
}

func (s *Server) createAdminLogin(w http.ResponseWriter, r *http.Request) {
	if !s.adminOrigin(w, r, true) {
		return
	}
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !s.allow("admin-qr-create:"+ip, 8, time.Minute) || !s.allow("admin-qr-create:global", 60, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	var body struct{}
	if !decode(w, r, &body) {
		return
	}
	browser := randomToken()
	if c, err := r.Cookie(s.pendingCookieName()); err == nil && validLoginID(c.Value) {
		browser = c.Value
	}
	id, nonce := randomToken(), randomToken()
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		reject(w, 503, "login_unavailable")
		return
	}
	code := fmt.Sprintf("%06d", number.Int64())
	payload := "hako://admin-login?" + url.Values{"v": {"1"}, "server": {s.config.PublicURL}, "request": {id}}.Encode()
	png, err := qrcode.Encode(payload, qrcode.Medium, -5)
	if err != nil {
		reject(w, 503, "login_unavailable")
		return
	}
	now := time.Now()
	expires := now.Add(adminLoginLifetime)
	s.adminMu.Lock()
	s.cleanupAdminLogins(now)
	for key, req := range s.adminLogins {
		if equal(req.BrowserHash, digest(browser)) {
			delete(s.adminLogins, key)
		}
	}
	if len(s.adminLogins) >= 256 {
		s.adminMu.Unlock()
		reject(w, 429, "too_many_login_requests")
		return
	}
	s.adminLogins[digest(id)] = &adminLoginRequest{BrowserHash: digest(browser), Code: code, Nonce: nonce, Browser: browserLabel(r.UserAgent()), ClientIP: s.loginClientIP(r), Status: "pending", Created: now, Expires: expires, QR: png}
	s.adminMu.Unlock()
	s.pendingCookie(w, browser, int(adminLoginLifetime.Seconds()))
	respond(w, 201, map[string]any{"id": id, "confirmationCode": code, "qrPayload": payload, "expiresAt": expires.UTC().Format(time.RFC3339), "pollIntervalMs": 2000})
}

// adminMu must be held. A QR request ID never substitutes for the private browser cookie.
func (s *Server) browserLogin(w http.ResponseWriter, r *http.Request) *adminLoginRequest {
	id := r.PathValue("id")
	cookie, err := r.Cookie(s.pendingCookieName())
	if err != nil || !validLoginID(id) {
		reject(w, 404, "login_request_not_found")
		return nil
	}
	req := s.adminLogins[digest(id)]
	if req == nil || !equal(req.BrowserHash, digest(cookie.Value)) {
		reject(w, 404, "login_request_not_found")
		return nil
	}
	if !time.Now().Before(req.Expires) {
		delete(s.adminLogins, digest(id))
		reject(w, 410, "login_request_expired")
		return nil
	}
	return req
}

func (s *Server) pollAdminLogin(w http.ResponseWriter, r *http.Request) {
	if !s.adminOrigin(w, r, false) {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.browserLogin(w, r)
	if req == nil {
		return
	}
	// Unknown IDs must not allocate limiter buckets in the shared, bounded map.
	if !s.allow("admin-qr-poll:"+digest(r.PathValue("id")), 60, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	if req.Status == "approved" && !s.validAdminApprover(req.ApproverSessionID, req.ApproverThumb) {
		req.Status = "denied"
	}
	respond(w, 200, map[string]string{"status": req.Status, "expiresAt": req.Expires.UTC().Format(time.RFC3339)})
}

func (s *Server) adminLoginQR(w http.ResponseWriter, r *http.Request) {
	if !s.adminOrigin(w, r, false) {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.browserLogin(w, r)
	if req == nil {
		return
	}
	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(req.QR)
}

func (s *Server) completeAdminLogin(w http.ResponseWriter, r *http.Request) {
	if !s.adminOrigin(w, r, true) {
		return
	}
	var body struct{}
	if !decode(w, r, &body) {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.browserLogin(w, r)
	if req == nil {
		return
	}
	if req.Status != "approved" {
		reject(w, 409, "login_not_approved")
		return
	}
	if !s.validAdminApprover(req.ApproverSessionID, req.ApproverThumb) {
		req.Status = "denied"
		reject(w, 403, "approver_revoked")
		return
	}
	if !time.Now().Before(req.Expires) {
		reject(w, 410, "login_request_expired")
		return
	}
	s.cleanupAdminLogins(time.Now())
	if len(s.adminSessions) >= 32 {
		reject(w, 429, "too_many_admin_sessions")
		return
	}
	token, csrf := randomToken(), randomToken()
	now := time.Now()
	if c, err := r.Cookie(s.adminCookieName()); err == nil {
		delete(s.adminSessions, digest(c.Value))
	}
	s.adminSessions[digest(token)] = adminSession{ID: randomToken(), Browser: req.Browser, CSRF: csrf, Created: now, LastUsed: now, ApproverSessionID: req.ApproverSessionID, ApproverThumb: req.ApproverThumb}
	delete(s.adminLogins, digest(r.PathValue("id")))
	s.pendingCookie(w, "", -1)
	s.adminCookie(w, token, 12*60*60)
	respond(w, 200, map[string]string{"csrfToken": csrf, "username": s.config.Username})
}

func (s *Server) consoleAdminApprover(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	sessionID, ok := s.authorized(w, r)
	if !ok {
		return "", "", false
	}
	thumb := ""
	s.store.inspect(func(st state) {
		if ss := st.Sessions[sessionID]; ss != nil && trustedConsoleState(&st, ss.Thumb) {
			thumb = ss.Thumb
		}
	})
	if thumb == "" {
		reject(w, 403, "admin_approval_not_allowed")
		return "", "", false
	}
	if !s.allow("admin-approval:"+sessionID, 60, time.Minute) {
		reject(w, 429, "rate_limited")
		return "", "", false
	}
	return sessionID, thumb, true
}

func (s *Server) inspectAdminLogin(w http.ResponseWriter, r *http.Request) {
	_, _, ok := s.consoleAdminApprover(w, r)
	if !ok {
		return
	}
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.adminLogins[digest(r.PathValue("id"))]
	if req == nil || !validLoginID(r.PathValue("id")) {
		reject(w, 404, "login_request_not_found")
		return
	}
	if !time.Now().Before(req.Expires) {
		reject(w, 410, "login_request_expired")
		return
	}
	if req.Status != "pending" && req.Status != "scanned" {
		reject(w, 409, "login_request_finished")
		return
	}
	req.Status = "scanned"
	respond(w, 200, map[string]string{"id": r.PathValue("id"), "origin": s.config.PublicURL, "confirmationCode": req.Code, "browser": req.Browser, "clientIP": req.ClientIP, "requestedAt": req.Created.UTC().Format(time.RFC3339), "expiresAt": req.Expires.UTC().Format(time.RFC3339), "nonce": req.Nonce})
}

func (s *Server) approveAdminLogin(w http.ResponseWriter, r *http.Request) {
	sessionID, thumb, ok := s.consoleAdminApprover(w, r)
	if !ok {
		return
	}
	var body struct {
		ConfirmationCode string `json:"confirmationCode"`
	}
	if !decode(w, r, &body) {
		return
	}
	p, err := verifyProof(r, s.config.PublicURL, strings.TrimPrefix(r.Header.Get("Authorization"), "DPoP "), time.Now())
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	req := s.adminLogins[digest(r.PathValue("id"))]
	if req == nil || !validLoginID(r.PathValue("id")) {
		reject(w, 404, "login_request_not_found")
		return
	}
	if !time.Now().Before(req.Expires) {
		reject(w, 410, "login_request_expired")
		return
	}
	if req.Status != "scanned" {
		reject(w, 409, "login_request_finished")
		return
	}
	if err != nil || !equal(p.Nonce, req.Nonce) || !equal(body.ConfirmationCode, req.Code) {
		reject(w, 400, "login_confirmation_mismatch")
		return
	}
	if !s.validAdminApprover(sessionID, thumb) {
		reject(w, 403, "approver_revoked")
		return
	}
	req.Status = "denied"
	if strings.HasSuffix(r.URL.Path, "/approve") {
		req.Status = "approved"
		req.ApproverSessionID = sessionID
		req.ApproverThumb = thumb
	}
	respond(w, 200, map[string]string{"status": req.Status})
}
