package server

import "strings"

// Public identity is independent of ledger, provider and trading venue aliases.
// Keep this normalization identical to InvestmentInstrumentIdentity in iOS.
func canonicalInvestmentInstrument(row investmentRow) investmentRow {
	kind := strings.ToLower(strings.TrimSpace(row["asset_type"]))
	code := strings.ToUpper(strings.TrimSpace(row["symbol"]))
	venue := strings.ToUpper(strings.TrimSpace(row["exchange"]))
	currency := strings.ToUpper(strings.TrimSpace(row["quote_currency"]))
	scope := venue
	switch {
	case kind == "crypto":
		scope = "CRYPTO"
		if strings.Contains(code, "/") {
			code = strings.Split(code, "/")[0]
		}
		if venue == "BINANCE" && strings.HasSuffix(code, "USDT") && len(code) > 4 {
			code = strings.TrimSuffix(code, "USDT")
		}
		venue = "BINANCE"
	case kind == "fund" && currency == "CNY":
		scope, venue = "CN", "OF"
		if !strings.Contains(code, ".") {
			code += ".OF"
		}
	case (kind == "stock" || kind == "etf") && currency == "USD":
		scope, venue = "US", "US"
		code = strings.TrimSuffix(code, ".US")
	case (kind == "stock" || kind == "etf") && currency == "HKD":
		scope, venue = "HK", "XHKG"
		code = strings.TrimSuffix(code, ".HK")
		for len(code) < 5 {
			code = "0" + code
		}
		code += ".HK"
	case (kind == "stock" || kind == "etf") && currency == "CNY":
		scope = "CN"
		suffix := map[string]string{"SH": "SH", "XSHG": "SH", "SZ": "SZ", "XSHE": "SZ", "BJ": "BJ", "XBSE": "BJ"}[venue]
		if !strings.Contains(code, ".") && suffix != "" {
			code += "." + suffix
		}
		parts := strings.Split(code, ".")
		if len(parts) == 2 {
			if mic := map[string]string{"SH": "XSHG", "SZ": "XSHE", "BJ": "XBSE"}[parts[1]]; mic != "" {
				venue = mic
			}
		}
	default:
		aliases := map[string]string{"SHF": "SHFE", "ZCE": "CZCE", "CFX": "CFFEX", "GFE": "GFEX", "SH": "XSHG", "SZ": "XSHE"}
		if v := aliases[venue]; v != "" {
			venue = v
		}
		scope = venue
	}
	if scope == "" {
		scope = "GLOBAL"
	}
	idType := strings.ToUpper(kind)
	parts := []string{idType, scope, code, currency}
	for i, value := range parts {
		parts[i] = investmentIdentityPart(value)
	}
	result := investmentRow{}
	for k, v := range row {
		result[k] = v
	}
	result["id"] = strings.Join(parts, ":")
	result["asset_type"], result["symbol"], result["exchange"], result["quote_currency"] = kind, code, venue, currency
	return result
}

func investmentIdentityPart(value string) string {
	const hex = "0123456789ABCDEF"
	var out strings.Builder
	for _, b := range []byte(value) {
		if b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || b >= '0' && b <= '9' || strings.ContainsRune("-._~", rune(b)) {
			out.WriteByte(b)
		} else {
			out.WriteByte('%')
			out.WriteByte(hex[b>>4])
			out.WriteByte(hex[b&15])
		}
	}
	return out.String()
}
