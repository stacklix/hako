package server

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testTradingCalendar(market string, year int, closed ...string) tradingCalendar {
	c := tradingCalendar{Market: market, Year: year, Source: "test", SessionOverrides: map[string][]marketSession{}}
	var days strings.Builder
	for day := time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC); day.Year() == year; day = day.AddDate(0, 0, 1) {
		open := day.Weekday() != time.Saturday && day.Weekday() != time.Sunday
		for _, date := range closed {
			if date == day.Format(time.DateOnly) {
				open = false
			}
		}
		if open {
			days.WriteByte('1')
		} else {
			days.WriteByte('0')
		}
	}
	c.TradingDays = days.String()
	return c
}

func TestTradingCalendarPublicReadAndIndependentWritePermission(t *testing.T) {
	f := newFixture(t, true)
	a := loginAdmin(f)
	created := createManagedApplication(f, a)
	c, _ := f.s.authClient(created.Application.ID)
	calendar := testTradingCalendar("US", 2026, "2026-11-26")
	calendar.SessionOverrides["2026-11-27"] = []marketSession{{"09:30", "13:00"}}
	body := map[string]any{"market": calendar.Market, "year": calendar.Year, "tradingDays": calendar.TradingDays, "source": "Tushare", "sessionOverrides": calendar.SessionOverrides, "expectedRevision": 0}
	call := func() *httptest.ResponseRecorder {
		return marketCall(f, c, created.Secret, "PUT", "/api/v1/market/calendars", body)
	}
	if w := call(); w.Code != 403 {
		t.Fatal("calendar writes default to off", w.Code, w.Body.String())
	}
	c.MarketWriteEnabled = true
	f.s.store.update(func(st *state) error { st.AuthClients[c.ID] = c; return nil })
	if w := call(); w.Code != 403 {
		t.Fatal("quote permission must not grant calendar writes", w.Code)
	}
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"calendarWriteEnabled": true}, 200)
	if w := call(); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	r := httptest.NewRequest("GET", "/api/v1/market/calendars?market=US&year=2026", nil)
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	var saved tradingCalendar
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &saved) != nil || saved.TradingDays != calendar.TradingDays || saved.Revision != 1 || saved.UpdatedBy != c.ID {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := call(); w.Code != 409 {
		t.Fatal("stale writer overwrote the calendar", w.Code)
	}
	body["expectedRevision"] = 1
	body["tradingDays"] = "101"
	if w := call(); w.Code != 400 {
		t.Fatal("partial calendar was accepted", w.Code)
	}
	body["tradingDays"] = calendar.TradingDays
	a.call("PATCH", "applications/"+c.ID, map[string]bool{"calendarWriteEnabled": false}, 200)
	if w := call(); w.Code != 403 {
		t.Fatal("revoked permission still allowed writes", w.Code)
	}
	w = httptest.NewRecorder()
	f.s.ServeHTTP(w, r.Clone(r.Context()))
	if w.Code != 200 {
		t.Fatal("read must stay public after write revocation", w.Code)
	}
	// Public reads never grant write authentication, including browser-origin requests.
	data, _ := json.Marshal(body)
	anonymous := httptest.NewRequest("PUT", "/api/v1/market/calendars", bytes.NewReader(data))
	w = httptest.NewRecorder()
	f.s.ServeHTTP(w, anonymous)
	if w.Code != 401 {
		t.Fatal("anonymous calendar write accepted", w.Code)
	}
}

func TestMarketTargetReadIsAnonymousButWritesStayAuthenticated(t *testing.T) {
	f := newFixture(t, true)
	setupMarketBook(t, f)
	r := httptest.NewRequest("GET", "/api/v1/market/update-targets", nil)
	r.Header.Set("Origin", "https://third-party.example")
	w := httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	if w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte(`"targetId"`)) {
		t.Fatal("market reads must not need application credentials", w.Code, w.Body.String())
	}
	if bytes.Contains(w.Body.Bytes(), []byte("Private Account")) || bytes.Contains(w.Body.Bytes(), []byte("0.058")) {
		t.Fatal("public read leaked ledger details")
	}
	r = httptest.NewRequest("POST", "/api/v1/market/quote-batches", strings.NewReader(`{"items":[]}`))
	w = httptest.NewRecorder()
	f.s.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("public read granted anonymous write access", w.Code)
	}
}

