package server

import (
	"context"
	"testing"
)

func TestGlobalInstrumentIdentity(t *testing.T) {
	for _, tc := range []struct{ kind, code, exchange, currency, want string }{
		{"etf", "QQQM", "IEXG", "USD", "ETF:US:QQQM:USD"},
		{"etf", "qqqm.us", "XNMS", "USD", "ETF:US:QQQM:USD"},
		{"stock", "700", "HK_CONNECT", "HKD", "STOCK:HK:00700.HK:HKD"},
		{"stock", "00700.HK", "XHKG", "HKD", "STOCK:HK:00700.HK:HKD"},
		{"fund", "017302", "OF", "CNY", "FUND:CN:017302.OF:CNY"},
		{"fund", "017302.OF", "", "CNY", "FUND:CN:017302.OF:CNY"},
		{"etf", "159941", "XSHE", "CNY", "ETF:CN:159941.SZ:CNY"},
		{"crypto", "BTCUSDT", "BINANCE", "USD", "CRYPTO:CRYPTO:BTC:USD"},
		{"crypto", "BTC/USD", "", "USD", "CRYPTO:CRYPTO:BTC:USD"},
		{"stock", "BRK/B", "NYSE", "USD", "STOCK:US:BRK%2FB:USD"},
	} {
		row := canonicalInvestmentInstrument(investmentRow{"asset_type": tc.kind, "symbol": tc.code, "exchange": tc.exchange, "quote_currency": tc.currency})
		if row["id"] != tc.want {
			t.Fatalf("%+v => %s", tc, row["id"])
		}
	}
}

func TestGlobalPricesAreSharedAndCannotBeDowngraded(t *testing.T) {
	f := newFixture(t, true)
	ctx := context.Background()
	instrument := investmentRow{"id": "ETF:US:QQQM:USD", "asset_type": "etf", "symbol": "QQQM", "exchange": "US", "quote_currency": "USD", "name": "QQQM", "price_type": "close"}
	for _, owner := range []string{"a", "b"} {
		_, err := f.s.persistInvestment(ctx, owner, investmentWrite{Tables: investmentRows{"market_instruments": {instrument}, "investment_assets": {{"id": "asset", "name": "QQQM", "asset_type": "etf", "quote_currency": "USD", "settlement_unit": "USD", "instrument_id": instrument["id"]}}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	put := func(source, final, price string) investmentChangeResult {
		t.Helper()
		result, err := f.s.persistInvestmentChanges(ctx, "a", investmentChangeWrite{Changes: investmentChanges{"market_daily_prices": {Upserts: []investmentRow{{"instrument_id": instrument["id"], "session_date": "2026-11-20", "valuation_date": "2026-11-21", "price_type": "close", "source": source, "price": price, "is_final": final}}}}})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	put("first", "0", "100")
	final := put("second", "1", "101")
	ignored := put("third", "0", "999")
	if ignored.Revision != final.Revision || ignored.Changes["market_daily_prices"].Upserts[0]["price"] != "101" {
		t.Fatal(ignored)
	}
	tx, err := f.s.investment.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	book, err := readInvestmentState(ctx, tx, "b", nil)
	if err != nil || len(book.Tables["market_daily_prices"]) != 1 || book.Tables["market_daily_prices"][0]["price"] != "101" || book.DirtyFrom == nil || *book.DirtyFrom != "2026-11-21" {
		t.Fatal(book, err)
	}
}
