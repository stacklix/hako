package server

import (
	"encoding/json"
	"maps"
	"net/http"
	"strings"
	"testing"
)

func TestInsuranceWithdrawalsPreserveOptionalCashValue(t *testing.T) {
	f := newFixture(t, true)
	day := "2026-11-09"
	events := []investmentRow{
		{"id": "first", "account_id": "insurance", "asset_id": "policy", "event_type": "insurance_withdrawal", "effective_date": day, "sequence": "1", "amount": "1000.123456789012345678"},
		{"id": "second", "account_id": "insurance", "asset_id": "policy", "event_type": "insurance_withdrawal", "effective_date": day, "sequence": "2", "amount": "200", "settled_amount": "0"},
	}
	input := investmentWrite{DirtyFrom: &day, Tables: investmentRows{
		"investment_accounts": {{"id": "insurance", "name": "保险", "currency": "CNY", "account_type": "insurance", "sort_order": "0"}},
		"investment_assets":   {{"id": "policy", "symbol": "POLICY", "name": "保单", "asset_type": "insurance", "quote_currency": "CNY", "settlement_unit": "CNY"}},
		"investment_events":   events,
	}}
	if status, data := f.call(http.MethodPut, "/api/v1/investment/book", input, f.tokens.AccessToken); status != http.StatusOK {
		t.Fatalf("insurance withdrawal write = %d %s", status, data)
	}
	status, data := f.call(http.MethodGet, "/api/v1/investment/book", nil, f.tokens.AccessToken)
	var saved investmentState
	if err := json.Unmarshal(data, &saved); err != nil || status != http.StatusOK {
		t.Fatalf("read = %d %s (%v)", status, data, err)
	}
	if len(saved.Tables["investment_events"]) != 2 {
		t.Fatalf("missing withdrawals: %+v", saved)
	}
	for _, event := range saved.Tables["investment_events"] {
		if event["id"] == "first" && (event["amount"] != "1000.12" || event["settled_amount"] != "") {
			t.Fatalf("optional value or decimal precision changed: %+v", event)
		}
		if event["id"] == "second" && event["settled_amount"] != "0" {
			t.Fatalf("explicit zero value lost: %+v", event)
		}
	}
}

func TestInvestmentGenericBalancesRoundTripAndRemovedContractsAreRejected(t *testing.T) {
	f := newFixture(t, true)
	const path = "/api/v1/investment/book"
	day := "2026-11-15"
	asset := investmentRow{"id": "generic", "name": "策略账户", "asset_type": "generic", "quote_currency": "USD", "settlement_unit": "USD"}
	adjustment := investmentRow{"id": "adjustment", "account_id": "account", "asset_id": "generic", "event_type": "adjustment", "effective_date": day, "sequence": "2", "settled_amount": "10800.123456789012345678"}
	initial := investmentWrite{DirtyFrom: &day, Tables: investmentRows{
		"investment_accounts": {{"id": "account", "name": "Binance", "account_type": "crypto", "currency": "USD", "sort_order": "0"}},
		"investment_assets":   {asset},
		"investment_events": {
			{"id": "deposit", "account_id": "account", "event_type": "deposit", "effective_date": day, "sequence": "0", "amount": "10000"},
			{"id": "buy", "account_id": "account", "asset_id": "generic", "event_type": "buy", "effective_date": day, "sequence": "1", "quantity": "1", "unit_price": "10000", "settled_amount": "10000"},
			adjustment,
		},
	}}
	if status, body := f.call(http.MethodPut, path, initial, f.tokens.AccessToken); status != http.StatusOK {
		t.Fatalf("generic write = %d %s", status, body)
	}
	for _, test := range []struct {
		table, column, value string
		row                  investmentRow
	}{
		{"investment_assets", "asset_type", "crypto_contract", asset},
		{"market_instruments", "asset_type", "crypto_contract", investmentRow{"id": "contract", "symbol": "BTCUSDT", "exchange": "BINANCE", "name": "Contract", "quote_currency": "USD", "price_type": "mark"}},
		{"investment_events", "event_type", "derivative_funding", adjustment},
		{"investment_assets", "collateral_asset_id", "generic", asset},
		{"market_derivative_specs", "pricing_model", "inverse", investmentRow{"instrument_id": "future", "contract_multiplier": "1"}},
		{"market_derivative_specs", "settlement_basis", "coin", investmentRow{"instrument_id": "future", "contract_multiplier": "1"}},
		{"market_derivative_specs", "settlement_unit", "BTC", investmentRow{"instrument_id": "future", "contract_multiplier": "1"}},
		{"investment_derivative_event_details", "funding_target", "account_available", investmentRow{"event_id": "adjustment"}},
		{"investment_derivative_event_details", "settlement_to_account_rate", "1", investmentRow{"event_id": "adjustment"}},
	} {
		t.Run(test.table+"/"+test.column, func(t *testing.T) {
			row := maps.Clone(test.row)
			row[test.column] = test.value
			write := investmentWrite{Generation: 1, DirtyFrom: &day, Tables: investmentRows{test.table: {row}}}
			if status, body := f.call(http.MethodPut, path, write, f.tokens.AccessToken); status != http.StatusBadRequest {
				t.Fatalf("removed contract data accepted: %d %s", status, body)
			}
		})
	}
	status, body := f.call(http.MethodGet, path, nil, f.tokens.AccessToken)
	var saved investmentState
	if err := json.Unmarshal(body, &saved); err != nil || status != http.StatusOK {
		t.Fatalf("read = %d %s (%v)", status, body, err)
	}
	if saved.Generation != 1 || len(saved.Tables["investment_events"]) != 3 || !maps.Equal(saved.Tables["investment_assets"][0], asset) {
		t.Fatalf("rejected writes changed the saved book: %+v", saved)
	}
	for _, event := range saved.Tables["investment_events"] {
		if event["id"] == "adjustment" && event["settled_amount"] != "10800.12" {
			t.Fatalf("balance precision changed: %+v", event)
		}
	}
}

