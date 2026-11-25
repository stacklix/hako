package server

import (
	"context"
	"encoding/json"
	"testing"
)

func TestInvestmentRecordChangesAreIncrementalAndAtomic(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	owner := f.s.investmentSubject()
	account := investmentRow{"id": "account", "name": "Account", "account_type": "securities", "currency": "USD", "sort_order": "0"}
	event := investmentRow{"id": "first", "account_id": "account", "event_type": "deposit", "effective_date": "2026-11-01", "sequence": "0", "amount": "100"}
	base, err := f.s.persistInvestment(ctx, owner, investmentWrite{Tables: investmentRows{"investment_accounts": {account}, "investment_events": {event}}})
	if err != nil {
		t.Fatal(err)
	}
	// Any delete/reinsert or update of the unaffected row would trip this trigger.
	_, err = f.s.investment.Exec(`CREATE TRIGGER protect_original_delete BEFORE DELETE ON investment_events WHEN OLD.id='first' BEGIN SELECT RAISE(ABORT,'unrelated row deleted');END;
 CREATE TRIGGER protect_original_update BEFORE UPDATE ON investment_events WHEN OLD.id='first' BEGIN SELECT RAISE(ABORT,'unrelated row updated');END;`)
	if err != nil {
		t.Fatal(err)
	}
	second := investmentRow{"id": "second", "account_id": "account", "event_type": "deposit", "effective_date": "2026-11-02", "sequence": "0", "amount": "25"}
	input := investmentChangeWrite{Generation: base.Generation, Changes: investmentChanges{"investment_events": {Upserts: []investmentRow{second}}}}
	code, data := f.call("POST", "/api/v1/investment/book/changes", input, f.tokens.AccessToken)
	if code != 200 {
		t.Fatalf("%d %s", code, data)
	}
	var saved investmentChangeResult
	if err = json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	if saved.Generation != base.Generation+1 || len(saved.Changes["investment_events"].Upserts) != 1 {
		t.Fatal(saved)
	}
	code, _ = f.call("POST", "/api/v1/investment/book/changes", input, f.tokens.AccessToken)
	if code != 409 {
		t.Fatal("old ledger version accepted", code)
	}
	// One bad reference rolls back all changes, including the valid preceding row.
	third := investmentRow{"id": "third", "account_id": "account", "event_type": "deposit", "effective_date": "2026-11-03", "sequence": "0", "amount": "10"}
	bad := investmentRow{"id": "bad", "account_id": "missing", "event_type": "deposit", "effective_date": "2026-11-03", "sequence": "1", "amount": "10"}
	_, err = f.s.persistInvestmentChanges(ctx, owner, investmentChangeWrite{Generation: saved.Generation, Changes: investmentChanges{"investment_events": {Upserts: []investmentRow{third, bad}}}})
	if err != errInvestmentInvalid {
		t.Fatal(err)
	}
	var count int
	if err = f.s.investment.QueryRow("SELECT COUNT(*) FROM investment_events").Scan(&count); err != nil || count != 2 {
		t.Fatal(count, err)
	}
	_, err = f.s.persistInvestmentChanges(ctx, owner, investmentChangeWrite{Generation: saved.Generation, Changes: investmentChanges{"investment_events": {Deletes: []investmentRow{{"id": "second", "amount": "25"}}}}})
	if err != errInvestmentInvalid {
		t.Fatal("delete must contain keys only", err)
	}
	next, err := f.s.persistInvestmentChanges(ctx, owner, investmentChangeWrite{Generation: saved.Generation, Changes: investmentChanges{"investment_events": {Deletes: []investmentRow{{"id": "second"}}}}})
	if err != nil || next.Generation != saved.Generation+1 {
		t.Fatal(next, err)
	}
}

func TestInvestmentMarketChangesDoNotConflictWithLedgerGeneration(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	owner := f.s.investmentSubject()
	base, err := f.s.persistInvestment(ctx, owner, investmentWrite{Tables: investmentRows{"market_instruments": {{"id": "CRYPTO:CRYPTO:BTC:USD", "asset_type": "crypto", "symbol": "BTCUSDT", "exchange": "BINANCE", "name": "BTC", "quote_currency": "USD", "price_type": "close"}}}})
	if err != nil {
		t.Fatal(err)
	}
	day := "2026-11-01"
	quote := investmentRow{"instrument_id": "CRYPTO:CRYPTO:BTC:USD", "session_date": day, "price_type": "close", "source": "test", "price": "123.4", "is_final": "1"}
	input := investmentChangeWrite{Generation: 0, DirtyFrom: &day, Changes: investmentChanges{"market_daily_prices": {Upserts: []investmentRow{quote}}}}
	result, err := f.s.persistInvestmentChanges(ctx, owner, input)
	if err != nil {
		t.Fatal(err)
	}
	if result.Generation != base.Generation || result.Revision != base.Revision+1 {
		t.Fatal("quotes changed ledger generation or failed to invalidate valuation inputs", result)
	}
	// Retry is a no-op after the server assigns the quote revision.
	again, err := f.s.persistInvestmentChanges(ctx, owner, input)
	if err != nil || again.Revision != result.Revision {
		t.Fatal(again, err)
	}
	// A later ledger edit must retain the earlier quote invalidation date.
	later := "2026-11-20"
	result, err = f.s.persistInvestmentChanges(ctx, owner, investmentChangeWrite{Generation: base.Generation, Revision: base.Revision, DirtyFrom: &later, Changes: investmentChanges{"investment_accounts": {Upserts: []investmentRow{{"id": "account", "name": "Account", "account_type": "securities", "currency": "USD", "sort_order": "0"}}}}})
	if err != nil || !result.ReloadRequired || result.DirtyFrom == nil || *result.DirtyFrom != day {
		t.Fatal(result, err)
	}
}
