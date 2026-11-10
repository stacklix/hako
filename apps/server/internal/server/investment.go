package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"hako/server/internal/dbschema"
)

type investmentRow map[string]string
type investmentRows map[string][]investmentRow

type investmentTable struct {
	name, keys, fields string
	output             bool
}

var investmentTables = []investmentTable{
	{"market_instruments", "id", "asset_type symbol exchange name quote_currency price_type", false},
	{"market_derivative_specs", "instrument_id", "pricing_model contract_multiplier settlement_basis settlement_unit expiry_date", false},
	{"investment_accounts", "id", "name account_type currency sort_order archived_at", false},
	{"investment_assets", "id", "instrument_id name asset_type settlement_unit annual_rate maturity_date collateral_asset_id position_side symbol quote_currency", false},
	{"investment_events", "id", "account_id asset_id event_type effective_date sequence amount quantity unit_price fee settled_amount transfer_id transfer_account_id version created_at updated_at deleted_at", false},
	{"investment_derivative_event_details", "event_id", "trade_action position_side margin_delta funding_target settlement_to_account_rate", false},
	{"investment_plans", "id", "account_id asset_id amount month_day next_date enabled last_result sort_order", false},
	{"investment_plan_runs", "plan_id scheduled_date", "status event_id executed_at result_detail", false},
	{"investment_watchlist", "asset_id", "instrument_id sort_order", false},
	{"market_daily_prices", "instrument_id session_date price_type source", "closed_at_utc valuation_date price is_final revision", false},
	{"market_daily_fx", "rate_date base_currency quote_currency source", "rate available_at_utc is_final revision", false},
	{"investment_manual_prices", "asset_id valuation_date", "value source is_final", false},
	{"investment_daily_snapshots", "snapshot_date", "total_cny total_usd cumulative_gain_cny daily_gain_cny status missing_inputs computed_revision", true},
	{"investment_account_daily_snapshots", "account_id snapshot_date", "cash_native holdings_native gain_native status", true},
	{"investment_balance_accounts", "id", "name category currency sort_order", false},
	{"investment_balance_records", "id", "balance_account_id recorded_at amount", false},
	{"investment_month_snapshots", "snapshot_date", "total_cny", true},
}

var (
	errInvestmentConflict  = errors.New("investment_conflict")
	errInvestmentInvalid   = errors.New("invalid_investment_data")
	investmentDay          = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	investmentDecimal      = regexp.MustCompile(`^-?\d+(\.\d+)?$`)
	investmentNumberFields = " amount quantity unit_price fee settled_amount annual_rate margin_delta settlement_to_account_rate price rate value contract_multiplier total_cny total_usd cumulative_gain_cny daily_gain_cny cash_native holdings_native gain_native "
)

const investmentIntegerFields = " sequence sort_order enabled month_day is_final version revision computed_revision "

var investmentRequired = map[string]string{
	"market_instruments":                 "asset_type symbol exchange name quote_currency price_type",
	"market_derivative_specs":            "pricing_model contract_multiplier settlement_basis settlement_unit",
	"investment_accounts":                "name account_type currency sort_order",
	"investment_assets":                  "name asset_type quote_currency settlement_unit",
	"investment_events":                  "account_id effective_date sequence event_type",
	"investment_plans":                   "account_id amount month_day next_date enabled",
	"investment_watchlist":               "sort_order",
	"market_daily_prices":                "price",
	"market_daily_fx":                    "rate",
	"investment_manual_prices":           "value",
	"investment_daily_snapshots":         "status computed_revision",
	"investment_account_daily_snapshots": "status",
	"investment_balance_accounts":        "name category currency",
	"investment_balance_records":         "balance_account_id recorded_at amount",
	"investment_month_snapshots":         "total_cny",
}

type investmentState struct {
	Generation int64          `json:"generation"`
	Revision   int64          `json:"revision"`
	DirtyFrom  *string        `json:"dirtyFrom"`
	Through    *string        `json:"through"`
	Tables     investmentRows `json:"tables"`
}

type investmentWrite struct {
	Generation int64          `json:"generation"`
	DirtyFrom  *string        `json:"dirtyFrom"`
	Through    *string        `json:"through"`
	Tables     investmentRows `json:"tables"`
}

func (t investmentTable) columns() []string {
	return strings.Fields(t.keys + " " + t.fields)
}

