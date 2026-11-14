package server

import (
	"encoding/json"
	"net/http"
	"testing"
)

// Source records are committed together after pruning derived snapshot references.
// An interrupted deletion must leave a valid, rebuildable ledger.
func TestInvestmentAccountDeletionWithSnapshotPruning(t *testing.T) {
	f := newFixture(t, true)
	const path = "/api/v1/investment/book"
	call := func(input *investmentWrite, expected int) investmentState {
		t.Helper()
		method := http.MethodGet
		var body any
		if input != nil {
			method, body = http.MethodPut, input
		}
		status, data := f.call(method, path, body, f.tokens.AccessToken)
		if status != expected {
			t.Fatalf("%s = %d %s, expected %d", method, status, data, expected)
		}
		var state investmentState
		if status == http.StatusOK {
			if err := json.Unmarshal(data, &state); err != nil {
				t.Fatal(err)
			}
		}
		return state
	}
	day := "2026-11-10"
	left := investmentRow{"id": "left", "name": "左", "account_type": "securities", "currency": "CNY", "sort_order": "0"}
	right := investmentRow{"id": "right", "name": "右", "account_type": "securities", "currency": "CNY", "sort_order": "1"}
	remaining := investmentRow{"id": "remaining", "account_id": "right", "event_type": "deposit", "effective_date": day, "sequence": "0", "amount": "10"}
	call(&investmentWrite{DirtyFrom: &day, Tables: investmentRows{
		"investment_accounts": {left, right},
		"investment_events": {
			{"id": "deposit", "account_id": "left", "event_type": "deposit", "effective_date": day, "sequence": "0", "amount": "100"},
			{"id": "out", "account_id": "left", "event_type": "transfer_out", "effective_date": day, "sequence": "1", "amount": "-50", "transfer_id": "transfer", "transfer_account_id": "right"},
			{"id": "in", "account_id": "right", "event_type": "transfer_in", "effective_date": day, "sequence": "1", "amount": "50", "transfer_id": "transfer", "transfer_account_id": "left"},
			remaining,
		},
		"investment_plans":     {{"id": "plan", "account_id": "left", "amount": "100", "month_day": "10", "next_date": "2026-12-10", "enabled": "1", "sort_order": "0"}},
		"investment_plan_runs": {{"plan_id": "plan", "scheduled_date": day, "status": "executed", "event_id": "deposit"}},
	}}, 200)
	snapshot := investmentRow{"snapshot_date": day, "computed_revision": "1", "status": "complete", "total_cny": "110"}
	rightDay := investmentRow{"account_id": "right", "snapshot_date": day, "cash_native": "60", "status": "complete"}
	call(&investmentWrite{Generation: 1, Through: &day, Tables: investmentRows{
		"investment_daily_snapshots": {snapshot},
		"investment_account_daily_snapshots": {
			{"account_id": "left", "snapshot_date": day, "cash_native": "50", "status": "complete"}, rightDay,
		},
	}}, 200)
	// Mixed source/output writes are forbidden by the current API.
	call(&investmentWrite{Generation: 2, Tables: investmentRows{
		"investment_accounts": {right}, "investment_account_daily_snapshots": {rightDay},
	}}, 400)
	call(&investmentWrite{Generation: 2, DirtyFrom: &day, Through: &day, Tables: investmentRows{
		"investment_account_daily_snapshots": {rightDay},
	}}, 200)
	// A failed source deletion preserves the accounts, transfer pair and plans.
	call(&investmentWrite{Generation: 3, DirtyFrom: &day, Through: &day, Tables: investmentRows{
		"investment_accounts": {right}, "investment_events": {remaining},
	}}, 400)
	retained := call(nil, 200)
	if retained.Generation != 3 || retained.DirtyFrom == nil || len(retained.Tables["investment_accounts"]) != 2 || len(retained.Tables["investment_events"]) != 4 {
		t.Fatalf("failed deletion changed source records or lost rebuild marker: %+v", retained)
	}
	call(&investmentWrite{Generation: 3, DirtyFrom: &day, Through: &day, Tables: investmentRows{
		"investment_accounts": {right}, "investment_events": {remaining}, "investment_plans": {}, "investment_plan_runs": {},
	}}, 200)
	deleted := call(nil, 200)
	if deleted.Revision != 2 || len(deleted.Tables["investment_accounts"]) != 1 || len(deleted.Tables["investment_events"]) != 1 || len(deleted.Tables["investment_plan_runs"]) != 0 {
		t.Fatalf("deletion did not remove associated input records: %+v", deleted)
	}
	snapshot["computed_revision"], snapshot["total_cny"], rightDay["cash_native"] = "2", "10", "10"
	call(&investmentWrite{Generation: 4, Through: &day, Tables: investmentRows{
		"investment_daily_snapshots": {snapshot}, "investment_account_daily_snapshots": {rightDay},
	}}, 200)
	if rebuilt := call(nil, 200); rebuilt.DirtyFrom != nil || rebuilt.Tables["investment_daily_snapshots"][0]["total_cny"] != "10" {
		t.Fatalf("deleted account remained in rebuilt history: %+v", rebuilt)
	}
}
