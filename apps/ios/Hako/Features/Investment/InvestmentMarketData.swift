import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentAsset {
    var catalogKey: String { [kind.rawValue, currency.rawValue, market, code].joined(separator: "|") }

    func validateCatalogIdentity(_ listed: InvestmentAsset) throws {
        guard kind == listed.kind, currency == listed.currency, code == listed.code, market == listed.market else {
            throw InvestmentError.invalid("请从对应市场的目录中选择标的，不能手工填写代码或交易所。")
        }
        guard name == listed.name else {
            throw InvestmentError.invalid("标的名称由目录提供（\(listed.name)），不能手工修改。请重新选择搜索结果。")
        }
    }
}

extension InvestmentBook {
    func catalogAssetsRequiringValidation(comparedTo previous: InvestmentBook) -> [InvestmentAsset] {
        func usedAssets(in book: InvestmentBook) -> Set<UUID> {
            Set(book.watched)
                .union(book.accounts.flatMap(\.events).compactMap(\.assetID))
                .union(book.plans.filter(\.enabled).compactMap(\.assetID))
        }
        // New ledger entries reuse the established identity. Rechecking the live
        // catalog here would reject balance changes when the vendor renames an asset.
        let used = usedAssets(in: self).subtracting(usedAssets(in: previous))
        return assets.values.filter { asset in
            guard asset.kind.requiresCatalog else { return false }
            guard let original = previous.asset(asset.id) else { return true }
            return used.contains(asset.id) || original.catalogKey != asset.catalogKey
                || original.name != asset.name || original.multiplier != asset.multiplier
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

enum InvestmentQuoteSource: String, CaseIterable, Identifiable {
    case tushare = "tushare-pro"
    case twelveData = "twelve-data"

    var id: Self { self }
    var title: String { self == .tushare ? "Tushare Pro" : "Twelve Data" }
    var credential: String { self == .tushare ? "API Token" : "API Key" }
}

struct InvestmentInstrumentSearch: Equatable {
    let query: String
    let kind: InvestmentKind
    let currency: InvestmentCurrency
    var stockConnect = false
    var accountType: InvestmentAccountType?

    var exactAsset: InvestmentAsset {
        let code = stockConnect ? InvestmentAsset.stockConnectCode(query) ?? query : query.uppercased()
        return InvestmentAsset(name: "", code: code, market: stockConnect ? InvestmentAsset.stockConnectMarket : "",
                               kind: kind, currency: currency)
    }

    func includes(_ asset: InvestmentAsset) -> Bool {
        guard permits(asset) else { return false }
        return asset.code.localizedCaseInsensitiveContains(query)
            || asset.name.localizedCaseInsensitiveContains(query)
            || (stockConnect && asset.code == exactAsset.code)
    }

    func permits(_ asset: InvestmentAsset) -> Bool {
        guard asset.kind == kind, asset.currency == currency, asset.isStockConnect == stockConnect else { return false }
        if let accountType {
            let account = InvestmentAccount(name: "", currency: asset.settlementCurrency, type: accountType)
            return (try? asset.validateEntry(in: account)) != nil
        }
        return (try? asset.validateMarket(settlingIn: asset.settlementCurrency)) != nil
    }
}

struct InvestmentQuoteSymbol {
    var twelveSymbol: String?
    var twelveMIC: String = ""
    var tushareSymbol: String?
    var tushareAPI: String?

    init(_ asset: InvestmentAsset) {
        if asset.isStockConnect {
            guard (try? asset.validateMarket(settlingIn: .cny)) != nil,
                  let number = Int(asset.code.dropLast(3)) else { return }
            twelveSymbol = String(format: "%04d", number)
            twelveMIC = "XHKG"
            tushareSymbol = asset.code
            tushareAPI = "hk_daily"
            return
        }
        guard !asset.isHongKongEquity, !asset.kind.isManual else { return }
        let code = asset.code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let market = asset.market.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch asset.currency {
        case .cny:
            guard let (base, venue) = asset.mainlandSymbol else { return }
            tushareSymbol = base + "." + venue
            if asset.kind.derivative {
                tushareAPI = asset.kind == .future ? "fut_daily" : "opt_daily"
                return
            }
            switch asset.kind {
            case .fund: tushareAPI = "fund_nav"
            case .etf: tushareAPI = "fund_daily"
            default: tushareAPI = "daily"
            }
            twelveSymbol = base
            twelveMIC = InvestmentAsset.mainlandMICs[venue] ?? ""
        case .hkd:
            return
        case .usd:
            if asset.kind == .crypto, (try? asset.validateMarket(settlingIn: .usd)) != nil {
                twelveSymbol = code + "/USD"
                return
            }
            guard asset.kind == .stock || asset.kind == .etf,
                  (try? asset.validateMarket(settlingIn: .usd)) != nil else { return }
            let symbol = code.hasSuffix(".US") ? String(code.dropLast(3)) : code
            guard symbol.first?.isASCII == true, symbol.first?.isLetter == true else { return }
            tushareSymbol = symbol
            tushareAPI = asset.kind == .etf ? "us_etf_daily" : "us_daily"
            twelveSymbol = symbol
            twelveMIC = market == "US" ? "" : market
        }
    }
}

struct InvestmentQuoteProvider {
    typealias Transport = (URLRequest, [String]) async throws -> (Data, URLResponse)
    let send: Transport

    init(send: @escaping Transport = { request, secrets in try await HTTPTransport.data(for: request, secrets: secrets) }) {
        self.send = { request, secrets in
            guard let sink = HakoExecutionDiagnostics.sink else { return try await send(request, secrets) }
            // Keep headers, query values and bodies out of shortcut history.
            let endpoint = HakoLog.sanitize((request.url?.host ?? "未知来源") + (request.url?.path ?? ""), secrets: secrets)
            let stage = "行情请求 " + (request.httpMethod ?? "GET") + " " + endpoint
            let context = "请求时限：" + String(format: "%.0f 秒", request.timeoutInterval)
            let event = HakoExecutionEvent(stage: stage, state: .started, detail: context)
            await sink(event)
            do {
                try Task.checkCancellation()
                let result = try await send(request, secrets)
                try Task.checkCancellation()
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                await sink(HakoExecutionEvent(id: event.id, stage: stage, state: status == 200 ? .succeeded : .failed,
                    detail: context + "\nHTTP \(status)；接收 \(result.0.count) 字节。HTTP 响应不代表行情数据已通过校验。"))
                return result
            } catch {
                let cancelled = HTTPTransport.isTaskCancellation(error)
                let cause = (error as? URLError)?.code == .timedOut ? "\n网络请求超时，区别于系统结束整次后台执行。" : ""
                let detail = HakoLog.sanitize(context + "\n" + HakoExecutionDiagnostics.failure(error) + cause, secrets: secrets)
                await sink(HakoExecutionEvent(id: event.id, stage: stage, state: cancelled ? .cancelled : .failed, detail: detail))
                throw error
            }
        }
    }

    static func quoteSummary(_ values: [InvestmentQuote]) -> String {
        guard let first = values.min(by: { $0.day < $1.day }), let last = values.max(by: { $0.day < $1.day }) else {
            return "未取得有效行情记录。"
        }
        let format = dateFormat("yyyy-MM-dd")
        let sources = Set(values.compactMap(\.source)).sorted().joined(separator: " / ")
        return "已校验 \(values.count) 条报价；\(format.string(from: first.day)) 至 \(format.string(from: last.day))。\n来源：\(sources.isEmpty ? "未标记" : sources)"
    }

    static func order(for currency: InvestmentCurrency) -> [InvestmentQuoteSource] {
        currency == .cny ? [.tushare, .twelveData] : [.twelveData, .tushare]
    }

    private struct TwelveCredentialResponse: Decodable {
        let code: Int?
        let current_usage: Int?
        let plan_limit: Int?
    }

    private static func twelveRequest(_ url: URL, key: String) throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw InvestmentError.invalid("行情接口地址无效")
        }
        // Use the vendor's query authentication rather than URLSession's reserved Authorization header.
        components.queryItems = (components.queryItems ?? []) + [.init(name: "apikey", value: key)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let authenticatedURL = components.url else { throw InvestmentError.invalid("行情接口地址无效") }
        return URLRequest(url: authenticatedURL, timeoutInterval: 15)
    }

    func testCredential(_ value: String, for source: InvestmentQuoteSource) async throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw InvestmentError.invalid("请先输入行情凭据。") }
        guard key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw InvestmentError.invalid("行情凭据只能包含可见 ASCII 字符。")
        }
        try Task.checkCancellation()
        switch source {
        case .tushare:
            let date = Self.dateFormat("yyyyMMdd").string(from: InvestmentBook.addDays(-1, to: InvestmentBook.day()))
            let table = try await tushareTable(api: "trade_cal", params: ["exchange": "SSE", "start_date": date, "end_date": date],
                                               fields: ["cal_date"], key: key)
            guard let index = table.fields.firstIndex(of: "cal_date"),
                  table.items.contains(where: { $0.count > index && $0[index]?.string == date }) else {
                throw InvestmentError.invalid("行情接口未返回有效的交易日历。")
            }
        case .twelveData:
            let request = try Self.twelveRequest(URL(string: "https://api.twelvedata.com/api_usage")!, key: key)
            let (data, response) = try await send(request, [key])
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = try? JSONDecoder().decode(TwelveCredentialResponse.self, from: data)
            guard status == 200, result?.code == nil, result?.current_usage != nil, result?.plan_limit != nil else {
                throw Self.failure(result?.code ?? status)
            }
        }
        try Task.checkCancellation()
    }

    private struct BinanceSpotSymbol: Decodable {
        struct Pair: Decodable {
            let baseAsset: String
            let quoteAsset: String
            let status: String
            let isSpotTradingAllowed: Bool
        }
        let symbols: [Pair]
    }

    private struct BinanceSpotNames: Decodable {
        struct Asset: Decodable {
            let assetCode: String
            let assetName: String?
        }
        let data: [Asset]
    }

    func cryptoCatalog() async throws -> [InvestmentAsset] {
        let url = URL(string: "https://data-api.binance.vision/api/v3/exchangeInfo?permissions=SPOT&symbolStatus=TRADING&showPermissionSets=false")!
        async let namesRequest = try? binanceSpotNames()
        let (data, response) = try await send(URLRequest(url: url, timeoutInterval: 10), [])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status) }
        let result = try JSONDecoder().decode(BinanceSpotSymbol.self, from: data)
        let codes = Set(result.symbols.filter { $0.status == "TRADING" && $0.isSpotTradingAllowed }
            .flatMap { [$0.baseAsset, $0.quoteAsset] })
        let names = await namesRequest ?? [:]
        try Task.checkCancellation()
        let fiat = Set(Locale.Currency.isoCurrencies.map(\.identifier))
        return codes.subtracting(fiat).compactMap { code in
            let asset = InvestmentAsset(name: names[code] ?? code, code: code, market: "BINANCE", kind: .crypto, currency: .usd)
            return (try? asset.validateMarket(settlingIn: .usd)) == nil ? nil : asset
        }
    }

    private func binanceSpotNames() async throws -> [String: String] {
        let url = URL(string: "https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset")!
        let (data, response) = try await send(URLRequest(url: url, timeoutInterval: 4), [])
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
        let assets = try JSONDecoder().decode(BinanceSpotNames.self, from: data).data
        var names: [String: String] = [:]
        for asset in assets {
            if let name = asset.assetName, !name.isEmpty { names[asset.assetCode] = name }
        }
        return names
    }

    private struct BinanceSpotPrice: Decodable {
        let symbol: String
        let price: String
    }

    func publicSpotUSDQuote(for asset: InvestmentAsset) async throws -> InvestmentQuote {
        guard asset.kind == .crypto else { throw InvestmentError.invalid("无效的现货币种") }
        try asset.validateMarket(settlingIn: .usd)
        if asset.code == "USDT" {
            return InvestmentQuote(day: InvestmentBook.day(), price: 1, source: "USDT 固定估值（1:1）")
        }
        let code = asset.code
        var url = URLComponents(string: "https://data-api.binance.vision/api/v3/ticker/price")!
        let symbol = code + "USDT"
        url.queryItems = [.init(name: "symbol", value: symbol)]
        guard let endpoint = url.url else { throw URLError(.badURL) }
        let (data, response) = try await send(URLRequest(url: endpoint, timeoutInterval: 8), [])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status) }
        let ticker = try JSONDecoder().decode(BinanceSpotPrice.self, from: data)
        guard ticker.symbol == symbol, let price = Decimal(string: ticker.price, locale: Locale(identifier: "en_US_POSIX")),
              price > 0 else { throw InvestmentError.invalid("没有匹配的 Binance 现货报价") }
        return InvestmentQuote(day: InvestmentBook.day(), price: price, source: "Binance 现货")
    }

    func searchInstruments(_ search: InvestmentInstrumentSearch, keys: [InvestmentQuoteSource: String],
                           consolidateUSListings: Bool = true) async throws -> [InvestmentAsset] {
        guard !search.query.isEmpty, !search.kind.isManual else { return [] }
        try Task.checkCancellation()
        if search.kind == .crypto {
            return try await cryptoCatalog().filter { search.includes($0) }
        }
        let asset = search.exactAsset
        let symbol = InvestmentQuoteSymbol(asset)
        if asset.usesUSEquityClose {
            let key = try Self.usEquityKey(keys)
            return try await twelveInstruments(search, symbol: symbol, key: key,
                                               consolidateUSListings: consolidateUSListings).filter(search.permits)
        }
        if search.kind != .crypto {
            return try await eastmoneyInstruments(search)
        }
        var lastError: Error?
        for source in Self.order(for: asset.currency) {
            try Task.checkCancellation()
            guard let key = keys[source] else { continue }
            do {
                let results: [InvestmentAsset]
                switch source {
                case .tushare:
                    continue
                case .twelveData:
                    results = try await twelveInstruments(search, symbol: symbol, key: key)
                }
                try Task.checkCancellation()
                let allowed = results.filter(search.permits)
                if !allowed.isEmpty { return allowed }
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private struct TwelveInstrumentSearch: Decodable {
        struct Instrument: Decodable {
            var symbol: String?
            var instrument_name: String?
            var instrument_type: String?
            var mic_code: String?
            var currency: String?
            var country: String?
        }
        var data: [Instrument]?
        var code: Int?
    }

    private func twelveInstruments(_ search: InvestmentInstrumentSearch, symbol: InvestmentQuoteSymbol, key: String,
                                   consolidateUSListings: Bool = true) async throws -> [InvestmentAsset] {
        let acceptedTypes: Set<String>
        switch search.kind {
        case .stock:
            acceptedTypes = ["common stock", "preferred stock", "american depositary receipt",
                             "depositary receipt", "global depositary receipt", "reit", "limited partnership"]
        case .etf: acceptedTypes = ["etf"]
        case .fund: acceptedTypes = ["mutual fund"]
        case .crypto: acceptedTypes = ["digital currency", "cryptocurrency"]
        case .future, .option, .insurance, .wealth, .deposit, .certificate, .generic: return []
        }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.twelvedata.com"
        url.path = "/symbol_search"
        let query = search.kind == .crypto ? search.query : symbol.twelveSymbol ?? search.query
        url.queryItems = [.init(name: "symbol", value: query), .init(name: "outputsize", value: "120")]
        guard let url = url.url else { return [] }
        let request = try Self.twelveRequest(url, key: key)
        let (data, response) = try await send(request, [key])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let result = try? JSONDecoder().decode(TwelveInstrumentSearch.self, from: data)
        guard status == 200, let instruments = result?.data else { throw Self.failure(result?.code ?? status) }

        let matches: [(asset: InvestmentAsset, identity: [String])] = instruments.compactMap { entry in
            guard let ticker = entry.symbol?.uppercased(), !ticker.isEmpty,
                  let name = entry.instrument_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  search.kind == .crypto || entry.currency?.uppercased() == search.currency.rawValue,
                  let type = entry.instrument_type?.lowercased(), acceptedTypes.contains(type) else { return nil }
            guard ticker.localizedCaseInsensitiveContains(query) || name.localizedCaseInsensitiveContains(search.query)
                    || (search.stockConnect && InvestmentAsset.stockConnectCode(ticker) == search.exactAsset.code) else { return nil }
            let mic = entry.mic_code?.uppercased() ?? ""
            let code: String
            let market: String
            if search.kind == .crypto {
                guard ticker.hasSuffix("/USD") else { return nil }
                code = String(ticker.dropLast(4))
                market = ""
            } else if search.stockConnect {
                guard mic == "XHKG", let normalized = InvestmentAsset.stockConnectCode(ticker) else { return nil }
                code = normalized
                market = InvestmentAsset.stockConnectMarket
            } else {
                guard search.currency != .usd || (entry.country?.lowercased() == "united states" && !mic.isEmpty && mic != "US"),
                      search.currency != .cny || InvestmentAsset.mainlandMICs.values.contains(mic)
                        || (search.kind == .fund && mic.isEmpty && entry.country?.lowercased() == "china") else { return nil }
                code = ticker
                market = mic
            }
            if search.query.contains("."), symbol.twelveSymbol != nil {
                guard (ticker == query || (search.stockConnect && code == search.exactAsset.code)),
                      symbol.twelveMIC.isEmpty || mic == symbol.twelveMIC else { return nil }
            }
            let asset = InvestmentAsset(name: name, code: code, market: market, kind: search.kind, currency: search.currency)
            guard (try? asset.validateMarket(settlingIn: asset.settlementCurrency)) != nil else { return nil }
            // Keep the full security name and subtype: a matching ticker alone is
            // insufficient evidence for collapsing different venue records.
            let normalizedName = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            return (asset, [code, normalizedName, type, search.currency.rawValue, search.kind.rawValue])
        }
        guard consolidateUSListings, search.currency == .usd,
              search.kind == .stock || search.kind == .etf else { return matches.map(\.asset) }

        let primaryMarkets: Set<String> = ["XNAS", "XNMS", "XNGS", "XNCM", "XNYS", "ARCX", "XASE", "BATS"]
        let groups = Dictionary(grouping: matches, by: { $0.identity })
        var emitted: Set<[String]> = []
        return matches.compactMap { match in
            let group = groups[match.identity]!
            let primary = group.filter { primaryMarkets.contains($0.asset.market) }
            // Only replace an IEX trading-venue duplicate when there is exactly
            // one unambiguous primary venue. Unknown or conflicting venues stay visible.
            guard group.contains(where: { $0.asset.market == "IEXG" }),
                  group.allSatisfy({ $0.asset.market == "IEXG" || primaryMarkets.contains($0.asset.market) }),
                  Set(primary.map { $0.asset.market }).count == 1,
                  let preferred = primary.first else { return match.asset }
            guard emitted.insert(match.identity).inserted else { return nil }
            return preferred.asset
        }
    }

    func latestQuote(for asset: InvestmentAsset, keys: [InvestmentQuoteSource: String], now: Date = .now) async throws -> InvestmentQuote {
        let today = InvestmentBook.day(now)
        if asset.kind == .crypto {
            return try await publicSpotUSDQuote(for: asset)
        }
        if asset.usesEastmoneyMarketData {
            let values = try await eastmoneyHistory(asset: asset, start: InvestmentBook.addDays(-30, to: today),
                                                    through: asset.usesPublishedFundNAV ? min(today, asset.lastClosedMarketDay(at: now)) : today, latestOnly: true)
            guard let quote = markDailyCloses(values, asset: asset, now: now).last else {
                throw InvestmentError.invalid("未取得最新报价。")
            }
            return quote
        }
        guard asset.usesUSEquityClose, let symbol = InvestmentQuoteSymbol(asset).twelveSymbol else {
            throw InvestmentError.invalid("该标的不支持最新报价。")
        }
        struct Quote: Decodable {
            var symbol, currency, mic_code, datetime, close: String?
            var code: Int?
        }
        let key = try Self.usEquityKey(keys)
        var url = URLComponents(string: "https://api.twelvedata.com/quote")!
        url.queryItems = [.init(name: "symbol", value: symbol), .init(name: "country", value: "United States")]
        let market = InvestmentQuoteSymbol(asset).twelveMIC
        if market == "XNAS" { url.queryItems?.append(.init(name: "exchange", value: "NASDAQ")) }
        else if !market.isEmpty { url.queryItems?.append(.init(name: "mic_code", value: market)) }
        if asset.kind == .etf { url.queryItems?.append(.init(name: "type", value: "ETF")) }
        let (data, response) = try await send(Self.twelveRequest(url.url!, key: key), [key])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let result = try? JSONDecoder().decode(Quote.self, from: data)
        guard status == 200, result?.code == nil else { throw Self.failure(result?.code ?? status) }
        let matchesMarket = market == "XNAS"
            ? ["XNAS", "XNMS", "XNGS", "XNCM"].contains(result?.mic_code?.uppercased() ?? "")
            : market.isEmpty || result?.mic_code?.uppercased() == market
        guard result?.symbol?.uppercased() == symbol, result?.currency?.uppercased() == asset.currency.rawValue,
              matchesMarket, let text = result?.close, let price = Decimal(string: text), !price.isNaN, price > 0,
              let rawDay = result?.datetime, let day = Self.dateFormat("yyyy-MM-dd").date(from: String(rawDay.prefix(10))),
              day <= today, day >= InvestmentBook.addDays(-30, to: today) else {
            throw InvestmentError.invalid("最新报价的代码、市场、币种、日期或价格不匹配。")
        }
        return markDailyCloses([.init(day: day, price: price, source: "Twelve Data")], asset: asset, now: now)[0]
    }

    func watchQuotes(for asset: InvestmentAsset, keys: [InvestmentQuoteSource: String],
                     through today: Date = InvestmentBook.day()) async throws -> [InvestmentQuote] {
        guard InvestmentKind.watchKinds(in: asset.currency).contains(asset.kind) else {
            throw InvestmentError.invalid("该报价币种不支持关注此资产类型。")
        }
        try asset.validateMarket(settlingIn: asset.settlementCurrency)
        let lookback = asset.usesPublishedFundNAV ? 30 : 14
        do {
            let quotes = try await history(asset: asset, start: InvestmentBook.addDays(-lookback, to: today),
                                           through: today, cached: nil, keys: keys)
            if let latest = quotes.last, latest.day >= InvestmentBook.addDays(-lookback, to: today) { return quotes }
            throw InvestmentError.invalid("没有获取到近 \(lookback) 天的报价。")
        } catch {
            try Task.checkCancellation()
            guard asset.kind == .crypto else { throw error }
        }
        try Task.checkCancellation()
        return [try await publicSpotUSDQuote(for: asset)]
    }

    func history(asset: InvestmentAsset, start: Date, through today: Date, cached: Date?,
                 keys: [InvestmentQuoteSource: String], now: Date = .now) async throws -> [InvestmentQuote] {
        if asset.kind == .crypto {
            return try await cryptoPriceHistory(code: asset.code, from: start, through: today, now: now)
        }
        let symbol = InvestmentQuoteSymbol(asset)
        if asset.usesUSEquityClose {
            let key = try Self.usEquityKey(keys)
            guard let code = symbol.twelveSymbol else { throw InvestmentError.invalid("美股标的代码或交易所无效") }
            let quotes = try await twelve(symbol: code, market: symbol.twelveMIC, currency: asset.currency,
                                          kind: asset.kind, start: start, end: today, key: key)
            return markDailyCloses(quotes, asset: asset, now: now)
        }
        let cutoff = max(cached ?? start, InvestmentBook.addDays(-7, to: today))
        var best: [InvestmentQuote] = []
        var failures: [String] = []
        if asset.usesEastmoneyMarketData {
            do {
                let result = markDailyCloses(try await eastmoneyHistory(asset: asset, start: start,
                    through: asset.usesPublishedFundNAV ? min(today, asset.lastClosedMarketDay(at: now)) : today), asset: asset, now: now)
                // Published fund NAVs and closed historical windows can legitimately end before a weekend.
                if !asset.kind.derivative || result.last!.day >= cutoff { return result }
                best = result
            } catch {
                try Task.checkCancellation()
                if !asset.kind.derivative, let empty = error as? InvestmentError, case .noMarketData = empty { throw empty }
                failures.append(Self.eastmoneyTitle + "：" + error.localizedDescription)
            }
            // Optional credentials supplement missing or expired derivative contracts.
            if !asset.kind.derivative {
                if !best.isEmpty { return best }
                throw InvestmentError.invalid(failures.joined(separator: "；"))
            }
        }
        for source in Self.order(for: asset.currency) {
            guard let key = keys[source] else { continue }
            do {
                var result: [InvestmentQuote]
                switch source {
                case .tushare:
                    guard let api = symbol.tushareAPI, let code = symbol.tushareSymbol else { continue }
                    result = try await tushare(api: api, symbol: code, start: start, end: today, key: key)
                case .twelveData:
                    guard let code = symbol.twelveSymbol else { continue }
                    result = try await twelve(symbol: code, market: symbol.twelveMIC, currency: asset.currency,
                                              kind: asset.kind, start: start, end: today, key: key)
                }
                result = markDailyCloses(result, asset: asset, now: now)
                if let day = result.last?.day {
                    if day >= cutoff { return result }
                    if best.last.map({ $0.day < day }) ?? true { best = result }
                }
            } catch {
                try Task.checkCancellation()
                failures.append(source.title + "：" + error.localizedDescription)
            }
        }
        if !best.isEmpty { return best }
        throw InvestmentError.invalid(failures.isEmpty ? "没有适用的已配置行情源" : failures.joined(separator: "；"))
    }

    private static func usEquityKey(_ keys: [InvestmentQuoteSource: String]) throws -> String {
        guard let key = keys[.twelveData]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw InvestmentError.invalid("请在投资记账设置中配置 Twelve Data API Key，以查询美股和美股 ETF。")
        }
        return key
    }

    private func markDailyCloses(_ quotes: [InvestmentQuote], asset: InvestmentAsset, now: Date) -> [InvestmentQuote] {
        guard asset.kind != .crypto else { return quotes }
        return quotes.map { quote in
            var quote = quote
            quote.isDailyClose = asset.kind == .fund || asset.marketClose(on: quote.day) <= now
            return quote
        }
    }

    private struct TwelveResponse: Decodable {
        struct Meta: Decodable {
            var currency: String?
            var type: String?
            var symbol: String?
            var mic_code: String?
            var currency_quote: String?
        }
        struct Bar: Decodable { var datetime: String; var close: String? }
        var meta: Meta?
        var values: [Bar]?
        var code: Int?
        var message: String?
    }

    func twelve(symbol: String, market: String, currency: InvestmentCurrency?, kind: InvestmentKind? = nil,
                start: Date, end: Date, key: String) async throws -> [InvestmentQuote] {
        let format = Self.dateFormat("yyyy-MM-dd")
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.twelvedata.com"
        url.path = "/time_series"
        url.queryItems = [
            .init(name: "symbol", value: symbol), .init(name: "interval", value: "1day"),
            .init(name: "start_date", value: format.string(from: start)),
            .init(name: "end_date", value: format.string(from: end)),
            .init(name: "outputsize", value: "5000")
        ]
        if kind != .crypto { url.queryItems?.append(.init(name: "adjust", value: "none")) }
        if currency == .usd, kind == .stock || kind == .etf {
            url.queryItems?.append(.init(name: "country", value: "United States"))
        }
        // XNAS denotes Nasdaq's operating market, while Twelve Data lists some
        // equities under a segment MIC (XNMS/XNGS/XNCM). Use the documented exchange
        // filter for this scope; explicit segment MICs must still match exactly.
        let nasdaqOperatingMarket = currency == .usd && (kind == .stock || kind == .etf) && market.uppercased() == "XNAS"
        if nasdaqOperatingMarket {
            url.queryItems?.append(.init(name: "exchange", value: "NASDAQ"))
        } else if !market.isEmpty {
            url.queryItems?.append(.init(name: "mic_code", value: market))
        }
        if kind == .etf { url.queryItems?.append(.init(name: "type", value: "ETF")) }
        if kind == .fund { url.queryItems?.append(.init(name: "type", value: "Mutual Fund")) }
        guard let url = url.url else { throw InvestmentError.invalid("标的代码无效") }
        let request = try Self.twelveRequest(url, key: key)
        let (data, response) = try await send(request, [key])
        let payload = try? JSONDecoder().decode(TwelveResponse.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Twelve Data explicitly reports an empty date range as HTTP 400.
        // Other 400 responses, missing symbols and auth/quota failures remain errors.
        if [200, 400].contains(status), payload?.code == 400, payload?.meta?.symbol?.uppercased() == symbol.uppercased(),
           payload?.message?.hasPrefix("No data is available on the specified dates.") == true {
            throw InvestmentError.noMarketData("该区间没有已发布行情")
        }
        guard status == 200, let bars = payload?.values else { throw Self.failure(payload?.code ?? status) }
        if kind == .crypto {
            guard payload?.meta?.symbol?.uppercased() == symbol,
                  payload?.meta?.currency_quote.map({ ["USD", "US DOLLAR"].contains($0.uppercased()) }) ?? true else {
                throw InvestmentError.invalid("返回的加密货币交易对不匹配")
            }
        } else if let currency, payload?.meta?.currency?.uppercased() != currency.rawValue {
            throw InvestmentError.invalid("返回的报价币种不匹配")
        }
        if currency == .usd, kind == .stock || kind == .etf {
            let returnedMIC = payload?.meta?.mic_code?.uppercased() ?? ""
            let marketMatches = nasdaqOperatingMarket
                ? ["XNAS", "XNMS", "XNGS", "XNCM"].contains(returnedMIC)
                : market.isEmpty || returnedMIC == market.uppercased()
            guard payload?.meta?.symbol?.uppercased() == symbol.uppercased(),
                  marketMatches else {
                throw InvestmentError.invalid("Twelve Data 返回的美股代码或交易所不匹配")
            }
            if kind == .etf, payload?.meta?.type?.lowercased() != "etf" {
                throw InvestmentError.invalid("Twelve Data 返回的标的不是 ETF")
            }
        }
        if kind == .fund, payload?.meta?.type?.lowercased() != "mutual fund" {
            throw InvestmentError.invalid("没有核实到该基金的净值序列")
        }
        guard !bars.isEmpty else { throw InvestmentError.noMarketData("该区间没有已发布行情") }
        let ledgerDay = InvestmentBook.day()
        let quotes: [InvestmentQuote] = bars.compactMap { bar in
            guard let day = format.date(from: bar.datetime), let close = bar.close,
                  let price = Decimal(string: close, locale: format.locale), price > 0 else { return nil }
            return InvestmentQuote(day: day, price: price, source: InvestmentQuoteSource.twelveData.title,
                                   isDailyClose: currency == nil ? day < ledgerDay : nil)
        }
        return try Self.valid(quotes, start: start, end: end)
    }

    private struct TushareRequest: Encodable {
        var api_name: String
        var token: String
        var params: [String: String]
        var fields: String
    }

    private struct TushareResponse: Decodable {
        struct Table: Decodable {
            var fields: [String]
            var items: [[Cell?]]
        }
        enum Cell: Decodable {
            case text(String), number(Decimal)
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let text = try? value.decode(String.self) { self = .text(text) }
                else { self = .number(try value.decode(Decimal.self)) }
            }
            var string: String? { if case .text(let value) = self { return value }; return nil }
            var decimal: Decimal? {
                switch self {
                case .number(let value): value
                case .text(let value): Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
                }
            }
        }
        var code: Int
        var msg: String?
        var data: Table?
    }

    private func tushare(api: String, symbol: String, start: Date, end: Date, key: String) async throws -> [InvestmentQuote] {
        let format = Self.dateFormat("yyyyMMdd")
        let nav = api == "fund_nav"
        let dateField = nav ? "nav_date" : "trade_date"
        let priceField = nav ? "unit_nav" : "close"
        let fields = nav ? ["ts_code", dateField, priceField, "ann_date"] : ["ts_code", dateField, priceField]
        let params = ["ts_code": symbol, "start_date": format.string(from: start), "end_date": format.string(from: end)]
        let table = try await tushareTable(api: api, params: params, fields: fields, key: key)
        guard let codeIndex = table.fields.firstIndex(of: "ts_code"),
              let dateIndex = table.fields.firstIndex(of: dateField),
              let priceIndex = table.fields.firstIndex(of: priceField) else {
            throw InvestmentError.invalid("行情响应缺少必要字段")
        }
        let announcement = table.fields.firstIndex(of: "ann_date")
        var rows: [Date: (quote: InvestmentQuote, announcement: String)] = [:]
        for row in table.items {
            guard row.count > max(codeIndex, dateIndex, priceIndex),
                  row[codeIndex]?.string?.uppercased() == symbol,
                  let date = row[dateIndex]?.string, let day = format.date(from: date),
                  let price = row[priceIndex]?.decimal, price > 0 else { continue }
            let published = announcement.flatMap { $0 < row.count ? row[$0]?.string : nil } ?? ""
            if let previous = rows[day], previous.announcement >= published { continue }
            rows[day] = (InvestmentQuote(day: day, price: price, source: InvestmentQuoteSource.tushare.title), published)
        }
        return try Self.valid(rows.values.map(\.quote), start: start, end: end)
    }

    private func tushareTable(api: String, params: [String: String], fields: [String], key: String) async throws -> TushareResponse.Table {
        let body = TushareRequest(api_name: api, token: key, params: params, fields: fields.joined(separator: ","))
        var request = URLRequest(url: URL(string: "https://api.tushare.pro/")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request, [key])
        let payload = try? JSONDecoder().decode(TushareResponse.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let payload, payload.code != 0 {
            let message = payload.msg?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = message.flatMap { $0.isEmpty ? nil : $0 } ?? Self.failure(payload.code).localizedDescription
            throw InvestmentError.invalid("Tushare Pro · \(api)（\(payload.code)）\n"
                + HakoLog.sanitize(reason, secrets: [key]))
        }
        guard status == 200, let payload, payload.code == 0, let table = payload.data else {
            throw Self.failure(payload?.code ?? status)
        }
        return table
    }

    func ecbRates(for currencies: Set<InvestmentCurrency>, start: Date, end: Date) async throws -> [InvestmentCurrency: [InvestmentQuote]] {
        guard !currencies.isEmpty else { return [:] }
        let format = Self.dateFormat("yyyy-MM-dd")
        let codes = currencies.union([.cny]).map(\.rawValue).sorted().joined(separator: "+")
        var url = URLComponents()
        url.scheme = "https"
        url.host = "data-api.ecb.europa.eu"
        url.path = "/service/data/EXR/D." + codes + ".EUR.SP00.A"
        url.queryItems = [.init(name: "startPeriod", value: format.string(from: start)),
                          .init(name: "endPeriod", value: format.string(from: end)),
                          .init(name: "format", value: "csvdata"), .init(name: "detail", value: "dataonly")]
        guard let url = url.url else { throw InvestmentError.invalid("汇率请求无效") }
        let (data, response) = try await send(URLRequest(url: url, timeoutInterval: 15), [])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let text = String(data: data, encoding: .utf8) else { throw Self.failure(status) }
        let rows = try CSV.parse(text)
        guard let header = rows.first, let code = header.firstIndex(of: "CURRENCY"),
              let time = header.firstIndex(of: "TIME_PERIOD"), let value = header.firstIndex(of: "OBS_VALUE") else {
            throw InvestmentError.invalid("欧洲央行汇率响应缺少必要字段")
        }
        var rates: [InvestmentCurrency: [Date: Decimal]] = [:]
        for row in rows.dropFirst() where row.count > max(code, time, value) {
            guard let currency = InvestmentCurrency(rawValue: row[code]), let day = format.date(from: row[time]),
                  let rate = Decimal(string: row[value], locale: format.locale), rate > 0 else { continue }
            rates[currency, default: [:]][day] = rate
        }
        var converted: [InvestmentCurrency: [InvestmentQuote]] = [:]
        for currency in currencies {
            let result = rates[currency, default: [:]].compactMap { day, rate in
                rates[.cny]?[day].map { InvestmentQuote(day: day, price: $0 / rate, source: "欧洲央行", isDailyClose: true) }
            }
            converted[currency] = try? Self.valid(result, start: start, end: end)
        }
        return converted
    }

    private static func dateFormat(_ pattern: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = InvestmentBook.calendar
        format.timeZone = InvestmentBook.calendar.timeZone
        format.dateFormat = pattern
        return format
    }

    private static func valid(_ quotes: [InvestmentQuote], start: Date, end: Date) throws -> [InvestmentQuote] {
        let rows = InvestmentBook.merge([], quotes.filter { $0.day >= start && $0.day <= end })
        guard !rows.isEmpty else { throw InvestmentError.invalid("没有可用行情") }
        return rows
    }

    private static func failure(_ code: Int) -> InvestmentError {
        switch code {
        case 429: .invalid("达到行情配额")
        case 401, 40102, 40103: .invalid("行情凭据无效（\(code)）")
        case 403, 2002: .invalid("没有该行情权限（\(code)）")
        default: .invalid("行情接口错误（\(code)）")
        }
    }
}
