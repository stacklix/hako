package server

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
)

func TestInvestmentCryptoCleanup040MustBeRemovedNextRelease(t *testing.T) {
	if releaseVersion != "0.4.0" {
		t.Fatal("Remove investment_crypto_cleanup_040.go, this test file and the startup call before the next release; keep schema 3")
	}
}

func cryptoCleanupFixture040(t *testing.T) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	for _, statement := range []string{
		`ALTER TABLE investment_assets ADD COLUMN collateral_asset_id TEXT`,
		`ALTER TABLE market_derivative_specs ADD COLUMN pricing_model TEXT`,
		`ALTER TABLE market_derivative_specs ADD COLUMN settlement_basis TEXT`,
		`ALTER TABLE market_derivative_specs ADD COLUMN settlement_unit TEXT`,
		`ALTER TABLE investment_derivative_event_details ADD COLUMN funding_target TEXT`,
		`ALTER TABLE investment_derivative_event_details ADD COLUMN settlement_to_account_rate TEXT`,
		`PRAGMA user_version=2`,
		`INSERT INTO investment_books(owner_id,id,generation,revision,snapshot_through) VALUES('owner','book',7,4,'2026-11-12'),('other','other',2,1,'2026-11-12')`,
		`INSERT INTO investment_accounts(book_id,id) VALUES('book','cash'),('other','cash')`,
		`INSERT INTO market_instruments(book_id,id,asset_type) VALUES('book','contract','crypto_contract'),('book','future','future'),('book','spot','crypto'),('other','contract','crypto')`,
		`INSERT INTO investment_assets(book_id,id,instrument_id,asset_type,collateral_asset_id,position_side) VALUES
		 ('book','contract','contract','crypto_contract','spot','short'),('book','future','future','future',NULL,'short'),
		 ('book','spot','spot','crypto',NULL,NULL),('other','contract','contract','crypto',NULL,NULL)`,
		`INSERT INTO investment_events(book_id,id,account_id,asset_id,event_type,effective_date,amount,quantity) VALUES
		 ('book','deposit','cash',NULL,'deposit','2026-11-01','9007199254740993.0001',NULL),
		 ('book','trade','cash','contract','derivative_trade','2026-11-02','0','1'),
		 ('book','funding','cash','contract','derivative_funding','2026-11-03','-10',NULL),
		 ('book','future-trade','cash','future','derivative_trade','2026-11-04','0','2'),
		 ('book','spot-buy','cash','spot','buy','2026-11-05','0','1.00000001'),
		 ('other','trade','cash','contract','buy','2026-11-02','0','3')`,
		`INSERT INTO investment_derivative_event_details(book_id,event_id,trade_action,margin_delta,funding_target,settlement_to_account_rate) VALUES
		 ('book','trade','open_short','50',NULL,'0.3'),('book','funding',NULL,NULL,'account_available','0.3'),('book','future-trade','open_short','1000',NULL,NULL)`,
		`INSERT INTO market_derivative_specs(book_id,instrument_id,contract_multiplier,pricing_model,settlement_basis,settlement_unit) VALUES
		 ('book','contract','10','inverse','coin','TRX'),('book','future','5','linear','cash','CNY')`,
		`INSERT INTO investment_plans(book_id,id,account_id,asset_id) VALUES('book','bad-plan','cash','contract'),('book','spot-plan','cash','spot')`,
		`INSERT INTO investment_plan_runs(book_id,plan_id,scheduled_date,event_id) VALUES('book','bad-plan','2026-11-02','trade'),('book','spot-plan','2026-11-05','spot-buy')`,
		`INSERT INTO investment_watchlist(book_id,asset_id,instrument_id) VALUES('book','contract','contract'),('book','spot','spot')`,
		`INSERT INTO investment_manual_prices(book_id,asset_id,valuation_date,value) VALUES('book','contract','2026-11-12','2'),('book','spot','2026-11-12','3')`,
		`INSERT INTO market_daily_prices(book_id,instrument_id,session_date,price_type,source,price) VALUES
		 ('book','contract','2026-11-12','mark','test','2'),('book','spot','2026-11-12','close','test','3')`,
		`INSERT INTO investment_daily_snapshots(book_id,snapshot_date,total_cny) VALUES('book','2026-11-12','1'),('other','2026-11-12','2')`,
		`INSERT INTO investment_account_daily_snapshots(book_id,account_id,snapshot_date) VALUES('book','cash','2026-11-12')`,
		`INSERT INTO investment_month_snapshots(book_id,snapshot_date,total_cny) VALUES('book','2026-10-31','1')`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	return db, path
}

