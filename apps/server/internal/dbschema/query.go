package dbschema

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

var ErrQuery = errors.New("only one SELECT or WITH query is supported")

type QueryResult struct {
	Columns []string `json:"columns"`
	Rows    [][]any  `json:"rows"`
	HasMore bool     `json:"hasMore"`
	Clipped bool     `json:"clipped"`
	Offset  int      `json:"offset"`
	Limit   int      `json:"limit"`
}

// A query is embedded as a subquery, so SQLite's grammar rejects mutations,
// PRAGMA, ATTACH and transaction statements. Reject statement separators outside
// literals/comments as well: the driver must receive exactly one statement.
func singleQuery(source string) (string, error) {
	if len(source) > 20000 {
		return "", ErrQuery
	}
	source = strings.TrimSpace(source)
	var quote byte
	line, block, ended := false, false, false
	for i := 0; i < len(source); i++ {
		c := source[i]
		if line {
			if c == '\n' {
				line = false
			}
			continue
		}
		if block {
			if c == '*' && i+1 < len(source) && source[i+1] == '/' {
				block = false
				i++
			}
			continue
		}
		if quote != 0 {
			if c == quote {
				if quote != ']' && i+1 < len(source) && source[i+1] == quote {
					i++
				} else {
					quote = 0
				}
			}
			continue
		}
		if c == '-' && i+1 < len(source) && source[i+1] == '-' {
			line = true
			i++
			continue
		}
		if c == '/' && i+1 < len(source) && source[i+1] == '*' {
			block = true
			i++
			continue
		}
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			continue
		}
		if ended {
			return "", ErrQuery
		}
		if c == ';' {
			source = source[:i] + " " + source[i+1:]
			ended = true
			continue
		}
		if c == '\'' || c == '"' || c == '`' {
			quote = c
		}
		if c == '[' {
			quote = ']'
		}
	}
	if quote != 0 || block || strings.TrimSpace(source) == "" {
		return "", ErrQuery
	}
	return source, nil
}

func Query(ctx context.Context, db *sql.DB, source string, limit, offset int) (QueryResult, error) {
	result := QueryResult{Rows: [][]any{}, Offset: offset, Limit: limit}
	query, err := singleQuery(source)
	if err != nil {
		return result, err
	}
	if limit < 1 || limit > 200 || offset < 0 || offset > 1000000 {
		return result, ErrQuery
	}
	rows, err := db.QueryContext(ctx, "SELECT * FROM (\n"+query+"\n) LIMIT ? OFFSET ?", limit+1, offset)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	result.Columns, err = rows.Columns()
	if err != nil {
		return result, err
	}
	bytes := 0
	for rows.Next() {
		if len(result.Rows) == limit {
			result.HasMore = true
			break
		}
		values := make([]any, len(result.Columns))
		pointers := make([]any, len(values))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			return result, err
		}
		for i, value := range values {
			switch v := value.(type) {
			case []byte:
				values[i] = fmt.Sprintf("[BLOB: %d bytes]", len(v))
			case int64:
				values[i] = fmt.Sprint(v) // Preserve integers beyond JavaScript's safe range.
			case float64:
				if math.IsInf(v, 0) || math.IsNaN(v) {
					values[i] = fmt.Sprint(v)
				}
			case string:
				if len(v) > 8192 {
					n := 8192
					for n > 0 && !utf8.RuneStart(v[n]) {
						n--
					}
					values[i] = v[:n] + "… [内容已截断]"
					result.Clipped = true
				}
			}
			bytes += len(fmt.Sprint(values[i]))
		}
		if bytes > 2*1024*1024 {
			return result, errors.New("result exceeds 2 MiB; select fewer columns or a smaller page")
		}
		result.Rows = append(result.Rows, values)
	}
	return result, rows.Err()
}