func openInvestmentDB(mainPath string) (*sql.DB, error) {
	path := mainPath
	if path != ":memory:" {
		path = filepath.Join(filepath.Dir(mainPath), "investment.sqlite")
		if filepath.Clean(path) == filepath.Clean(mainPath) {
			path = mainPath + ".ledger"
		}
		file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return nil, err
		}
		if err := file.Close(); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000"); err == nil {
		err = dbschema.Initialize(db, func(tx *sql.Tx) error {
			if _, err := tx.Exec(`CREATE TABLE investment_books (
				owner_id TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, name TEXT NOT NULL DEFAULT '我的投资',
				timezone TEXT NOT NULL DEFAULT 'Asia/Shanghai', generation INTEGER NOT NULL DEFAULT 0,
				revision INTEGER NOT NULL DEFAULT 0, snapshot_dirty_from TEXT, snapshot_through TEXT
			)`); err != nil {
				return err
			}
			for _, table := range investmentTables {
				keys := strings.Fields(table.keys)
				definitions := []string{"book_id TEXT NOT NULL"}
				for i, column := range table.columns() {
					definition := column + " TEXT"
					if strings.Contains(investmentIntegerFields, " "+column+" ") {
						definition = column + " INTEGER"
					}
					if i < len(keys) {
						definition += " NOT NULL"
					}
					definitions = append(definitions, definition)
				}
				definitions = append(definitions, "PRIMARY KEY(book_id,"+strings.Join(keys, ",")+")")
				if _, err := tx.Exec("CREATE TABLE " + table.name + " (" + strings.Join(definitions, ",") + ") WITHOUT ROWID"); err != nil {
					return err
				}
			}
			_, err := tx.Exec(`CREATE INDEX investment_events_account_day
				ON investment_events(book_id,account_id,effective_date,sequence);
				CREATE INDEX investment_balance_records_account_day
				ON investment_balance_records(book_id,balance_account_id,recorded_at);`)
			return err
		})
	}
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func (s *Server) investmentRoutes() {
	s.mux.HandleFunc("GET /api/v1/investment/book", s.readInvestment)
	s.mux.HandleFunc("PUT /api/v1/investment/book", s.writeInvestment)
	s.mux.HandleFunc("GET /api/v1/investment/export", s.exportInvestment)
}

func (s *Server) investmentOwner(w http.ResponseWriter, r *http.Request) (string, bool) {
	if _, ok := s.authorized(w, r); !ok {
		return "", false
	}
	return s.investmentSubject(), true
}

func (s *Server) investmentSubject() string {
	var owner string
	s.store.inspect(func(state state) { owner = state.Subject })
	return owner
}

func (s *Server) readInvestment(w http.ResponseWriter, r *http.Request) {
	owner, ok := s.investmentOwner(w, r)
	if !ok {
		return
	}
	s.readInvestmentBook(w, r, owner, nil)
}

func (s *Server) readInvestmentBook(w http.ResponseWriter, r *http.Request, owner string, tables []string) {
	tx, err := s.investment.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	state, err := readInvestmentState(r.Context(), tx, owner, tables)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	respond(w, 200, state)
}

func readInvestmentState(ctx context.Context, tx *sql.Tx, owner string, tables []string) (investmentState, error) {
	state := investmentState{Tables: investmentRows{}}
	var bookID string
	err := tx.QueryRowContext(ctx, "SELECT id,generation,revision,snapshot_dirty_from,snapshot_through FROM investment_books WHERE owner_id=?", owner).
		Scan(&bookID, &state.Generation, &state.Revision, &state.DirtyFrom, &state.Through)
	if errors.Is(err, sql.ErrNoRows) {
		return state, nil
	}
	if err != nil {
		return state, err
	}
	for _, table := range investmentTables {
		if tables != nil && !slices.Contains(tables, table.name) {
			continue
		}
		rows, err := table.read(ctx, tx, bookID)
		if err != nil {
			return state, err
		}
		state.Tables[table.name] = rows
	}
	return state, nil
}

