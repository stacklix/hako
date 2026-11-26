package server

import (
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"
)

type marketTarget struct {
	ID            string `json:"targetId,omitempty"`
	Key           string `json:"key"`
	Kind          string `json:"kind"`
	InstrumentID  string `json:"instrumentId,omitempty"`
	Symbol        string `json:"symbol,omitempty"`
	Exchange      string `json:"exchange,omitempty"`
	Currency      string `json:"currency,omitempty"`
	BaseCurrency  string `json:"baseCurrency,omitempty"`
	QuoteCurrency string `json:"quoteCurrency,omitempty"`
	PriceType     string `json:"priceType,omitempty"`
	AssetType     string `json:"assetType,omitempty"`
	Source        string `json:"source"`
	From          string `json:"fromDate"`
	Through       string `json:"throughDate"`
	Expires       int64  `json:"expiresAt"`
}
type marketObservation struct {
	Date       string `json:"date"`
	Value      string `json:"value"`
	ObservedAt string `json:"observedAt"`
}
type marketUpdateItem struct {
	TargetID string              `json:"targetId"`
	Source   string              `json:"source,omitempty"`
	Quotes   []marketObservation `json:"quotes"`
	Complete bool                `json:"complete"`
}
type marketUpdateResult struct {
	TargetID string `json:"targetId"`
	Status   string `json:"status"`
	Error    string `json:"error,omitempty"`
	Count    int    `json:"count"`
}
type marketCoverage struct {
	CheckedAt   int64    `json:"checkedAt"`
	From        string   `json:"from"`
	Through     string   `json:"through"`
	NoDataDates []string `json:"noDataDates"`
}

func (s *Server) marketClient(w http.ResponseWriter, r *http.Request, write bool) (AuthClientConfig, bool) {
	c, ok := s.appClient(w, r)
	if !ok {
		return c, false
	}
	if write && !c.MarketWriteEnabled {
		reject(w, 403, "market_permission_required")
		return c, false
	}
	if !s.allow("market:"+c.ID, 120, time.Minute) {
		reject(w, 429, "rate_limited")
		return c, false
	}
	return c, true
}

func (s *Server) signMarketTarget(_ AuthClientConfig, target marketTarget) string {
	target.ID = ""
	data, _ := json.Marshal(target)
	h := hmac.New(sha256.New, s.config.MasterKey)
	h.Write([]byte("hako-public-market/v1\n"))
	h.Write(data)
	return raw64.EncodeToString(data) + "." + raw64.EncodeToString(h.Sum(nil))
}
func (s *Server) parseMarketTarget(c AuthClientConfig, id string, now time.Time) (marketTarget, bool) {
	var t marketTarget
	parts := strings.Split(id, ".")
	if len(id) > 8192 || len(parts) != 2 {
		return t, false
	}
	data, err := raw64.DecodeString(parts[0])
	if err != nil || json.Unmarshal(data, &t) != nil || t.Expires < now.Unix() || t.Expires > now.Add(16*time.Minute).Unix() {
		return t, false
	}
	return t, hmac.Equal([]byte(s.signMarketTarget(c, t)), []byte(id))
}

func marketLocation(exchange string) *time.Location {
	name := "Asia/Shanghai"
	switch strings.ToUpper(exchange) {
	case "NASDAQ", "NYSE", "XNYS", "XNAS", "AMEX", "US", "XASE", "ARCX", "BATS", "BATY", "EDGA", "EDGX", "XNGS", "XNMS", "XNCM", "XOTC", "OTCM", "IEXG", "MEMX":
		name = "America/New_York"
	case "HKEX", "XHKG", "HK":
		name = "Asia/Hong_Kong"
	}
	location, _ := time.LoadLocation(name)
	return location
}
func marketLastClose(now time.Time, instrument investmentRow) string {
	location := marketLocation(instrument["exchange"])
	local := now.In(location)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, location)
	hour := 15
	if location.String() == "America/New_York" || location.String() == "Asia/Hong_Kong" {
		hour = 16
	}
	if instrument["asset_type"] == "crypto" {
		return now.UTC().AddDate(0, 0, -1).Format(time.DateOnly)
	}
	if local.Before(day.Add(time.Duration(hour) * time.Hour)) {
		day = day.AddDate(0, 0, -1)
	}
	for day.Weekday() == time.Saturday || day.Weekday() == time.Sunday {
		day = day.AddDate(0, 0, -1)
	}
	return day.Format(time.DateOnly)
}

