package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"hako/server/internal/dbschema"
)

func TestInvestmentDatabaseRejectsUnsupportedSchemaWithoutChangingRecords(t *testing.T) {
	for _, version := range []int{2, 3, 4, 5, 6, 7, 8, 11} {
		t.Run(fmt.Sprintf("schema_%d", version), func(t *testing.T) {
			testInvestmentDatabaseRejectsSchema(t, version)
		})
	}
}

func testInvestmentDatabaseRejectsSchema(t *testing.T, originalVersion int) {
	t.Helper()
	directory := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(directory, "investment.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`
		CREATE TABLE investment_assets (id TEXT PRIMARY KEY, asset_type TEXT, collateral_asset_id TEXT);
		INSERT INTO investment_assets VALUES ('legacy', 'crypto_contract', 'spot');
	`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(fmt.Sprintf("PRAGMA user_version=%d", originalVersion)); err != nil {
		t.Fatal(err)
	}
	var originalSchema string
	if err := db.QueryRow("SELECT sql FROM sqlite_schema WHERE name='investment_assets'").Scan(&originalSchema); err != nil {
		t.Fatal(err)
	}
	opened, err := openInvestmentDB(filepath.Join(directory, "main.sqlite"))
	if opened != nil {
		opened.Close()
		t.Fatal("old schema was opened")
	}
	if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("unsupported database schema version %d (expected %d)", originalVersion, investmentSchemaVersion)) {
		t.Fatalf("old schema error = %v", err)
	}
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != originalVersion {
		t.Fatalf("old schema version changed: %d (%v)", version, err)
	}
	var schema, assetType, collateral string
	if err := db.QueryRow("SELECT sql FROM sqlite_schema WHERE name='investment_assets'").Scan(&schema); err != nil || schema != originalSchema {
		t.Fatalf("old table definition changed: %q (%v)", schema, err)
	}
	if err := db.QueryRow("SELECT asset_type,collateral_asset_id FROM investment_assets WHERE id='legacy'").Scan(&assetType, &collateral); err != nil || assetType != "crypto_contract" || collateral != "spot" {
		t.Fatalf("old records changed: %s %s (%v)", assetType, collateral, err)
	}
}

func TestInvestmentCurrentSchemaReopensWithoutChangingLedger(t *testing.T) {
	for _, version := range []int{9, investmentSchemaVersion} {
		t.Run(fmt.Sprintf("schema_%d", version), func(t *testing.T) {
			testInvestmentSchemaReopensWithoutChangingLedger(t, version)
		})
	}
}

func testInvestmentSchemaReopensWithoutChangingLedger(t *testing.T, originalVersion int) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if db != nil {
			db.Close()
		}
	})
	if _, err := db.Exec(`INSERT INTO investment_books(owner_id,id,generation,revision,snapshot_through)
		VALUES('owner','book',7,3,'2026-11-15');
		INSERT INTO investment_accounts(book_id,id,name,account_type,currency,sort_order,archived_at)
		VALUES('book','account','基金理财','fund_wealth','CNY',0,'2026-11-16T00:00:00Z');
		INSERT INTO market_instruments(id,asset_type,symbol,exchange,name,quote_currency,price_type)
		VALUES('STOCK:HK:00700.HK:HKD','stock','00700.HK','XHKG','腾讯','HKD','close');
		INSERT INTO investment_assets(book_id,id,instrument_id,name,asset_type,settlement_unit,exchange)
		VALUES('book','asset','STOCK:HK:00700.HK:HKD','腾讯','stock','CNY','HK_CONNECT');
		INSERT INTO investment_watchlist(book_id,asset_id,instrument_id,sort_order)
		VALUES('book','asset','STOCK:HK:00700.HK:HKD',0);
		INSERT INTO market_daily_prices(instrument_id,session_date,price_type,source,price,is_final)
		VALUES('STOCK:HK:00700.HK:HKD','2026-11-15','close','行情源','300.1234',1);
		INSERT INTO market_daily_fx(rate_date,base_currency,quote_currency,rate,source,is_final)
		VALUES('2026-11-15','HKD','CNY','0.912345678901234567','欧洲央行',1);
		INSERT INTO investment_events(book_id,id,account_id,event_type,effective_date,amount)
		VALUES('book','event','account','deposit','2026-11-15','100.123456789012345678');
		INSERT INTO investment_plans(book_id,id,account_id,amount,frequency,schedule_day,next_date,enabled)
		VALUES('book','plan','account','100','monthly',1,'2026-12-01',1);
		INSERT INTO investment_plan_runs(book_id,plan_id,scheduled_date,status,event_id)
		VALUES('book','plan','2026-11-01','executed','event');
		INSERT INTO investment_daily_snapshots(book_id,snapshot_date,total_cny,status,computed_revision)
		VALUES('book','2026-11-15','100.123456789012345678','complete',3);`); err != nil {
		t.Fatal(err)
	}
	schema, err := dbschema.Inspect(context.Background(), db)
	if err != nil || schema.Version != investmentSchemaVersion || len(schema.Tables) != len(investmentTables)+2 {
		t.Fatalf("initialized schema = %+v (%v)", schema, err)
	}
	contents := func() string {
		t.Helper()
		tx, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		tables := investmentRows{}
		for _, table := range investmentTables {
			rows, err := table.read(context.Background(), tx, "book")
			if err != nil {
				t.Fatal(err)
			}
			tables[table.name] = rows
		}
		data, err := json.Marshal(tables)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	before := contents()
	if originalVersion == 9 {
		// Schema 9 has the same ledger tables but no trading calendar table.
		if _, err := db.Exec("DROP TABLE market_trading_calendars; PRAGMA user_version=9"); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	afterSchema, err := dbschema.Inspect(context.Background(), db)
	if err != nil || !reflect.DeepEqual(schema, afterSchema) || contents() != before {
		t.Fatalf("reopening changed the schema or ledger: %v", err)
	}
	var generation, revision int
	var through string
	if err := db.QueryRow("SELECT generation,revision,snapshot_through FROM investment_books WHERE id='book'").Scan(&generation, &revision, &through); err != nil || generation != 7 || revision != 3 || through != "2026-11-15" {
		t.Fatalf("book metadata changed: %d/%d/%s (%v)", generation, revision, through, err)
	}
	for _, retired := range []string{"fund", "wealth", "unknown"} {
		if _, err := db.Exec("UPDATE investment_accounts SET account_type=? WHERE id='account'", retired); err == nil {
			t.Fatalf("schema accepted account type %q", retired)
		}
	}
	if _, err := db.Exec(`INSERT INTO market_trading_calendars
		(market,year,trading_days,source,updated_at,updated_by,revision)
		VALUES('CN_A',2026,?,'test','2026-11-26T00:00:00Z','agent',1)`, strings.Repeat("1", 365)); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	var days string
	if err := db.QueryRow("SELECT trading_days FROM market_trading_calendars WHERE market='CN_A' AND year=2026").Scan(&days); err != nil || days != strings.Repeat("1", 365) || contents() != before {
		t.Fatalf("reopening changed calendars or ledger: %q (%v)", days, err)
	}
}

func TestInvestmentCalendarMigrationFailurePreservesSchemaAndCanRetry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// A conflicting object must fail rather than silently skip calendar creation.
	if _, err := db.Exec(`DROP TABLE market_trading_calendars;
		CREATE VIEW market_trading_calendars AS SELECT 'preserved' AS value;
		INSERT INTO investment_books(owner_id,id,generation,revision) VALUES('owner','book',7,3);
		PRAGMA user_version=9;`); err != nil {
		t.Fatal(err)
	}
	before, err := dbschema.Inspect(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := openInvestmentDB(path)
	if opened != nil {
		opened.Close()
		t.Fatal("conflicting schema was opened")
	}
	if err == nil || !strings.Contains(err.Error(), "migrate investment calendars") {
		t.Fatalf("migration error = %v", err)
	}
	after, err := dbschema.Inspect(context.Background(), db)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("failed migration changed schema or version: %+v (%v)", after, err)
	}
	var value string
	if err := db.QueryRow("SELECT value FROM market_trading_calendars").Scan(&value); err != nil || value != "preserved" {
		t.Fatalf("conflicting object changed: %q (%v)", value, err)
	}
	var generation, revision int
	if err := db.QueryRow("SELECT generation,revision FROM investment_books WHERE id='book'").Scan(&generation, &revision); err != nil || generation != 7 || revision != 3 {
		t.Fatalf("failed migration changed book: %d/%d (%v)", generation, revision, err)
	}
	if _, err := db.Exec("DROP VIEW market_trading_calendars"); err != nil {
		t.Fatal(err)
	}
	opened, err = openInvestmentDB(path)
	if err != nil {
		t.Fatalf("retry migration: %v", err)
	}
	defer opened.Close()
	after, err = dbschema.Inspect(context.Background(), opened)
	if err != nil || after.Version != investmentSchemaVersion || len(after.Tables) != len(before.Tables)+1 {
		t.Fatalf("retried schema = %+v (%v)", after, err)
	}
}

func TestInvestmentAccountTypeWriteAcceptsUnifiedAndRejectsRetiredTypes(t *testing.T) {
	f := newFixture(t, true)
	for _, kind := range []string{"fund", "wealth", "unknown", "fund_wealth"} {
		input := investmentWrite{Tables: investmentRows{"investment_accounts": {
			{"id": "account", "name": "基金理财", "currency": "CNY", "account_type": kind, "sort_order": "0"},
		}}}
		want := http.StatusBadRequest
		if kind == "fund_wealth" {
			want = http.StatusOK
		}
		if status, body := f.call(http.MethodPut, "/api/v1/investment/book", input, f.tokens.AccessToken); status != want {
			t.Fatalf("%s write = %d %s (want %d)", kind, status, body, want)
		}
	}
}
