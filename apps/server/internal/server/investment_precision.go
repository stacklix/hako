package server

import (
	"math/big"
	"strings"
)

// Round decimal text directly: ledger values must never pass through float64.
// Rates and unit prices keep four places. Amounts below 0.01 also keep four;
// other amounts keep two.
func investmentRoundedDecimal(value string, fourPlaces bool) string {
	number, ok := new(big.Rat).SetString(value)
	if !ok {
		return value
	}
	negative := number.Sign() < 0
	number.Abs(number)
	round := func(scale int64) *big.Int {
		scaled := new(big.Int).Mul(number.Num(), big.NewInt(scale))
		quotient, remainder := new(big.Int), new(big.Int)
		quotient.QuoRem(scaled, number.Denom(), remainder)
		if remainder.Lsh(remainder, 1).Cmp(number.Denom()) >= 0 {
			quotient.Add(quotient, big.NewInt(1))
		}
		return quotient
	}
	digits := 2
	hundredths := new(big.Int).Quo(new(big.Int).Mul(number.Num(), big.NewInt(100)), number.Denom())
	if fourPlaces || hundredths.Sign() == 0 {
		digits = 4
	}
	units := round(100)
	if digits == 4 {
		units = round(10000)
	}
	if units.Sign() == 0 {
		return "0"
	}
	text := units.String()
	if len(text) <= digits {
		text = strings.Repeat("0", digits+1-len(text)) + text
	}
	text = strings.TrimRight(strings.TrimRight(text[:len(text)-digits]+"."+text[len(text)-digits:], "0"), ".")
	if negative {
		text = "-" + text
	}
	return text
}

func normalizeInvestmentNumbers(row investmentRow) {
	for column, value := range row {
		// Preserve traded units exactly; currency rounding changes the trade itself.
		if column != "quantity" && strings.Contains(investmentNumberFields, " "+column+" ") {
			row[column] = investmentRoundedDecimal(value, column == "rate" || column == "unit_price" || column == "price")
		}
	}
}
