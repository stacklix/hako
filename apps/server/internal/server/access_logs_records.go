package server

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"hako/server/internal/accesslog"
)

func (s *Server) adminAccessLogRecords(w http.ResponseWriter, r *http.Request) {
	a := s.accessLogs
	if a == nil {
		reject(w, 409, "access_logs_disabled")
		return
	}
	q := r.URL.Query()
	window, err := parseAccessLogWindow(r, time.Now())
	if err != nil {
		reject(w, 400, "invalid_log_filter")
		return
	}
	filters := accesslog.RecordFilters{From: window.from, To: window.to}
	for _, filter := range []struct {
		key    string
		target *string
		max    int
	}{{"domain", &filters.Domain, 512}, {"ip", &filters.IP, 64}, {"path", &filters.Path, 1048576}} {
		value := q.Get(filter.key)
		if len(value) > filter.max || (filter.key == "path" && value != "" && (!strings.HasPrefix(value, "/") || strings.ContainsAny(value, "?#"))) {
			reject(w, 400, "invalid_log_filter")
			return
		}
		if filter.key == "ip" && value != "" && value != "(unknown)" {
			ip := net.ParseIP(value)
			if ip == nil {
				reject(w, 400, "invalid_log_filter")
				return
			}
			value = ip.String()
		}
		*filter.target = value
	}
	if text := q.Get("status"); text != "" {
		status, err := strconv.Atoi(text)
		if err != nil || status < 100 || status > 599 {
			reject(w, 400, "invalid_log_filter")
			return
		}
		filters.Status = status
	}
	filters.Limit = 200
	for key, target := range map[string]*int{"limit": &filters.Limit, "offset": &filters.Offset} {
		if text := q.Get(key); text != "" {
			value, err := strconv.Atoi(text)
			if err != nil || value < 0 || (key == "limit" && (value < 1 || value > 500)) {
				reject(w, 400, "invalid_log_filter")
				return
			}
			*target = value
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	value, err := a.Records(ctx, filters)
	writeAccessLogQuery(w, value, err)
}
