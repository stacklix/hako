package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func marketCall(f *fixture, c AuthClientConfig, secret, method, path string, body any) *httptest.ResponseRecorder {
	data, _ := json.Marshal(body)
	r := httptest.NewRequest(method, f.s.config.PublicURL+path, bytes.NewReader(data))
	r.Header.Set("X-Hako-Client", c.ID)
	r.Header.Set("Authorization", "Bearer "+secret)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	return w
}

func setupMarketBook(t *testing.T, f *fixture) investmentState {
	t.Helper()
	day := time.Now().UTC().AddDate(0, 0, -2).Format(time.DateOnly)
	state, err := f.s.persistInvestment(context.Background(), f.s.investmentSubject(), investmentWrite{Tables: investmentRows{
		"market_instruments":       {{"id": "btc", "asset_type": "crypto", "symbol": "BTCUSDT", "exchange": "BINANCE", "name": "BTC", "quote_currency": "USD", "price_type": "close"}},
		"investment_assets":        {{"id": "asset", "instrument_id": "btc", "asset_type": "crypto", "symbol": "BTCUSDT", "name": "BTC", "quote_currency": "USD", "settlement_unit": "USD"}},
		"investment_accounts":      {{"id": "account", "name": "Private Account", "account_type": "crypto", "currency": "USD", "sort_order": "0"}},
		"investment_events":        {{"id": "buy", "account_id": "account", "asset_id": "asset", "event_type": "opening", "effective_date": day, "quantity": "0.058", "sequence": "0"}},
		"investment_manual_prices": {{"asset_id": "asset", "valuation_date": day, "value": "90", "source": "manual", "is_final": "1"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestMarketPermissionsLatestOverwriteAndLedgerIsolation(t *testing.T) {
	f := newFixture(t, true)
	base := setupMarketBook(t, f)
	c, secret := appTestClient(f, "app_market")
	path := "/api/v1/market/update-targets"
	if w := marketCall(f, c, secret, "GET", path, nil); w.Code != 403 {
		t.Fatal(w.Code, w.Body.String())
	}
	c.MarketReadEnabled = true
	if err := f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil }); err != nil {
		t.Fatal(err)
	}
	w := marketCall(f, c, secret, "GET", path, nil)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var list struct {
		Targets []marketTarget `json:"targets"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(w.Body.Bytes(), []byte("Private Account")) || bytes.Contains(w.Body.Bytes(), []byte("0.058")) {
		t.Fatal("private ledger disclosed")
	}
	var latest marketTarget
	for _, target := range list.Targets {
		if target.Kind == "latest" && target.InstrumentID == "btc" {
			latest = target
		}
	}
	if latest.ID == "" {
		t.Fatal("no latest target", list)
	}
	observed := time.Now().UTC().Format(time.RFC3339Nano)
	item := marketUpdateItem{TargetID: latest.ID, Quotes: []marketObservation{{Date: latest.Through, Value: "100.1234", ObservedAt: observed}}}
	body := map[string]any{"items": []marketUpdateItem{item}}
	if w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", body); w.Code != 403 {
		t.Fatal("read permission allowed writes", w.Code)
	}
	c.MarketWriteEnabled = true
	if err := f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil }); err != nil {
		t.Fatal(err)
	}
	if w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", body); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var generation, revision int64
	if err := f.s.investment.QueryRow("SELECT generation,revision FROM investment_books").Scan(&generation, &revision); err != nil {
		t.Fatal(err)
	}
	if generation != base.Generation || revision != base.Revision+1 {
		t.Fatal("market writes must not advance ledger generation", generation, revision)
	}
	if w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", body); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var after int64
	f.s.investment.QueryRow("SELECT revision FROM investment_books").Scan(&after)
	if after != revision {
		t.Fatal("retry changed revision")
	}
	item.Quotes[0].ObservedAt = time.Now().Add(-time.Minute).UTC().Format(time.RFC3339Nano)
	item.Quotes[0].Value = "1"
	w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", map[string]any{"items": []marketUpdateItem{item}})
	var price, manual string
	f.s.investment.QueryRow("SELECT price FROM market_daily_prices").Scan(&price)
	f.s.investment.QueryRow("SELECT value FROM investment_manual_prices").Scan(&manual)
	if w.Code != 200 || price != "100.1234" || manual != "90" {
		t.Fatal("old quote or manual value overwritten", price, manual, w.Body.String())
	}
	item.Quotes[0].ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	item.Quotes[0].Value = "101"
	w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", map[string]any{"items": []marketUpdateItem{item}})
	f.s.investment.QueryRow("SELECT price FROM market_daily_prices").Scan(&price)
	if w.Code != 200 || price != "101" {
		t.Fatal("newer quote failed to replace the same observation", price, w.Body.String())
	}
	// Ledger edits based on the pre-market version are still valid.
	_, err := f.s.persistInvestmentChanges(context.Background(), f.s.investmentSubject(), investmentChangeWrite{Generation: base.Generation, Changes: investmentChanges{"investment_accounts": {Upserts: []investmentRow{{"id": "account", "name": "Renamed", "account_type": "crypto", "currency": "USD", "sort_order": "0"}}}}})
	if err != nil {
		t.Fatal("market feed conflicted with ledger edit", err)
	}
	// Another application's key cannot reuse this application's signed targets.
	other, otherSecret := appTestClient(f, "app_other")
	other.MarketWriteEnabled = true
	f.s.store.update(func(st *state) error { st.AuthClients[other.ID] = other; return nil })
	w = marketCall(f, other, otherSecret, "POST", "/api/v1/market/quote-batches", body)
	if w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte("invalid_or_expired_target")) {
		t.Fatal("cross-application target accepted", w.Code, w.Body.String())
	}
	c.Enabled = false
	f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
	if w = marketCall(f, c, secret, "GET", path, nil); w.Code != 401 {
		t.Fatal("disabled application accepted", w.Code)
	}
}

func TestManagedApplicationMarketPermissions(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	created := createManagedApplication(f, a)
	if created.Application.MarketReadEnabled || created.Application.MarketWriteEnabled {
		t.Fatal("market permissions must require explicit enablement")
	}
	data := a.call("PATCH", "applications/"+created.Application.ID, map[string]bool{"marketReadEnabled": true, "marketWriteEnabled": true}, 200)
	if !bytes.Contains(data, []byte(`"marketReadEnabled":true`)) || !bytes.Contains(data, []byte(`"marketWriteEnabled":true`)) {
		t.Fatal("permission response missing", string(data))
	}
	c, _ := f.s.authClient(created.Application.ID)
	if !c.MarketReadEnabled || !c.MarketWriteEnabled {
		t.Fatal("permissions not persisted")
	}
	if w := marketCall(f, c, created.Secret, "GET", "/api/v1/market/update-targets", nil); w.Code != 200 {
		t.Fatal("enabled application cannot query market targets", w.Code, w.Body.String())
	}
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"marketWriteEnabled": false}, 200)
	if w := marketCall(f, c, created.Secret, "POST", "/api/v1/market/quote-batches", map[string]any{"items": []any{}}); w.Code != 403 {
		t.Fatal("revoked permission still allowed writes", w.Code)
	}
}

func TestMarketValidationItemAtomicityAndCoverage(t *testing.T) {
	f := newFixture(t, true)
	setupMarketBook(t, f)
	c, secret := appTestClient(f, "app_market")
	c.MarketReadEnabled = true
	c.MarketWriteEnabled = true
	f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
	w := marketCall(f, c, secret, "GET", "/api/v1/market/update-targets", nil)
	var list struct {
		Targets []marketTarget `json:"targets"`
	}
	json.Unmarshal(w.Body.Bytes(), &list)
	var target marketTarget
	for _, entry := range list.Targets {
		if entry.Kind == "daily_close" {
			target = entry
			break
		}
	}
	if target.ID == "" {
		t.Fatal("history target missing")
	}
	observed := time.Now().UTC().Format(time.RFC3339Nano)
	item := marketUpdateItem{TargetID: target.ID, Quotes: []marketObservation{{Date: target.From, Value: "10", ObservedAt: observed}, {Date: target.Through, Value: "10.00001", ObservedAt: observed}}}
	w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", map[string]any{"items": []marketUpdateItem{item}})
	if w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte("invalid_quote_or_precision")) {
		t.Fatal(w.Code, w.Body.String())
	}
	var count int
	f.s.investment.QueryRow("SELECT COUNT(*) FROM market_daily_prices").Scan(&count)
	if count != 0 {
		t.Fatal("invalid item partially saved")
	}
	// Explicit provider coverage with no observations records an empty session, not a zero price.
	item.Quotes = nil
	item.Complete = true
	w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", map[string]any{"items": []marketUpdateItem{item}})
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	f.s.investment.QueryRow("SELECT COUNT(*) FROM market_daily_prices").Scan(&count)
	if count != 0 {
		t.Fatal("fabricated quote")
	}
	coverage := false
	f.s.store.inspect(func(st state) {
		for _, entry := range st.MarketCoverage {
			coverage = coverage || len(entry.NoDataDates) > 0
		}
	})
	if !coverage {
		t.Fatal("coverage not recorded")
	}
	item.TargetID += "tamper"
	w = marketCall(f, c, secret, "POST", "/api/v1/market/quote-batches", map[string]any{"items": []marketUpdateItem{item}})
	if !bytes.Contains(w.Body.Bytes(), []byte("invalid_or_expired_target")) {
		t.Fatal("modified target accepted")
	}
}
