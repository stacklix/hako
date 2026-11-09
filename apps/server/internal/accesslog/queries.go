package accesslog

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Normal responses are 101, 200–299 and 304; every other valid status is abnormal.
type Hour struct {
	Domain     string `json:"domain"`
	Hour       string `json:"hour"`
	Visits     int64  `json:"visits"`
	NonSuccess int64  `json:"nonSuccess"`
	Success    int64  `json:"success"`
}

type Rank struct {
	Value string `json:"value"`
	Count int64  `json:"count"`
}

type Client struct {
	Rank
	UserAgents     []Rank `json:"userAgents"`
	URLs           []Rank `json:"urls"`
	SuccessURLs    []Rank `json:"successURLs"`
	NonSuccessURLs []Rank `json:"nonSuccessURLs"`
}

type Page struct {
	Rank
	IPs        []Rank `json:"ips"`
	UserAgents []Rank `json:"userAgents"`
}

func DisabledSummary() map[string]any {
	return map[string]any{"status": Status{Retention: 7}, "domains": []string{}, "hours": []Hour{}, "totals": []Hour{}}
}

func (a *Service) Summary(ctx context.Context, from, to time.Time, rangeHours int, domain string) (map[string]any, error) {
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	domains := []string{}
	rows, err := tx.QueryContext(ctx, "SELECT DISTINCT domain FROM access_counts WHERE occurred_at>=? AND occurred_at<=? ORDER BY domain", from.Unix(), to.Unix())
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
		return nil, err
	}
	predicate := "occurred_at>=? AND occurred_at<=?"
	args := []any{from.Unix(), to.Unix()}
	if domain != "" {
		predicate += " AND domain=?"
		args = append(args, domain)
	}
	query := `SELECT domain,hour,SUM(count),SUM(CASE WHEN (status NOT IN (101,304) AND (status<200 OR status>=300)) THEN count ELSE 0 END) FROM access_counts WHERE ` + predicate + " GROUP BY domain,hour ORDER BY hour DESC,domain LIMIT 2001"
	rows, err = tx.QueryContext(ctx, query, args...)
	hours := []Hour{}
	if err == nil {
		for rows.Next() {
			var value Hour
			var hour int64
			if err = rows.Scan(&value.Domain, &hour, &value.Visits, &value.NonSuccess); err != nil {
				break
			}
			value.Success = value.Visits - value.NonSuccess
			value.Hour = time.Unix(hour, 0).In(a.location).Format(time.RFC3339)
			hours = append(hours, value)
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
	}
	if err != nil {
		return nil, err
	}
	truncated := len(hours) > 2000
	if truncated {
		hours = hours[:2000]
	}
	totals := []Hour{}
	rows, err = tx.QueryContext(ctx, `SELECT domain,SUM(count),SUM(CASE WHEN (status NOT IN (101,304) AND (status<200 OR status>=300)) THEN count ELSE 0 END) FROM access_counts WHERE `+predicate+" GROUP BY domain ORDER BY domain", args...)
	if err == nil {
		for rows.Next() {
			var v Hour
			if err = rows.Scan(&v.Domain, &v.Visits, &v.NonSuccess); err != nil {
				break
			}
			v.Success = v.Visits - v.NonSuccess
			totals = append(totals, v)
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": a.Status(), "rangeHours": rangeHours, "from": from.In(a.location).Format(time.RFC3339), "to": to.In(a.location).Format(time.RFC3339), "domains": domains, "hours": hours, "totals": totals, "truncated": truncated}, nil
}

// Only internal constants are interpolated as SQL identifiers; all log/filter values are bound.
func (a *Service) ranks(ctx context.Context, tx *sql.Tx, column, predicate string, args ...any) ([]Rank, error) {
	if column != "ip" && column != "ua" && column != "url" {
		return nil, fmt.Errorf("invalid rank column")
	}
	rows, err := tx.QueryContext(ctx, "SELECT "+column+",SUM(count) AS total FROM access_counts WHERE "+predicate+" GROUP BY "+column+" ORDER BY total DESC,"+column+" LIMIT 10", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []Rank{}
	for rows.Next() {
		var v Rank
		if err = rows.Scan(&v.Value, &v.Count); err != nil {
			return nil, err
		}
		values = append(values, v)
	}
	return values, rows.Err()
}

func (a *Service) Details(ctx context.Context, from, to time.Time, hour *time.Time, domain string) (map[string]any, error) {
	args := []any{domain, from.Unix(), to.Unix()}
	where := "domain=? AND occurred_at>=? AND occurred_at<=?"
	if hour != nil {
		where += " AND hour=?"
		args = append(args, hour.Unix())
	}
	var visits, nonSuccess int64
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	err = tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(count),0),COALESCE(SUM(CASE WHEN (status NOT IN (101,304) AND (status<200 OR status>=300)) THEN count ELSE 0 END),0) FROM access_counts WHERE `+where, args...).Scan(&visits, &nonSuccess)
	// Keep every nested ranking within the selected domain/hour and its IP or abnormal-response page.
	rank := func(column, predicate string, params ...any) []Rank {
		if err != nil {
			return []Rank{}
		}
		var values []Rank
		values, err = a.ranks(ctx, tx, column, predicate, params...)
		return values
	}
	clients := []Client{}
	for _, ip := range rank("ip", where, args...) {
		params := append(append([]any{}, args...), ip.Value)
		clients = append(clients, Client{
			Rank:           ip,
			UserAgents:     rank("ua", where+" AND ip=?", params...),
			URLs:           rank("url", where+" AND ip=?", params...),
			SuccessURLs:    rank("url", where+" AND ip=? AND (status IN (101,304) OR (status>=200 AND status<300))", params...),
			NonSuccessURLs: rank("url", where+" AND ip=? AND (status NOT IN (101,304) AND (status<200 OR status>=300))", params...),
		})
	}
	urls := rank("url", where, args...)
	successURLs := rank("url", where+" AND (status IN (101,304) OR (status>=200 AND status<300))", args...)
	missing := []Page{}
	for _, page := range rank("url", where+" AND (status NOT IN (101,304) AND (status<200 OR status>=300))", args...) {
		params := append(append([]any{}, args...), page.Value)
		missing = append(missing, Page{page, rank("ip", where+" AND (status NOT IN (101,304) AND (status<200 OR status>=300)) AND url=?", params...), rank("ua", where+" AND (status NOT IN (101,304) AND (status<200 OR status>=300)) AND url=?", params...)})
	}
	nonSuccessIPs := rank("ip", where+" AND (status NOT IN (101,304) AND (status<200 OR status>=300))", args...)
	nonSuccessUserAgents := rank("ua", where+" AND (status NOT IN (101,304) AND (status<200 OR status>=300))", args...)
	if err != nil {
		return nil, err
	}
	return map[string]any{"domain": domain, "from": from.In(a.location).Format(time.RFC3339), "to": to.In(a.location).Format(time.RFC3339), "visits": visits, "success": visits - nonSuccess, "nonSuccess": nonSuccess, "topClients": clients, "topURLs": urls, "successURLs": successURLs, "nonSuccessPages": missing, "nonSuccessIPs": nonSuccessIPs, "nonSuccessUserAgents": nonSuccessUserAgents}, nil
}
