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
	for _, version := range []int{2, 3, 4, 5, 8} {
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
	if err != nil || schema.Version != investmentSchemaVersion || len(schema.Tables) != len(investmentTables)+1 {
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
