package server

import (
	"context"
	"database/sql"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type accessRecord struct {
	Time      string `json:"time"`
	Domain    string `json:"domain"`
	Status    int    `json:"status"`
	IP        string `json:"ip"`
	Path      string `json:"path"`
	UserAgent string `json:"userAgent"`
	Count     int64  `json:"count"`
}

// Query every retained aggregate, rather than truncating the result to a ranking.
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
	where := "occurred_at>=? AND occurred_at<=?"
	args := []any{window.from.Unix(), window.to.Unix()}
	for _, filter := range []struct {
		key, column string
		max         int
	}{{"domain", "domain", 512}, {"ip", "ip", 64}, {"path", "url", 1048576}} {
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
		if value != "" {
			where += " AND " + filter.column + "=?"
			args = append(args, value)
		}
	}
	if text := q.Get("status"); text != "" {
		status, err := strconv.Atoi(text)
		if err != nil || status < 100 || status > 599 {
			reject(w, 400, "invalid_log_filter")
			return
		}
		where += " AND status=?"
		args = append(args, status)
	}
	limit, offset := 200, 0
	for key, target := range map[string]*int{"limit": &limit, "offset": &offset} {
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
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	var totalRows, requests int64
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*),COALESCE(SUM(count),0) FROM access_counts WHERE "+where, args...).Scan(&totalRows, &requests); err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	params := append(append([]any{}, args...), limit, offset)
	rows, err := tx.QueryContext(ctx, "SELECT occurred_at,domain,status,ip,url,ua,count FROM access_counts WHERE "+where+" ORDER BY occurred_at DESC,domain,status,ip,url,ua,hour LIMIT ? OFFSET ?", params...)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer rows.Close()
	values := []accessRecord{}
	for rows.Next() {
		var v accessRecord
		var stamp int64
		if err = rows.Scan(&stamp, &v.Domain, &v.Status, &v.IP, &v.Path, &v.UserAgent, &v.Count); err != nil {
			break
		}
		v.Time = time.Unix(stamp, 0).In(a.location).Format(time.RFC3339)
		values = append(values, v)
	}
	if err != nil || rows.Err() != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	respond(w, 200, map[string]any{"from": window.from.In(a.location).Format(time.RFC3339), "to": window.to.In(a.location).Format(time.RFC3339), "timezone": a.location.String(), "rows": values, "totalRows": totalRows, "requests": requests, "offset": offset, "limit": limit, "hasMore": int64(offset) < totalRows && int64(len(values)) < totalRows-int64(offset)})
}
