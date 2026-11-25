package server

import (
	"context"
	"path/filepath"
	"testing"
)

const legacyMarketDDL = `DROP TABLE market_daily_prices;DROP TABLE market_derivative_specs;DROP TABLE market_instruments;
 CREATE TABLE market_instruments(book_id TEXT NOT NULL,id TEXT NOT NULL,asset_type TEXT,symbol TEXT,exchange TEXT,name TEXT,quote_currency TEXT,price_type TEXT,PRIMARY KEY(book_id,id)) WITHOUT ROWID;
 CREATE TABLE market_derivative_specs(book_id TEXT NOT NULL,instrument_id TEXT NOT NULL,contract_multiplier TEXT,expiry_date TEXT,PRIMARY KEY(book_id,instrument_id)) WITHOUT ROWID;
 CREATE TABLE market_daily_prices(book_id TEXT NOT NULL,instrument_id TEXT NOT NULL,session_date TEXT NOT NULL,price_type TEXT NOT NULL,source TEXT NOT NULL,closed_at_utc TEXT,valuation_date TEXT,price TEXT,is_final INTEGER,revision INTEGER,PRIMARY KEY(book_id,instrument_id,session_date,price_type,source)) WITHOUT ROWID;`

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

func TestGlobalMarketMigrationRemapsReferencesAndDeduplicates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "main.sqlite")
	db, err := openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(legacyMarketDDL); err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO investment_books(owner_id,id,generation,revision) VALUES('a','a',2,3),('b','b',4,5);
	 INSERT INTO market_instruments VALUES('a','old-a','stock','00700.HK','HK_CONNECT','腾讯','HKD','close'),('b','old-b','stock','700','XHKG','Tencent','HKD','close');
	 INSERT INTO investment_assets(book_id,id,instrument_id,name,asset_type,settlement_unit,symbol,quote_currency) VALUES('a','asset-a','old-a','腾讯','stock','CNY','00700.HK','HKD'),('b','asset-b','old-b','Tencent','stock','HKD','700','HKD');
	 INSERT INTO investment_accounts(book_id,id,name,account_type,currency,sort_order) VALUES('a','account','Account','securities','CNY',0);
	 INSERT INTO investment_events(book_id,id,account_id,asset_id,event_type,effective_date,quantity,unit_price) VALUES('a','event','account','asset-a','opening','2026-11-20','100','300');
	 INSERT INTO investment_watchlist(book_id,asset_id,instrument_id,sort_order) VALUES('a','asset-a','old-a',0);
	 INSERT INTO investment_manual_prices(book_id,asset_id,valuation_date,value,source,is_final) VALUES('a','asset-a','2026-11-19','299','手动录入',1);
	 INSERT INTO market_daily_prices VALUES('a','old-a','2026-11-20','close','one','2026-11-20T08:00:00Z','2026-11-20','300.1234',1,3),('b','old-b','2026-11-20','close','two','2026-11-20T09:00:00Z','2026-11-20','301.5678',1,4),('b','old-b','2026-11-20','close','temp','2026-11-20T10:00:00Z','2026-11-20','999',0,5);
	 PRAGMA user_version=8;`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = openInvestmentDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count, version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 9 {
		t.Fatal(version, err)
	}
	if err = db.QueryRow("SELECT COUNT(*) FROM market_instruments").Scan(&count); err != nil || count != 1 {
		t.Fatal(count, err)
	}
	var id, rate, source, exchange, quantity, price string
	if err = db.QueryRow("SELECT instrument_id,price,source FROM market_daily_prices").Scan(&id, &rate, &source); err != nil || id != "STOCK:HK:00700.HK:HKD" || rate != "301.5678" || source != "two" {
		t.Fatal(id, rate, source, err)
	}
	if err = db.QueryRow("SELECT instrument_id,exchange FROM investment_assets WHERE book_id='a'").Scan(&id, &exchange); err != nil || id != "STOCK:HK:00700.HK:HKD" || exchange != "HK_CONNECT" {
		t.Fatal(id, exchange, err)
	}
	if err = db.QueryRow("SELECT quantity,unit_price FROM investment_events").Scan(&quantity, &price); err != nil || quantity != "100" || price != "300" {
		t.Fatal(quantity, price, err)
	}
	if err = db.QueryRow("SELECT instrument_id FROM investment_watchlist").Scan(&id); err != nil || id != "STOCK:HK:00700.HK:HKD" {
		t.Fatal(id, err)
	}
	if err = db.QueryRow("SELECT value FROM investment_manual_prices").Scan(&rate); err != nil || rate != "299" {
		t.Fatal(rate, err)
	}
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if err = validateInvestmentLinks(context.Background(), tx, "a"); err != nil {
		t.Fatal(err)
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