func TestInvestmentCryptoCleanup040RunsOnStartupAndOnlyOnce(t *testing.T) {
	db, path := cryptoCleanupFixture040(t)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, query := range []string{
		`SELECT count(*) FROM investment_assets WHERE book_id='book' AND id='contract'`,
		`SELECT count(*) FROM investment_events WHERE book_id='book' AND id IN ('trade','funding')`,
		`SELECT count(*) FROM market_instruments WHERE asset_type='crypto_contract'`,
		`SELECT count(*) FROM market_derivative_specs WHERE instrument_id='contract'`,
		`SELECT count(*) FROM investment_derivative_event_details WHERE event_id IN ('trade','funding')`,
		`SELECT count(*) FROM investment_plans WHERE id='bad-plan'`,
		`SELECT count(*) FROM investment_plan_runs WHERE plan_id='bad-plan'`,
		`SELECT count(*) FROM investment_watchlist WHERE asset_id='contract'`,
		`SELECT count(*) FROM investment_manual_prices WHERE asset_id='contract'`,
		`SELECT count(*) FROM market_daily_prices WHERE instrument_id='contract'`,
		`SELECT count(*) FROM investment_daily_snapshots WHERE book_id='book'`,
		`SELECT count(*) FROM investment_account_daily_snapshots WHERE book_id='book'`,
		`SELECT count(*) FROM investment_month_snapshots WHERE book_id='book'`,
	} {
		var count int
		if err := db.QueryRow(query).Scan(&count); err != nil || count != 0 {
			t.Fatalf("%s: %d %v", query, count, err)
		}
	}
	for query, expected := range map[string]string{
		`SELECT amount FROM investment_events WHERE book_id='book' AND id='deposit'`:                 "9007199254740993.0001",
		`SELECT quantity FROM investment_events WHERE book_id='book' AND id='spot-buy'`:              "1.00000001",
		`SELECT quantity FROM investment_events WHERE book_id='other' AND id='trade'`:                "3",
		`SELECT contract_multiplier FROM market_derivative_specs WHERE instrument_id='future'`:       "5",
		`SELECT trade_action FROM investment_derivative_event_details WHERE event_id='future-trade'`: "open_short",
		`SELECT total_cny FROM investment_daily_snapshots WHERE book_id='other'`:                     "2",
		`SELECT snapshot_dirty_from FROM investment_books WHERE id='book'`:                           "2026-11-01",
		`SELECT generation FROM investment_books WHERE id='book'`:                                    "8",
		`SELECT revision FROM investment_books WHERE id='book'`:                                      "5",
		`PRAGMA user_version`: "3",
	} {
		var got string
		if err := db.QueryRow(query).Scan(&got); err != nil || got != expected {
			t.Fatalf("%s: %s %v", query, got, err)
		}
	}
	for table, columns := range map[string][]string{
		"investment_assets":                   {"collateral_asset_id"},
		"market_derivative_specs":             {"pricing_model", "settlement_basis", "settlement_unit"},
		"investment_derivative_event_details": {"funding_target", "settlement_to_account_rate"},
	} {
		var schema string
		if err := db.QueryRow("SELECT sql FROM sqlite_schema WHERE name=?", table).Scan(&schema); err != nil {
			t.Fatal(err)
		}
		for _, column := range columns {
			if strings.Contains(schema, column) {
				t.Fatalf("obsolete column %s remains in %s", column, table)
			}
		}
	}
	if err := migrateInvestmentCrypto040(db); err != nil {
		t.Fatal(err)
	}
	var generation int
	if err := db.QueryRow("SELECT generation FROM investment_books WHERE id='book'").Scan(&generation); err != nil || generation != 8 {
		t.Fatalf("migration repeated: %d %v", generation, err)
	}
}

func TestInvestmentCryptoCleanup040RollsBackOnSchemaFailure(t *testing.T) {
	db, _ := cryptoCleanupFixture040(t)
	if _, err := db.Exec("ALTER TABLE investment_derivative_event_details DROP COLUMN settlement_to_account_rate"); err != nil {
		t.Fatal(err)
	}
	if err := migrateInvestmentCrypto040(db); err == nil {
		t.Fatal("expected migration failure")
	}
	var version, count int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatalf("version %d %v", version, err)
	}
	if err := db.QueryRow("SELECT count(*) FROM investment_assets WHERE asset_type='crypto_contract'").Scan(&count); err != nil || count != 1 {
		t.Fatalf("deletion was not rolled back: %d %v", count, err)
	}
	if _, err := db.Exec("ALTER TABLE investment_derivative_event_details ADD COLUMN settlement_to_account_rate TEXT"); err != nil {
		t.Fatal(err)
	}
	if err := migrateInvestmentCrypto040(db); err != nil {
		t.Fatal(err)
	}
}