func (s *Server) marketUpdateTargets(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !s.allow("public-market:"+ip, 120, time.Minute) {
		reject(w, 429, "rate_limited")
		return
	}
	c := AuthClientConfig{}
	limit := 100
	if value := r.URL.Query().Get("limit"); value != "" {
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 500 {
			reject(w, 400, "invalid_limit")
			return
		}
		limit = n
	}
	cursor := r.URL.Query().Get("cursor")
	if len(cursor) > 512 {
		reject(w, 400, "invalid_cursor")
		return
	}
	tx, err := s.investment.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	owner := s.investmentSubject()
	state, err := readInvestmentState(r.Context(), tx, owner, []string{"market_instruments", "investment_assets", "investment_accounts", "investment_events", "investment_watchlist", "investment_plans", "market_daily_prices", "market_daily_fx"})
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	now := time.Now()
	targets := s.marketTargets(c, owner, state, now)
	filtered := []marketTarget{}
	for _, target := range targets {
		if target.Key > cursor {
			filtered = append(filtered, target)
		}
	}
	next := ""
	if len(filtered) > limit {
		filtered = filtered[:limit]
		next = filtered[len(filtered)-1].Key
	}
	for i := range filtered {
		filtered[i].ID = s.signMarketTarget(c, filtered[i])
	}
	respond(w, 200, map[string]any{"targets": filtered, "nextCursor": next, "calendarRequests": missingMarketCalendars(state, now), "pollAfterSeconds": 60, "maxDecimalPlaces": 4, "revision": state.Revision})
}

