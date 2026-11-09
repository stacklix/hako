package server

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"hako/server/internal/accesslog"
)

type accessLogWindow struct {
	hours    int
	from, to time.Time
}

func parseAccessLogWindow(r *http.Request, now time.Time) (accessLogWindow, error) {
	w := accessLogWindow{hours: 24, to: time.Unix(now.Unix(), 0)}
	query := r.URL.Query()
	if query.Get("date") != "" {
		return w, fmt.Errorf("use rangeHours")
	}
	if value := query.Get("rangeHours"); value != "" {
		var err error
		w.hours, err = strconv.Atoi(value)
		if err != nil {
			return w, err
		}
	}
	switch w.hours {
	case 1, 3, 6, 12, 24, 72, 168:
	default:
		return w, fmt.Errorf("invalid range")
	}
	w.from = w.to.Add(-time.Duration(w.hours) * time.Hour)
	if query.Get("from") != "" || query.Get("to") != "" {
		var err error
		w.from, err = time.Parse(time.RFC3339, query.Get("from"))
		if err != nil {
			return w, err
		}
		w.to, err = time.Parse(time.RFC3339, query.Get("to"))
		if err != nil {
			return w, err
		}
		if w.to.Before(w.from) || w.to.Sub(w.from) > time.Duration(w.hours)*time.Hour || w.to.After(now.Add(5*time.Second)) || w.to.Before(now.Add(-accesslog.Retention)) {
			return w, fmt.Errorf("invalid window")
		}
	}
	if cutoff := time.Unix(now.Add(-accesslog.Retention).Unix(), 0); w.from.Before(cutoff) {
		w.from = cutoff
	}
	if w.to.After(now) {
		w.to = time.Unix(now.Unix(), 0)
	}
	return w, nil
}

func (s *Server) adminAccessLogs(w http.ResponseWriter, r *http.Request) {
	a := s.accessLogs
	if a == nil {
		respond(w, 200, accesslog.DisabledSummary())
		return
	}
	window, err := parseAccessLogWindow(r, time.Now())
	domain := r.URL.Query().Get("domain")
	if err != nil || len(domain) > 512 {
		reject(w, 400, "invalid_log_filter")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	value, err := a.Summary(ctx, window.from, window.to, window.hours, domain)
	writeAccessLogQuery(w, value, err)
}

func writeAccessLogQuery(w http.ResponseWriter, value map[string]any, err error) {
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	respond(w, 200, value)
}

func (s *Server) adminAccessLogHour(w http.ResponseWriter, r *http.Request) {
	s.adminAccessLogDetails(w, r, true)
}

func (s *Server) adminAccessLogRankings(w http.ResponseWriter, r *http.Request) {
	s.adminAccessLogDetails(w, r, false)
}

func (s *Server) adminAccessLogDetails(w http.ResponseWriter, r *http.Request, requireHour bool) {
	a := s.accessLogs
	if a == nil {
		reject(w, 409, "access_logs_disabled")
		return
	}
	domain := r.URL.Query().Get("domain")
	window, err := parseAccessLogWindow(r, time.Now())
	if err != nil || domain == "" || len(domain) > 512 {
		reject(w, 400, "invalid_log_filter")
		return
	}
	var hour *time.Time
	hourText := r.URL.Query().Get("hour")
	if requireHour || hourText != "" {
		parsed, err := time.Parse(time.RFC3339, hourText)
		if err != nil || parsed.In(a.Location()).Minute() != 0 || parsed.Second() != 0 || parsed.Nanosecond() != 0 {
			reject(w, 400, "invalid_log_filter")
			return
		}
		hour = &parsed
		if !parsed.IsZero() {
			hourText = parsed.In(a.Location()).Format(time.RFC3339)
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	value, err := a.Details(ctx, window.from, window.to, hour, domain)
	if err == nil {
		value["hour"] = hourText
	}
	writeAccessLogQuery(w, value, err)
}
