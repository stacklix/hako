package server

import (
	"crypto/rand"
	"embed"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"
)

//go:embed web/*
var adminFiles embed.FS

type adminSession struct {
	ID, Browser                      string
	CSRF                             string
	Created, LastUsed                time.Time
	ApproverSessionID, ApproverThumb string
}

func (s *Server) adminRoutes() {
	s.mux.HandleFunc("GET /admin", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/admin/", http.StatusSeeOther) })
	for path, file := range map[string]string{"/admin/": "index.html", "/admin/agents": "index.html", "/admin/access-logs": "index.html", "/admin/app.js": "app.js", "/admin/access-logs.js": "access-logs.js", "/admin/style.css": "style.css"} {
		s.mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != path {
				http.NotFound(w, r)
				return
			}
			adminHeaders(w)
			data, _ := adminFiles.ReadFile("web/" + file)
			w.Header().Set("Content-Type", map[string]string{"index.html": "text/html; charset=utf-8", "app.js": "text/javascript; charset=utf-8", "access-logs.js": "text/javascript; charset=utf-8", "style.css": "text/css; charset=utf-8"}[file])
			_, _ = w.Write(data)
		})
	}
	s.qrLoginRoutes()
	s.mux.HandleFunc("GET /admin/api/session", s.admin(s.adminCurrent))
	s.mux.HandleFunc("POST /admin/api/logout", s.admin(s.adminLogout))
	s.mux.HandleFunc("GET /admin/api/agents", s.admin(s.adminAgents))
	s.mux.HandleFunc("GET /admin/api/access-logs", s.admin(s.adminAccessLogs))
	s.mux.HandleFunc("GET /admin/api/access-logs/hour", s.admin(s.adminAccessLogHour))
	s.mux.HandleFunc("GET /admin/api/access-logs/rankings", s.admin(s.adminAccessLogRankings))
	s.mux.HandleFunc("POST /admin/api/agents", s.admin(s.registerAgent))
	s.mux.HandleFunc("DELETE /admin/api/agents/{id}", s.admin(s.adminDeleteAgent))
	s.mux.HandleFunc("POST /admin/api/agents/{id}/requests", s.admin(s.forwardAgentRequest))
}

func adminHeaders(w http.ResponseWriter) {
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
}
func (s *Server) adminCookieName() string {
	if strings.HasPrefix(s.config.PublicURL, "https://") {
		return "__Host-hako_admin"
	}
	return "hako_admin"
}
func (s *Server) adminCookie(w http.ResponseWriter, value string, maxAge int) {
	http.SetCookie(w, &http.Cookie{Name: s.adminCookieName(), Value: value, Path: "/", Secure: strings.HasPrefix(s.config.PublicURL, "https://"), HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: maxAge})
}
func (s *Server) adminOrigin(w http.ResponseWriter, r *http.Request, mutation bool) bool {
	adminHeaders(w)
	u, _ := url.Parse(s.config.PublicURL)
	if r.Host != u.Host || r.Header.Get("Sec-Fetch-Site") == "cross-site" || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != s.config.PublicURL) || (mutation && r.Header.Get("Origin") != s.config.PublicURL) {
		reject(w, 403, "invalid_origin")
		return false
	}
	if !s.hasAdminConsole() {
		reject(w, 503, "admin_not_configured")
		return false
	}
	if mutation && r.Method != "DELETE" {
		media, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if media != "application/json" {
			reject(w, 415, "json_required")
			return false
		}
	}
	return true
}
func adminExpired(ss adminSession, now time.Time) bool {
	return now.Sub(ss.Created) >= 12*time.Hour || now.Sub(ss.LastUsed) >= 30*time.Minute
}
func (s *Server) admin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		mutation := r.Method != "GET"
		if !s.adminOrigin(w, r, mutation) {
			return
		}
		if !s.allow("admin-api", 600, time.Minute) {
			reject(w, 429, "rate_limited")
			return
		}
		cookie, err := r.Cookie(s.adminCookieName())
		if err != nil {
			reject(w, 401, "admin_login_required")
			return
		}
		s.adminMu.Lock()
		id := digest(cookie.Value)
		ss, ok := s.adminSessions[id]
		if !ok || adminExpired(ss, time.Now()) || !s.validAdminApprover(ss.ApproverSessionID, ss.ApproverThumb) {
			delete(s.adminSessions, id)
			s.adminMu.Unlock()
			s.adminCookie(w, "", -1)
			reject(w, 401, "admin_login_required")
			return
		}
		if mutation && !equal(ss.CSRF, r.Header.Get("X-CSRF-Token")) {
			s.adminMu.Unlock()
			reject(w, 403, "invalid_csrf")
			return
		}
		// Passive polling does not extend an idle administrator's session.
		if r.Method != http.MethodGet || (r.URL.Path != "/admin/api/agents" && !strings.HasPrefix(r.URL.Path, "/admin/api/access-logs")) {
			ss.LastUsed = time.Now()
			s.adminSessions[id] = ss
		}
		s.adminMu.Unlock()
		next(w, r)
	}
}
func (s *Server) adminCurrent(w http.ResponseWriter, r *http.Request) {
	c, _ := r.Cookie(s.adminCookieName())
	s.adminMu.Lock()
	ss := s.adminSessions[digest(c.Value)]
	s.adminMu.Unlock()
	respond(w, 200, map[string]string{"csrfToken": ss.CSRF, "username": s.config.Username})
}
func (s *Server) adminLogout(w http.ResponseWriter, r *http.Request) {
	c, _ := r.Cookie(s.adminCookieName())
	s.adminMu.Lock()
	delete(s.adminSessions, digest(c.Value))
	s.adminMu.Unlock()
	s.adminCookie(w, "", -1)
	respond(w, 200, map[string]bool{"ok": true})
}
func (s *Server) adminAgents(w http.ResponseWriter, r *http.Request) {
	respond(w, 200, map[string]any{"agents": s.agentItems(true), "updatedAt": time.Now().UTC().Format(time.RFC3339)})
}
func registryError(w http.ResponseWriter, err error) {
	respond(w, 400, map[string]string{"error": "invalid_public_key_or_device", "message": err.Error()})
}