func TestTradingCalendarValidation(t *testing.T) {
	for _, year := range []int{2026, 2028, 2000, 2100} {
		c := testTradingCalendar("CN_A", year)
		if !validTradingCalendar(c) {
			t.Fatal("valid year rejected", year)
		}
		c.TradingDays += "1"
		if validTradingCalendar(c) {
			t.Fatal("wrong year length accepted", year)
		}
	}
	c := testTradingCalendar("US", 2026, "2026-11-26")
	for _, sessions := range [][]marketSession{{{"16:00", "09:30"}}, {{"09:30", "12:00"}, {"11:30", "16:00"}}, {{"9:30", "16:00"}}, nil} {
		c.SessionOverrides = map[string][]marketSession{"2026-11-27": sessions}
		if validTradingCalendar(c) {
			t.Fatal("invalid sessions accepted", sessions)
		}
	}
	c.SessionOverrides = map[string][]marketSession{"2026-11-26": {{"09:30", "16:00"}}}
	if validTradingCalendar(c) {
		t.Fatal("closed day accepted an open session")
	}
	c.SessionOverrides = map[string][]marketSession{}
	c.TradingDays = "2" + c.TradingDays[1:]
	if validTradingCalendar(c) {
		t.Fatal("nonbinary date accepted")
	}
}

func TestMarketTargetsUseSharedAnnualCalendar(t *testing.T) {
	f := newFixture(t, true)
	id := "ETF:US:SPYM:USD"
	c := testTradingCalendar("US", 2026, "2026-11-26")
	c.SessionOverrides["2026-11-27"] = []marketSession{{"09:30", "13:00"}}
	book := investmentState{Calendars: []tradingCalendar{c}, Tables: investmentRows{
		"market_instruments":   {{"id": id, "asset_type": "etf", "symbol": "SPYM", "exchange": "US", "quote_currency": "USD", "price_type": "close"}},
		"investment_assets":    {{"id": "spym", "instrument_id": id}},
		"investment_watchlist": {{"asset_id": "spym"}},
	}}
	for _, at := range []string{"2026-11-26T05:00:00Z", "2026-11-26T18:00:00Z", "2026-11-27T14:29:59Z"} {
		now, _ := time.Parse(time.RFC3339, at)
		targets := f.s.marketTargets(AuthClientConfig{}, "owner", book, now)
		if len(targets) != 1 || targets[0].Kind != "daily_close" || targets[0].From != "2026-11-25" || targets[0].Through != "2026-11-25" {
			t.Fatal(at, targets)
		}
	}
	book.Tables["market_daily_prices"] = []investmentRow{{"instrument_id": id, "session_date": "2026-11-25", "price_type": "close", "is_final": "1"}}
	for _, tc := range []struct {
		at        string
		count     int
		kind, day string
	}{
		{"2026-11-26T18:00:00Z", 0, "", ""},
		{"2026-11-27T14:30:00Z", 1, "latest", "2026-11-27"},
		{"2026-11-27T18:00:00Z", 1, "daily_close", "2026-11-27"},
	} {
		now, _ := time.Parse(time.RFC3339, tc.at)
		targets := f.s.marketTargets(AuthClientConfig{}, "owner", book, now)
		if len(targets) != tc.count || (tc.count > 0 && (targets[0].Kind != tc.kind || targets[0].Through != tc.day)) {
			t.Fatal(tc.at, targets)
		}
	}
	book.Calendars = nil
	now, _ := time.Parse(time.RFC3339, "2026-11-27T15:00:00Z")
	if got := f.s.marketTargets(AuthClientConfig{}, "owner", book, now); len(got) != 0 {
		t.Fatal("unknown calendar guessed an open session", got)
	}
}

func TestCalendarTimeZonesLunchAndYearBoundary(t *testing.T) {
	calendars := []tradingCalendar{testTradingCalendar("US", 2026), testTradingCalendar("US", 2025), testTradingCalendar("CN_A", 2026)}
	for _, tc := range []struct {
		market, at string
		open       bool
	}{
		{"US", "2026-03-06T14:30:00Z", true},
		{"US", "2026-03-09T13:29:59Z", false},
		{"US", "2026-03-09T13:30:00Z", true},
		{"CN_A", "2026-11-26T03:29:59Z", true},
		{"CN_A", "2026-11-26T03:30:00Z", false},
		{"CN_A", "2026-11-26T05:00:00Z", true},
		{"CN_A", "2026-11-26T07:00:00Z", false},
	} {
		now, _ := time.Parse(time.RFC3339, tc.at)
		if got := calendarLatestAvailable(calendars, tc.market, now); got != tc.open {
			t.Fatal(tc, got)
		}
	}
	now, _ := time.Parse(time.RFC3339, "2026-01-01T05:00:00Z")
	if day, known := calendarLastClose(calendars, "US", now); !known || day != "2025-12-31" {
		t.Fatal(day, known)
	}
}