func (t investmentTable) read(ctx context.Context, tx *sql.Tx, owner string) ([]investmentRow, error) {
	columns := t.columns()
	rows, err := tx.QueryContext(ctx, "SELECT "+strings.Join(columns, ",")+" FROM "+t.name+
		" WHERE book_id=? ORDER BY "+strings.Join(strings.Fields(t.keys), ","), owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []investmentRow{}
	values := make([]sql.NullString, len(columns))
	args := make([]any, len(columns))
	for i := range values {
		args[i] = &values[i]
	}
	for rows.Next() {
		if err := rows.Scan(args...); err != nil {
			return nil, err
		}
		row := investmentRow{}
		for i, value := range values {
			if value.Valid {
				row[columns[i]] = value.String
			}
		}
		result = append(result, row)
	}
	return result, rows.Err()
}

func (s *Server) writeInvestment(w http.ResponseWriter, r *http.Request) {
	owner, ok := s.investmentOwner(w, r)
	if !ok {
		return
	}
	var write investmentWrite
	if !decode(w, r, &write) {
		return
	}
	state, err := s.persistInvestment(r.Context(), owner, write)
	switch {
	case errors.Is(err, errInvestmentConflict):
		reject(w, 409, "investment_conflict")
	case errors.Is(err, errInvestmentInvalid):
		reject(w, 400, "invalid_investment_data")
	case err != nil:
		reject(w, 503, "storage_unavailable")
	default:
		respond(w, 200, state)
	}
}

func (s *Server) persistInvestment(ctx context.Context, owner string, write investmentWrite) (investmentState, error) {
	state := investmentState{Tables: write.Tables}
	if write.Generation < 0 || len(write.Tables) > len(investmentTables) ||
		(write.DirtyFrom != nil && !validInvestmentDate(*write.DirtyFrom)) ||
		(write.Through != nil && !validInvestmentDate(*write.Through)) {
		return state, errInvestmentInvalid
	}
	tx, err := s.investment.BeginTx(ctx, nil)
	if err != nil {
		return state, err
	}
	defer tx.Rollback()
	var bookID string
	err = tx.QueryRowContext(ctx, "SELECT id,generation,revision FROM investment_books WHERE owner_id=?", owner).
		Scan(&bookID, &state.Generation, &state.Revision)
	if errors.Is(err, sql.ErrNoRows) && write.Generation == 0 {
		var id [16]byte
		if _, err := rand.Read(id[:]); err != nil {
			return state, err
		}
		id[6], id[8] = id[6]&0x0f|0x40, id[8]&0x3f|0x80
		bookID = fmt.Sprintf("%X-%X-%X-%X-%X", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
		if _, err := tx.ExecContext(ctx, "INSERT INTO investment_books(owner_id,id) VALUES(?,?)", owner, bookID); err != nil {
			return state, err
		}
	} else if errors.Is(err, sql.ErrNoRows) {
		return state, errInvestmentConflict
	} else if err != nil {
		return state, err
	}
	if state.Generation != write.Generation {
		return state, errInvestmentConflict
	}
	matched := 0
	inputsChanged := false
	outputsChanged := false
	for _, table := range investmentTables {
		rows, supplied := write.Tables[table.name]
		if !supplied {
			continue
		}
		matched++
		inputsChanged = inputsChanged || !table.output
		outputsChanged = outputsChanged || table.output
		if table.name == "investment_daily_snapshots" {
			for _, row := range rows {
				if row["computed_revision"] != strconv.FormatInt(state.Revision, 10) {
					return state, errInvestmentConflict
				}
			}
		}
		if err := table.replace(ctx, tx, bookID, rows); err != nil {
			return state, err
		}
	}
	if matched != len(write.Tables) || (inputsChanged && outputsChanged) {
		return state, errInvestmentInvalid
	}
	if err := validateInvestmentLinks(ctx, tx, bookID); err != nil {
		return state, err
	}
	if inputsChanged {
		state.Revision++
	}
	state.Generation++
	state.DirtyFrom, state.Through = write.DirtyFrom, write.Through
	if _, err := tx.ExecContext(ctx, "UPDATE investment_books SET generation=?,revision=?,snapshot_dirty_from=?,snapshot_through=? WHERE owner_id=?",
		state.Generation, state.Revision, state.DirtyFrom, state.Through, owner); err != nil {
		return state, err
	}
	return state, tx.Commit()
}

func (t investmentTable) replace(ctx context.Context, tx *sql.Tx, owner string, rows []investmentRow) error {
	if rows == nil || len(rows) > 500_000 {
		return errInvestmentInvalid
	}
	columns := t.columns()
	allowed := make(map[string]bool, len(columns))
	for _, column := range columns {
		allowed[column] = true
	}
	keys := strings.Fields(t.keys)
	seen := make(map[string]bool, len(rows))
	var quoteVersions map[string]investmentRow
	if t.name == "market_daily_prices" || t.name == "market_daily_fx" {
		current, err := t.read(ctx, tx, owner)
		if err != nil {
			return err
		}
		quoteVersions = make(map[string]investmentRow, len(current))
		for _, row := range current {
			quoteVersions[investmentRowKey(row, keys)] = row
		}
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM "+t.name+" WHERE book_id=?", owner); err != nil {
		return err
	}
	stmt, err := tx.PrepareContext(ctx, "INSERT INTO "+t.name+"(book_id,"+strings.Join(columns, ",")+") VALUES (?"+strings.Repeat(",?", len(columns))+")")
	if err != nil {
		return err
	}
	defer stmt.Close()
	args := make([]any, len(columns)+1)
	args[0] = owner
	for _, row := range rows {
		for _, column := range keys {
			value, exists := row[column]
			if !exists || (value == "" && column != "source") || strings.ContainsRune(value, 0) {
				return errInvestmentInvalid
			}
		}
		key := investmentRowKey(row, keys)
		if seen[key] {
			return errInvestmentInvalid
		}
		seen[key] = true
		for _, field := range strings.Fields(investmentRequired[t.name]) {
			if _, exists := row[field]; !exists {
				return errInvestmentInvalid
			}
		}
		for column, value := range row {
			if !allowed[column] || len(value) > 16384 ||
				(strings.Contains(investmentNumberFields, " "+column+" ") && !investmentDecimal.MatchString(value)) {
				return errInvestmentInvalid
			}
			if strings.Contains(investmentIntegerFields, " "+column+" ") {
				number, err := strconv.ParseInt(value, 10, 64)
				if err != nil || number < 0 || ((column == "enabled" || column == "is_final") && number > 1) {
					return errInvestmentInvalid
				}
			}
			if (strings.HasSuffix(column, "_date") || column == "effective_date") && !validInvestmentDate(value) {
				return errInvestmentInvalid
			}
		}
		if row["asset_type"] == "option" {
			return errInvestmentInvalid
		}
		if quoteVersions != nil {
			prior := quoteVersions[key]
			revision, _ := strconv.ParseInt(prior["revision"], 10, 64)
			if revision == 0 || investmentQuoteChanged(prior, row, columns) {
				revision++
			}
			row["revision"] = strconv.FormatInt(revision, 10)
		}
		for i, column := range columns {
			args[i+1] = nil
			if value, ok := row[column]; ok {
				args[i+1] = value
			}
		}
		if _, err := stmt.ExecContext(ctx, args...); err != nil {
			return err
		}
	}
	return nil
}

func validInvestmentDate(value string) bool {
	if !investmentDay.MatchString(value) {
		return false
	}
	_, err := time.Parse(time.DateOnly, value)
	return err == nil
}

func investmentRowKey(row investmentRow, keys []string) string {
	var key strings.Builder
	for _, column := range keys {
		key.WriteString(row[column])
		key.WriteByte(0)
	}
	return key.String()
}

func investmentQuoteChanged(before, after investmentRow, columns []string) bool {
	for _, column := range columns {
		if column != "revision" && before[column] != after[column] {
			return true
		}
	}
	return false
}

func validateInvestmentLinks(ctx context.Context, tx *sql.Tx, owner string) error {
	for _, link := range []struct{ from, column, to, target string }{
		{"investment_events", "account_id", "investment_accounts", "id"},
		{"investment_events", "asset_id", "investment_assets", "id"},
		{"investment_events", "transfer_account_id", "investment_accounts", "id"},
		{"investment_derivative_event_details", "event_id", "investment_events", "id"},
		{"investment_assets", "instrument_id", "market_instruments", "id"},
		{"investment_assets", "collateral_asset_id", "investment_assets", "id"},
		{"market_derivative_specs", "instrument_id", "market_instruments", "id"},
		{"market_daily_prices", "instrument_id", "market_instruments", "id"},
		{"investment_manual_prices", "asset_id", "investment_assets", "id"},
		{"investment_watchlist", "asset_id", "investment_assets", "id"},
		{"investment_plans", "account_id", "investment_accounts", "id"},
		{"investment_plans", "asset_id", "investment_assets", "id"},
		{"investment_plan_runs", "plan_id", "investment_plans", "id"},
		{"investment_account_daily_snapshots", "account_id", "investment_accounts", "id"},
		{"investment_balance_records", "balance_account_id", "investment_balance_accounts", "id"},
	} {
		var missing bool
		query := "SELECT EXISTS(SELECT 1 FROM " + link.from + " a WHERE a.book_id=? AND a." + link.column +
			" IS NOT NULL AND NOT EXISTS(SELECT 1 FROM " + link.to + " b WHERE b.book_id=a.book_id AND b." + link.target + "=a." + link.column + "))"
		if err := tx.QueryRowContext(ctx, query, owner).Scan(&missing); err != nil {
			return err
		}
		if missing {
			return errInvestmentInvalid
		}
	}
	return nil
}
