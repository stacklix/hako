package server

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"
)

func TestInvestmentSnapshotRebuildAcceptsMultiYearHTTPChanges(t *testing.T) {
	f := newFixture(t, true)
	owner := f.s.investmentSubject()
	first := time.Date(2024, 7, 12, 0, 0, 0, 0, time.UTC)
	base, err := f.s.persistInvestment(context.Background(), owner, investmentWrite{Tables: investmentRows{
		"investment_accounts": {{"id": "account", "name": "Account", "account_type": "securities", "currency": "CNY", "sort_order": "0"}},
		"investment_events":   {{"id": "deposit", "account_id": "account", "event_type": "deposit", "effective_date": first.Format("2006-01-02"), "sequence": "0", "amount": "100"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	const days = 867
	through := first.AddDate(0, 0, days-1).Format("2006-01-02")
	input := investmentChangeWrite{Generation: base.Generation, Revision: base.Revision, Through: &through, Changes: investmentChanges{}}
	for index := 0; index < days; index++ {
		day := first.AddDate(0, 0, index).Format("2006-01-02")
		for table, row := range map[string]investmentRow{
			"investment_daily_snapshots":         {"snapshot_date": day, "computed_revision": strconv.FormatInt(base.Revision, 10), "status": "complete", "total_cny": "100", "total_usd": "14", "cumulative_gain_cny": "0", "daily_gain_cny": "0"},
			"investment_account_daily_snapshots": {"account_id": "account", "snapshot_date": day, "cash_native": "100", "holdings_native": "0", "gain_native": "0", "status": "complete"},
		} {
			change := input.Changes[table]
			change.Upserts = append(change.Upserts, row)
			input.Changes[table] = change
		}
	}
	encoded, err := json.Marshal(input)
	if err != nil || len(encoded) <= 16*1024 {
		t.Fatal("fixture must exceed the default HTTP envelope limit", len(encoded), err)
	}
	code, data := f.call("POST", "/api/v1/investment/book/changes", input, f.tokens.AccessToken)
	if code != 200 {
		t.Fatalf("multi-year snapshot request (%d bytes) failed: %d %s", len(encoded), code, data)
	}
	code, data = f.call("GET", "/api/v1/investment/book", nil, f.tokens.AccessToken)
	var saved investmentState
	if code != 200 || json.Unmarshal(data, &saved) != nil || saved.Through == nil || *saved.Through != through || saved.DirtyFrom != nil {
		t.Fatalf("snapshot rebuild did not advance the cutoff: %d", code)
	}
	for _, table := range []string{"investment_daily_snapshots", "investment_account_daily_snapshots"} {
		if len(saved.Tables[table]) != days {
			t.Fatalf("%s: saved %d days, want %d", table, len(saved.Tables[table]), days)
		}
	}
}

func TestInvestmentMonthlyChangesBodyLimitDoesNotAffectWholeBookWrites(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	owner := f.s.investmentSubject()
	var accounts []investmentRow
	for index := 0; index < 100; index++ {
		accounts = append(accounts, investmentRow{"id": "account-" + strconv.Itoa(index), "name": "Account", "account_type": "securities", "currency": "CNY", "sort_order": strconv.Itoa(index)})
	}
	base, err := f.s.persistInvestment(ctx, owner, investmentWrite{Tables: investmentRows{"investment_accounts": accounts}})
	if err != nil {
		t.Fatal(err)
	}
	first := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	through := "2026-10-31"
	monthlyRows := func(accountCount int) investmentChanges {
		result := investmentChanges{}
		for index := 0; index < 31; index++ {
			day := first.AddDate(0, 0, index).Format("2006-01-02")
			daily := result["investment_daily_snapshots"]
			daily.Upserts = append(daily.Upserts, investmentRow{"snapshot_date": day, "computed_revision": strconv.FormatInt(base.Revision, 10), "status": "complete", "total_cny": strconv.Itoa(100 * accountCount), "total_usd": strconv.Itoa(14 * accountCount), "cumulative_gain_cny": "0", "daily_gain_cny": "0"})
			result["investment_daily_snapshots"] = daily
			for account := 0; account < accountCount; account++ {
				change := result["investment_account_daily_snapshots"]
				change.Upserts = append(change.Upserts, investmentRow{"account_id": accounts[account]["id"], "snapshot_date": day, "cash_native": "100", "holdings_native": "0", "gain_native": "0", "status": "complete"})
				result["investment_account_daily_snapshots"] = change
			}
		}
		return result
	}
	input := investmentChangeWrite{Generation: base.Generation, Revision: base.Revision, Through: &through, Changes: monthlyRows(8)}
	encoded, err := json.Marshal(input)
	if err != nil || len(encoded) <= 16*1024 || len(encoded) > 256*1024 {
		t.Fatal("monthly fixture must fit the investment change limit while exceeding the default limit", len(encoded), err)
	}
	code, data := f.call("POST", "/api/v1/investment/book/changes", input, f.tokens.AccessToken)
	var saved investmentChangeResult
	if code != 200 || json.Unmarshal(data, &saved) != nil {
		t.Fatalf("monthly snapshot request (%d bytes) failed: %d %s", len(encoded), code, data)
	}
	t.Logf("normal monthly request: %d bytes", len(encoded))
	input.Generation, input.Revision = saved.Generation, saved.Revision
	input.Changes = monthlyRows(100)
	input.Changes["investment_daily_snapshots"].Upserts[0]["total_cny"] = "999"
	encoded, err = json.Marshal(input)
	if err != nil || len(encoded) <= 256*1024 {
		t.Fatal("oversized fixture must exceed the investment change limit", len(encoded), err)
	}
	code, data = f.call("POST", "/api/v1/investment/book/changes", input, f.tokens.AccessToken)
	var failure map[string]string
	if code != 400 || json.Unmarshal(data, &failure) != nil || failure["error"] != "invalid_request" {
		t.Fatalf("oversized snapshot request (%d bytes) was not rejected by HTTP decoding: %d %s", len(encoded), code, data)
	}
	t.Logf("rejected monthly request: %d bytes", len(encoded))
	code, data = f.call("GET", "/api/v1/investment/book", nil, f.tokens.AccessToken)
	var unchanged investmentState
	if code != 200 || json.Unmarshal(data, &unchanged) != nil || unchanged.Generation != saved.Generation || unchanged.Revision != saved.Revision || len(unchanged.Tables["investment_account_daily_snapshots"]) != 8*31 || unchanged.Tables["investment_daily_snapshots"][0]["total_cny"] != "800" {
		t.Fatal("rejected request changed saved snapshots or metadata")
	}
	// Whole-book export/import remains a separate envelope, bounded at 32 MiB.
	wholeBook := investmentWrite{Generation: saved.Generation, Through: &through, Tables: investmentRows{}}
	for table, change := range input.Changes {
		wholeBook.Tables[table] = change.Upserts
	}
	code, data = f.call("PUT", "/api/v1/investment/book", wholeBook, f.tokens.AccessToken)
	var imported investmentState
	if code != 200 || json.Unmarshal(data, &imported) != nil || len(imported.Tables["investment_account_daily_snapshots"]) != 100*31 || imported.Tables["investment_daily_snapshots"][0]["total_cny"] != "999" {
		t.Fatalf("whole-book request inherited the smaller incremental limit: %d", code)
	}
}

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

func TestInvestmentMetadataOnlyCheckpointRejectsConcurrentNAVRevision(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	owner := f.s.investmentSubject()
	pending, completed := "2026-11-01", "2026-10-31"
	base, err := f.s.persistInvestment(ctx, owner, investmentWrite{DirtyFrom: &pending, Tables: investmentRows{
		"market_instruments": {{"id": "FUND:CN:017302.OF:CNY", "asset_type": "fund", "symbol": "017302.OF", "exchange": "OF", "name": "Fund", "quote_currency": "CNY", "price_type": "nav"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	checkpoint, err := f.s.persistInvestmentChanges(ctx, owner, investmentChangeWrite{
		Generation: base.Generation, Revision: base.Revision, DirtyFrom: &pending, Through: &completed,
		Changes: investmentChanges{"investment_daily_snapshots": {Upserts: []investmentRow{{"snapshot_date": completed, "status": "complete", "computed_revision": strconv.FormatInt(base.Revision, 10), "total_cny": "100", "total_usd": "14", "cumulative_gain_cny": "0"}}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	// A late NAV arrives independently of ledger generation while the client is
	// preparing an unchanged month whose checkpoint would have an empty delta.
	lateDay := "2026-10-29"
	code, data := f.call("POST", "/api/v1/investment/book/changes", investmentChangeWrite{
		Generation: 0, Revision: 0, DirtyFrom: &lateDay,
		Changes: investmentChanges{"market_daily_prices": {Upserts: []investmentRow{{"instrument_id": "FUND:CN:017302.OF:CNY", "session_date": lateDay, "valuation_date": lateDay, "price_type": "nav", "source": "published NAV", "price": "1.23", "is_final": "1"}}}},
	}, f.tokens.AccessToken)
	var market investmentChangeResult
	if code != 200 || json.Unmarshal(data, &market) != nil || market.Generation != checkpoint.Generation || market.Revision != checkpoint.Revision+1 || market.DirtyFrom == nil || *market.DirtyFrom != lateDay {
		t.Fatalf("late NAV did not invalidate the earlier month: %d %s", code, data)
	}
	later, next := "2026-12-01", "2026-11-30"
	for _, request := range []investmentChangeWrite{
		{Generation: checkpoint.Generation, Revision: checkpoint.Revision, DirtyFrom: &later, Through: &next, Changes: investmentChanges{}},
		{Generation: checkpoint.Generation, Revision: checkpoint.Revision, Through: &next, Changes: investmentChanges{}},
		{Generation: checkpoint.Generation, Revision: checkpoint.Revision, Changes: investmentChanges{}},
	} {
		code, data = f.call("POST", "/api/v1/investment/book/changes", request, f.tokens.AccessToken)
		if code != 409 {
			t.Fatalf("stale empty-delta checkpoint overwrote NAV invalidation: %d %s", code, data)
		}
	}
	read := func() investmentState {
		t.Helper()
		code, data := f.call("GET", "/api/v1/investment/book", nil, f.tokens.AccessToken)
		var state investmentState
		if code != 200 || json.Unmarshal(data, &state) != nil {
			t.Fatalf("reading checkpoint failed: %d %s", code, data)
		}
		return state
	}
	retained := read()
	if retained.Generation != market.Generation || retained.Revision != market.Revision || retained.DirtyFrom == nil || *retained.DirtyFrom != lateDay || retained.Through == nil || *retained.Through != completed || len(retained.Tables["investment_daily_snapshots"]) != 1 || retained.Tables["investment_daily_snapshots"][0]["total_cny"] != "100" {
		t.Fatal("rejected checkpoints changed snapshots, metadata or the late-NAV revision")
	}
	// A genuine no-op is still legal with an older input revision. It cannot
	// overwrite anything, and the response asks the client to reload its inputs.
	code, data = f.call("POST", "/api/v1/investment/book/changes", investmentChangeWrite{
		Generation: market.Generation, Revision: checkpoint.Revision, DirtyFrom: &lateDay, Through: &completed, Changes: investmentChanges{},
	}, f.tokens.AccessToken)
	var unchanged investmentChangeResult
	if code != 200 || json.Unmarshal(data, &unchanged) != nil || !unchanged.ReloadRequired || unchanged.Generation != market.Generation || unchanged.Revision != market.Revision {
		t.Fatalf("read-only empty delta was rejected or changed the checkpoint: %d %s", code, data)
	}
	// Once the client has recalculated against the new revision, it may commit
	// progress even when the derived monetary values were unchanged.
	code, data = f.call("POST", "/api/v1/investment/book/changes", investmentChangeWrite{
		Generation: market.Generation, Revision: market.Revision, DirtyFrom: &later, Through: &next, Changes: investmentChanges{},
	}, f.tokens.AccessToken)
	var advanced investmentChangeResult
	if code != 200 || json.Unmarshal(data, &advanced) != nil || advanced.Generation != market.Generation+1 || advanced.Revision != market.Revision || advanced.DirtyFrom == nil || *advanced.DirtyFrom != later || advanced.Through == nil || *advanced.Through != next {
		t.Fatalf("current-revision empty checkpoint could not advance: %d %s", code, data)
	}
}
