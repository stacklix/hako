package server

import "database/sql"

// One-release bridge for schema 4. Remove in the next iteration after deployment.
// Account IDs, source records and valuation snapshots remain unchanged.
func upgradeInvestmentFundWealthAccounts(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version != 4 {
		return nil
	}
	_, err = tx.Exec(`CREATE TABLE investment_accounts_v5 (
		book_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT,
		account_type TEXT CHECK(account_type IN (` + investmentAccountTypesSQL + `)),
		currency TEXT, sort_order INTEGER, archived_at TEXT,
		PRIMARY KEY(book_id,id)
	) WITHOUT ROWID;
	INSERT INTO investment_accounts_v5(book_id,id,name,account_type,currency,sort_order,archived_at)
		SELECT book_id,id,name,CASE WHEN account_type IN ('fund','wealth') THEN 'fund_wealth' ELSE account_type END,
			currency,sort_order,archived_at FROM investment_accounts;
	UPDATE investment_books SET generation=generation+1
		WHERE id IN (SELECT book_id FROM investment_accounts WHERE account_type IN ('fund','wealth'));
	DROP TABLE investment_accounts;
	ALTER TABLE investment_accounts_v5 RENAME TO investment_accounts;
	PRAGMA user_version=5;`)
	if err != nil {
		return err
	}
	return tx.Commit()
}
