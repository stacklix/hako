package server

import (
	"encoding/json"
	"maps"
	"net/http"
	"path/filepath"
	"strings"
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

func TestEmptyPlanSchemaUpgradePreservesLedger(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hako.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO investment_books(owner_id,id) VALUES('owner','book');
		INSERT INTO investment_events(book_id,id,account_id,event_type,effective_date,amount) VALUES('book','event','account','deposit','2026-11-15','100.123456789');
		INSERT INTO investment_daily_snapshots(book_id,snapshot_date,total_cny,status) VALUES('book','2026-11-15','200.12','complete');
		ALTER TABLE investment_plans DROP COLUMN frequency;
		ALTER TABLE investment_plans RENAME COLUMN schedule_day TO month_day;
		PRAGMA user_version = 3;`)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var version int
	var amount, total string
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != investmentSchemaVersion {
		t.Fatalf("schema = %d (%v)", version, err)
	}
	if err := db.QueryRow("SELECT amount FROM investment_events WHERE id='event'").Scan(&amount); err != nil || amount != "100.123456789" {
		t.Fatalf("event = %s (%v)", amount, err)
	}
	if err := db.QueryRow("SELECT total_cny FROM investment_daily_snapshots").Scan(&total); err != nil || total != "200.12" {
		t.Fatalf("snapshot = %s (%v)", total, err)
	}
	if err := upgradeEmptyInvestmentPlans(db); err != nil {
		t.Fatal(err)
	}
}

func TestPlanSchemaUpgradeRefusesUnconvertedPlans(t *testing.T) {
	db, err := openInvestmentDB(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`ALTER TABLE investment_plans DROP COLUMN frequency;
		ALTER TABLE investment_plans RENAME COLUMN schedule_day TO month_day;
		INSERT INTO investment_plans(book_id,id,account_id,amount,month_day,next_date,enabled) VALUES('book','plan','account','100','8','2026-12-08',1);
		PRAGMA user_version = 3;`)
	if err != nil {
		t.Fatal(err)
	}
	if err := upgradeEmptyInvestmentPlans(db); err == nil || !strings.Contains(err.Error(), "no data was changed") {
		t.Fatalf("upgrade = %v", err)
	}
	var version, day int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 3 {
		t.Fatalf("schema changed: %d (%v)", version, err)
	}
	if err := db.QueryRow("SELECT month_day FROM investment_plans WHERE id='plan'").Scan(&day); err != nil || day != 8 {
		t.Fatalf("plan changed: %d (%v)", day, err)
	}
}
