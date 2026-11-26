package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const marketCalendarsSQL = `CREATE TABLE market_trading_calendars (
	market TEXT NOT NULL CHECK(market IN ('CN_A','US','HK')),
	year INTEGER NOT NULL CHECK(year BETWEEN 1970 AND 2100),
	trading_days TEXT NOT NULL CHECK(trading_days NOT GLOB '*[^01]*' AND
	 length(trading_days)=CASE WHEN year%4=0 AND (year%100<>0 OR year%400=0) THEN 366 ELSE 365 END),
	session_overrides TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(session_overrides)),
	source TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	updated_by TEXT NOT NULL,
	revision INTEGER NOT NULL CHECK(revision>0),
	PRIMARY KEY(market,year)
) WITHOUT ROWID`

type marketSession struct {
	Open  string `json:"open"`
	Close string `json:"close"`
}

type tradingCalendar struct {
	Market           string                     `json:"market"`
	Year             int                        `json:"year"`
	TradingDays      string                     `json:"tradingDays"`
	SessionOverrides map[string][]marketSession `json:"sessionOverrides"`
	Source           string                     `json:"source"`
	UpdatedAt        string                     `json:"updatedAt"`
	UpdatedBy        string                     `json:"updatedBy"`
	Revision         int64                      `json:"revision"`
}

type calendarRequest struct {
	Market string `json:"market"`
	Year   int    `json:"year"`
}

func missingMarketCalendars(book investmentState, now time.Time) []calendarRequest {
	markets := map[string]bool{}
	for _, instrument := range book.Tables["market_instruments"] {
		if market := calendarMarket(instrument); market != "" {
			markets[market] = true
		}
	}
	result := []calendarRequest{}
	for market := range markets {
		year := now.In(calendarLocation(market)).Year()
		first := year - 1
		for _, event := range book.Tables["investment_events"] {
			if date, err := time.Parse(time.DateOnly, event["effective_date"]); err == nil && date.Year() < first {
				first = date.Year()
			}
		}
		for candidate := max(first, 1970); candidate <= min(year, 2100); candidate++ {
			found := false
			for _, c := range book.Calendars {
				if c.Market == market && c.Year == candidate {
					found = true
					break
				}
			}
			if !found {
				result = append(result, calendarRequest{market, candidate})
			}
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Market == result[j].Market {
			return result[i].Year < result[j].Year
		}
		return result[i].Market < result[j].Market
	})
	return result
}

func calendarLocation(market string) *time.Location {
	switch market {
	case "CN_A":
		return marketLocation("")
	case "US":
		return marketLocation("US")
	case "HK":
		return marketLocation("HK")
	}
	return nil
}

func calendarMarket(instrument investmentRow) string {
	if instrument["asset_type"] != "stock" && instrument["asset_type"] != "etf" {
		return ""
	}
	switch strings.ToUpper(instrument["exchange"]) {
	case "SH", "SZ", "BJ", "SSE", "SZSE", "BSE", "XSHG", "XSHE", "XBSE":
		return "CN_A"
	case "US", "NASDAQ", "NYSE", "AMEX", "XNAS", "XNYS", "XASE", "ARCX", "BATS", "BATY", "EDGA", "EDGX", "XNGS", "XNMS", "XNCM", "XOTC", "OTCM", "IEXG", "MEMX":
		return "US"
	case "HK", "HKEX", "XHKG", "HK_CONNECT":
		return "HK"
	}
	return ""
}

func (c tradingCalendar) sessions(date time.Time) ([]marketSession, bool) {
	if date.Year() != c.Year || date.YearDay() > len(c.TradingDays) {
		return nil, false
	}
	if c.TradingDays[date.YearDay()-1] == '0' {
		return nil, true
	}
	if sessions, exists := c.SessionOverrides[date.Format(time.DateOnly)]; exists {
		return sessions, true
	}
	switch c.Market {
	case "CN_A":
		return []marketSession{{"09:30", "11:30"}, {"13:00", "15:00"}}, true
	case "US":
		return []marketSession{{"09:30", "16:00"}}, true
	case "HK":
		return []marketSession{{"09:30", "12:00"}, {"13:00", "16:00"}}, true
	}
	return nil, false
}

func calendarTime(day time.Time, text string) time.Time {
	value, _ := time.ParseInLocation("2006-01-02 15:04", day.Format(time.DateOnly)+" "+text, day.Location())
	return value
}

func calendarSessions(calendars []tradingCalendar, market string, day time.Time) ([]marketSession, bool) {
	for _, calendar := range calendars {
		if calendar.Market == market && calendar.Year == day.Year() {
			return calendar.sessions(day)
		}
	}
	return nil, false
}

func calendarLastClose(calendars []tradingCalendar, market string, now time.Time) (string, bool) {
	local := now.In(calendarLocation(market))
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, local.Location())
	for range 367 {
		sessions, known := calendarSessions(calendars, market, day)
		if !known {
			return "", false
		}
		if len(sessions) > 0 && !now.Before(calendarTime(day, sessions[len(sessions)-1].Close)) {
			return day.Format(time.DateOnly), true
		}
		day = day.AddDate(0, 0, -1)
	}
	return "", false
}

func calendarLatestAvailable(calendars []tradingCalendar, market string, now time.Time) bool {
	local := now.In(calendarLocation(market))
	sessions, known := calendarSessions(calendars, market, local)
	if !known {
		return false
	}
	for _, session := range sessions {
		if !now.Before(calendarTime(local, session.Open)) && now.Before(calendarTime(local, session.Close)) {
			return true
		}
	}
	return false
}

