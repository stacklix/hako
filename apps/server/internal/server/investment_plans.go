package server

import (
	"math/big"
	"strconv"
	"time"
)

func validInvestmentPlan(row investmentRow) bool {
	amount, ok := new(big.Rat).SetString(row["amount"])
	if !ok || amount.Sign() <= 0 {
		return false
	}
	day, err := strconv.Atoi(row["schedule_day"])
	if err != nil {
		return false
	}
	next, err := time.Parse(time.DateOnly, row["next_date"])
	if err != nil {
		return false
	}
	switch row["frequency"] {
	case "daily":
		return day == 0
	case "weekly", "biweekly":
		weekday := (int(next.Weekday())+6)%7 + 1
		return day >= 1 && day <= 7 && day == weekday
	case "monthly":
		last := time.Date(next.Year(), next.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day()
		return day >= 1 && day <= 31 && next.Day() == min(day, last)
	default:
		return false
	}
}