func (s *Server) marketTargets(c AuthClientConfig, owner string, bookState investmentState, now time.Time) []marketTarget {
	today := now.In(marketLocation("")).Format(time.DateOnly)
	assets := map[string]investmentRow{}
	for _, row := range bookState.Tables["investment_assets"] {
		assets[row["id"]] = row
	}
	needed := map[string]string{}
	active := map[string]bool{}
	currencies := map[string]bool{}
	activeAccounts := map[string]bool{}
	for _, row := range bookState.Tables["investment_accounts"] {
		activeAccounts[row["id"]] = row["archived_at"] == ""
		if row["archived_at"] == "" {
			currencies[row["currency"]] = true
		}
	}
	first := today
	for _, row := range bookState.Tables["investment_events"] {
		if row["deleted_at"] != "" {
			continue
		}
		date := row["effective_date"]
		if date < first {
			first = date
		}
		asset := assets[row["asset_id"]]
		id := asset["instrument_id"]
		if id == "" {
			continue
		}
		if needed[id] == "" || date < needed[id] {
			needed[id] = date
		}
		if activeAccounts[row["account_id"]] {
			active[id] = true
			currencies[asset["quote_currency"]] = true
		}
	}
	for _, table := range []string{"investment_watchlist", "investment_plans"} {
		for _, row := range bookState.Tables[table] {
			if table == "investment_plans" && row["enabled"] != "1" {
				continue
			}
			asset := assets[row["asset_id"]]
			id := asset["instrument_id"]
			if id != "" {
				active[id] = true
				if needed[id] == "" {
					needed[id] = today
				}
				currencies[asset["quote_currency"]] = true
			}
		}
	}
	coverage := map[string]marketCoverage{}
	s.store.inspect(func(st state) {
		for key, value := range st.MarketCoverage {
			coverage[key] = value
		}
	})
	source := "external"
	result := []marketTarget{}
	add := func(target marketTarget) {
		target.Source = source
		target.Expires = now.Add(15 * time.Minute).Unix()
		if target.Kind != "latest" {
			cached := coverage[owner+"|"+target.Key+"|"+target.Source]
			known := map[string]bool{}
			if now.Unix()-cached.CheckedAt < 900 {
				for _, date := range cached.NoDataDates {
					known[date] = true
				}
			}
			for _, row := range bookState.Tables["market_daily_prices"] {
				if target.InstrumentID != "" && row["instrument_id"] == target.InstrumentID && row["price_type"] == target.PriceType && row["is_final"] == "1" {
					known[row["session_date"]] = true
				}
			}
			for _, row := range bookState.Tables["market_daily_fx"] {
				if target.Kind == "fx" && row["base_currency"] == target.BaseCurrency && row["quote_currency"] == target.QuoteCurrency && finalInvestmentFX(row) {
					known[row["rate_date"]] = true
				}
			}
			crypto := false
			for _, instrument := range bookState.Tables["market_instruments"] {
				if instrument["id"] == target.InstrumentID {
					crypto = instrument["asset_type"] == "crypto"
				}
			}
			for target.From <= target.Through {
				day, e := time.Parse(time.DateOnly, target.From)
				if e != nil {
					return
				}
				trading := day.Weekday() != time.Saturday && day.Weekday() != time.Sunday
				market := calendarMarket(investmentRow{"exchange": target.Exchange, "asset_type": target.AssetType})
				if market != "" {
					sessions, knownDay := calendarSessions(bookState.Calendars, market, day)
					if !knownDay {
						return
					}
					trading = len(sessions) > 0
				}
				if !known[target.From] && (crypto || trading) {
					break
				}
				target.From = day.AddDate(0, 0, 1).Format(time.DateOnly)
			}
			if target.From > target.Through {
				return
			}
			start, err := time.Parse(time.DateOnly, target.From)
			if err != nil {
				return
			}
			maximum := start.AddDate(0, 0, 365).Format(time.DateOnly)
			if target.Through > maximum {
				target.Through = maximum
			}
			for next := start.AddDate(0, 0, 1); next.Format(time.DateOnly) <= target.Through; next = next.AddDate(0, 0, 1) {
				if known[next.Format(time.DateOnly)] {
					target.Through = next.AddDate(0, 0, -1).Format(time.DateOnly)
					break
				}
			}
		}
		result = append(result, target)
	}
	for _, instrument := range bookState.Tables["market_instruments"] {
		id := instrument["id"]
		start := needed[id]
		if start == "" {
			continue
		}
		target := marketTarget{Key: "close|" + id, Kind: "daily_close", InstrumentID: id, Symbol: instrument["symbol"], Exchange: instrument["exchange"], Currency: instrument["quote_currency"], PriceType: instrument["price_type"], AssetType: instrument["asset_type"], From: start, Through: marketLastClose(now, instrument)}
		market := calendarMarket(instrument)
		latestAvailable := true
		if market != "" {
			through, known := calendarLastClose(bookState.Calendars, market, now)
			if !known {
				continue
			}
			target.Through = through
			latestAvailable = calendarLatestAvailable(bookState.Calendars, market, now)
		}
		if market != "" && target.From > target.Through {
			// Newly watched assets need their last completed session before today's open.
			target.From = target.Through
		}
		// NAVs have no intraday/latest quote; new holdings also need the latest published NAV.
		fundNAV := instrument["asset_type"] == "fund" && instrument["price_type"] == "nav" && strings.HasSuffix(instrument["symbol"], ".OF")
		if fundNAV {
			end, _ := time.Parse(time.DateOnly, target.Through)
			recent := end.AddDate(0, 0, -30).Format(time.DateOnly)
			if target.From > recent {
				target.From = recent
			}
		}
		add(target)
		if fundNAV || !active[id] || !latestAvailable {
			continue
		}
		localDay := now.In(marketLocation(instrument["exchange"])).Format(time.DateOnly)
		if instrument["asset_type"] == "crypto" {
			localDay = now.UTC().Format(time.DateOnly)
		}
		fresh := false
		for _, row := range bookState.Tables["market_daily_prices"] {
			if row["instrument_id"] == id && row["session_date"] == localDay {
				observed, err := time.Parse(time.RFC3339Nano, row["closed_at_utc"])
				if row["is_final"] == "1" || (err == nil && now.Sub(observed) >= 0 && now.Sub(observed) < 5*time.Minute) {
					fresh = true
				}
			}
		}
		if !fresh {
			target.Key = "latest|" + id
			target.Kind = "latest"
			target.From = localDay
			target.Through = localDay
			add(target)
		}
	}
	if len(bookState.Tables["investment_accounts"]) > 0 {
		currencies["USD"] = true
	}
	for currency := range currencies {
		if currency == "" || currency == "CNY" {
			continue
		}
		add(marketTarget{Key: "fx|" + currency + "|CNY", Kind: "fx", BaseCurrency: currency, QuoteCurrency: "CNY", From: first, Through: today})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Key < result[j].Key })
	return result
}

