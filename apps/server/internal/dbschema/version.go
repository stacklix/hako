package dbschema

import (
	"database/sql"
	"fmt"
)

const CurrentVersion = 2

// Initialize creates the current schema only in an empty database.
func Initialize(db *sql.DB, create func(*sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	switch version {
	case CurrentVersion:
		return nil
	case 0:
		var populated bool
		if err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*')").Scan(&populated); err != nil {
			return err
		}
		if populated {
			return fmt.Errorf("database has not been migrated: start Hako from migration commit 957cbb2 once before upgrading")
		}
		if err := create(tx); err != nil {
			return err
		}
		if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", CurrentVersion)); err != nil {
			return err
		}
		return tx.Commit()
	default:
		return fmt.Errorf("unsupported database schema version %d (expected %d)", version, CurrentVersion)
	}
}
