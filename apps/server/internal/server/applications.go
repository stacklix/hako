package server

import (
	"errors"
	"mime"
	"net/http"
	"sort"
	"strings"
	"time"
)

type applicationView struct {
	OIDC      *OIDCClient `json:"oidc,omitempty"`
	ID        string      `json:"id"`
	Name      string      `json:"name"`
	Origin    string      `json:"origin"`
	Enabled   bool        `json:"enabled"`
	CreatedAt string      `json:"createdAt"`
}

func publicApplication(c AuthClientConfig) applicationView {
	return applicationView{OIDC: c.OIDC, ID: c.ID, Name: c.Name, Origin: c.Origin, Enabled: c.Enabled, CreatedAt: time.Unix(c.CreatedAt, 0).UTC().Format(time.RFC3339)}
}

func (s *Server) applicationManagementRoutes() {
	s.mux.HandleFunc("GET /admin/api/applications", s.admin(s.listApplications))
	s.mux.HandleFunc("POST /admin/api/applications", s.admin(s.createApplication))
	s.mux.HandleFunc("PATCH /admin/api/applications/{id}", s.admin(s.updateApplication))
	s.mux.HandleFunc("POST /admin/api/applications/{id}/rotate", s.admin(s.rotateApplication))
	s.mux.HandleFunc("GET /api/v1/applications", s.consoleApplications(s.listApplications))
	s.mux.HandleFunc("POST /api/v1/applications", s.consoleApplications(s.createApplication))
	s.mux.HandleFunc("PATCH /api/v1/applications/{id}", s.consoleApplications(s.updateApplication))
	s.mux.HandleFunc("POST /api/v1/applications/{id}/rotate", s.consoleApplications(s.rotateApplication))
}

// Native administration uses the existing trusted Console session and DPoP.
// Application secrets and browser cookies never authenticate these routes.
func (s *Server) consoleApplications(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.authorized(w, r)
		if !ok {
			return
		}
		if r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
			reject(w, http.StatusForbidden, "native_console_required")
			return
		}
		if r.Method != http.MethodGet {
			media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil || media != "application/json" {
				reject(w, 415, "json_required")
				return
			}
			if !s.allow("console-app-write:"+id, 30, time.Minute) {
				reject(w, 429, "rate_limited")
				return
			}
		}
		next(w, r)
	}
}

func (s *Server) listApplications(w http.ResponseWriter, r *http.Request) {
	items := []applicationView{}
	s.store.inspect(func(st state) {
		for _, c := range st.AuthClients {
			items = append(items, publicApplication(c))
		}
	})
	sort.Slice(items, func(i, j int) bool {
		if items[i].CreatedAt == items[j].CreatedAt {
			return items[i].ID < items[j].ID
		}
		return items[i].CreatedAt > items[j].CreatedAt
	})
	respond(w, 200, map[string]any{"applications": items, "issuer": s.config.PublicURL})
}

func (s *Server) applicationSecret(w http.ResponseWriter, c AuthClientConfig, secret string, status int) {
	respond(w, status, map[string]any{"application": publicApplication(c), "clientSecret": secret, "configuration": "OIDC_ISSUER=" + s.config.PublicURL + "\n" + oidcConfiguration(c) + "HAKO_URL=" + s.config.PublicURL + "\nHAKO_CLIENT_ID=" + c.ID + "\nHAKO_CLIENT_SECRET=" + secret})
}

func (s *Server) createApplication(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name   string      `json:"name"`
		Origin string      `json:"origin"`
		OIDC   *OIDCClient `json:"oidc"`
	}
	if !decode(w, r, &body) {
		return
	}
	secret := randomToken()
	c := AuthClientConfig{OIDC: body.OIDC, Revision: randomToken(), ID: "app_" + randomToken()[:20], Name: strings.TrimSpace(body.Name), Origin: strings.TrimRight(strings.TrimSpace(body.Origin), "/"), SecretHash: digest(secret), Enabled: true, CreatedAt: time.Now().Unix()}
	if validateAuthClients([]AuthClientConfig{c}) != nil || s.validateOIDCRegistration(c.OIDC) != nil {
		reject(w, 400, "invalid_application_details")
		return
	}
	tooMany := errors.New("too_many_applications")
	if err := s.store.update(func(st *state) error {
		if len(st.AuthClients) >= 64 {
			return tooMany
		}
		st.AuthClients[c.ID] = c
		return nil
	}); err != nil {
		if errors.Is(err, tooMany) {
			reject(w, 409, "too_many_applications")
		} else {
			reject(w, 503, "storage_unavailable")
		}
		return
	}
	s.applicationSecret(w, c, secret, 201)
}

// Invalidate both pending and completed grants; re-enabling never restores old grants.
func (s *Server) invalidateApplication(id string) {
	s.adminMu.Lock()
	defer s.adminMu.Unlock()
	if s.oidc != nil {
		s.invalidateOIDCLocked(id)
	}
	for key, req := range s.adminLogins {
		if req.ClientID == id {
			delete(s.adminLogins, key)
		}
	}
	for key, ss := range s.adminSessions {
		if ss.ClientID == id {
			delete(s.adminSessions, key)
		}
	}
}

func (s *Server) updateApplication(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled *bool       `json:"enabled"`
		OIDC    *OIDCClient `json:"oidc"`
	}
	if !decode(w, r, &body) {
		return
	}
	if (body.Enabled == nil && body.OIDC == nil) || s.validateOIDCRegistration(body.OIDC) != nil {
		reject(w, 400, "invalid_application_details")
		return
	}
	var result AuthClientConfig
	missing := errors.New("application_not_found")
	if err := s.store.update(func(st *state) error {
		var ok bool
		result, ok = st.AuthClients[r.PathValue("id")]
		if !ok {
			return missing
		}
		if body.Enabled != nil {
			result.Enabled = *body.Enabled
		}
		if body.OIDC != nil {
			result.OIDC = body.OIDC
		}
		if err := validateOIDCClient(result.OIDC); err != nil {
			return err
		}
		result.Revision = randomToken()
		st.AuthClients[result.ID] = result
		return nil
	}); err != nil {
		if errors.Is(err, missing) {
			reject(w, 404, "application_not_found")
		} else {
			reject(w, 503, "storage_unavailable")
		}
		return
	}
	s.invalidateApplication(result.ID)
	respond(w, 200, map[string]any{"application": publicApplication(result)})
}

func (s *Server) rotateApplication(w http.ResponseWriter, r *http.Request) {
	var body struct{}
	if !decode(w, r, &body) {
		return
	}
	secret := randomToken()
	var result AuthClientConfig
	missing := errors.New("application_not_found")
	if err := s.store.update(func(st *state) error {
		var ok bool
		result, ok = st.AuthClients[r.PathValue("id")]
		if !ok {
			return missing
		}
		result.SecretHash = digest(secret)
		result.Revision = randomToken()
		st.AuthClients[result.ID] = result
		return nil
	}); err != nil {
		if errors.Is(err, missing) {
			reject(w, 404, "application_not_found")
		} else {
			reject(w, 503, "storage_unavailable")
		}
		return
	}
	s.invalidateApplication(result.ID)
	s.applicationSecret(w, result, secret, 200)
}