func readTradingCalendars(ctx context.Context, tx *sql.Tx) ([]tradingCalendar, error) {
	rows, err := tx.QueryContext(ctx, `SELECT market,year,trading_days,session_overrides,source,updated_at,updated_by,revision FROM market_trading_calendars ORDER BY market,year`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []tradingCalendar{}
	for rows.Next() {
		var c tradingCalendar
		var overrides string
		if err := rows.Scan(&c.Market, &c.Year, &c.TradingDays, &overrides, &c.Source, &c.UpdatedAt, &c.UpdatedBy, &c.Revision); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(overrides), &c.SessionOverrides); err != nil {
			return nil, err
		}
		result = append(result, c)
	}
	return result, rows.Err()
}

func (s *Server) readMarketCalendars(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !s.allow("public-calendars:"+ip, 120, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	market, yearText := r.URL.Query().Get("market"), r.URL.Query().Get("year")
	year, err := strconv.Atoi(yearText)
	if calendarLocation(market) == nil || err != nil || year < 1970 || year > 2100 {
		reject(w, 400, "invalid_calendar_key")
		return
	}
	tx, err := s.investment.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	calendars, err := readTradingCalendars(r.Context(), tx)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	for _, c := range calendars {
		if c.Market == market && c.Year == year {
			w.Header().Set("Cache-Control", "no-cache")
			respond(w, 200, c)
			return
		}
	}
	reject(w, 404, "calendar_not_available")
}

func validTradingCalendar(c tradingCalendar) bool {
	if calendarLocation(c.Market) == nil || c.Year < 1970 || c.Year > 2100 || len(c.Source) == 0 || len(c.Source) > 100 || strings.IndexFunc(c.Source, unicode.IsControl) >= 0 {
		return false
	}
	want := time.Date(c.Year, time.December, 31, 0, 0, 0, 0, time.UTC).YearDay()
	if len(c.TradingDays) != want || strings.Trim(c.TradingDays, "01") != "" || len(c.SessionOverrides) > want {
		return false
	}
	for date, sessions := range c.SessionOverrides {
		day, err := time.Parse(time.DateOnly, date)
		if err != nil || day.Year() != c.Year || c.TradingDays[day.YearDay()-1] != '1' || len(sessions) == 0 || len(sessions) > 4 {
			return false
		}
		last := ""
		for _, session := range sessions {
			open, e1 := time.Parse("15:04", session.Open)
			close, e2 := time.Parse("15:04", session.Close)
			if e1 != nil || e2 != nil || len(session.Open) != 5 || len(session.Close) != 5 || !close.After(open) || session.Open < last {
				return false
			}
			last = session.Close
		}
	}
	return true
}

func (s *Server) writeMarketCalendar(w http.ResponseWriter, r *http.Request) {
	c, ok := s.appClient(w, r)
	if !ok {
		return
	}
	if !c.CalendarWriteEnabled {
		reject(w, 403, "calendar_write_permission_required")
		return
	}
	if !s.allow("calendar-write:"+c.ID, 60, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	var body struct {
		Market           string                     `json:"market"`
		Year             int                        `json:"year"`
		TradingDays      string                     `json:"tradingDays"`
		SessionOverrides map[string][]marketSession `json:"sessionOverrides"`
		Source           string                     `json:"source"`
		ExpectedRevision *int64                     `json:"expectedRevision"`
	}
	if !decode(w, r, &body) {
		return
	}
	calendar := tradingCalendar{Market: body.Market, Year: body.Year, TradingDays: body.TradingDays, SessionOverrides: body.SessionOverrides, Source: strings.TrimSpace(body.Source)}
	if body.ExpectedRevision == nil || *body.ExpectedRevision < 0 || !validTradingCalendar(calendar) {
		reject(w, 400, "invalid_trading_calendar")
		return
	}
	if calendar.SessionOverrides == nil {
		calendar.SessionOverrides = map[string][]marketSession{}
	}
	overrides, _ := json.Marshal(calendar.SessionOverrides)
	tx, err := s.investment.BeginTx(r.Context(), nil)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	var current int64
	err = tx.QueryRowContext(r.Context(), "SELECT revision FROM market_trading_calendars WHERE market=? AND year=?", calendar.Market, calendar.Year).Scan(&current)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		reject(w, 503, "storage_unavailable")
		return
	}
	if current != *body.ExpectedRevision {
		reject(w, 409, "calendar_revision_conflict")
		return
	}
	calendar.Revision = current + 1
	calendar.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	calendar.UpdatedBy = c.ID
	_, err = tx.ExecContext(r.Context(), `INSERT INTO market_trading_calendars(market,year,trading_days,session_overrides,source,updated_at,updated_by,revision) VALUES(?,?,?,?,?,?,?,?)
	 ON CONFLICT(market,year) DO UPDATE SET trading_days=excluded.trading_days,session_overrides=excluded.session_overrides,source=excluded.source,updated_at=excluded.updated_at,updated_by=excluded.updated_by,revision=excluded.revision`,
		calendar.Market, calendar.Year, calendar.TradingDays, string(overrides), calendar.Source, calendar.UpdatedAt, calendar.UpdatedBy, calendar.Revision)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	if err := tx.Commit(); err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	respond(w, 200, calendar)
}
