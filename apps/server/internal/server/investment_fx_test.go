package server

import (
	"context"
	"testing"
)

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
