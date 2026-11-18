import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct InvestmentMarketDataTests {
    static func main() async throws {
        mapping()
        try catalogIdentityCannotBeHandEdited()

        try catalogValidationIncludesNewUsesOfExistingAssets()
        try await credentialTestsUseAuthenticatedEndpoints()
        try await credentialTestsRejectInvalidResponses()
        try await eastmoneyCatalogFindsNamesCodesAndMarkets()
        try await eastmoneyUSCatalogSeparatesStocksAndETFs()
        try await eastmoneyStockConnectCatalogNormalizesCodes()
        try await eastmoneyHistoryUsesUnadjustedClosesWithoutKeys()
        try await eastmoneyBenchmarkIdentitiesAndClosingDates()
        try await eastmoneyDerivativeMarketsAndContractFormats()
        try await eastmoneyExpiredContractsCanUseTushare()
        try await eastmoneyFundNAVPaginatesAndRejectsMoneyYields()
        try await eastmoneyCloseTimesAndWatchFreshness()
        try await eastmoneyFailuresAndRetryAreExplicit()
        try await cryptocurrencyUsesUSDPair()
        try await binanceSpotCatalogFindsTRX()
        try await publicSpotPricesAreConvertedToDollars()
        try await cryptoDailyClosesUseTheLedgerDay()
        try await cryptoChartHistoryUsesPublicDailyCloses()
        try await cryptoChartHistoryUsesDirectDollarPricesWhenUnavailable()

        try await referenceRates()
        print("Investment market data checks passed")
    }



    static func catalogIdentityCannotBeHandEdited() throws {
        for kind in [InvestmentKind.stock, .fund, .etf, .crypto] {
            let listed = InvestmentAsset(name: "目录名称", code: "ABC", market: "XNAS", kind: kind, currency: .usd)
            try listed.validateCatalogIdentity(listed)
            for field in ["name", "code", "market", "kind", "currency"] {
                var changed = listed
                switch field {
                case "name": changed.name = "自定义名称"
                case "code": changed.code = "OTHER"
                case "market": changed.market = ""
                case "kind": changed.kind = .wealth
                default: changed.currency = .cny
                }
                do {
                    try changed.validateCatalogIdentity(listed)
                    preconditionFailure("Manual identity change passed: \(field)")
                } catch is InvestmentError { }
            }
        }
    }



    static func catalogValidationIncludesNewUsesOfExistingAssets() throws {
        let listed = InvestmentAsset(name: "苹果", code: "AAPL", market: "XNAS", kind: .stock, currency: .usd)
        let account = InvestmentAccount(name: "美股", currency: .usd, type: .securities)
        let original = InvestmentBook(accounts: [account], assets: [listed.id: listed])
        precondition(original.catalogAssetsRequiringValidation(comparedTo: original).isEmpty)
        var edited = original
        edited.assets[listed.id]!.name = "手填名称"
        precondition(edited.catalogAssetsRequiringValidation(comparedTo: original).map(\.id) == [listed.id])
        var traded = original
        traded.accounts[0].events.append(.init(day: day(1), kind: .buy, assetID: listed.id, quantity: 1, price: 1))
        precondition(traded.catalogAssetsRequiringValidation(comparedTo: original).map(\.id) == [listed.id])
        precondition(original.catalogAssetsRequiringValidation(comparedTo: traded).isEmpty, "Deletion must not require a catalog request")
        var watched = original
        watched.watched = [listed.id]
        precondition(watched.catalogAssetsRequiringValidation(comparedTo: original).map(\.id) == [listed.id])
        var planned = original
        planned.plans = [.init(accountID: account.id, assetID: listed.id, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: day(1))]
        precondition(planned.catalogAssetsRequiringValidation(comparedTo: original).map(\.id) == [listed.id])
    }

    static func credentialTestsUseAuthenticatedEndpoints() async throws {
        var requests = 0
        let provider = InvestmentQuoteProvider { request, secrets in
            requests += 1
            precondition(secrets == ["fixture"])
            precondition(request.url?.query == nil)
            if request.url?.host == "api.tushare.pro" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(request.httpMethod == "POST" && body["api_name"] as? String == "trade_cal")
                precondition(body["token"] as? String == "fixture")
                let params = body["params"] as! [String: String]
                precondition(params["exchange"] == "SSE" && params["start_date"] == params["end_date"])
                let date = params["start_date"]!
                return response(request, "{\"code\":0,\"data\":{\"fields\":[\"cal_date\"],\"items\":[[\"" + date + "\"]]}}")
            }
            precondition(request.url?.host == "api.twelvedata.com" && request.url?.path == "/api_usage")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "apikey fixture")
            return response(request, #"{"timestamp":"2026-11-12 13:00:00","current_usage":0,"plan_limit":8,"plan_category":"Basic"}"#)
        }
        for source in InvestmentQuoteSource.allCases {
            try await provider.testCredential(" \nfixture\n", for: source)
        }
        precondition(requests == 2)
        for value in ["", " \n", "中文", "bad\nkey"] {
            do {
                try await provider.testCredential(value, for: .tushare)
                preconditionFailure("Invalid credentials must be rejected before a request")
            } catch InvestmentError.invalid {}
        }
        precondition(requests == 2)
    }

    static func credentialTestsRejectInvalidResponses() async throws {
        let responses: [(InvestmentQuoteSource, String)] = [
            (.tushare, #"{"code":2002,"data":null}"#),
            (.tushare, #"{"code":0,"data":{"fields":["cal_date"],"items":[]}}"#),
            (.twelveData, #"{"status":"error","code":401}"#),
            (.twelveData, #"{"status":"error","code":429}"#),
            (.twelveData, #"{"status":"ok"}"#)
        ]
        for (source, payload) in responses {
            let provider = InvestmentQuoteProvider { request, _ in response(request, payload) }
            do {
                try await provider.testCredential("fixture", for: source)
                preconditionFailure("A failed or incomplete response must not pass the connection test")
            } catch InvestmentError.invalid {}
        }
        let offline = InvestmentQuoteProvider { _, _ in throw URLError(.notConnectedToInternet) }
        do {
            try await offline.testCredential("fixture", for: .twelveData)
            preconditionFailure("Network failure must not pass the connection test")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
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
        precondition(spot.allSatisfy { $0.market == "BINANCE" })
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
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let rates = try await provider.coinbaseUSDDailyQuotes(for: "USDT", from: first, through: first)
        precondition(rates.count == 1 && rates[0].day == first && rates[0].price == Decimal(string: "0.99"))
        let spot = try await provider.binanceSpotDailyQuotes(for: "TRX", from: first, through: first, usdtUSD: [first: rates[0].price])
        precondition(spot.count == 1 && spot[0].price == Decimal(string: "0.3168") && spot[0].isDailyClose == true)
    }

    static func cryptoChartHistoryUsesPublicDailyCloses() async throws {
        let first = day(29), next = day(30)
        let start = Int64(first.timeIntervalSince1970), end = Int64(next.timeIntervalSince1970)
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(secrets.isEmpty)
            switch request.url!.path {
            case "/api/v3/brokerage/market/products/USDT-USD/candles":
                return response(request, #"{"candles":[{"start":"\#(end - 14_400)","close":"0.99"}]}"#)
            case "/api/v3/klines":
                return response(request, #"[[\#(start * 1000),"1","1","1","0.32","1",\#(end * 1000 - 1)]]"#)
            default: preconditionFailure("Unexpected public price request")
            }
        }
        let values = try await provider.cryptoPriceHistory(code: "TRX", from: first, through: first)
        precondition(values.count == 1 && values[0].day == first && values[0].price == Decimal(string: "0.3168"))
        precondition(values[0].isDailyClose == true)
        let stable = try await provider.cryptoPriceHistory(code: "USDT", from: first, through: first)
        precondition(stable.count == 1 && stable[0].price == Decimal(string: "0.99"))
        let today = InvestmentBook.day()
        let incomplete = try await provider.cryptoPriceHistory(code: "TRX", from: today, through: today)
        precondition(incomplete.isEmpty)
    }

    static func cryptoChartHistoryUsesDirectDollarPricesWhenUnavailable() async throws {
        let first = day(29), end = Int64(day(30).timeIntervalSince1970)
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(secrets.isEmpty)
            guard request.url!.path == "/api/v3/brokerage/market/products/BTC-USD/candles" else {
                throw URLError(.cannotConnectToHost)
            }
            return response(request, #"{"candles":[{"start":"\#(end - 14_400)","close":"98000"}]}"#)
        }
        let values = try await provider.cryptoPriceHistory(code: "BTC", from: first, through: first)
        precondition(values.count == 1 && values[0].day == first && values[0].price == 98000)
        precondition(values[0].isDailyClose == true)
        let empty = InvestmentQuoteProvider { request, _ in response(request, #"{"candles":[]}"#) }
        do {
            _ = try await empty.cryptoPriceHistory(code: "BTC", from: first, through: first)
            preconditionFailure("Missing prices must report a query failure")
        } catch is InvestmentError { }
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
