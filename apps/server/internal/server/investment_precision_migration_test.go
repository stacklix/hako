package server

import (
	"path/filepath"
	"testing"
)

func TestInvestmentPrecisionUpgradeIsAtomicAndRunsOnce(t *testing.T) {
	for _, invalid := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "rollback"}[invalid], func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "main.sqlite")
			db, err := openInvestmentDB(path)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			_, err = db.Exec(`
				INSERT INTO investment_books(owner_id,id,generation,revision,snapshot_dirty_from,snapshot_through)
				VALUES('owner','book',7,3,'2026-11-15','2026-11-17');
				INSERT INTO investment_events(book_id,id,account_id,event_type,effective_date,sequence,amount,quantity,unit_price,fee)
				VALUES('book','event','account','buy','2024-01-01',0,'1000.123456','0.00123456','12.345','0.00567');
				INSERT INTO market_daily_fx(book_id,rate_date,base_currency,quote_currency,source,rate,revision)
				VALUES('book','2026-11-17','USD','CNY','test','7.123456',2);
				INSERT INTO investment_daily_snapshots(book_id,snapshot_date,total_cny,cumulative_gain_cny,status,computed_revision)
				VALUES('book','2026-11-17','461884.8840618873546','-100.345','complete',3);
				PRAGMA user_version=6;`)
			if err != nil {
				t.Fatal(err)
			}
			if invalid {
				if _, err := db.Exec("UPDATE market_daily_fx SET rate='broken'"); err != nil {
					t.Fatal(err)
				}
			}
			err = upgradeInvestmentPrecision(db)
			var version, generation, revision int
			var amount, quantity, price, fee, total, dirty, fx string
			check := func() {
				t.Helper()
				if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
					t.Fatal(err)
				}
				if err := db.QueryRow("SELECT generation,revision,snapshot_dirty_from FROM investment_books").Scan(&generation, &revision, &dirty); err != nil {
					t.Fatal(err)
				}
				if err := db.QueryRow("SELECT amount,quantity,unit_price,fee FROM investment_events").Scan(&amount, &quantity, &price, &fee); err != nil {
					t.Fatal(err)
				}
				if err := db.QueryRow("SELECT total_cny FROM investment_daily_snapshots").Scan(&total); err != nil {
					t.Fatal(err)
				}
				if err := db.QueryRow("SELECT rate FROM market_daily_fx").Scan(&fx); err != nil {
					t.Fatal(err)
				}
			}
			check()
			if invalid {
				if err == nil || version != 6 || generation != 7 || revision != 3 || amount != "1000.123456" || total != "461884.8840618873546" {
					t.Fatalf("migration was not rolled back: %v %d/%d/%d %s %s", err, version, generation, revision, amount, total)
				}
				return
			}
			if err != nil || version != 7 || generation != 8 || revision != 4 || dirty != "2024-01-01" || amount != "1000.12" || quantity != "0.0012" || price != "12.35" || fee != "0.0057" || total != "461884.88" || fx != "7.1235" {
				t.Fatalf("migration = %v %d/%d/%d %s %s/%s/%s/%s %s %s", err, version, generation, revision, dirty, amount, quantity, price, fee, total, fx)
			}
			// Reopen through the real startup path: no second rewrite or generation bump.
			db.Close()
			db, err = openInvestmentDB(path)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			check()
			if generation != 8 || revision != 4 || version != 7 {
				t.Fatal("migration ran twice")
			}
		})
	}
}
