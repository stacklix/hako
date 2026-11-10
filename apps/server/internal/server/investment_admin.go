package server

import "net/http"

var investmentAdminTables = map[string][]string{
	"overview": {"investment_accounts", "investment_daily_snapshots", "investment_account_daily_snapshots"},
	"accounts": {"investment_accounts", "investment_assets", "investment_events", "investment_derivative_event_details",
		"investment_account_daily_snapshots", "investment_plans"},
	"watchlist": {"investment_watchlist", "investment_assets", "market_daily_prices", "investment_manual_prices"},
	"balance-sheet": {"investment_accounts", "investment_daily_snapshots", "investment_month_snapshots",
		"investment_balance_accounts", "investment_balance_records"},
}

func (s *Server) adminInvestment(w http.ResponseWriter, r *http.Request) {
	tables, ok := investmentAdminTables[r.PathValue("view")]
	if !ok {
		reject(w, http.StatusNotFound, "not_found")
		return
	}
	s.readInvestmentBook(w, r, s.investmentSubject(), tables)
}
