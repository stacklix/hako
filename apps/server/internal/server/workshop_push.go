package server

import (
	"net/http"
	"strings"
	"time"

	"hako/server/internal/notify"
	"hako/server/internal/workshop"
)

func (s *Server) workshopPushSettings(w http.ResponseWriter, r *http.Request) {
	sessionID, ok := s.authorized(w, r)
	if !ok {
		return
	}
	if s.notifications == nil {
		reject(w, 503, "notifications_unavailable")
		return
	}
	var console string
	s.store.inspect(func(st state) {
		if ss := st.Sessions[sessionID]; ss != nil {
			console = ss.Thumb
		}
	})
	if console == "" {
		reject(w, 401, "invalid_session")
		return
	}
	s.workshopPushMu.Lock()
	defer s.workshopPushMu.Unlock()
	if r.Method == http.MethodPut {
		var input struct {
			Enabled *bool `json:"enabled"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		if !decodeJSON(r.Body, &input) || input.Enabled == nil {
			reject(w, 400, "invalid_request")
			return
		}
		if err := s.store.update(func(st *state) error {
			if st.WorkshopPush == nil {
				st.WorkshopPush = map[string]int64{}
			}
			if *input.Enabled {
				// An idempotent enable preserves the original subscription boundary.
				if st.WorkshopPush[console] == 0 {
					st.WorkshopPush[console] = time.Now().UnixMilli()
				}
			} else {
				delete(st.WorkshopPush, console)
			}
			return nil
		}); err != nil {
			reject(w, 500, "notification_settings_failed")
			return
		}
		if !*input.Enabled {
			if err := s.notifications.SuppressWorkshop(console); err != nil {
				reject(w, 500, "notification_settings_failed")
				return
			}
		}
	}
	var since int64
	s.store.inspect(func(st state) { since = st.WorkshopPush[console] })
	configured, registered := s.notifications.WorkshopReadiness(console)
	respond(w, 200, map[string]any{"enabled": since > 0, "configured": configured, "registered": registered})
}

func (s *Server) receiveWorkshopTerminal(computer AgentConfig, frame workshop.Frame) bool {
	if !workshopOperationID.MatchString(frame.OperationID) || len(frame.Result) > 8192 || !s.allow("workshop-terminal:"+computer.ID, 120, time.Minute) {
		return false
	}
	var event notify.WorkshopTerminal
	if !decodeJSONBytes(frame.Result, &event) {
		return false
	}
	event.ComputerID, event.OperationID = computer.ID, frame.OperationID
	if !event.Valid() || event.QuestionID != frame.QuestionID {
		return false
	}
	s.workshopPushMu.Lock()
	defer s.workshopPushMu.Unlock()
	// The module is optional and cannot be enabled while absent. A receipt here
	// means intentionally skipped, so terminal reports cannot break normal queries.
	if s.notifications == nil {
		return true
	}
	console := s.notifications.WorkshopConsole()
	var since int64
	s.store.inspect(func(st state) {
		for _, entry := range s.registry.Load().Consoles {
			if entry.thumb == console {
				since = st.WorkshopPush[console]
				break
			}
		}
	})
	return s.notifications.EnqueueWorkshop(event, console, since) == nil
}

func decodeJSONBytes(data []byte, target any) bool {
	// Use the same strict decoder as other native API requests.
	return decodeJSON(strings.NewReader(string(data)), target)
}
