package server

import "database/sql"

// TODO(next iteration): remove this schema-5 migration and its startup call after
// deployment. Schema 6 reads month-end balances from investment_daily_snapshots.
func migrateInvestmentMonthSnapshots(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err = tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version != 5 {
		return nil
	}
	// Only derived monthly totals are retired; daily snapshots and source records
	// remain untouched. Advance generation so existing disk copies are refreshed.
	if _, err = tx.Exec(`DROP TABLE investment_month_snapshots;
		UPDATE investment_books SET generation = generation + 1;
		PRAGMA user_version = 6;`); err != nil {
		return err
	}
	return tx.Commit()
}
