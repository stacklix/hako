package server

import (
	"database/sql"
	"fmt"
	"strings"
)

// One-time data upgrade, authorized with the precision change. Schema 7 records
// completion, so reopening the database never rewrites historical data again.
func upgradeInvestmentPrecision(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version != 6 {
		return nil
	}
	changedBooks := map[string]bool{}
	for _, table := range investmentTables {
		var numeric []string
		for _, column := range table.columns() {
			if strings.Contains(investmentNumberFields, " "+column+" ") {
				numeric = append(numeric, column)
			}
		}
		if len(numeric) == 0 {
			continue
		}
		keys := append([]string{"book_id"}, strings.Fields(table.keys)...)
		columns := append(append([]string{}, keys...), numeric...)
		rows, err := tx.Query("SELECT " + strings.Join(columns, ",") + " FROM " + table.name)
		if err != nil {
			return err
		}
		var changes []investmentRow
		for rows.Next() {
			values := make([]sql.NullString, len(columns))
			args := make([]any, len(columns))
			for i := range values {
				args[i] = &values[i]
			}
			if err := rows.Scan(args...); err != nil {
				rows.Close()
				return err
			}
			row := investmentRow{}
			for i, value := range values {
				if value.Valid {
					if i >= len(keys) && !investmentDecimal.MatchString(value.String) {
						rows.Close()
						return fmt.Errorf("invalid decimal in %s.%s", table.name, columns[i])
					}
					row[columns[i]] = value.String
				}
			}
			if normalizeInvestmentNumbers(row) {
				changes = append(changes, row)
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
		for _, row := range changes {
			var assignments, predicates []string
			var args []any
			for _, column := range numeric {
				if value, exists := row[column]; exists {
					assignments = append(assignments, column+"=?")
					args = append(args, value)
				}
			}
			if table.name == "market_daily_prices" || table.name == "market_daily_fx" {
				assignments = append(assignments, "revision=COALESCE(revision,0)+1")
			}
			for _, column := range keys {
				predicates = append(predicates, column+"=?")
				args = append(args, row[column])
			}
			if _, err := tx.Exec("UPDATE "+table.name+" SET "+strings.Join(assignments, ",")+" WHERE "+strings.Join(predicates, " AND "), args...); err != nil {
				return err
			}
			changedBooks[row["book_id"]] = changedBooks[row["book_id"]] || !table.output
		}
	}
	for book, inputsChanged := range changedBooks {
		if !inputsChanged {
			if _, err := tx.Exec("UPDATE investment_books SET generation=generation+1 WHERE id=?", book); err != nil {
				return err
			}
			continue
		}
		// Any changed input invalidates derived history, including currency conversion.
		_, err := tx.Exec(`UPDATE investment_books SET generation=generation+1, revision=revision+1,
			snapshot_dirty_from=(SELECT MIN(day) FROM (
				SELECT snapshot_dirty_from AS day FROM investment_books WHERE id=?
				UNION ALL SELECT effective_date FROM investment_events WHERE book_id=?
				UNION ALL SELECT snapshot_date FROM investment_daily_snapshots WHERE book_id=?
			)) WHERE id=?`, book, book, book, book)
		if err != nil {
			return err
		}
	}
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version=%d", investmentSchemaVersion)); err != nil {
		return err
	}
	return tx.Commit()
}
