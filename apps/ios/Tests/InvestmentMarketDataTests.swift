import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct InvestmentMarketDataTests {
    static func main() async throws {
        mapping()
        try await alternateAfterUnavailableQuote()
        try await watchRequiresRecentQuotes()
        try await usDailyBarWaitsForExchangeClose()
        try await stockConnectUsesHKDQuotes()
        try await instrumentSearchReturnsMatchingChoices()
        try await cryptocurrencyUsesUSDPair()
        try await binanceSpotCatalogFindsTRX()
        try await publicSpotPricesAreConvertedToDollars()
        try await cryptoDailyClosesUseTheLedgerDay()
        try await exchangeContractsUseTheirOwnMultipliersAndMarkPrices()
        try await domesticFundNAV()
        try await referenceRates()
        print("Investment market data checks passed")
    }

    static func mapping() {
        let china = InvestmentQuoteSymbol(asset("600519.SH", .stock, .cny))
        precondition(china.tushareSymbol == "600519.SH" && china.tushareAPI == "daily")
        precondition(china.twelveSymbol == "600519" && china.twelveMIC == "XSHG")
        let shenzhen = InvestmentQuoteSymbol(asset("000001", .stock, .cny))
        precondition(shenzhen.tushareSymbol == "000001.SZ")
        let beijing = InvestmentQuoteSymbol(asset("920002", .stock, .cny))
        precondition(beijing.tushareSymbol == "920002.BJ")
        let hongKong = InvestmentQuoteSymbol(asset("0700.HK", .stock, .hkd))
        precondition(hongKong.tushareSymbol == nil && hongKong.twelveSymbol == nil)
        let hongKongUSD = InvestmentQuoteSymbol(asset("09010.HK", .etf, .usd))
        precondition(hongKongUSD.tushareSymbol == nil && hongKongUSD.twelveSymbol == nil)
        let usETF = InvestmentQuoteSymbol(asset("VOO.US", .etf, .usd))
        precondition(usETF.tushareSymbol == "VOO" && usETF.tushareAPI == "us_etf_daily")
        let future = InvestmentQuoteSymbol(asset("CU1811.SHF", .future, .cny))
        precondition(future.tushareSymbol == "CU1811.SHF" && future.tushareAPI == "fut_daily" && future.twelveSymbol == nil)
        let option = InvestmentQuoteSymbol(asset("10001313.SH", .option, .cny))
        precondition(option.tushareAPI == "opt_daily" && option.tushareSymbol == "10001313.SH")
        precondition(InvestmentQuoteSymbol(asset("600519.SH", .stock, .cny, market: "XSHE")).tushareSymbol == nil)
    }

    static func alternateAfterUnavailableQuote() async throws {
        var requested: [String] = []
        let provider = InvestmentQuoteProvider { request, _ in
            let host = request.url!.host!
            requested.append(host)
            if host == "api.tushare.pro" {
                return response(request, #"{"code":2002,"data":null}"#)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(.init(name: "symbol", value: "600519")))
            precondition(query.contains(.init(name: "mic_code", value: "XSHG")))
            return response(request, #"{"meta":{"currency":"CNY"},"values":[{"datetime":"2026-10-30","close":"1500.20"}]}"#)
        }
        let rows = try await provider.history(asset: asset("600519", .stock, .cny),
            start: day(1), through: day(30), cached: nil, keys: [.tushare:"token", .twelveData:"key"])
        precondition(requested == ["api.tushare.pro", "api.twelvedata.com"])
        precondition(rows.first?.source == "Twelve Data" && rows.first?.price == Decimal(string: "1500.20"))
    }

    static func watchRequiresRecentQuotes() async throws {
        precondition(InvestmentKind.watchKinds(in: .cny) == [.stock, .etf, .fund, .future])
        precondition(InvestmentKind.watchKinds(in: .usd) == [.stock, .etf, .crypto])
        precondition(InvestmentKind.watchKinds(in: .hkd) == [.stock, .etf])
        let provider = InvestmentQuoteProvider { request, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(request.url?.path == "/time_series")
            let ticker = query.first { $0.name == "symbol" }?.value
            if ticker == "VOO" {
                return response(request, #"{"meta":{"currency":"USD"},"values":[{"datetime":"2026-10-30","close":"500.20"}]}"#)
            }
            precondition(ticker == "OLD")
            return response(request, #"{"meta":{"currency":"USD"},"values":[{"datetime":"2026-10-01","close":"10.25"}]}"#)
        }
        let keys: [InvestmentQuoteSource: String] = [.twelveData: "fixture"]
        let quotes = try await provider.watchQuotes(for: asset("VOO", .etf, .usd), keys: keys, through: day(30))
        precondition(quotes.last?.day == day(30) && quotes.last?.price == Decimal(string: "500.20"))
        do {
            _ = try await provider.watchQuotes(for: asset("OLD", .etf, .usd), keys: keys, through: day(30))
            preconditionFailure("Old history is not enough to add an instrument to the watchlist")
        } catch InvestmentError.invalid {}
        do {
            _ = try await provider.watchQuotes(for: asset("VOO", .etf, .usd), keys: [:], through: day(30))
            preconditionFailure("A non-crypto watch requires a working quote source")
        } catch InvestmentError.invalid {}
    }

    static func usDailyBarWaitsForExchangeClose() async throws {
        let provider = InvestmentQuoteProvider { request, _ in
            response(request, #"{"meta":{"currency":"USD"},"values":[{"datetime":"2026-10-30","close":"500.20"}]}"#)
        }
        let session = day(30)
        let close = InvestmentBook.usEquityClose(on: session)
        let symbol = asset("VOO", .etf, .usd)
        let keys: [InvestmentQuoteSource: String] = [.twelveData: "fixture"]
        let early = try await provider.history(asset: symbol, start: session, through: session, cached: nil,
                                               keys: keys, now: close.addingTimeInterval(-60))
        let complete = try await provider.history(asset: symbol, start: session, through: session, cached: nil,
                                                  keys: keys, now: close)
        precondition(early.last?.isDailyClose == false && complete.last?.isDailyClose == true)
    }

    static func domesticFundNAV() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["api_name"] as? String == "fund_nav" && secrets == ["fixture"])
            precondition((body["params"] as? [String: String])?["ts_code"] == "110022.OF")
            return response(request, #"""
                {"code":0,"data":{"fields":["unit_nav","ann_date","ts_code","nav_date"],"items":[
                [1.42,"20261031","110022.OF","20261030"],[1.40,"20261030","110022.OF","20261030"],
                [11.2,"20261031","000001.OF","20261030"]]}}
                """#)
        }
        let rows = try await provider.history(asset: asset("110022", .fund, .cny),
            start: day(1), through: day(30), cached: nil, keys: [.tushare:"fixture"])
        precondition(rows.count == 1 && rows[0].price == Decimal(string: "1.42") && rows[0].source == "Tushare Pro")
        let legacy = try JSONDecoder().decode(InvestmentQuote.self, from: Data(#"{"day":0,"price":1}"#.utf8))
        precondition(legacy.source == nil)
    }

    static func stockConnectUsesHKDQuotes() async throws {
        var requested: [String] = []
        let provider = InvestmentQuoteProvider { request, _ in
            let host = request.url!.host!
            requested.append(host)
            if host == "api.twelvedata.com" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query.contains(.init(name: "symbol", value: "2800")))
                precondition(query.contains(.init(name: "mic_code", value: "XHKG")))
                precondition(query.contains(.init(name: "type", value: "ETF")))
                return response(request, #"{"meta":{"currency":"USD"},"values":[{"datetime":"2026-10-30","close":"10"}]}"#)
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["api_name"] as? String == "hk_daily")
            precondition((body["params"] as? [String: String])?["ts_code"] == "02800.HK")
            return response(request, #"{"code":0,"data":{"fields":["ts_code","trade_date","close"],"items":[["02800.HK","20261030",24]]}}"#)
        }
        let rows = try await provider.history(asset: asset("02800.HK", .etf, .hkd, market: InvestmentAsset.stockConnectMarket),
            start: day(1), through: day(30), cached: nil, keys: [.tushare:"token", .twelveData:"key"])
        precondition(requested == ["api.twelvedata.com", "api.tushare.pro"])
        precondition(rows.first?.source == "Tushare Pro" && rows.first?.price == 24)
    }

    static func referenceRates() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(request.url?.host == "data-api.ecb.europa.eu" && secrets.isEmpty)
            return response(request, "CURRENCY,TIME_PERIOD,OBS_VALUE\nCNY,2026-10-30,8.4\nUSD,2026-10-30,1.2\nHKD,2026-10-30,9.6\n")
        }
        let rates = try await provider.ecbRates(for: [.usd, .hkd], start: day(1), end: day(30))
        precondition(rates[.usd]?.first?.price == 7 && rates[.hkd]?.first?.price == Decimal(string: "0.875"))
    }

    static func instrumentSearchReturnsMatchingChoices() async throws {
        let provider = InvestmentQuoteProvider { request, _ in
            if request.url?.host == "api.tushare.pro" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(body["api_name"] as? String == "fund_basic")
                precondition(body["params"] as? [String: String] == ["market": "O", "ts_code": "110022.OF"])
                return response(request, #"{"code":0,"data":{"fields":["name","ts_code"],"items":[["其他基金","000001.OF"],["易方达消费行业","110022.OF"]]}}"#)
            }
            precondition(request.url?.path == "/symbol_search")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if query?.contains(.init(name: "symbol", value: "0700")) == true {
                return response(request, #"""
                    {"data":[
                    {"symbol":"0700","instrument_name":"Wrong currency","instrument_type":"Common Stock","mic_code":"XHKG","currency":"USD"},
                    {"symbol":"00700","instrument_name":"Wrong type","instrument_type":"ETF","mic_code":"XHKG","currency":"HKD"},
                    {"symbol":"00700","instrument_name":"Tencent","instrument_type":"Common Stock","mic_code":"XHKG","currency":"HKD"}]}
                    """#)
            }
            return response(request, #"""
                {"data":[
                {"symbol":"XYZ","instrument_name":"US Listing","instrument_type":"Common Stock","mic_code":"XNAS","country":"United States","currency":"USD"},
                {"symbol":"XYZ","instrument_name":"Another Listing","instrument_type":"Common Stock","mic_code":"XNYS","country":"United States","currency":"USD"},
                {"symbol":"XYZ.A","instrument_name":"Other Class","instrument_type":"Common Stock","mic_code":"XNAS","country":"United States","currency":"USD"},
                {"symbol":"XYZ","instrument_name":"Foreign Listing","instrument_type":"Common Stock","mic_code":"XLON","country":"United Kingdom","currency":"USD"}]}
                """#)
        }
        let funds = try await provider.searchInstruments(.init(query: "110022", kind: .fund, currency: .cny), keys: [.tushare: "fixture"])
        precondition(funds.map(\.name) == ["易方达消费行业"])
        let connect = try await provider.searchInstruments(.init(query: "700", kind: .stock, currency: .hkd, stockConnect: true),
                                                            keys: [.twelveData: "fixture"])
        precondition(connect.map(\.name) == ["Tencent"] && connect.first?.code == "00700.HK")
        let us = try await provider.searchInstruments(.init(query: "XY", kind: .stock, currency: .usd), keys: [.twelveData: "fixture"])
        precondition(us.map(\.name) == ["US Listing", "Another Listing", "Other Class"])
        precondition(us.map(\.market) == ["XNAS", "XNYS", "XNAS"])
    }

    static func cryptocurrencyUsesUSDPair() async throws {
        let provider = InvestmentQuoteProvider { request, _ in
            if request.url?.path == "/symbol_search" {
                return response(request, #"""
                    {"data":[
                    {"symbol":"BTC/USD","instrument_name":"Bitcoin","instrument_type":"Digital Currency"},
                    {"symbol":"BTC/USDT","instrument_name":"Bitcoin in Tether","instrument_type":"Digital Currency"}]}
                    """#)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            precondition(query?.contains(.init(name: "symbol", value: "BTC/USD")) == true)
            return response(request, #"{"meta":{"symbol":"BTC/USD","currency_quote":"US Dollar"},"values":[{"datetime":"2026-10-30","close":"10000.25"}]}"#)
        }
        let keys: [InvestmentQuoteSource: String] = [.twelveData: "fixture"]
        let choices = try await provider.searchInstruments(.init(query: "BTC", kind: .crypto, currency: .usd, accountType: .crypto), keys: keys)
        precondition(choices.map(\.code) == ["BTC"])
        let rows = try await provider.history(asset: choices[0], start: day(1), through: day(30), cached: nil, keys: keys)
        precondition(rows.first?.price == Decimal(string: "10000.25"))
    }

    static func binanceSpotCatalogFindsTRX() async throws {
        let pairs = #"""
            {"symbols":[
            {"baseAsset":"TRX","quoteAsset":"USDT","status":"TRADING","isSpotTradingAllowed":true},
            {"baseAsset":"TRX","quoteAsset":"EUR","status":"TRADING","isSpotTradingAllowed":true},
            {"baseAsset":"OLD","quoteAsset":"USDT","status":"BREAK","isSpotTradingAllowed":true},
            {"baseAsset":"OTHER","quoteAsset":"USDT","status":"TRADING","isSpotTradingAllowed":false}]}
            """#
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(secrets.isEmpty && request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.url?.host == "www.binance.com" {
                return response(request, #"{"data":[{"assetCode":"TRX","assetName":"TRON"}]}"#)
            }
            precondition(request.url?.host == "data-api.binance.vision" && request.url?.path == "/api/v3/exchangeInfo")
            precondition(request.url?.query?.contains("permissions=SPOT") == true)
            return response(request, pairs)
        }
        let spot = try await provider.cryptoCatalog()
        let query = InvestmentInstrumentSearch(query: "trx", kind: .crypto, currency: .usd, accountType: .crypto)
        precondition(Set(spot.map(\.code)) == ["TRX", "USDT"])
        precondition(spot.filter(query.includes).map(\.name) == ["TRON"])
        let byName = InvestmentInstrumentSearch(query: "tron", kind: .crypto, currency: .usd)
        precondition(spot.filter(byName.includes).map(\.code) == ["TRX"])

        let codeOnly = InvestmentQuoteProvider { request, _ in
            if request.url?.host == "www.binance.com" { throw URLError(.timedOut) }
            return response(request, pairs)
        }
        let fallback = try await codeOnly.cryptoCatalog()
        precondition(fallback.filter(query.includes).map(\.name) == ["TRX"])
    }

    static func publicSpotPricesAreConvertedToDollars() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(secrets.isEmpty)
            switch request.url?.path {
            case "/v2/prices/USDT-USD/spot":
                return response(request, #"{"data":{"amount":"0.998635","base":"USDT","currency":"USD"}}"#)
            case "/api/v3/ticker/price":
                precondition(request.url?.host == "data-api.binance.vision" && request.url?.query == "symbol=TRXUSDT")
                return response(request, #"{"symbol":"TRXUSDT","price":"0.32060000"}"#)
            case "/v2/prices/TRX-USD/spot":
                return response(request, #"{"data":{"amount":"0.319985","base":"TRX","currency":"USD"}}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let trx = asset("TRX", .crypto, .usd)
        let rate = try await provider.coinbaseSpotUSDQuote(code: "USDT")
        let quote = try await provider.publicSpotUSDQuote(for: trx, usdtUSD: rate)
        precondition(quote.price == Decimal(string: "0.320162381") && quote.source == "Binance 现货")
        let direct = try await provider.publicSpotUSDQuote(for: trx, usdtUSD: nil)
        precondition(direct.price == Decimal(string: "0.319985") && direct.source == "Coinbase 现货")
        let watched = try await provider.watchQuotes(for: trx, keys: [:])
        precondition(watched.last?.price == quote.price && watched.last?.source == quote.source)
    }

    static func exchangeContractsUseTheirOwnMultipliersAndMarkPrices() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(secrets.isEmpty && request.value(forHTTPHeaderField: "Authorization") == nil)
            switch request.url?.path {
            case "/fapi/v1/exchangeInfo":
                return response(request, #"{"symbols":[{"symbol":"BTCUSDT","baseAsset":"BTC","quoteAsset":"USDT","marginAsset":"USDT","contractType":"PERPETUAL","status":"TRADING"}]}"#)
            case "/linear-swap-api/v1/swap_contract_info":
                return response(request, #"{"status":"ok","data":[{"symbol":"BTC","contract_code":"BTC-USDT","contract_size":0.001,"contract_status":1,"delivery_date":"","trade_partition":"USDT"}]}"#)
            case "/dapi/v1/exchangeInfo":
                return response(request, #"{"symbols":[{"symbol":"BTCUSD_PERP","baseAsset":"BTC","quoteAsset":"USD","marginAsset":"BTC","contractType":"PERPETUAL","contractStatus":"TRADING","contractSize":100}]}"#)
            case "/swap-api/v1/swap_contract_info":
                return response(request, #"{"status":"ok","data":[{"symbol":"BTC","contract_code":"BTC-USD","contract_size":100,"contract_status":1}]}"#)
            case "/api/v1/contract_contract_info":
                return response(request, #"{"status":"ok","data":[{"symbol":"BTC","contract_code":"BTC261113","contract_size":100,"contract_status":1,"delivery_date":"20261113"}]}"#)
            case "/fapi/v1/premiumIndex":
                return response(request, #"{"symbol":"BTCUSDT","markPrice":"75814.3","indexPrice":"75848","time":1794113807000}"#)
            case "/dapi/v1/premiumIndex":
                return response(request, #"[{"symbol":"BTCUSD_PERP","markPrice":"75713.8","time":1794113807000}]"#)
            case "/index/market/history/linear_swap_mark_price_kline":
                precondition(request.url?.query?.contains("contract_code=BTC-USDT") == true)
                return response(request, #"{"status":"ok","ch":"market.BTC-USDT.mark_price.1min","data":[{"id":1794113760,"close":"75836.4"}]}"#)
            case "/index/market/history/swap_mark_price_kline":
                return response(request, #"{"status":"ok","ch":"market.BTC-USD.mark_price.1min","data":[{"id":1794113760,"close":"75778"}]}"#)
            case "/index/market/history/mark_price_kline":
                precondition(request.url?.query?.contains("symbol=BTC261113") == true)
                return response(request, #"{"status":"ok","ch":"market.BTC261113.mark_price.1min","data":[{"id":1794113760,"close":"75890"}]}"#)
            case "/v2/prices/USDT-USD/spot":
                return response(request, #"{"data":{"amount":"0.998615","base":"USDT","currency":"USD"}}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let binance = try await provider.contractCatalog(.binance, basis: .stablecoin)
        let htx = try await provider.contractCatalog(.htx, basis: .stablecoin)
        let inverseBinance = try await provider.contractCatalog(.binance, basis: .coin)
        let inverseHTX = try await provider.contractCatalog(.htx, basis: .coin)
        precondition(binance.first?.asset.multiplier == 1 && binance.first?.settlementCode == "USDT")
        precondition(htx.first?.asset.multiplier == Decimal(string: "0.001") && htx.first?.settlementCode == "USDT")
        precondition(inverseBinance.first?.asset.multiplier == 100 && inverseBinance.first?.settlementCode == "BTC")
        precondition(inverseHTX.map(\.asset.code) == ["BTC-USD", "BTC261113"] && inverseHTX.allSatisfy { $0.settlementCode == "BTC" })

        let now = Date(timeIntervalSince1970: 1794113807)
        let listings = binance + htx + inverseBinance + inverseHTX
        let expected = ["75814.3", "75836.4", "75713.8", "75778", "75890"]
        precondition(listings.count == expected.count)
        for (listing, value) in zip(listings, expected) {
            let mark = try await provider.contractMark(listing.asset, now: now)
            precondition(mark.price == Decimal(string: value) && mark.day == InvestmentBook.day(now))
        }
        let usd = try await provider.coinbaseSpotUSDQuote(code: "USDT")
        precondition(usd.price == Decimal(string: "0.998615"))
        let stale = try? await provider.contractMark(binance[0].asset, now: now.addingTimeInterval(301))
        precondition(stale == nil)
    }

    static func cryptoDailyClosesUseTheLedgerDay() async throws {
        let first = day(29), next = day(30)
        let start = Int64(first.timeIntervalSince1970)
        let end = Int64(next.timeIntervalSince1970)
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(secrets.isEmpty)
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            switch url.path {
            case "/api/v3/brokerage/market/products/USDT-USD/candles":
                precondition(query.contains(.init(name: "granularity", value: "FOUR_HOUR")))
                return response(request, #"{"candles":[{"start":"\#(start)","close":"0.8"},{"start":"\#(end - 14_400)","close":"0.99"}]}"#)
            case "/api/v3/klines":
                precondition(query.contains(.init(name: "timeZone", value: "8")))
                return response(request, #"[[\#(start * 1000),"1","1","1","0.32","1",\#(end * 1000 - 1)]]"#)
            case "/fapi/v1/markPriceKlines":
                precondition(query.contains(.init(name: "interval", value: "8h")))
                return response(request, #"[[\#(start * 1000),"1","1","1","0.3","0",\#((start + 28_800) * 1000 - 1)],[\#((end - 28_800) * 1000),"1","1","1","0.34","0",\#(end * 1000 - 1)]]"#)
            case "/index/market/history/swap_mark_price_kline":
                precondition(query.contains(.init(name: "period", value: "1day")))
                return response(request, #"{"status":"ok","ch":"market.TRX-USD.mark_price.1day","data":[{"id":\#(start),"close":"0.35"},{"id":\#(end),"close":"0.36"}]}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let rates = try await provider.coinbaseUSDDailyQuotes(for: "USDT", from: first, through: first)
        precondition(rates.count == 1 && rates[0].day == first && rates[0].price == Decimal(string: "0.99"))
        let spot = try await provider.binanceSpotDailyQuotes(for: "TRX", from: first, through: first, usdtUSD: [first: rates[0].price])
        precondition(spot.count == 1 && spot[0].price == Decimal(string: "0.3168") && spot[0].isDailyClose == true)
        var contract = asset("TRXUSDT", .cryptoContract, .usd, market: "BINANCE")
        contract.contractBasis = .stablecoin
        let binance = try await provider.contractDailyQuotes(for: contract, from: first, through: first)
        precondition(binance.count == 1 && binance[0].day == first && binance[0].price == Decimal(string: "0.34"))
        contract = asset("TRX-USD", .cryptoContract, .usd, market: "HTX")
        contract.contractBasis = .coin
        let htx = try await provider.contractDailyQuotes(for: contract, from: first, through: first)
        precondition(htx.count == 1 && htx[0].day == first && htx[0].price == Decimal(string: "0.35"))
    }

    static func asset(_ code: String, _ kind: InvestmentKind, _ currency: InvestmentCurrency, market: String = "") -> InvestmentAsset {
        InvestmentAsset(name: code, code: code, market: market, kind: kind, currency: currency)
    }

    static func day(_ value: Int) -> Date {
        InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 10, day: value))!
    }

    static func response(_ request: URLRequest, _ text: String) -> (Data, URLResponse) {
        (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
