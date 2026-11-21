package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"hako/server/internal/workshop"
)

func (s *Server) workshopAdminRoutes() {
	s.mux.HandleFunc("GET /consilium/api/workshop/computers", s.admin(func(w http.ResponseWriter, r *http.Request) {
		respond(w, http.StatusOK, s.workshopComputers())
	}))
	s.mux.HandleFunc("POST /consilium/api/workshop/calls", s.admin(func(w http.ResponseWriter, r *http.Request) {
		var frame workshop.Frame
		if !decode(w, r, &frame) {
			return
		}
		respond(w, http.StatusOK, s.workshopCall(r.Context(), frame))
	}))
	s.mux.HandleFunc("GET /consilium/api/workshop/events/{computerID}/{operationID}/{cursor}", s.admin(s.adminWorkshopEvents))
}

// Streams share the existing workshop subscription pool and cursor semantics.
// Recheck the browser and its approving Console while the response is open.
func (s *Server) adminWorkshopEvents(w http.ResponseWriter, r *http.Request) {
	cookie, _ := r.Cookie(s.adminCookieName())
	id := digest(cookie.Value)
	valid := func() bool {
		s.adminMu.Lock()
		defer s.adminMu.Unlock()
		ss, ok := s.adminSessions[id]
		return ok && ss.ClientID == "" && !adminExpired(ss, time.Now()) && s.validAdminApprover(ss.ApproverSessionID, ss.ApproverThumb)
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Accel-Buffering", "no")
	controller := http.NewResponseController(w)
	send := func(data string) bool {
		_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if _, err := fmt.Fprint(w, data); err != nil {
			return false
		}
		return controller.Flush() == nil
	}
	if !send(": connected\n\n") {
		return
	}
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	s.workshopEvents(r.Context(), r, heartbeat.C, func() bool {
		return valid() && send(": heartbeat\n\n")
	}, valid, func(value any) bool {
		data, err := json.Marshal(value)
		return err == nil && send("data: "+string(data)+"\n\n")
	})
}
