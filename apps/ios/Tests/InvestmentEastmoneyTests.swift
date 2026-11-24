import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentMarketDataTests {
    static func twelveEmptyDatesRemainDistinctFromAPIFailures() async throws {
        let empty = InvestmentQuoteProvider { request, _ in
            (Data(#"{"code":400,"message":"No data is available on the specified dates. Try setting different start/end dates.","status":"error","meta":{"symbol":"AAPL","interval":"1day","exchange":""}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await empty.history(asset: asset("AAPL", .stock, .usd), start: day(1), through: day(2), cached: nil, keys: [.twelveData: "fixture"])
            preconditionFailure("Explicit no-data response lost")
        } catch InvestmentError.noMarketData(_) { }
        for code in [400, 401, 403, 429, 500] {
            let failure = InvestmentQuoteProvider { request, _ in
                response(request, "{\"code\":\(code),\"message\":\"Invalid request\",\"status\":\"error\"}")
            }
            do {
                _ = try await failure.history(asset: asset("AAPL", .stock, .usd), start: day(1), through: day(2), cached: nil, keys: [.twelveData: "fixture"])
                preconditionFailure("Failed request accepted as data")
            } catch InvestmentError.noMarketData(_) { preconditionFailure("API errors must never become holiday coverage") }
            catch is InvestmentError { }
        }
    }

    static func eastmoneyBenchmarkIdentitiesAndClosingDates() async throws {
        let calendar = InvestmentBook.calendar
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18))!
        for benchmark in InvestmentBenchmark.allCases {
            let provider = InvestmentQuoteProvider { request, secrets in
                let query = eastmoneyQuery(request)
                precondition(secrets.isEmpty && query["secid"] == benchmark.quoteID && query["fqt"] == "0")
                precondition(request.url?.host == "push2his.eastmoney.com")
                return try eastmoneyBars(request, code: benchmark == .sp500 ? "SPX" : "000300", market: benchmark == .sp500 ? 100 : 1,
                    bars: ["2026-11-16,100,101", "2026-11-17,101,102", "2026-11-18,102,103"])
            }
            let values = try await provider.benchmarkHistory(benchmark, from: InvestmentBook.addDays(-10, to: day), through: day,
                now: day.addingTimeInterval(4 * 3600))
            precondition(values.allSatisfy { $0.isDailyClose == true && $0.day <= day })
            if benchmark == .sp500 {
                precondition(values.count == 1 && values[0].day == InvestmentBook.addDays(-1, to: day) && values[0].price == 101,
                             "A US session must be closed before it becomes visible on its Beijing date")
            } else { precondition(values.count == 2 && values.last?.day == InvestmentBook.addDays(-1, to: day)) }
        }
        let wrong = InvestmentQuoteProvider { request, _ in
            try eastmoneyBars(request, code: "510300", market: 1, bars: ["2026-11-17,10,10"])
        }
        do {
            _ = try await wrong.benchmarkHistory(.hs300, from: InvestmentBook.addDays(-10, to: day), through: day)
            preconditionFailure("An ETF must never be accepted as the index benchmark")
        } catch is InvestmentError { }
    }

    static func eastmoneySearch(_ request: URLRequest, _ entries: [[String: String]]) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: ["QuotationCodeTable": ["Status": 0, "Data": entries]]),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    static func eastmoneyBars(_ request: URLRequest, code: String, market: Int, bars: [String]) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: ["rc": 0, "data": ["code": code, "market": market, "klines": bars]]),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    static func eastmoneyQuery(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    static func eastmoneyCatalogFindsNamesCodesAndMarkets() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(request.url?.host == "searchapi.eastmoney.com" && secrets.isEmpty)
            precondition(eastmoneyQuery(request)["type"] == "14")
            return try eastmoneySearch(request, [
                ["Code": "600036", "Name": "招商银行", "Classify": "AStock", "MktNum": "1"],
                ["Code": "600036", "Name": "招商银行", "Classify": "AStock", "MktNum": "1"],
                ["Code": "600036", "Name": "错误市场", "Classify": "AStock", "MktNum": "0"],
                ["Code": "000001", "Name": "平安银行", "Classify": "AStock", "MktNum": "0"],
                ["Code": "920002", "Name": "万达轴承", "Classify": "AStock", "MktNum": "0"],
                ["Code": "510300", "Name": "沪深300ETF", "Classify": "Fund", "MktNum": "1"],
                ["Code": "159919", "Name": "沪深300ETF嘉实", "Classify": "Fund", "MktNum": "0"],
                ["Code": "110022", "Name": "易方达消费行业股票", "Classify": "OTCFUND", "MktNum": "150"]])
        }
        let cases: [(String, InvestmentKind, Set<String>)] = [
            ("招商", .stock, ["600036.SH"]), ("6000", .stock, ["600036.SH"]),
            ("600036", .stock, ["600036.SH"]), ("600036.SH", .stock, ["600036.SH"]),
            ("600036.SZ", .stock, []), ("银行", .stock, ["600036.SH", "000001.SZ"]),
            ("920002", .stock, ["920002.BJ"]),
            ("沪深300", .etf, ["510300.SH", "159919.SZ"]), ("510300.SH", .etf, ["510300.SH"]),
            ("510300", .stock, []), ("易方达消费", .fund, ["110022.OF"]), ("110022.OF", .fund, ["110022.OF"])]
        for (query, kind, expected) in cases {
            let rows = try await provider.searchInstruments(.init(query: query, kind: kind, currency: .cny), keys: [:])
            precondition(Set(rows.map(\.code)) == expected && rows.count == expected.count, query)
        }
    }

    static func twelveUSCatalogSeparatesStocksAndETFs() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            let query = eastmoneyQuery(request)
            precondition(request.url?.host == "api.twelvedata.com" && request.url?.path == "/symbol_search")
            precondition(query["apikey"] == "fixture" && secrets == ["fixture"])
            return response(request, #"""
                {"data":[
                {"symbol":"AAPL","instrument_name":"Apple Inc","instrument_type":"Common Stock","mic_code":"XNAS","currency":"USD","country":"United States"},
                {"symbol":"AAPL22","instrument_name":"Apple Notes","instrument_type":"Bond","mic_code":"XNAS","currency":"USD","country":"United States"},
                {"symbol":"VOO","instrument_name":"Vanguard S&P 500 ETF","instrument_type":"ETF","mic_code":"ARCX","currency":"USD","country":"United States"},
                {"symbol":"AAPL","instrument_name":"Wrong country","instrument_type":"Common Stock","mic_code":"XTSE","currency":"USD","country":"Canada"},
                {"symbol":"AAPL","instrument_name":"Wrong currency","instrument_type":"Common Stock","mic_code":"XNAS","currency":"CAD","country":"United States"}]}
                """#)
        }
        let keys: [InvestmentQuoteSource: String] = [.twelveData: "fixture", .tushare: "must-not-use"]
        let stocks = try await provider.searchInstruments(.init(query: "AAPL.US", kind: .stock, currency: .usd), keys: keys)
        precondition(stocks.map(\.code) == ["AAPL"] && stocks.first?.market == "XNAS")
        let etfs = try await provider.searchInstruments(.init(query: "VOO", kind: .etf, currency: .usd), keys: keys)
        precondition(etfs.map(\.code) == ["VOO"] && etfs.first?.market == "ARCX")
        let byName = try await provider.searchInstruments(.init(query: "Apple", kind: .stock, currency: .usd), keys: keys)
        precondition(byName.map(\.code) == ["AAPL"])
        let wrong = try await provider.searchInstruments(.init(query: "VOO", kind: .stock, currency: .usd), keys: keys)
        precondition(wrong.isEmpty)
    }

    static func twelveUSEquitiesRequireKeysAndPreserveErrors() async throws {
        let unused = InvestmentQuoteProvider { _, _ in preconditionFailure("No other provider may be queried") }
        for keys: [InvestmentQuoteSource: String] in [[:], [.tushare: "fixture"], [.twelveData: "  "]] {
            do {
                _ = try await unused.searchInstruments(.init(query: "AAPL", kind: .stock, currency: .usd), keys: keys)
                preconditionFailure("Missing Twelve Data Key must be explicit")
            } catch { precondition(error.localizedDescription.contains("Twelve Data API Key")) }
            do {
                _ = try await unused.history(asset: asset("VOO", .etf, .usd), start: day(1), through: day(30), cached: nil, keys: keys)
                preconditionFailure("US history needs Twelve Data Key")
            } catch { precondition(error.localizedDescription.contains("Twelve Data API Key")) }
        }
        for code in [401, 429] {
            let rejected = InvestmentQuoteProvider { request, _ in
                precondition(request.url?.host == "api.twelvedata.com")
                return response(request, "{\"status\":\"error\",\"code\":\(code)}")
            }
            do {
                _ = try await rejected.history(asset: asset("AAPL", .stock, .usd), start: day(1), through: day(30), cached: nil,
                                               keys: [.twelveData: "fixture", .tushare: "must-not-use"])
                preconditionFailure("API rejection must not fall back")
            } catch is InvestmentError { }
        }
        for meta in [
            #"{"symbol":"OTHER","currency":"USD","mic_code":"XNAS"}"#,
            #"{"symbol":"AAPL","currency":"CNY","mic_code":"XNAS"}"#,
            #"{"symbol":"AAPL","currency":"USD","mic_code":"XNYS"}"#] {
            let wrong = InvestmentQuoteProvider { request, _ in
                response(request, "{\"meta\":\(meta),\"values\":[{\"datetime\":\"2026-10-30\",\"close\":\"20\"}]}")
            }
            do {
                _ = try await wrong.history(asset: asset("AAPL", .stock, .usd, market: "XNAS"), start: day(1), through: day(30),
                                            cached: nil, keys: [.twelveData: "fixture"])
                preconditionFailure("Wrong US identity must never be accepted")
            } catch is InvestmentError { }
        }
    }

    static func twelveNasdaqOperatingMarketIncludesSegments() async throws {
        for mic in ["XNAS", "XNMS", "XNGS", "XNCM"] {
            let provider = InvestmentQuoteProvider { request, _ in
                let query = eastmoneyQuery(request)
                precondition(query["symbol"] == "QQQM" && query["interval"] == "1day")
                precondition(query["exchange"] == "NASDAQ" && query["mic_code"] == nil)
                precondition(query["country"] == "United States" && query["type"] == "ETF" && query["adjust"] == "none")
                return response(request, "{\"meta\":{\"symbol\":\"QQQM\",\"currency\":\"USD\",\"mic_code\":\"\(mic)\",\"type\":\"ETF\"},\"values\":[{\"datetime\":\"2026-10-30\",\"close\":\"250\"}]}")
            }
            let values = try await provider.history(asset: asset("QQQM", .etf, .usd, market: "XNAS"),
                start: day(1), through: day(30), cached: nil, keys: [.twelveData: "fixture"])
            precondition(values.count == 1 && values[0].price == 250)
        }
        let exact = InvestmentQuoteProvider { request, _ in
            let query = eastmoneyQuery(request)
            precondition(query["mic_code"] == "XNMS" && query["exchange"] == nil)
            return response(request, #"{"meta":{"symbol":"QQQM","currency":"USD","mic_code":"XNGS","type":"ETF"},"values":[{"datetime":"2026-10-30","close":"250"}]}"#)
        }
        do {
            _ = try await exact.history(asset: asset("QQQM", .etf, .usd, market: "XNMS"),
                start: day(1), through: day(30), cached: nil, keys: [.twelveData: "fixture"])
            preconditionFailure("Explicit Nasdaq segments must not be widened to other segments")
        } catch is InvestmentError { }
        for mic in ["XNYS", "IEXG", "XMEX", ""] {
            let wrong = InvestmentQuoteProvider { request, _ in
                response(request, "{\"meta\":{\"symbol\":\"QQQM\",\"currency\":\"USD\",\"mic_code\":\"\(mic)\",\"type\":\"ETF\"},\"values\":[{\"datetime\":\"2026-10-30\",\"close\":\"250\"}]}")
            }
            do {
                _ = try await wrong.history(asset: asset("QQQM", .etf, .usd, market: "XNAS"),
                    start: day(1), through: day(30), cached: nil, keys: [.twelveData: "fixture"])
                preconditionFailure("Nasdaq scope must reject other exchanges and missing MICs")
            } catch is InvestmentError { }
        }
        for code in [404, 429] {
            var calls = 0
            let rejected = InvestmentQuoteProvider { request, _ in
                calls += 1
                return response(request, "{\"status\":\"error\",\"code\":\(code)}")
            }
            do {
                _ = try await rejected.history(asset: asset("QQQM", .etf, .usd, market: "XNAS"),
                    start: day(1), through: day(30), cached: nil, keys: [.twelveData: "fixture"])
                preconditionFailure("Failed requests must remain errors")
            } catch is InvestmentError { }
            precondition(calls == 1, "Market selection must not introduce error-driven retry requests")
        }
    }

    static func eastmoneyStockConnectCatalogNormalizesCodes() async throws {
        let provider = InvestmentQuoteProvider { request, _ in
            if request.url?.host == "push2.eastmoney.com" {
                let code = eastmoneyQuery(request)["secid"] == "116.00823" ? "00823" : "02800"
                return response(request, code == "02800"
                    ? #"{"rc":0,"data":{"f57":"02800","f107":116,"f127":"","f172":"HKD","f198":""}}"#
                    : #"{"rc":0,"data":{"f57":"00823","f107":116,"f127":"地产","f172":"HKD","f198":"HK25"}}"#)
            }
            return try eastmoneySearch(request, [
                ["Code": "00700", "Name": "腾讯控股", "Classify": "HK", "MktNum": "116", "SecurityType": "19"],
                ["Code": "02800", "Name": "盈富基金", "Classify": "HK", "MktNum": "116", "SecurityType": "6"],
                ["Code": "00823", "Name": "领展房产基金", "Classify": "HK", "MktNum": "116", "SecurityType": "6"],
                ["Code": "09010", "Name": "美元柜台", "Classify": "HK", "MktNum": "116", "SecurityType": "6"]])
        }
        for query in ["700", "00700", "00700.HK", "腾讯"] {
            let rows = try await provider.searchInstruments(.init(query: query, kind: .stock, currency: .hkd, stockConnect: true), keys: [:])
            precondition(rows.map(\.code) == ["00700.HK"] && rows.first?.settlementCurrency == .cny)
        }
        let etfs = try await provider.searchInstruments(.init(query: "2800", kind: .etf, currency: .hkd, stockConnect: true), keys: [:])
        precondition(etfs.map(\.code) == ["02800.HK"])
        let wrong = try await provider.searchInstruments(.init(query: "00700", kind: .etf, currency: .hkd, stockConnect: true), keys: [:])
        precondition(wrong.isEmpty)
        let reit = try await provider.searchInstruments(.init(query: "00823", kind: .etf, currency: .hkd, stockConnect: true), keys: [:])
        precondition(reit.isEmpty, "A REIT must not be returned as an ETF")
    }

    static func eastmoneyHistoryUsesUnadjustedClosesWithoutKeys() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(request.url?.host == "push2his.eastmoney.com" && secrets.isEmpty && request.httpBody == nil)
            let query = eastmoneyQuery(request)
            precondition(query["secid"] == "1.600036" && query["klt"] == "101" && query["fqt"] == "0")
            return try eastmoneyBars(request, code: "600036", market: 1, bars: [
                "2026-09-30,30,31,32,29,100", "2026-10-29,30,31.50,32,29,100",
                "2026-10-30,31,32.25,33,30,100", "2026-10-31,1,999,999,1,100",
                "2026-10-28,1,-,2,1,0"])
        }
        let rows = try await provider.history(asset: asset("600036.SH", .stock, .cny), start: day(1), through: day(30), cached: nil,
                                              keys: [.tushare: "must-not-use", .twelveData: "must-not-use"], now: day(31))
        precondition(rows.map(\.price) == [Decimal(string: "31.50")!, Decimal(string: "32.25")!])
        precondition(rows.allSatisfy { $0.source == "东方财富" && $0.isDailyClose == true })
        let mismatch = InvestmentQuoteProvider { request, _ in
            try eastmoneyBars(request, code: "600000", market: 1, bars: ["2026-10-30,1,2,2,1,1"])
        }
        do {
            _ = try await mismatch.history(asset: asset("600036.SH", .stock, .cny), start: day(1), through: day(30), cached: nil, keys: [:])
            preconditionFailure("Mismatched symbol must not be stored")
        } catch is InvestmentError { }
    }

    static func eastmoneyDerivativeMarketsAndContractFormats() async throws {
        let cases: [(String, InvestmentKind, String)] = [
            ("RB2701.SHF", .future, "113.rb2701"), ("M2701.DCE", .future, "114.m2701"),
            ("MA2701.ZCE", .future, "115.MA701"), ("IF2612.CFX", .future, "220.IF2612"),
            ("SC2612.INE", .future, "142.sc2612"), ("SI2701.GFE", .future, "225.si2701"),
            ("10012189.SH", .option, "10.10012189"), ("90007769.SZ", .option, "12.90007769"),
            ("EB2612-P-9000.DCE", .option, "140.eb2612p9000"), ("MO2611-P-6000.CFX", .option, "221.MO2611-P-6000")]
        for (code, kind, quoteID) in cases {
            let provider = InvestmentQuoteProvider { request, secrets in
                let query = eastmoneyQuery(request)
                precondition(secrets.isEmpty && query["secid"] == quoteID)
                precondition(query["forcect"] == "1" && query["iscca"] == "1")
                let parts = quoteID.split(separator: ".")
                return try eastmoneyBars(request, code: String(parts[1]), market: Int(parts[0])!, bars: ["2026-10-30,3030,3007,3032,3006,100"])
            }
            let rows = try await provider.history(asset: asset(code, kind, .cny), start: day(1), through: day(30), cached: nil, keys: [:])
            precondition(rows.first?.price == 3007)
        }
        let provider = InvestmentQuoteProvider { request, _ in
            try eastmoneySearch(request, [["Code": "IF2612", "Name": "沪深2612", "Classify": "CFFEX", "JYS": "CFFEX",
                                          "SecurityTypeName": "期货", "MktNum": "220"]])
        }
        let matches = try await provider.searchInstruments(.init(query: "IF2612.CFX", kind: .future, currency: .cny), keys: [:])
        precondition(matches.map(\.code) == ["IF2612.CFX"])
    }

    static func eastmoneyExpiredContractsCanUseTushare() async throws {
        var hosts: [String] = []
        let provider = InvestmentQuoteProvider { request, _ in
            hosts.append(request.url!.host!)
            if request.url?.host == "push2his.eastmoney.com" { return response(request, #"{"rc":100,"data":null}"#) }
            precondition(request.url?.host == "api.tushare.pro")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["api_name"] as? String == "fut_daily")
            return response(request, #"{"code":0,"data":{"fields":["ts_code","trade_date","close"],"items":[["RB2610.SHF","20261012",3100]]}}"#)
        }
        let rows = try await provider.history(asset: asset("RB2610.SHF", .future, .cny), start: day(1), through: day(30), cached: nil,
                                              keys: [.tushare: "fixture"])
        precondition(hosts == ["push2his.eastmoney.com", "api.tushare.pro"])
        precondition(rows.first?.price == 3100 && rows.first?.source == "Tushare Pro")
        let empty = InvestmentQuoteProvider { request, _ in response(request, #"{"rc":100,"data":null}"#) }
        do {
            _ = try await empty.history(asset: asset("RB2610.SHF", .future, .cny), start: day(1), through: day(30), cached: nil, keys: [:])
            preconditionFailure("Missing expired data must not become zero prices")
        } catch is InvestmentError { }
    }

    static func eastmoneyFundNAVPaginatesAndRejectsMoneyYields() async throws {
        var pages: [String] = []
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(request.url?.host == "api.fund.eastmoney.com" && secrets.isEmpty)
            precondition(request.value(forHTTPHeaderField: "Referer") == "https://fundf10.eastmoney.com/")
            let query = eastmoneyQuery(request)
            precondition(query["fundCode"] == "110022" && query["startDate"] == "2026-10-01" && query["endDate"] == "2026-10-30")
            pages.append(query["pageIndex"]!)
            if query["pageIndex"] == "1" {
                return response(request, #"{"ErrCode":0,"TotalCount":3,"PageIndex":1,"Data":{"FundType":"001","LSJZList":[{"FSRQ":"2026-10-30","DWJZ":"1.42","LJJZ":"9.42"},{"FSRQ":"2026-10-29","DWJZ":"1.40"}]}}"#)
            }
            return response(request, #"{"ErrCode":0,"TotalCount":3,"PageIndex":2,"Data":{"FundType":"001","LSJZList":[{"FSRQ":"2026-10-28","DWJZ":"1.39"}]}}"#)
        }
        let rows = try await provider.history(asset: asset("110022.OF", .fund, .cny), start: day(1), through: day(30), cached: nil, keys: [:])
        precondition(pages == ["1", "2"] && rows.count == 3 && rows.last?.price == Decimal(string: "1.42"))
        precondition(rows.allSatisfy { $0.isDailyClose == true && $0.source == "东方财富 · 天天基金" })
        let money = InvestmentQuoteProvider { request, _ in
            precondition(request.url?.host == "api.fund.eastmoney.com")
            return response(request, #"{"ErrCode":0,"TotalCount":1,"Data":{"FundType":"005","SYType":"每万份收益","LSJZList":[{"FSRQ":"2026-10-30","DWJZ":"0.2150"}]}}"#)
        }
        do {
            _ = try await money.history(asset: asset("000198.OF", .fund, .cny), start: day(1), through: day(30), cached: nil, keys: [.tushare: "unused"])
            preconditionFailure("A money-market yield is not a NAV")
        } catch let error as InvestmentError { precondition(error.localizedDescription.contains("每万份收益")) }
    }

    static func twelveUSCloseTimesAndWatchFreshness() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            let query = eastmoneyQuery(request)
            precondition(request.url?.host == "api.twelvedata.com" && request.url?.path == "/time_series")
            precondition(query["apikey"] == "fixture" && secrets == ["fixture"])
            precondition(query["interval"] == "1day" && query["adjust"] == "none" && query["type"] == "ETF")
            precondition(query["country"] == "United States")
            if query["start_date"] != "2026-10-01" {
                precondition(query["start_date"] == "2026-10-16" && query["end_date"] == "2026-10-30",
                             "Watch validation must only request the most recent 14 days")
            }
            let code = query["symbol"]!
            if code == "VOO" { precondition(query["mic_code"] == "ARCX") }
            let date = code == "OLD" ? "2026-10-01" : "2026-10-30"
            return response(request, "{\"meta\":{\"symbol\":\"\(code)\",\"currency\":\"USD\",\"mic_code\":\"ARCX\",\"type\":\"ETF\"},\"values\":[{\"datetime\":\"\(date)\",\"close\":\"500.20\"}]}")
        }
        let keys: [InvestmentQuoteSource: String] = [.twelveData: "fixture"]
        let close = InvestmentBook.usEquityClose(on: day(30))
        let symbol = asset("VOO", .etf, .usd, market: "ARCX")
        precondition(!symbol.usesEastmoneyMarketData)
        let early = try await provider.history(asset: symbol, start: day(1), through: day(30), cached: nil, keys: keys, now: close.addingTimeInterval(-60))
        let done = try await provider.history(asset: symbol, start: day(1), through: day(30), cached: nil, keys: keys, now: close)
        precondition(early.last?.isDailyClose == false && done.last?.isDailyClose == true)
        precondition(done.last?.source == "Twelve Data" && done.last?.price == Decimal(string: "500.20"))
        let watch = try await provider.watchQuotes(for: symbol, keys: keys, through: day(30))
        precondition(watch.last?.price == Decimal(string: "500.20"))
        do {
            _ = try await provider.watchQuotes(for: asset("OLD", .etf, .usd), keys: keys, through: day(30))
            preconditionFailure("Stale prices must not pass watch validation")
        } catch is InvestmentError { }
        let hk = InvestmentQuoteProvider { request, _ in
            precondition(eastmoneyQuery(request)["secid"] == "116.02800")
            return try eastmoneyBars(request, code: "02800", market: 116, bars: ["2026-10-30,23,24,25,22,1"])
        }
        let rows = try await hk.history(asset: asset("02800.HK", .etf, .hkd, market: InvestmentAsset.stockConnectMarket),
                                        start: day(1), through: day(30), cached: nil, keys: [:])
        precondition(rows.first?.price == 24)
    }

    static func eastmoneyFailuresAndRetryAreExplicit() async throws {
        var attempts = 0
        let retry = InvestmentQuoteProvider { request, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return try eastmoneySearch(request, [])
        }
        let empty = try await retry.searchInstruments(.init(query: "不存在", kind: .fund, currency: .cny), keys: [:])
        precondition(empty.isEmpty && attempts == 2)
        let offline = InvestmentQuoteProvider { _, _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.searchInstruments(.init(query: "110022", kind: .fund, currency: .cny), keys: [:])
            preconditionFailure("Network failure must not be reported as no matches")
        } catch is URLError { }
    }

    static func referenceRates() async throws {
        let provider = InvestmentQuoteProvider { request, secrets in
            precondition(request.url?.host == "data-api.ecb.europa.eu" && secrets.isEmpty)
            return response(request, "CURRENCY,TIME_PERIOD,OBS_VALUE\nCNY,2026-10-30,8.4\nUSD,2026-10-30,1.2\nHKD,2026-10-30,9.6\n")
        }
        let rates = try await provider.ecbRates(for: [.usd, .hkd], start: day(1), end: day(30))
        precondition(rates[.usd]?.first?.price == 7 && rates[.hkd]?.first?.price == Decimal(string: "0.875"))
    }
}
