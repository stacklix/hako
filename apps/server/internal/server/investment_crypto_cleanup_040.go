package server

import (
	"database/sql"
	"fmt"
)

// TEMPORARY 0.4.0 migration. Delete this file, its test and the startup call in the NEXT RELEASE.
// The permanent schema version remains 3; installations must run 0.4.0 once first.
// All data deletion, snapshot invalidation and column removal commit atomically.
func migrateInvestmentCrypto040(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version != 2 {
		return nil // Fresh/current/unsupported versions are handled by InitializeVersion.
	}
	statements := []string{
		`CREATE TEMP TABLE removed_crypto_assets AS
		 SELECT book_id,id FROM investment_assets WHERE asset_type='crypto_contract'
		 OR EXISTS(SELECT 1 FROM market_instruments i WHERE i.book_id=investment_assets.book_id
		 AND i.id=investment_assets.instrument_id AND i.asset_type='crypto_contract')`,
		`CREATE TEMP TABLE removed_crypto_events AS
		 SELECT book_id,id FROM investment_events e WHERE event_type='derivative_funding'
		 OR EXISTS(SELECT 1 FROM removed_crypto_assets a WHERE a.book_id=e.book_id AND a.id=e.asset_id)`,
		`CREATE TEMP TABLE removed_crypto_plans AS
		 SELECT book_id,id FROM investment_plans p WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_assets a WHERE a.book_id=p.book_id AND a.id=p.asset_id)`,
		`CREATE TEMP TABLE affected_crypto_books AS SELECT book_id FROM removed_crypto_assets
		 UNION SELECT book_id FROM removed_crypto_events
		 UNION SELECT book_id FROM market_instruments WHERE asset_type='crypto_contract'`,
		`DELETE FROM investment_plan_runs AS r WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_plans p WHERE p.book_id=r.book_id AND p.id=r.plan_id)
		 OR EXISTS(SELECT 1 FROM removed_crypto_events e WHERE e.book_id=r.book_id AND e.id=r.event_id)`,
		`DELETE FROM investment_plans AS p WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_plans r WHERE r.book_id=p.book_id AND r.id=p.id)`,
		`DELETE FROM investment_derivative_event_details AS d WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_events e WHERE e.book_id=d.book_id AND e.id=d.event_id)`,
		`DELETE FROM investment_events AS e WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_events r WHERE r.book_id=e.book_id AND r.id=e.id)`,
		`DELETE FROM investment_manual_prices AS p WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_assets a WHERE a.book_id=p.book_id AND a.id=p.asset_id)`,
		`DELETE FROM investment_watchlist AS w WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_assets a WHERE a.book_id=w.book_id AND a.id=w.asset_id)
		 OR EXISTS(SELECT 1 FROM market_instruments i WHERE i.book_id=w.book_id AND i.id=w.instrument_id AND i.asset_type='crypto_contract')`,
		`DELETE FROM investment_assets AS a WHERE EXISTS
		 (SELECT 1 FROM removed_crypto_assets r WHERE r.book_id=a.book_id AND r.id=a.id)`,
		`DELETE FROM market_daily_prices AS p WHERE EXISTS
		 (SELECT 1 FROM market_instruments i WHERE i.book_id=p.book_id AND i.id=p.instrument_id AND i.asset_type='crypto_contract')`,
		`DELETE FROM market_derivative_specs AS s WHERE EXISTS
		 (SELECT 1 FROM market_instruments i WHERE i.book_id=s.book_id AND i.id=s.instrument_id AND i.asset_type='crypto_contract')`,
		`DELETE FROM market_instruments WHERE asset_type='crypto_contract'`,
		`DELETE FROM investment_daily_snapshots WHERE book_id IN (SELECT book_id FROM affected_crypto_books)`,
		`DELETE FROM investment_account_daily_snapshots WHERE book_id IN (SELECT book_id FROM affected_crypto_books)`,
		`DELETE FROM investment_month_snapshots WHERE book_id IN (SELECT book_id FROM affected_crypto_books)`,
		`UPDATE investment_books SET snapshot_through=NULL,
		 snapshot_dirty_from=(SELECT MIN(effective_date) FROM investment_events WHERE book_id=investment_books.id)
		 WHERE id IN (SELECT book_id FROM affected_crypto_books)`,
		// Invalidate every pre-migration writer, including books without contract holdings.
		`UPDATE investment_books SET generation=generation+1, revision=revision+1`,
		`ALTER TABLE investment_assets DROP COLUMN collateral_asset_id`,
		`ALTER TABLE market_derivative_specs DROP COLUMN pricing_model`,
		`ALTER TABLE market_derivative_specs DROP COLUMN settlement_basis`,
		`ALTER TABLE market_derivative_specs DROP COLUMN settlement_unit`,
		`ALTER TABLE investment_derivative_event_details DROP COLUMN funding_target`,
		`ALTER TABLE investment_derivative_event_details DROP COLUMN settlement_to_account_rate`,
		`DROP TABLE removed_crypto_assets`,
		`DROP TABLE removed_crypto_events`,
		`DROP TABLE removed_crypto_plans`,
		`DROP TABLE affected_crypto_books`,
		fmt.Sprintf("PRAGMA user_version=%d", investmentSchemaVersion),
	}
	for _, statement := range statements {
		if _, err := tx.Exec(statement); err != nil {
			return fmt.Errorf("investment 0.4 crypto cleanup: %w", err)
		}
	}
	return tx.Commit()
}
