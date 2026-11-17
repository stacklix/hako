package server

import "net/http"

// Report the live database version, rather than assuming initialization succeeded.
// Native clients authenticate using their Console session; no admin cookie is needed.
func (s *Server) investmentVersion(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorized(w, r); !ok {
		return
	}
	var version int
	if err := s.investment.QueryRowContext(r.Context(), "PRAGMA user_version").Scan(&version); err != nil {
		reject(w, http.StatusInternalServerError, "storage_error")
		return
	}
	respond(w, http.StatusOK, map[string]int{
		"version": version, "expectedVersion": investmentSchemaVersion,
	})
}