func (s *Server) writeMarketQuotes(w http.ResponseWriter, r *http.Request) {
	c, ok := s.marketClient(w, r, true)
	if !ok {
		return
	}
	var input struct {
		Items []marketUpdateItem `json:"items"`
	}
	if !decode(w, r, &input) {
		return
	}
	if len(input.Items) == 0 || len(input.Items) > 500 {
		reject(w, 400, "invalid_batch")
		return
	}
	owner := s.investmentSubject()
	now := time.Now()
	tx, err := s.investment.BeginTx(r.Context(), nil)
	if err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	defer tx.Rollback()
	var book string
	var revision int64
	var dirty sql.NullString
	if err = tx.QueryRowContext(r.Context(), "SELECT id,revision,snapshot_dirty_from FROM investment_books WHERE owner_id=?", owner).Scan(&book, &revision, &dirty); err != nil {
		reject(w, 409, "investment_book_required")
		return
	}
	results := []marketUpdateResult{}
	completed := map[string]marketCoverage{}
	seen := map[string]bool{}
	total := 0
	changed := false
	sharedFXFrom := ""
	for _, item := range input.Items {
		result := marketUpdateResult{TargetID: item.TargetID, Status: "rejected"}
		target, valid := s.parseMarketTarget(c, item.TargetID, now)
		if !valid {
			result.Error = "invalid_or_expired_target"
			results = append(results, result)
			continue
		}
		if target.Kind == "fx" && len(item.Quotes) > 0 && (strings.TrimSpace(item.Source) == "" || strings.TrimSpace(item.Source) != item.Source || len(item.Source) > 160 || strings.ContainsAny(item.Source, "\r\n\t\x00")) {
			result.Error = "invalid_source"
			results = append(results, result)
			continue
		}
		if len(item.Quotes) > 1000 || total+len(item.Quotes) > 5000 {
			result.Error = "too_many_quotes"
			results = append(results, result)
			continue
		}
		total += len(item.Quotes)
		table := investmentTables[9]
		if target.Kind == "fx" {
			table = investmentTables[10]
		}
		// Validate an entire item before saving any of its observations.
		rows := []investmentRow{}
		itemKeys := map[string]bool{}
		bad := ""
		for _, quote := range item.Quotes {
			observed, e := time.Parse(time.RFC3339Nano, quote.ObservedAt)
			fraction := strings.Split(quote.Value, ".")
			if !validInvestmentDate(quote.Date) || quote.Date < target.From || quote.Date > target.Through || e != nil || observed.After(now.Add(5*time.Minute)) || !investmentDecimal.MatchString(quote.Value) || strings.HasPrefix(quote.Value, "-") || strings.Trim(quote.Value, "0.") == "" || (len(fraction) == 2 && len(strings.TrimRight(fraction[1], "0")) > 4) {
				bad = "invalid_quote_or_precision"
				break
			}
			row := investmentRow{"source": target.Source, "is_final": "1"}
			if target.Kind != "fx" {
				row["source"] = "external:" + c.ID
			}
			if target.Kind == "fx" {
				row["source"] = item.Source
				row["rate_date"] = quote.Date
				row["base_currency"] = target.BaseCurrency
				row["quote_currency"] = target.QuoteCurrency
				row["rate"] = quote.Value
				row["available_at_utc"] = observed.UTC().Format(time.RFC3339Nano)
			} else {
				row["instrument_id"] = target.InstrumentID
				row["session_date"] = quote.Date
				row["valuation_date"] = quote.Date
				row["price_type"] = target.PriceType
				row["price"] = quote.Value
				row["closed_at_utc"] = observed.UTC().Format(time.RFC3339Nano)
				if target.Kind == "latest" {
					row["is_final"] = "0"
				} else if marketLocation(target.Exchange).String() == "America/New_York" {
					date, _ := time.ParseInLocation(time.DateOnly, quote.Date, marketLocation(target.Exchange))
					row["valuation_date"] = date.AddDate(0, 0, 1).Format(time.DateOnly)
				}
			}
			if e = table.prepareRow(row); e != nil {
				bad = "invalid_quote"
				break
			}
			key := table.name + "|" + investmentRowKey(row, strings.Fields(table.keys))
			if seen[key] || itemKeys[key] {
				bad = "duplicate_quote"
				break
			}
			itemKeys[key] = true
			rows = append(rows, row)
		}
		if bad != "" {
			result.Error = bad
			results = append(results, result)
			continue
		}
		if target.InstrumentID != "" {
			var exists bool
			if err = tx.QueryRowContext(r.Context(), "SELECT EXISTS(SELECT 1 FROM market_instruments WHERE id=?)", target.InstrumentID).Scan(&exists); err != nil {
				reject(w, 503, "storage_unavailable")
				return
			}
			if !exists {
				result.Error = "instrument_removed"
				results = append(results, result)
				continue
			}
		}
		for _, row := range rows {
			key := table.name + "|" + investmentRowKey(row, strings.Fields(table.keys))
			seen[key] = true
			previous, e := table.row(r.Context(), tx, book, row)
			if e != nil {
				reject(w, 503, "storage_unavailable")
				return
			}
			if target.Kind == "fx" && finalInvestmentFX(previous) {
				continue
			}
			dateColumn, timeColumn := "valuation_date", "closed_at_utc"
			if target.Kind == "fx" {
				dateColumn, timeColumn = "rate_date", "available_at_utc"
			}
			oldTime, oldErr := time.Parse(time.RFC3339Nano, previous[timeColumn])
			newTime, _ := time.Parse(time.RFC3339Nano, row[timeColumn])
			if target.Kind != "fx" && ((previous["is_final"] == "1" && row["is_final"] != "1") || (oldErr == nil && newTime.Before(oldTime) && !(previous["is_final"] != "1" && row["is_final"] == "1"))) {
				continue
			}
			if !investmentQuoteChanged(previous, row, table.columns()) {
				continue
			}
			if e = table.upsert(r.Context(), tx, book, row); e != nil {
				reject(w, 503, "storage_unavailable")
				return
			}
			changed = true
			result.Count++
			if sharedFXFrom == "" || row[dateColumn] < sharedFXFrom {
				sharedFXFrom = row[dateColumn]
			}
			if !dirty.Valid || row[dateColumn] < dirty.String {
				dirty = sql.NullString{String: row[dateColumn], Valid: true}
			}
		}
		result.Status = "unchanged"
		if result.Count > 0 {
			result.Status = "updated"
		}
		if item.Complete && target.Kind != "latest" {
			dates := map[string]bool{}
			for _, quote := range item.Quotes {
				dates[quote.Date] = true
			}
			empty := []string{}
			start, _ := time.Parse(time.DateOnly, target.From)
			for day := start; day.Format(time.DateOnly) <= target.Through; day = day.AddDate(0, 0, 1) {
				date := day.Format(time.DateOnly)
				if !dates[date] {
					empty = append(empty, date)
				}
			}
			completed[owner+"|"+target.Key+"|"+target.Source] = marketCoverage{From: target.From, Through: target.Through, NoDataDates: empty, CheckedAt: now.Unix()}
		}
		results = append(results, result)
	}
	if changed {
		if sharedFXFrom != "" {
			if err = invalidateSharedFX(r.Context(), tx, book, sharedFXFrom); err != nil {
				reject(w, 503, "storage_unavailable")
				return
			}
		}
		revision++
		if _, err = tx.ExecContext(r.Context(), "UPDATE investment_books SET revision=?,snapshot_dirty_from=? WHERE owner_id=?", revision, dirty, owner); err != nil {
			reject(w, 503, "storage_unavailable")
			return
		}
	}
	if err = tx.Commit(); err != nil {
		reject(w, 503, "storage_unavailable")
		return
	}
	if len(completed) > 0 {
		if err = s.store.update(func(st *state) error {
			if st.MarketCoverage == nil {
				st.MarketCoverage = map[string]marketCoverage{}
			}
			for key, value := range completed {
				old := st.MarketCoverage[key]
				if old.From != "" && old.From <= value.Through && old.Through >= value.From {
					if old.From < value.From {
						value.From = old.From
					}
					if old.Through > value.Through {
						value.Through = old.Through
					}
				}
				absent := map[string]bool{}
				for _, date := range append(old.NoDataDates, value.NoDataDates...) {
					absent[date] = true
				}
				value.NoDataDates = []string{}
				for date := range absent {
					value.NoDataDates = append(value.NoDataDates, date)
				}
				sort.Strings(value.NoDataDates)
				st.MarketCoverage[key] = value
			}
			return nil
		}); err != nil {
			reject(w, 503, "coverage_storage_unavailable")
			return
		}
	}
	respond(w, 200, map[string]any{"results": results, "revision": revision})
}