func TestInvestmentBookRequiresAuthAndCommitsAtomically(t *testing.T) {
	f := newFixture(t, true)
	path := "/api/v1/investment/book"
	if status, _ := f.call(http.MethodGet, path, nil, ""); status != http.StatusUnauthorized {
		t.Fatalf("unauthenticated read = %d", status)
	}
	token := f.tokens.AccessToken
	read := func() investmentState {
		t.Helper()
		status, data := f.call(http.MethodGet, path, nil, token)
		var result investmentState
		if err := json.Unmarshal(data, &result); err != nil || status != 200 {
			t.Fatalf("read = %d %s, %v", status, data, err)
		}
		return result
	}
	write := func(input investmentWrite, expected int) investmentState {
		t.Helper()
		status, data := f.call(http.MethodPut, path, input, token)
		if status != expected {
			t.Fatalf("write = %d %s, expected %d", status, data, expected)
		}
		var result investmentState
		if status == 200 {
			if err := json.Unmarshal(data, &result); err != nil {
				t.Fatal(err)
			}
		}
		return result
	}
	if got := read(); got.Generation != 0 || len(got.Tables) != 0 {
		t.Fatalf("new book = %+v", got)
	}
	day := "2026-11-09"
	account := investmentRow{"id": "account", "name": "测试", "account_type": "securities", "currency": "CNY", "sort_order": "0"}
	event := investmentRow{"id": "event", "account_id": "account", "event_type": "deposit", "effective_date": day, "sequence": "0", "amount": "9007199254740993.0001"}
	first := investmentWrite{DirtyFrom: &day, Tables: investmentRows{
		"investment_accounts": {account}, "investment_events": {event},
		"market_daily_fx": {{"rate_date": day, "base_currency": "USD", "quote_currency": "CNY", "source": "test", "rate": "7.123456789012345678", "is_final": "1"}},
	}}
	got := write(first, 200)
	if got.Generation != 1 || got.Revision != 1 || got.DirtyFrom == nil || *got.DirtyFrom != day ||
		got.Tables["market_daily_fx"][0]["revision"] != "1" {
		t.Fatalf("first write = %+v", got)
	}
	write(first, 409)
	write(investmentWrite{Generation: 1, Tables: investmentRows{"investment_accounts": {}}}, 400)
	if got := read(); got.Generation != 1 || got.Tables["investment_events"][0]["amount"] != "9007199254740993" {
		t.Fatalf("rollback or decimal precision lost: %+v", got)
	}
	snapshot := investmentRow{"snapshot_date": day, "status": "complete", "computed_revision": "0", "total_cny": "720", "total_usd": "100"}
	output := investmentWrite{Generation: 1, Through: &day, Tables: investmentRows{"investment_daily_snapshots": {snapshot}}}
	write(output, 409)
	snapshot["computed_revision"] = "1"
	got = write(output, 200)
	if got.Generation != 2 || got.Revision != 1 || got.DirtyFrom != nil {
		t.Fatalf("snapshot metadata = %+v", got)
	}
	got = read()
	if got.Tables["investment_daily_snapshots"][0]["total_usd"] != "100" ||
		got.Tables["market_daily_fx"][0]["rate"] != "7.1235" {
		t.Fatalf("round-trip = %+v", got)
	}
	event["amount"] = "1080"
	got = write(investmentWrite{Generation: 2, DirtyFrom: &day, Through: &day,
		Tables: investmentRows{"investment_events": {event}}}, 200)
	if got.Generation != 3 || got.Revision != 2 || got.DirtyFrom == nil {
		t.Fatalf("edited book = %+v", got)
	}
	if got := read(); got.Tables["investment_daily_snapshots"][0]["total_cny"] != "720" {
		t.Fatal("snapshot changed before the client submitted the recalculation")
	}
	snapshot["computed_revision"], snapshot["total_cny"], snapshot["total_usd"] = "2", "1080", "150"
	output.Generation = 3
	write(output, 200)
	got = read()
	if snapshots := got.Tables["investment_daily_snapshots"]; len(snapshots) != 1 || snapshots[0]["total_usd"] != "150" {
		t.Fatalf("same-day snapshot was not replaced: %+v", snapshots)
	}
}