// Both entry points authenticate before sharing registry validation and persistence.
func (s *Server) registerAgent(w http.ResponseWriter, r *http.Request) {
	var request struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		PublicKeyPEM string `json:"publicKeyPem"`
	}
	if !decode(w, r, &request) {
		return
	}
	s.registryMu.Lock()
	defer s.registryMu.Unlock()
	old := s.registry.Load()
	if request.ID == "" {
		used := make(map[string]bool, len(old.Agents))
		for _, agent := range old.Agents {
			used[agent.ID] = true
		}
		var err error
		request.ID, err = allocateAgentID(used, rand.Reader)
		if err != nil {
			reject(w, 503, "device_id_unavailable")
			return
		}
	}
	a, err := parseAgent(AgentConfig{ID: request.ID, Name: request.Name, PublicKeyPEM: request.PublicKeyPEM}, false)
	if err != nil {
		registryError(w, err)
		return
	}
	for _, v := range old.Agents {
		if v.ID == a.ID || v.keyID == a.keyID {
			reject(w, 409, "duplicate_agent")
			return
		}
	}
	next, err := loadRegistry(append(append([]AgentConfig{}, old.Agents...), a), old.Consoles, false)
	if err != nil {
		registryError(w, err)
		return
	}
	if err = s.saveRegistry(next); err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	respond(w, 201, map[string]string{"id": a.ID, "keyId": a.keyID})
}
func (s *Server) adminDeleteAgent(w http.ResponseWriter, r *http.Request) {
	s.registryMu.Lock()
	defer s.registryMu.Unlock()
	old := s.registry.Load()
	agents := []AgentConfig{}
	for _, a := range old.Agents {
		if a.ID != r.PathValue("id") {
			agents = append(agents, a)
		}
	}
	if len(agents) == len(old.Agents) {
		reject(w, 404, "agent_not_found")
		return
	}
	next, err := loadRegistry(agents, old.Consoles, false)
	if err != nil {
		registryError(w, err)
		return
	}
	if err = s.saveRegistry(next); err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	s.mu.Lock()
	c := s.online[r.PathValue("id")]
	delete(s.online, r.PathValue("id"))
	delete(s.lastSeen, r.PathValue("id"))
	s.mu.Unlock()
	if c != nil {
		c.close()
	}
	respond(w, 200, map[string]bool{"ok": true})
}
