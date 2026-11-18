package server

import (
	"path/filepath"
	"testing"
)

func TestInvestmentMonthlyMigrationRetainsDailySnapshotsAndRunsOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`CREATE TABLE investment_month_snapshots(book_id TEXT, snapshot_date TEXT, total_cny TEXT);
 INSERT INTO investment_month_snapshots VALUES('book','2026-10-31','999');
 INSERT INTO investment_books(owner_id,id,generation,revision) VALUES('owner','book',7,3);
 INSERT INTO investment_daily_snapshots(book_id,snapshot_date,total_cny,status,computed_revision) VALUES('book','2026-10-31','100.123456789012345678','complete',3);
 PRAGMA user_version=5;`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	for range 2 {
		db, err = openInvestmentDB(path)
		if err != nil {
			t.Fatal(err)
		}
		var count, generation int
		var total string
		if err = db.QueryRow("SELECT COUNT(*) FROM sqlite_schema WHERE name='investment_month_snapshots'").Scan(&count); err != nil || count != 0 {
			t.Fatalf("retired table: %d %v", count, err)
		}
		if err = db.QueryRow("SELECT total_cny FROM investment_daily_snapshots").Scan(&total); err != nil || total != "100.123456789012345678" {
			t.Fatalf("daily data changed: %s %v", total, err)
		}
		if err = db.QueryRow("SELECT generation FROM investment_books").Scan(&generation); err != nil || generation != 8 {
			t.Fatalf("migration ran more than once: %d %v", generation, err)
		}
		db.Close()
	}
}
