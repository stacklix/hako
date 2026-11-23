package server

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestInvestmentWriteStoresAndReturnsRoundedNumbers(t *testing.T) {
	f := newFixture(t, true)
	day := "2026-11-17"
	input := investmentWrite{DirtyFrom: &day, Tables: investmentRows{
		"investment_accounts": {{"id": "account", "name": "精度测试", "currency": "CNY", "account_type": "securities", "sort_order": "0"}},
		"investment_assets":   {{"id": "asset", "name": "股票", "asset_type": "stock", "symbol": "600000", "quote_currency": "CNY", "settlement_unit": "CNY"}},
		"investment_events": {{"id": "trade", "account_id": "account", "asset_id": "asset", "event_type": "buy", "effective_date": day,
			"sequence": "7", "amount": "100.12345", "quantity": "0.00123456", "unit_price": "12.3456", "fee": "0.00567", "settled_amount": "100.12345"}},
		"market_daily_fx": {{"rate_date": day, "base_currency": "USD", "quote_currency": "CNY", "source": "test", "rate": "7.1234567"}},
	}}
	status, body := f.call(http.MethodPut, "/api/v1/investment/book", input, f.tokens.AccessToken)
	var saved investmentState
	if err := json.Unmarshal(body, &saved); err != nil || status != http.StatusOK {
		t.Fatalf("write = %d %s %v", status, body, err)
	}
	trade := saved.Tables["investment_events"][0]
	if trade["quantity"] != "0.00123456" || trade["unit_price"] != "12.3456" || trade["fee"] != "0.0057" || trade["amount"] != "100.12" || trade["settled_amount"] != "100.12" || trade["sequence"] != "7" || saved.Tables["market_daily_fx"][0]["rate"] != "7.1235" {
		t.Fatalf("response was not normalized: %+v", saved)
	}
	var quantity, price, rate string
	if err := f.s.investment.QueryRow("SELECT quantity,unit_price FROM investment_events WHERE id='trade'").Scan(&quantity, &price); err != nil {
		t.Fatal(err)
	}
	if err := f.s.investment.QueryRow("SELECT rate FROM market_daily_fx").Scan(&rate); err != nil {
		t.Fatal(err)
	}
	if quantity != trade["quantity"] || price != trade["unit_price"] || rate != "7.1235" {
		t.Fatal("response precision differs from stored database values")
	}
}

func TestInvestmentDecimalPrecision(t *testing.T) {
	for _, test := range []struct {
		input, want string
		fx          bool
	}{
		{"461884.88406188735462735462735462735462", "461884.88", false},
		{"460997.5774186740512075540221536266206", "460997.58", false},
		{"7.123456789012345678", "7.1235", true},
		{"0.00123456", "0.0012", false},
		{"1.00123456", "1", false},
		{"-1.00123456", "-1", false},
		{"1.00496", "1", false},
		{"1.00999", "1.01", false},
		{"9.99999", "10", false},
		{"-12.345", "-12.35", false},
		{"0.00005", "0.0001", false},
		{"-0.000049", "0", false},
		{"9007199254740993.0001", "9007199254740993", false},
		{"123456789012345678901234567890.125", "123456789012345678901234567890.13", false},
	} {
		t.Run(test.input, func(t *testing.T) {
			if got := investmentRoundedDecimal(test.input, test.fx); got != test.want {
				t.Fatalf("round = %s, want %s", got, test.want)
			}
			if got := investmentRoundedDecimal(test.want, test.fx); got != test.want {
				t.Fatalf("rounding is not idempotent: %s", got)
			}
		})
	}
}

func TestInvestmentCryptoQuantitySurvivesWriteAndRead(t *testing.T) {
	for _, units := range []string{"0.058", "0.00000001", "1.123456789012345678"} {
		t.Run(units, func(t *testing.T) {
			f := newFixture(t, true)
			input := investmentWrite{Tables: investmentRows{
				"investment_accounts": {{"id": "account", "name": "Crypto", "currency": "USD", "account_type": "crypto", "sort_order": "0"}},
				"investment_assets":   {{"id": "btc", "name": "Bitcoin", "asset_type": "crypto", "symbol": "BTC", "quote_currency": "USD", "settlement_unit": "USD"}},
				"investment_events":   {{"id": "trade", "account_id": "account", "asset_id": "btc", "event_type": "opening", "effective_date": "2026-11-23", "sequence": "0", "amount": "0", "quantity": units, "unit_price": "71504"}},
			}}
			status, body := f.call(http.MethodPut, "/api/v1/investment/book", input, f.tokens.AccessToken)
			if status != http.StatusOK {
				t.Fatalf("write = %d %s", status, body)
			}
			var saved investmentState
			if err := json.Unmarshal(body, &saved); err != nil {
				t.Fatal(err)
			}
			if saved.Tables["investment_events"][0]["quantity"] != units {
				t.Fatalf("write changed quantity: %s", body)
			}
			status, body = f.call(http.MethodGet, "/api/v1/investment/book", nil, f.tokens.AccessToken)
			if status != http.StatusOK {
				t.Fatalf("read = %d %s", status, body)
			}
			if err := json.Unmarshal(body, &saved); err != nil {
				t.Fatal(err)
			}
			if saved.Tables["investment_events"][0]["quantity"] != units {
				t.Fatalf("read changed quantity: %s", body)
			}
			var stored string
			if err := f.s.investment.QueryRow("SELECT quantity FROM investment_events WHERE id='trade'").Scan(&stored); err != nil {
				t.Fatal(err)
			}
			if stored != units {
				t.Fatalf("stored quantity = %s, want %s", stored, units)
			}
		})
	}
}

func TestInvestmentPricePrecision(t *testing.T) {
	for _, value := range []string{"12.3456", "1.005", "0.0123", "0.0001", "71504.1234"} {
		row := investmentRow{"unit_price": value, "price": value, "amount": value}
		normalizeInvestmentNumbers(row)
		if row["unit_price"] != value || row["price"] != value {
			t.Fatalf("price lost precision: %+v", row)
		}
		if row["amount"] != investmentRoundedDecimal(value, false) {
			t.Fatalf("amount precision changed: %+v", row)
		}
	}
	row := investmentRow{"unit_price": "12.34565", "price": "0.99999"}
	normalizeInvestmentNumbers(row)
	if row["unit_price"] != "12.3457" || row["price"] != "1" {
		t.Fatalf("prices must round to four places: %+v", row)
	}
}
