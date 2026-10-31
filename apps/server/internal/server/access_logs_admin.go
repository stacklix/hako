package server

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

type accessHour struct {
	Domain   string `json:"domain"`
	Hour     string `json:"hour"`
	Visits   int64  `json:"visits"`
	NotFound int64  `json:"notFound"`
}

type accessRank struct {
	Value string `json:"value"`
	Count int64  `json:"count"`
}

type accessClient struct {
	accessRank
	UserAgents []accessRank `json:"userAgents"`
	URLs       []accessRank `json:"urls"`
}

type accessPage struct {
	accessRank
	IPs        []accessRank `json:"ips"`
	UserAgents []accessRank `json:"userAgents"`
}

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
		if w.to.Before(w.from) || w.to.Sub(w.from) > time.Duration(w.hours)*time.Hour || w.to.After(now.Add(5*time.Second)) || w.to.Before(now.Add(-accessLogRetention)) {
			return w, fmt.Errorf("invalid window")
		}
	}
	if cutoff := time.Unix(now.Add(-accessLogRetention).Unix(), 0); w.from.Before(cutoff) {
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
		respond(w, 200, map[string]any{"status": accessLogStatus{Retention: 7}, "domains": []string{}, "hours": []accessHour{}, "totals": []accessHour{}})
		return
	}
	window, err := parseAccessLogWindow(r, time.Now())
	if err != nil || len(r.URL.Query().Get("domain")) > 512 {
		reject(w, 400, "invalid_log_filter")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	domains := []string{}
	rows, err := tx.QueryContext(ctx, "SELECT DISTINCT domain FROM access_counts WHERE occurred_at>=? AND occurred_at<=? ORDER BY domain", window.from.Unix(), window.to.Unix())
	if err == nil {
		for rows.Next() {
			var domain string
			if err = rows.Scan(&domain); err != nil {
				break
			}
			domains = append(domains, domain)
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
	}
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	predicate := "occurred_at>=? AND occurred_at<=?"
	args := []any{window.from.Unix(), window.to.Unix()}
	if domain := r.URL.Query().Get("domain"); domain != "" {
		predicate += " AND domain=?"
		args = append(args, domain)
	}
	query := `SELECT domain,hour,SUM(count),SUM(CASE WHEN status=404 THEN count ELSE 0 END) FROM access_counts WHERE ` + predicate + " GROUP BY domain,hour ORDER BY hour DESC,domain LIMIT 2001"
	rows, err = tx.QueryContext(ctx, query, args...)
	hours := []accessHour{}
	if err == nil {
		for rows.Next() {
			var value accessHour
			var hour int64
			if err = rows.Scan(&value.Domain, &hour, &value.Visits, &value.NotFound); err != nil {
				break
			}
			value.Hour = time.Unix(hour, 0).In(a.location).Format(time.RFC3339)
			hours = append(hours, value)
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
	}
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	truncated := len(hours) > 2000
	if truncated {
		hours = hours[:2000]
	}
	totals := []accessHour{}
	rows, err = tx.QueryContext(ctx, `SELECT domain,SUM(count),SUM(CASE WHEN status=404 THEN count ELSE 0 END) FROM access_counts WHERE `+predicate+" GROUP BY domain ORDER BY domain", args...)
	if err == nil {
		for rows.Next() {
			var v accessHour
			if err = rows.Scan(&v.Domain, &v.Visits, &v.NotFound); err != nil {
				break
			}
			totals = append(totals, v)
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
	}
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	respond(w, 200, map[string]any{"status": a.snapshot(), "rangeHours": window.hours, "from": window.from.In(a.location).Format(time.RFC3339), "to": window.to.In(a.location).Format(time.RFC3339), "domains": domains, "hours": hours, "totals": totals, "truncated": truncated})
}

// Only internal constants are interpolated as SQL identifiers; all log/filter values are bound.
func (a *accessLogService) ranks(ctx context.Context, tx *sql.Tx, column, predicate string, args ...any) ([]accessRank, error) {
	if column != "ip" && column != "ua" && column != "url" {
		return nil, fmt.Errorf("invalid rank column")
	}
	rows, err := tx.QueryContext(ctx, "SELECT "+column+",SUM(count) AS total FROM access_counts WHERE "+predicate+" GROUP BY "+column+" ORDER BY total DESC,"+column+" LIMIT 10", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []accessRank{}
	for rows.Next() {
		var v accessRank
		if err = rows.Scan(&v.Value, &v.Count); err != nil {
			return nil, err
		}
		values = append(values, v)
	}
	return values, rows.Err()
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
	var hour time.Time
	hourText := r.URL.Query().Get("hour")
	if requireHour || hourText != "" {
		hour, err = time.Parse(time.RFC3339, hourText)
		if err != nil || hour.In(a.location).Minute() != 0 || hour.Second() != 0 || hour.Nanosecond() != 0 {
			reject(w, 400, "invalid_log_filter")
			return
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	args := []any{domain, window.from.Unix(), window.to.Unix()}
	where := "domain=? AND occurred_at>=? AND occurred_at<=?"
	if hourText != "" {
		where += " AND hour=?"
		args = append(args, hour.Unix())
	}
	var visits, notFound int64
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	err = tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(count),0),COALESCE(SUM(CASE WHEN status=404 THEN count ELSE 0 END),0) FROM access_counts WHERE `+where, args...).Scan(&visits, &notFound)
	// Keep every nested ranking within the selected domain/hour and its IP or 404 page.
	rank := func(column, predicate string, params ...any) []accessRank {
		if err != nil {
			return []accessRank{}
		}
		var values []accessRank
		values, err = a.ranks(ctx, tx, column, predicate, params...)
		return values
	}
	clients := []accessClient{}
	for _, ip := range rank("ip", where, args...) {
		params := append(append([]any{}, args...), ip.Value)
		clients = append(clients, accessClient{ip, rank("ua", where+" AND ip=?", params...), rank("url", where+" AND ip=?", params...)})
	}
	urls := rank("url", where, args...)
	missing := []accessPage{}
	for _, page := range rank("url", where+" AND status=404", args...) {
		params := append(append([]any{}, args...), page.Value)
		missing = append(missing, accessPage{page, rank("ip", where+" AND status=404 AND url=?", params...), rank("ua", where+" AND status=404 AND url=?", params...)})
	}
	ips404 := rank("ip", where+" AND status=404", args...)
	ua404 := rank("ua", where+" AND status=404", args...)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	if !hour.IsZero() {
		hourText = hour.In(a.location).Format(time.RFC3339)
	}
	respond(w, 200, map[string]any{"domain": domain, "hour": hourText, "from": window.from.In(a.location).Format(time.RFC3339), "to": window.to.In(a.location).Format(time.RFC3339), "visits": visits, "notFound": notFound, "topClients": clients, "topURLs": urls, "notFoundPages": missing, "notFoundIPs": ips404, "notFoundUserAgents": ua404})
}
