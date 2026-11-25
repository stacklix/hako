package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strconv"
	"strings"
)

type investmentChange struct {
	Upserts []investmentRow `json:"upserts"`
	Deletes []investmentRow `json:"deletes"`
}
type investmentChanges map[string]investmentChange
type investmentChangeWrite struct {
	Generation int64             `json:"generation"`
	Revision   int64             `json:"revision"`
	DirtyFrom  *string           `json:"dirtyFrom"`
	Through    *string           `json:"through"`
	Changes    investmentChanges `json:"changes"`
}
type investmentChangeResult struct {
	Generation     int64             `json:"generation"`
	Revision       int64             `json:"revision"`
	DirtyFrom      *string           `json:"dirtyFrom"`
	Through        *string           `json:"through"`
	Changes        investmentChanges `json:"changes"`
	ReloadRequired bool              `json:"reloadRequired"`
}

func (s *Server) changeInvestment(w http.ResponseWriter, r *http.Request) {
	owner, ok := s.investmentOwner(w, r)
	if !ok {
		return
	}
	var input investmentChangeWrite
	if !decode(w, r, &input) {
		return
	}
	result, err := s.persistInvestmentChanges(r.Context(), owner, input)
	switch {
	case errors.Is(err, errInvestmentConflict):
		reject(w, 409, "investment_conflict")
	case errors.Is(err, errInvestmentInvalid):
		reject(w, 400, "invalid_investment_data")
	case err != nil:
		reject(w, 503, "storage_unavailable")
	default:
		respond(w, 200, result)
	}
}

