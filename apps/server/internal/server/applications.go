package server

import (
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

type applicationView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Origin    string `json:"origin"`
	Enabled   bool   `json:"enabled"`
	CreatedAt string `json:"createdAt"`
}

func publicApplication(c AuthClientConfig) applicationView {
	return applicationView{ID: c.ID, Name: c.Name, Origin: c.Origin, Enabled: c.Enabled, CreatedAt: time.Unix(c.CreatedAt, 0).UTC().Format(time.RFC3339)}
}

func (s *Server) applicationManagementRoutes() {
	s.mux.HandleFunc("GET /admin/api/applications", s.admin(s.listApplications))
	s.mux.HandleFunc("POST /admin/api/applications", s.admin(s.createApplication))
	s.mux.HandleFunc("PATCH /admin/api/applications/{id}", s.admin(s.updateApplication))
	s.mux.HandleFunc("POST /admin/api/applications/{id}/rotate", s.admin(s.rotateApplication))
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
	respond(w, 200, map[string]any{"applications": items})
}

func (s *Server) applicationSecret(w http.ResponseWriter, c AuthClientConfig, secret string, status int) {
	respond(w, status, map[string]any{"application": publicApplication(c), "clientSecret": secret, "configuration": "HAKO_URL=" + s.config.PublicURL + "\nHAKO_CLIENT_ID=" + c.ID + "\nHAKO_CLIENT_SECRET=" + secret})
}

func (s *Server) createApplication(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name   string `json:"name"`
		Origin string `json:"origin"`
	}
	if !decode(w, r, &body) {
		return
	}
	secret := randomToken()
	c := AuthClientConfig{ID: "app_" + randomToken()[:20], Name: strings.TrimSpace(body.Name), Origin: strings.TrimRight(strings.TrimSpace(body.Origin), "/"), SecretHash: digest(secret), Enabled: true, CreatedAt: time.Now().Unix()}
	if validateAuthClients([]AuthClientConfig{c}) != nil {
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
		Enabled *bool `json:"enabled"`
	}
	if !decode(w, r, &body) {
		return
	}
	if body.Enabled == nil {
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
		result.Enabled = *body.Enabled
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
