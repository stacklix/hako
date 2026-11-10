package server

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

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
	if got := read(); got.Generation != 1 || got.Tables["investment_events"][0]["amount"] != event["amount"] {
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
		got.Tables["market_daily_fx"][0]["rate"] != "7.123456789012345678" {
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
	const path = "/admin/api/investment/"
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
		status, html, _ := guest.request(http.MethodGet, "/admin/investment/"+view, nil, "", "")
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