func (s *Server) persistInvestmentChanges(ctx context.Context, owner string, input investmentChangeWrite) (investmentChangeResult, error) {
	result := investmentChangeResult{Changes: investmentChanges{}}
	if input.Generation < 0 || input.Revision < 0 || len(input.Changes) > len(investmentTables) ||
		(input.DirtyFrom != nil && !validInvestmentDate(*input.DirtyFrom)) || (input.Through != nil && !validInvestmentDate(*input.Through)) {
		return result, errInvestmentInvalid
	}
	tx, err := s.investment.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	var bookID string
	err = tx.QueryRowContext(ctx, "SELECT id,generation,revision,snapshot_dirty_from,snapshot_through FROM investment_books WHERE owner_id=?", owner).
		Scan(&bookID, &result.Generation, &result.Revision, &result.DirtyFrom, &result.Through)
	if errors.Is(err, sql.ErrNoRows) && input.Generation == 0 {
		var id [16]byte
		if _, err = rand.Read(id[:]); err != nil {
			return result, err
		}
		id[6] = id[6]&0x0f | 0x40
		id[8] = id[8]&0x3f | 0x80
		bookID = fmt.Sprintf("%X-%X-%X-%X-%X", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
		_, err = tx.ExecContext(ctx, "INSERT INTO investment_books(owner_id,id) VALUES(?,?)", owner, bookID)
	} else if errors.Is(err, sql.ErrNoRows) {
		return result, errInvestmentConflict
	}
	if err != nil {
		return result, err
	}
	marketOnly := len(input.Changes) > 0
	for name := range input.Changes {
		marketOnly = marketOnly && (name == "market_daily_prices" || name == "market_daily_fx")
	}
	if !marketOnly && result.Generation != input.Generation {
		return result, errInvestmentConflict
	}
	// Quotes change independently of ledger generation. This hints a cache reload;
	// it never rejects a quote write based on the revision supplied by the client.
	result.ReloadRequired = result.Revision != input.Revision || result.Generation != input.Generation

	var before int64
	if err = tx.QueryRowContext(ctx, "SELECT total_changes()").Scan(&before); err != nil {
		return result, err
	}
	inputs, outputs, matched := false, false, 0
	for _, table := range investmentTables {
		change, ok := input.Changes[table.name]
		if !ok {
			continue
		}
		matched++
		if len(change.Upserts)+len(change.Deletes) > 500_000 || (len(change.Upserts) == 0 && len(change.Deletes) == 0) {
			return result, errInvestmentInvalid
		}
		inputs = inputs || !table.output
		outputs = outputs || table.output
		seen := map[string]bool{}
		keys := strings.Fields(table.keys)
		confirmed := investmentChange{Upserts: []investmentRow{}, Deletes: []investmentRow{}}
		for _, row := range change.Deletes {
			if len(row) != len(keys) {
				return result, errInvestmentInvalid
			}
			for _, key := range keys {
				value, ok := row[key]
				if !ok || (value == "" && key != "source") || strings.ContainsRune(value, 0) {
					return result, errInvestmentInvalid
				}
			}
			key := investmentRowKey(row, keys)
			if seen[key] {
				return result, errInvestmentInvalid
			}
			seen[key] = true
			args := []any{bookID}
			where := []string{"book_id=?"}
			for _, column := range keys {
				where = append(where, column+"=?")
				args = append(args, row[column])
			}
			if _, err = tx.ExecContext(ctx, "DELETE FROM "+table.name+" WHERE "+strings.Join(where, " AND "), args...); err != nil {
				return result, err
			}
			confirmed.Deletes = append(confirmed.Deletes, row)
		}
		for _, row := range change.Upserts {
			if err = table.prepareRow(row); err != nil {
				return result, err
			}
			key := investmentRowKey(row, keys)
			if seen[key] {
				return result, errInvestmentInvalid
			}
			seen[key] = true
			if table.name == "investment_daily_snapshots" && row["computed_revision"] != strconv.FormatInt(result.Revision, 10) {
				return result, errInvestmentConflict
			}
			if err = table.upsert(ctx, tx, bookID, row); err != nil {
				return result, err
			}
			confirmed.Upserts = append(confirmed.Upserts, row)
		}
		result.Changes[table.name] = confirmed
	}
	if matched != len(input.Changes) || (inputs && outputs) {
		return result, errInvestmentInvalid
	}
	if outputs && result.ReloadRequired {
		return result, errInvestmentConflict
	}
	if err = validateInvestmentLinks(ctx, tx, bookID); err != nil {
		return result, err
	}
	var after int64
	if err = tx.QueryRowContext(ctx, "SELECT total_changes()").Scan(&after); err != nil {
		return result, err
	}
	changed := after != before
	if changed || !reflect.DeepEqual(result.DirtyFrom, input.DirtyFrom) || !reflect.DeepEqual(result.Through, input.Through) {
		if changed && inputs {
			result.Revision++
		}
		if !marketOnly {
			result.Generation++
		}
		if marketOnly {
			if input.DirtyFrom != nil && (result.DirtyFrom == nil || *input.DirtyFrom < *result.DirtyFrom) {
				result.DirtyFrom = input.DirtyFrom
			}
		} else {
			if !inputs || result.DirtyFrom == nil || (input.DirtyFrom != nil && *input.DirtyFrom < *result.DirtyFrom) {
				result.DirtyFrom = input.DirtyFrom
			}
			result.Through = input.Through
		}
		if _, err = tx.ExecContext(ctx, "UPDATE investment_books SET generation=?,revision=?,snapshot_dirty_from=?,snapshot_through=? WHERE owner_id=?", result.Generation, result.Revision, result.DirtyFrom, result.Through, owner); err != nil {
			return result, err
		}
	}
	return result, tx.Commit()
}

func (t investmentTable) row(ctx context.Context, tx *sql.Tx, book string, key investmentRow) (investmentRow, error) {
	columns := t.columns()
	args := []any{book}
	where := []string{"book_id=?"}
	for _, column := range strings.Fields(t.keys) {
		where = append(where, column+"=?")
		args = append(args, key[column])
	}
	values := make([]sql.NullString, len(columns))
	dest := make([]any, len(columns))
	for i := range values {
		dest[i] = &values[i]
	}
	err := tx.QueryRowContext(ctx, "SELECT "+strings.Join(columns, ",")+" FROM "+t.name+" WHERE "+strings.Join(where, " AND "), args...).Scan(dest...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	row := investmentRow{}
	for i, value := range values {
		if value.Valid {
			row[columns[i]] = value.String
		}
	}
	return row, nil
}

// All rows are full records, but only the changed records are sent and written.
func (t investmentTable) upsert(ctx context.Context, tx *sql.Tx, book string, row investmentRow) error {
	previous, err := t.row(ctx, tx, book, row)
	if err != nil {
		return err
	}
	columns := t.columns()
	if t.name == "market_daily_prices" || t.name == "market_daily_fx" {
		revision, _ := strconv.ParseInt(previous["revision"], 10, 64)
		if revision == 0 || investmentQuoteChanged(previous, row, columns) {
			revision++
		}
		row["revision"] = strconv.FormatInt(revision, 10)
	}
	if reflect.DeepEqual(previous, row) {
		return nil
	}
	args := []any{book}
	for _, column := range columns {
		if v, ok := row[column]; ok {
			args = append(args, v)
		} else {
			args = append(args, nil)
		}
	}
	updates := []string{}
	for _, column := range strings.Fields(t.fields) {
		updates = append(updates, column+"=excluded."+column)
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO "+t.name+"(book_id,"+strings.Join(columns, ",")+") VALUES (?"+strings.Repeat(",?", len(columns))+") ON CONFLICT(book_id,"+strings.Join(strings.Fields(t.keys), ",")+") DO UPDATE SET "+strings.Join(updates, ","), args...)
	return err
}
