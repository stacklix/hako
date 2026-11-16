package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"
)

func seedInvestmentSchema4(t *testing.T, db *sql.DB) {
	t.Helper()
	_, err := db.Exec(`PRAGMA ignore_check_constraints=ON;
		INSERT INTO investment_books(owner_id,id,generation,revision,snapshot_through)
			VALUES('owner','book',7,3,'2026-11-15'),('other','other-book',2,1,NULL);
		INSERT INTO investment_accounts(book_id,id,name,account_type,currency,sort_order,archived_at) VALUES
			('book','fund','养老金','fund','CNY',0,NULL),
			('book','wealth','理财','wealth','CNY',1,'2026-11-16T00:00:00Z'),
			('other-book','broker','证券','securities','CNY',0,NULL);
		INSERT INTO investment_events(book_id,id,account_id,event_type,effective_date,sequence,amount) VALUES
			('book','fund-cash','fund','deposit','2026-11-15',0,'100.123456789012345678'),
			('book','wealth-cash','wealth','deposit','2026-11-15',0,'250');
		INSERT INTO investment_assets(book_id,id,name,asset_type,quote_currency,settlement_unit)
			VALUES('book','asset','理财产品','wealth','CNY','CNY');
		INSERT INTO investment_plans(book_id,id,account_id,amount,frequency,schedule_day,next_date,enabled)
			VALUES('book','plan','fund','100','monthly',1,'2026-12-01',1);
		INSERT INTO investment_plan_runs(book_id,plan_id,scheduled_date,status,event_id)
			VALUES('book','plan','2026-11-01','executed','fund-cash');
		INSERT INTO investment_daily_snapshots(book_id,snapshot_date,total_cny,status,computed_revision)
			VALUES('book','2026-11-15','350.123456789012345678','complete',3);
		INSERT INTO investment_account_daily_snapshots(book_id,account_id,snapshot_date,cash_native,status)
			VALUES('book','fund','2026-11-15','100.123456789012345678','complete');
		INSERT INTO investment_month_snapshots(book_id,snapshot_date,total_cny)
			VALUES('book','2026-10-31','200');
		PRAGMA ignore_check_constraints=OFF;
		PRAGMA user_version=4;`)
	if err != nil {
		t.Fatal(err)
	}
}

func TestInvestmentSchema5UnifiesTypesAndPreservesHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	seedInvestmentSchema4(t, db)
	history := func() string {
		t.Helper()
		tx, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		tables := investmentRows{}
		for _, table := range investmentTables {
			if table.name == "investment_accounts" {
				continue
			}
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
	before := history()
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var version, count, generation, revision, unaffected int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 5 {
		t.Fatalf("schema = %d (%v)", version, err)
	}
	if err := db.QueryRow("SELECT COUNT(*) FROM investment_accounts WHERE account_type='fund_wealth'").Scan(&count); err != nil || count != 2 {
		t.Fatalf("converted accounts = %d (%v)", count, err)
	}
	var archived, name, currency string
	var order int
	if err := db.QueryRow("SELECT name,currency,sort_order,archived_at FROM investment_accounts WHERE id='wealth'").Scan(&name, &currency, &order, &archived); err != nil || name != "理财" || currency != "CNY" || order != 1 || archived != "2026-11-16T00:00:00Z" {
		t.Fatalf("account identity changed: %s %s %d %s (%v)", name, currency, order, archived, err)
	}
	if err := db.QueryRow("SELECT generation,revision FROM investment_books WHERE id='book'").Scan(&generation, &revision); err != nil || generation != 8 || revision != 3 {
		t.Fatalf("revision fence = %d/%d (%v)", generation, revision, err)
	}
	if err := db.QueryRow("SELECT generation FROM investment_books WHERE id='other-book'").Scan(&unaffected); err != nil || unaffected != 2 {
		t.Fatalf("unrelated book changed = %d (%v)", unaffected, err)
	}
	if after := history(); after != before {
		t.Fatalf("history changed:\nbefore %s\nafter %s", before, after)
	}
	if err := upgradeInvestmentFundWealthAccounts(db); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow("SELECT generation FROM investment_books WHERE id='book'").Scan(&generation); err != nil || generation != 8 {
		t.Fatalf("upgrade was repeated: %d (%v)", generation, err)
	}
	if _, err := db.Exec("UPDATE investment_accounts SET account_type='fund' WHERE id='fund'"); err == nil {
		t.Fatal("schema 5 accepted retired account type")
	}
}

func TestInvestmentSchema5RollsBackOnInvalidAccount(t *testing.T) {
	db, err := openInvestmentDB(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	seedInvestmentSchema4(t, db)
	if _, err := db.Exec(`PRAGMA ignore_check_constraints=ON;
		INSERT INTO investment_accounts(book_id,id,account_type) VALUES('book','invalid','unknown');
		PRAGMA ignore_check_constraints=OFF;`); err != nil {
		t.Fatal(err)
	}
	if err := upgradeInvestmentFundWealthAccounts(db); err == nil {
		t.Fatal("invalid migration succeeded")
	}
	var version, generation, oldTypes int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 4 {
		t.Fatalf("schema changed: %d (%v)", version, err)
	}
	if err := db.QueryRow("SELECT generation FROM investment_books WHERE id='book'").Scan(&generation); err != nil || generation != 7 {
		t.Fatalf("generation changed: %d (%v)", generation, err)
	}
	if err := db.QueryRow("SELECT COUNT(*) FROM investment_accounts WHERE account_type IN ('fund','wealth')").Scan(&oldTypes); err != nil || oldTypes != 2 {
		t.Fatalf("old types changed: %d (%v)", oldTypes, err)
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
