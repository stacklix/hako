package server

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestInvestmentFXMigrationPreservesPreferredRatesAndReopens(t *testing.T) {
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(legacyMarketDDL); err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO investment_books(owner_id,id,generation,revision) VALUES('owner','book',2,3);
		INSERT INTO investment_accounts(book_id,id,name,account_type,currency,sort_order) VALUES('book','account','Cash','securities','USD',0);
		DROP TABLE market_daily_fx;
		CREATE TABLE market_daily_fx(book_id TEXT NOT NULL,rate_date TEXT NOT NULL,base_currency TEXT NOT NULL,
		quote_currency TEXT NOT NULL,source TEXT NOT NULL,rate TEXT,available_at_utc TEXT,is_final INTEGER,revision INTEGER,
		PRIMARY KEY(book_id,rate_date,base_currency,quote_currency,source)) WITHOUT ROWID;
		INSERT INTO market_daily_fx VALUES
		('book','2026-11-20','USD','CNY','old','7.123456789012345678','2026-11-20T12:00:00Z',1,4),
		('book','2026-11-20','USD','CNY','new','9','2026-11-20T13:00:00Z',0,2),
		('book','2026-11-20','HKD','CNY','a','0.9','2026-11-20T12:00:00Z',1,3),
		('book','2026-11-20','HKD','CNY','b','0.91','2026-11-20T13:00:00Z',1,4),
		('book','2026-11-23','USD','CNY','invalid','0','2026-11-23T13:00:00Z',1,1),
		('book','2026-11-23','USD','CNY','valid','7.2','2026-11-23T12:00:00Z',NULL,1),
		('another-book','2026-11-20','USD','CNY','old','6','2026-11-20T12:00:00Z',1,1);
		PRAGMA user_version=7;`)
	if err != nil {
		db.Close()
		t.Fatal(err)
	}
	db.Close()
	for i := 0; i < 2; i++ {
		db, err = openInvestmentDB(path)
		if err != nil {
			t.Fatal(err)
		}
		var version, count, generation, revision int
		if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 9 {
			t.Fatal(version, err)
		}
		if err = db.QueryRow("SELECT COUNT(*) FROM market_daily_fx").Scan(&count); err != nil || count != 3 {
			t.Fatal(count, err)
		}
		var rate, source string
		if err = db.QueryRow("SELECT rate,source FROM market_daily_fx WHERE base_currency='USD' AND rate_date='2026-11-20'").Scan(&rate, &source); err != nil || rate != "7.123456789012345678" || source != "old" {
			t.Fatal(rate, source, err)
		}
		if err = db.QueryRow("SELECT rate FROM market_daily_fx WHERE base_currency='HKD'").Scan(&rate); err != nil || rate != "0.91" {
			t.Fatal(rate, err)
		}
		if err = db.QueryRow("SELECT generation,revision FROM investment_books").Scan(&generation, &revision); err != nil || generation != 3 || revision != 4 {
			t.Fatal(generation, revision, err)
		}
		if _, err = db.Exec("INSERT INTO market_daily_fx(rate_date,base_currency,quote_currency,source,rate) VALUES('2026-11-20','USD','CNY','other','9')"); err == nil {
			t.Fatal("source still participates in FX identity")
		}
		if _, err = db.Exec("SELECT book_id FROM market_daily_fx"); err == nil {
			t.Fatal("FX still has a ledger column")
		}
		db.Close()
	}
}

func TestInvestmentFXIsSharedWithoutReplacingAnotherLedgersRates(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	create := func(owner string) investmentState {
		t.Helper()
		state, err := f.s.persistInvestment(ctx, owner, investmentWrite{Tables: investmentRows{
			"investment_accounts": {{"id": owner, "name": owner, "currency": "USD", "account_type": "securities", "sort_order": "0"}},
		}})
		if err != nil {
			t.Fatal(err)
		}
		return state
	}
	a, b := create("a"), create("b")
	read := func(owner string) investmentState {
		t.Helper()
		tx, err := f.s.investment.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		state, err := readInvestmentState(ctx, tx, owner, nil)
		if err != nil {
			t.Fatal(err)
		}
		return state
	}
	rate := investmentRow{"rate_date": "2026-11-20", "base_currency": "USD", "quote_currency": "CNY", "rate": "7.1", "source": "欧洲央行", "is_final": "1"}
	_, err := f.s.persistInvestmentChanges(ctx, "a", investmentChangeWrite{Generation: a.Generation, Revision: a.Revision, Changes: investmentChanges{
		"market_daily_fx": {Upserts: []investmentRow{rate}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	other := read("b")
	if len(other.Tables["market_daily_fx"]) != 1 || other.Tables["market_daily_fx"][0]["rate"] != "7.1" || other.Revision != b.Revision+1 || other.Generation != b.Generation || other.DirtyFrom == nil || *other.DirtyFrom != "2026-11-20" {
		t.Fatal(other)
	}
	if fresh := read("new-owner"); len(fresh.Tables["market_daily_fx"]) != 1 || len(fresh.Tables["investment_accounts"]) != 0 {
		t.Fatal("a new ledger should reuse public FX without seeing another ledger", fresh)
	}
	ignored, err := f.s.persistInvestmentChanges(ctx, "b", investmentChangeWrite{Generation: other.Generation, Revision: other.Revision, Changes: investmentChanges{
		"market_daily_fx": {Upserts: []investmentRow{{"rate_date": "2026-11-20", "base_currency": "USD", "quote_currency": "CNY", "rate": "9", "source": "other", "is_final": "1"}}},
	}})
	if err != nil || ignored.Revision != other.Revision || ignored.Changes["market_daily_fx"].Upserts[0]["rate"] != "7.1" {
		t.Fatal("another ledger replaced a final shared rate", ignored, err)
	}
	_, err = f.s.persistInvestment(ctx, "b", investmentWrite{Generation: b.Generation, Tables: investmentRows{
		"market_daily_fx": {{"rate_date": "2026-11-23", "base_currency": "USD", "quote_currency": "CNY", "rate": "7.2", "source": "欧洲央行", "is_final": "0"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if state := read("a"); len(state.Tables["market_daily_fx"]) != 2 || state.Tables["market_daily_fx"][0]["rate"] != "7.1" || len(state.Tables["investment_accounts"]) != 1 || state.Tables["investment_accounts"][0]["id"] != "a" {
		t.Fatal("a partial upload must not remove shared rates or share private ledger rows", state)
	}
	if _, err = f.s.persistInvestment(ctx, "b", investmentWrite{Generation: b.Generation + 1, Tables: investmentRows{"market_daily_fx": {}}}); err != nil {
		t.Fatal(err)
	}
	if state := read("a"); len(state.Tables["market_daily_fx"]) != 2 {
		t.Fatal("an empty ledger upload removed global FX", state)
	}
	_, err = f.s.persistInvestmentChanges(ctx, "b", investmentChangeWrite{Changes: investmentChanges{
		"market_daily_fx": {Deletes: []investmentRow{{"rate_date": "2026-11-20", "base_currency": "USD", "quote_currency": "CNY"}}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if state := read("a"); len(state.Tables["market_daily_fx"]) != 1 || state.Tables["market_daily_fx"][0]["rate_date"] != "2026-11-23" {
		t.Fatal("explicit shared FX deletion did not propagate", state)
	}
}

func TestInvestmentFXMigrationRollsBackOnFailure(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "broken.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec(`CREATE TABLE market_daily_fx(book_id,rate_date,base_currency,quote_currency,rate,source,available_at_utc,is_final,revision);
		INSERT INTO market_daily_fx VALUES('b','2026-11-20','USD','CNY','7','old',NULL,1,1); PRAGMA user_version=7;`); err != nil {
		t.Fatal(err)
	}
	if err = migrateInvestmentMarket(db); err == nil {
		t.Fatal("migration without books should fail")
	}
	var version, count int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 7 {
		t.Fatal(version, err)
	}
	if err = db.QueryRow("SELECT COUNT(*) FROM market_daily_fx WHERE source='old'").Scan(&count); err != nil || count != 1 {
		t.Fatal(count, err)
	}
}

func TestInvestmentFXProvisionalPromotesOnceAndConfirmsStoredRecord(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	owner := f.s.investmentSubject()
	write := func(rate, source, final string) investmentChangeResult {
		t.Helper()
		result, err := f.s.persistInvestmentChanges(ctx, owner, investmentChangeWrite{Changes: investmentChanges{
			"market_daily_fx": {Upserts: []investmentRow{{"rate_date": "2026-11-20", "base_currency": "USD", "quote_currency": "CNY", "rate": rate, "source": source, "is_final": final}}},
		}})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	first := write("7", "old", "0")
	final := write("7.1", "欧洲央行", "1")
	if final.Revision != first.Revision+1 {
		t.Fatal("promotion not persisted")
	}
	ignored := write("8", "another", "1")
	row := ignored.Changes["market_daily_fx"].Upserts[0]
	if ignored.Revision != final.Revision || row["rate"] != "7.1" || row["source"] != "欧洲央行" || row["is_final"] != "1" {
		t.Fatal(ignored)
	}
	var count int
	if err := f.s.investment.QueryRow("SELECT COUNT(*) FROM market_daily_fx").Scan(&count); err != nil || count != 1 {
		t.Fatal(count, err)
	}
	// Full ledger replacement cannot silently change a finalized FX observation either.
	_, err := f.s.persistInvestment(ctx, owner, investmentWrite{Generation: ignored.Generation, Tables: investmentRows{
		"market_daily_fx": {{"rate_date": "2026-11-20", "base_currency": "USD", "quote_currency": "CNY", "source": "different", "rate": "9", "is_final": "0"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	var rate string
	if err = f.s.investment.QueryRow("SELECT rate FROM market_daily_fx").Scan(&rate); err != nil || rate != "7.1" {
		t.Fatal(rate, err)
	}
}
