package dbschema

import (
	"database/sql"
	"fmt"
)

// Upgrade runs the legacy migration at most once per database file.
func Upgrade(db *sql.DB, migrate func(*sql.Tx) error) (bool, error) {
	tx, err := db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return false, err
	}
	switch version {
	case 2:
		return false, nil
	case 0:
		if err := migrate(tx); err != nil {
			return false, err
		}
		var check string
		if err := tx.QueryRow("PRAGMA quick_check").Scan(&check); err != nil {
			return false, err
		}
		if check != "ok" {
			return false, fmt.Errorf("database integrity check failed: %s", check)
		}
		if _, err := tx.Exec("PRAGMA user_version = 2"); err != nil {
			return false, err
		}
		if err := tx.Commit(); err != nil {
			return false, err
		}
		return true, nil
	default:
		return false, fmt.Errorf("unsupported database schema version %d (expected 2)", version)
	}
}

func TableExists(tx *sql.Tx, name string) (bool, error) {
	var exists bool
	err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?)", name).Scan(&exists)
	return exists, err
}
