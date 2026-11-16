package server

import (
	"database/sql"
	"fmt"
)

// Investment is a separate SQLite database with its own schema version.
const investmentSchemaVersion = 5

const investmentAccountTypesSQL = "'securities','fund_wealth','futures','deposits','crypto','insurance'"

// Existing ledgers can adopt the new schedule schema when they have no plans to convert.
func upgradeEmptyInvestmentPlans(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version != 3 {
		return nil
	}
	var count int
	if err := tx.QueryRow("SELECT (SELECT COUNT(*) FROM investment_plans) + (SELECT COUNT(*) FROM investment_plan_runs)").Scan(&count); err != nil {
		return err
	}
	if count != 0 {
		return fmt.Errorf("investment schema 3 still contains recurring plans or runs; remove them before upgrading to schema 4 (no data was changed)")
	}
	if _, err := tx.Exec(`ALTER TABLE investment_plans RENAME COLUMN month_day TO schedule_day;
		ALTER TABLE investment_plans ADD COLUMN frequency TEXT;
		PRAGMA user_version = 4;`); err != nil {
		return err
	}
	return tx.Commit()
}
