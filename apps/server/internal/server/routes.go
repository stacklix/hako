package server

import "net/http"

func (s *Server) systemRoutes() {
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { respond(w, 200, map[string]bool{"ok": true}) })
	s.mux.HandleFunc("GET /api/v1/version", serverVersion)
}

func (s *Server) consoleRoutes() {
	s.mux.HandleFunc("POST /api/v1/auth/challenge", s.challenge)
	s.mux.HandleFunc("POST /api/v1/auth/login", s.login)
	s.mux.HandleFunc("POST /api/v1/auth/refresh", s.refresh)
	s.mux.HandleFunc("POST /api/v1/auth/logout", s.logout)
	s.mux.HandleFunc("GET /api/v1/auth/session", s.currentSession)
	s.mux.HandleFunc("GET /api/v1/sessions", s.sessions)
	s.mux.HandleFunc("DELETE /api/v1/web-sessions/{id}", s.revokeWebSession)
}

func (s *Server) accessLogRoutes() {
	s.mux.HandleFunc("GET /api/v1/access-logs", s.consoleAccessLogs(s.adminAccessLogs))
	s.mux.HandleFunc("GET /api/v1/access-logs/rankings", s.consoleAccessLogs(s.adminAccessLogRankings))
	s.mux.HandleFunc("GET /api/v1/access-logs/records", s.consoleAccessLogs(s.adminAccessLogRecords))
	s.mux.HandleFunc("GET /api/v1/access-logs/hour", s.consoleAccessLogs(s.adminAccessLogHour))
}

func (s *Server) agentRoutes() {
	s.mux.HandleFunc("GET /api/v1/agents", s.agents)
	s.mux.HandleFunc("POST /api/v1/agents", s.addAgent)
	s.mux.HandleFunc("POST /api/v1/agents/{id}/requests", s.requestAgent)
	s.mux.HandleFunc("GET /ws/agent", s.agentSocket)
	s.mux.HandleFunc("GET /ws/console/agents", s.consoleAgentSocket)
	s.mux.HandleFunc("GET /ws/console/agents/live/{id}", s.consoleAgentSocket)
	s.mux.HandleFunc("GET /ws/console/agents/terminal/{terminalID}", s.consoleAgentSocket)
}
