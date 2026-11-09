package accesslog

import (
	"context"
	"database/sql"
	"strings"
	"time"
)

type Record struct {
	Time      string `json:"time"`
	Domain    string `json:"domain"`
	Status    int    `json:"status"`
	IP        string `json:"ip"`
	Path      string `json:"path"`
	UserAgent string `json:"userAgent"`
	Count     int64  `json:"count"`
}

type RecordFilters struct {
	From, To              time.Time
	Domain, IP, Path      string
	Status, Limit, Offset int
}

// Records queries retained aggregates using a stable order for pagination.
func (a *Service) Records(ctx context.Context, filters RecordFilters) (map[string]any, error) {
	from, to := filters.From, filters.To
	limit, offset := filters.Limit, filters.Offset
	where := "occurred_at>=? AND occurred_at<=?"
	args := []any{from.Unix(), to.Unix()}
	if filters.Domain != "" {
		where += " AND domain=?"
		args = append(args, filters.Domain)
	}
	if filters.IP != "" {
		where += " AND ip=?"
		args = append(args, filters.IP)
	}
	if filters.Path != "" {
		// Match trailing-slash variants without rewriting stored paths.
		where += " AND rtrim(url,'/')=?"
		args = append(args, strings.TrimRight(filters.Path, "/"))
	}
	if filters.Status != 0 {
		where += " AND status=?"
		args = append(args, filters.Status)
	}
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var totalRows, requests int64
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*),COALESCE(SUM(count),0) FROM access_counts WHERE "+where, args...).Scan(&totalRows, &requests); err != nil {
		return nil, err
	}
	params := append(append([]any{}, args...), limit, offset)
	rows, err := tx.QueryContext(ctx, "SELECT occurred_at,domain,status,ip,url,ua,count FROM access_counts WHERE "+where+" ORDER BY occurred_at DESC,domain,status,ip,url,ua,hour LIMIT ? OFFSET ?", params...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []Record{}
	for rows.Next() {
		var v Record
		var stamp int64
		if err = rows.Scan(&stamp, &v.Domain, &v.Status, &v.IP, &v.Path, &v.UserAgent, &v.Count); err != nil {
			break
		}
		v.Time = time.Unix(stamp, 0).In(a.location).Format(time.RFC3339)
		values = append(values, v)
	}
	if err != nil {
		return nil, err
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	return map[string]any{"from": from.In(a.location).Format(time.RFC3339), "to": to.In(a.location).Format(time.RFC3339), "timezone": a.location.String(), "rows": values, "totalRows": totalRows, "requests": requests, "offset": offset, "limit": limit, "hasMore": int64(offset) < totalRows && int64(len(values)) < totalRows-int64(offset)}, nil
}
