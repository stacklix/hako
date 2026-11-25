package server

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
)

// Investment is a separate SQLite database with its own schema version.
const investmentSchemaVersion = 9

const investmentAccountTypesSQL = "'securities','fund_wealth','futures','deposits','crypto','insurance'"

func finalInvestmentFX(row investmentRow) bool {
	if row["is_final"] != "1" {
		return false
	}
	rate, ok := new(big.Rat).SetString(row["rate"])
	return ok && rate.Sign() > 0
}

func equalInvestmentNumber(left, right string) bool {
	a, aOK := new(big.Rat).SetString(left)
	b, bOK := new(big.Rat).SetString(right)
	return aOK && bOK && a.Cmp(b) == 0
}

// The approved v7 migration removes the ledger and provider from FX identity, keeping the
// previously preferred positive observation (final, then latest publication).
// All DDL, data and version changes commit together; startup failures roll back.
func migrateInvestmentMarket(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err = tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version != 7 && version != 8 {
		return nil
	}
	if version == 7 {
		_, err = tx.Exec(`CREATE TABLE market_daily_fx_next (
		rate_date TEXT NOT NULL, base_currency TEXT NOT NULL,
		quote_currency TEXT NOT NULL, rate TEXT, source TEXT, available_at_utc TEXT,
		is_final INTEGER, revision INTEGER,
		PRIMARY KEY(rate_date,base_currency,quote_currency)
	) WITHOUT ROWID;
	INSERT INTO market_daily_fx_next
	SELECT rate_date,base_currency,quote_currency,rate,source,available_at_utc,is_final,revision FROM (
		SELECT *,ROW_NUMBER() OVER (
			PARTITION BY rate_date,base_currency,quote_currency
			ORDER BY COALESCE(is_final,0) DESC,COALESCE(available_at_utc,'') DESC,source DESC,book_id DESC
		) AS preference FROM market_daily_fx WHERE CAST(rate AS REAL)>0
	) WHERE preference=1;
	DROP TABLE market_daily_fx;
	ALTER TABLE market_daily_fx_next RENAME TO market_daily_fx;`)
		if err != nil {
			return fmt.Errorf("migrate investment FX: %w", err)
		}
	}
	if err = migrateGlobalInstruments(tx); err != nil {
		return err
	}
	if _, err = tx.Exec(`UPDATE investment_books SET generation=generation+1,revision=revision+1,
		snapshot_dirty_from=(SELECT MIN(day) FROM (
		 SELECT snapshot_dirty_from AS day UNION ALL SELECT MIN(effective_date) FROM investment_events WHERE book_id=investment_books.id
		 UNION ALL SELECT MIN(rate_date) FROM market_daily_fx UNION ALL SELECT MIN(valuation_date) FROM market_daily_prices
		))`); err != nil {
		return err
	}
	if _, err = tx.Exec("PRAGMA user_version=9"); err != nil {
		return err
	}
	return tx.Commit()
}

func investmentChangesCount(ctx context.Context, tx *sql.Tx) (int64, error) {
	var count int64
	err := tx.QueryRowContext(ctx, "SELECT total_changes()").Scan(&count)
	return count, err
}

func earliestMarketDate(rows []investmentRow) string {
	first := ""
	for _, row := range rows {
		day := row["rate_date"]
		if day == "" {
			day = row["valuation_date"]
		}
		if day == "" {
			day = row["session_date"]
		}
		if day != "" && (first == "" || day < first) {
			first = day
		}
	}
	return first
}

// Shared FX can change every ledger's valuation, including ledgers that did
// not make the request. Leave the caller's metadata to its normal transaction.
func invalidateSharedFX(ctx context.Context, tx *sql.Tx, caller, from string) error {
	_, err := tx.ExecContext(ctx, `UPDATE investment_books SET revision=revision+1,
		snapshot_dirty_from=CASE WHEN snapshot_dirty_from IS NULL OR snapshot_dirty_from>? THEN ? ELSE snapshot_dirty_from END
		WHERE id<>?`, from, from, caller)
	return err
}
