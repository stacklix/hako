package server

import (
	"database/sql"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"
)

func migrationMarketRows(tx *sql.Tx, table string) ([]investmentRow, error) {
	rows, err := tx.Query("SELECT * FROM " + table + " ORDER BY book_id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	values := make([]sql.NullString, len(columns))
	args := make([]any, len(columns))
	for i := range args {
		args[i] = &values[i]
	}
	result := []investmentRow{}
	for rows.Next() {
		if err = rows.Scan(args...); err != nil {
			return nil, err
		}
		row := investmentRow{}
		for i, v := range values {
			if v.Valid {
				row[columns[i]] = v.String
			}
		}
		result = append(result, row)
	}
	return result, rows.Err()
}

func migrateGlobalInstruments(tx *sql.Tx) error {
	instruments, err := migrationMarketRows(tx, "market_instruments")
	if err != nil {
		return err
	}
	specs, err := migrationMarketRows(tx, "market_derivative_specs")
	if err != nil {
		return err
	}
	prices, err := migrationMarketRows(tx, "market_daily_prices")
	if err != nil {
		return err
	}
	_, err = tx.Exec(`CREATE TEMP TABLE investment_instrument_map(book_id TEXT,old_id TEXT,new_id TEXT,exchange TEXT,PRIMARY KEY(book_id,old_id)) WITHOUT ROWID;
	 CREATE TABLE market_instruments_next(id TEXT NOT NULL,asset_type TEXT,symbol TEXT,exchange TEXT,name TEXT,quote_currency TEXT,price_type TEXT,PRIMARY KEY(id)) WITHOUT ROWID;
	 CREATE TABLE market_derivative_specs_next(instrument_id TEXT NOT NULL,contract_multiplier TEXT,expiry_date TEXT,PRIMARY KEY(instrument_id)) WITHOUT ROWID;
	 CREATE TABLE market_daily_prices_next(instrument_id TEXT NOT NULL,session_date TEXT NOT NULL,price_type TEXT NOT NULL,source TEXT,closed_at_utc TEXT,valuation_date TEXT,price TEXT,is_final INTEGER,revision INTEGER,PRIMARY KEY(instrument_id,session_date,price_type)) WITHOUT ROWID;`)
	if err != nil {
		return err
	}
	mapping := map[string]string{}
	catalog := map[string]investmentRow{}
	sort.Slice(instruments, func(i, j int) bool {
		return instruments[i]["book_id"]+"\x00"+instruments[i]["id"] < instruments[j]["book_id"]+"\x00"+instruments[j]["id"]
	})
	for _, row := range instruments {
		canonical := canonicalInvestmentInstrument(row)
		id := canonical["id"]
		mapping[row["book_id"]+"\x00"+row["id"]] = id
		if _, err = tx.Exec("INSERT INTO investment_instrument_map VALUES(?,?,?,?)", row["book_id"], row["id"], id, row["exchange"]); err != nil {
			return err
		}
		if catalog[id] == nil {
			catalog[id] = canonical
		}
	}
	info, err := tx.Query("PRAGMA table_info(investment_assets)")
	if err != nil {
		return err
	}
	hasExchange := false
	for info.Next() {
		var n, notnull, pk int
		var name, kind string
		var value any
		if err = info.Scan(&n, &name, &kind, &notnull, &value, &pk); err != nil {
			info.Close()
			return err
		}
		if name == "exchange" {
			hasExchange = true
		}
	}
	if err = info.Err(); err != nil {
		info.Close()
		return err
	}
	info.Close()
	if !hasExchange {
		if _, err = tx.Exec("ALTER TABLE investment_assets ADD COLUMN exchange TEXT"); err != nil {
			return err
		}
	}
	for _, table := range []string{"investment_assets", "investment_watchlist"} {
		var missing bool
		if err = tx.QueryRow("SELECT EXISTS(SELECT 1 FROM " + table + " a WHERE instrument_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM investment_instrument_map m WHERE m.book_id=a.book_id AND m.old_id=a.instrument_id))").Scan(&missing); err != nil {
			return err
		}
		if missing {
			return fmt.Errorf("migrate public instruments: missing instrument reference in %s", table)
		}
		if table == "investment_assets" {
			if _, err = tx.Exec(`UPDATE investment_assets AS a SET exchange=(SELECT m.exchange FROM investment_instrument_map m WHERE m.book_id=a.book_id AND m.old_id=a.instrument_id) WHERE instrument_id IS NOT NULL`); err != nil {
				return err
			}
		}
		if _, err = tx.Exec("UPDATE " + table + " AS a SET instrument_id=(SELECT m.new_id FROM investment_instrument_map m WHERE m.book_id=a.book_id AND m.old_id=a.instrument_id) WHERE instrument_id IS NOT NULL"); err != nil {
			return err
		}
	}
	contracts := map[string]investmentRow{}
	for _, row := range specs {
		id := mapping[row["book_id"]+"\x00"+row["instrument_id"]]
		if id == "" {
			return fmt.Errorf("migrate public instruments: orphan contract")
		}
		row["instrument_id"] = id
		if previous := contracts[id]; previous != nil {
			left, lok := new(big.Rat).SetString(previous["contract_multiplier"])
			right, rok := new(big.Rat).SetString(row["contract_multiplier"])
			if !lok || !rok || left.Cmp(right) != 0 || previous["expiry_date"] != "" && row["expiry_date"] != "" && previous["expiry_date"] != row["expiry_date"] {
				return fmt.Errorf("migrate public instruments: conflicting contract specifications for %s", id)
			}
			if previous["expiry_date"] == "" {
				previous["expiry_date"] = row["expiry_date"]
			}
		} else {
			contracts[id] = row
		}
	}
	quotes := map[string]investmentRow{}
	for _, row := range prices {
		id := mapping[row["book_id"]+"\x00"+row["instrument_id"]]
		if id == "" {
			return fmt.Errorf("migrate public instruments: orphan price")
		}
		row["instrument_id"] = id
		amount, ok := new(big.Rat).SetString(row["price"])
		if !ok || amount.Sign() <= 0 {
			continue
		}
		key := investmentRowKey(row, strings.Fields(investmentTables[9].keys))
		if previous := quotes[key]; previous == nil || preferMigrationQuote(row, previous) {
			quotes[key] = row
		}
	}
	for _, item := range []struct {
		table  investmentTable
		values map[string]investmentRow
	}{{investmentTables[0], catalog}, {investmentTables[1], contracts}, {investmentTables[9], quotes}} {
		columns := item.table.columns()
		for _, row := range item.values {
			args := make([]any, len(columns))
			for i, key := range columns {
				if v, ok := row[key]; ok {
					args[i] = v
				}
			}
			if _, err = tx.Exec("INSERT INTO "+item.table.name+"_next("+strings.Join(columns, ",")+") VALUES (?"+strings.Repeat(",?", len(columns)-1)+")", args...); err != nil {
				return err
			}
		}
	}
	_, err = tx.Exec(`DROP TABLE market_daily_prices;DROP TABLE market_derivative_specs;DROP TABLE market_instruments;
	 ALTER TABLE market_instruments_next RENAME TO market_instruments;
	 ALTER TABLE market_derivative_specs_next RENAME TO market_derivative_specs;
	 ALTER TABLE market_daily_prices_next RENAME TO market_daily_prices;
	 DROP TABLE investment_instrument_map;`)
	return err
}

func preferMigrationQuote(next, previous investmentRow) bool {
	if (next["is_final"] == "1") != (previous["is_final"] == "1") {
		return next["is_final"] == "1"
	}
	a, _ := time.Parse(time.RFC3339Nano, next["closed_at_utc"])
	b, _ := time.Parse(time.RFC3339Nano, previous["closed_at_utc"])
	if !a.Equal(b) {
		return a.After(b)
	}
	if next["source"] != previous["source"] {
		return next["source"] > previous["source"]
	}
	return next["book_id"] > previous["book_id"]
}
