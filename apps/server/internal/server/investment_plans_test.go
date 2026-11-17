package server

import (
	"encoding/json"
	"maps"
	"net/http"
	"testing"
)

func TestInvestmentPlanPeriodsValidateAndRoundTrip(t *testing.T) {
	f := newFixture(t, true)
	const path = "/api/v1/investment/book"
	plans := []investmentRow{}
	for _, period := range []struct{ frequency, day, next string }{
		{"daily", "0", "2026-11-16"}, {"weekly", "1", "2026-11-16"},
		{"biweekly", "7", "2026-11-22"}, {"monthly", "31", "2027-02-28"},
	} {
		plans = append(plans, investmentRow{"id": period.frequency, "account_id": "account", "amount": "100.25",
			"frequency": period.frequency, "schedule_day": period.day, "next_date": period.next, "enabled": "1"})
	}
	input := investmentWrite{Tables: investmentRows{
		"investment_accounts": {{"id": "account", "name": "定投", "currency": "CNY", "account_type": "securities", "sort_order": "0"}},
		"investment_plans":    plans,
	}}
	if status, body := f.call(http.MethodPut, path, input, f.tokens.AccessToken); status != http.StatusOK {
		t.Fatalf("write plans = %d %s", status, body)
	}
	for _, change := range []investmentRow{
		{"frequency": "hourly"}, {"frequency": "daily", "schedule_day": "1"},
		{"schedule_day": "0"}, {"schedule_day": "8"}, {"schedule_day": "1.5"},
		{"next_date": "2026-11-17"}, {"frequency": "biweekly", "schedule_day": "8"},
		{"frequency": "monthly", "schedule_day": "32"},
		{"frequency": "monthly", "schedule_day": "31", "next_date": "2027-02-27"},
		{"amount": "0"}, {"amount": "-100"}, {"month_day": "16"}, {"frequency": ""},
	} {
		row := maps.Clone(plans[1])
		maps.Copy(row, change)
		write := investmentWrite{Generation: 1, Tables: investmentRows{"investment_plans": {row}}}
		if status, body := f.call(http.MethodPut, path, write, f.tokens.AccessToken); status != http.StatusBadRequest {
			t.Fatalf("invalid plan %v = %d %s", change, status, body)
		}
	}
	legacy := maps.Clone(plans[3])
	delete(legacy, "frequency")
	if status, body := f.call(http.MethodPut, path, investmentWrite{Generation: 1, Tables: investmentRows{"investment_plans": {legacy}}}, f.tokens.AccessToken); status != http.StatusBadRequest {
		t.Fatalf("missing period = %d %s", status, body)
	}
	status, body := f.call(http.MethodGet, path, nil, f.tokens.AccessToken)
	var state investmentState
	if err := json.Unmarshal(body, &state); err != nil || status != http.StatusOK || state.Generation != 1 || len(state.Tables["investment_plans"]) != 4 {
		t.Fatalf("round trip after rejected writes = %d %s (%v)", status, body, err)
	}
	for _, row := range state.Tables["investment_plans"] {
		if !validInvestmentPlan(row) || row["month_day"] != "" {
			t.Fatalf("invalid persisted schedule: %v", row)
		}
	}
}
