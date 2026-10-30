package server

import "net/http"

// Reuse the admin queries, but authenticate native clients with the existing
// registered Console identity and DPoP session. No cookie or new credential.
func (s *Server) consoleAccessLogs(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if _, ok := s.authorized(w, r); !ok {
			return
		}
		next(w, r)
	}
}