func TestAdminInvestmentIsReadOnlyAndUsesTheIOSBook(t *testing.T) {
	f := newFixture(t, true)
	const path = "/consilium/api/investment/"
	guest := &adminClient{f: f}
	if status, _, _ := guest.request(http.MethodGet, path+"accounts", nil, "", ""); status != http.StatusUnauthorized {
		t.Fatalf("unauthenticated investment read = %d", status)
	}
	write := investmentWrite{Tables: investmentRows{
		"investment_accounts": {{"id": "account", "name": "测试账户", "currency": "CNY", "account_type": "securities", "sort_order": "0"}},
		"investment_events":   {{"id": "event", "account_id": "account", "event_type": "deposit", "effective_date": "2026-11-09", "sequence": "0", "amount": "100.25"}},
	}}
	if status, body := f.call(http.MethodPut, "/api/v1/investment/book", write, f.tokens.AccessToken); status != http.StatusOK {
		t.Fatalf("iOS investment write = %d %s", status, body)
	}
	admin := loginAdmin(f)
	for _, view := range []string{"overview", "accounts", "watchlist", "balance-sheet"} {
		status, html, _ := guest.request(http.MethodGet, "/consilium/investment/"+view, nil, "", "")
		if status != 200 || !strings.Contains(string(html), "investment-subnav") || strings.Contains(string(html), "测试账户") {
			t.Fatalf("investment shell %s = %d", view, status)
		}
		status, body, response := admin.request(http.MethodGet, path+view, nil, f.s.config.PublicURL, "")
		var book investmentState
		if err := json.Unmarshal(body, &book); err != nil || status != 200 || response.Header.Get("Cache-Control") != "no-store" ||
			book.Generation != 1 || len(book.Tables) != len(investmentAdminTables[view]) {
			t.Fatalf("investment view %s = %d %s (%v)", view, status, body, err)
		}
		for _, table := range investmentAdminTables[view] {
			if _, exists := book.Tables[table]; !exists {
				t.Fatalf("%s did not include %s", view, table)
			}
		}
		if view == "accounts" && book.Tables["investment_events"][0]["amount"] != "100.25" {
			t.Fatalf("admin read did not match the saved ledger: %s", body)
		}
	}
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		admin.call(method, "investment/accounts", write, http.StatusMethodNotAllowed)
	}
	admin.call(http.MethodGet, "investment/unknown", nil, http.StatusNotFound)
}
