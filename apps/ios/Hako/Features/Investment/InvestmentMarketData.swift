import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentAsset {
    var catalogKey: String { [kind.rawValue, currency.rawValue, market, code, basis.rawValue].joined(separator: "|") }

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
        var used = Set(watched).subtracting(previous.watched)
        let oldEvents = Dictionary(previous.accounts.flatMap(\.events).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in accounts.flatMap(\.events) where oldEvents[event.id]?.assetID != event.assetID {
            if let id = event.assetID { used.insert(id) }
        }
        for plan in plans where plan.enabled {
            let old = previous.plans.first { $0.id == plan.id }
            if let id = plan.assetID, old?.assetID != id || old?.enabled != true { used.insert(id) }
        }
        return assets.values.filter { asset in
            guard asset.kind.requiresCatalog else { return false }
            guard let original = previous.asset(asset.id) else { return true }
            return used.contains(asset.id) || original.catalogKey != asset.catalogKey
                || original.name != asset.name || original.multiplier != asset.multiplier
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct InvestmentContractSearch {
    let query: String
    let exchange: InvestmentContractExchange?
    let side: InvestmentContractSide?

    init(_ input: String) throws {
        let parts = input.uppercased().split(separator: "•", omittingEmptySubsequences: false)
        guard parts.count <= 3, let first = parts.first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvestmentError.invalid("请输入合约代码，例如 TRXUSD•S•HTX（空）或 TRXUSD•L•HTX（多）。")
        }
        query = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if parts.count == 3 {
            let marker = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let direction = InvestmentContractSide.allCases.first(where: { $0.shortCode == marker }) else {
                throw InvestmentError.invalid("合约方向使用 S（空）或 L（多）。")
            }
            side = direction
        } else { side = nil }
        if parts.count > 1 {
            let suffix = parts.last!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let venue = InvestmentContractExchange.allCases.first(where: { $0.shortCode == suffix }) else {
                throw InvestmentError.invalid("合约交易所仅支持 HTX 和 BIN（Binance）。")
            }
            exchange = venue
        } else { exchange = nil }
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
        self.send = send
    }

    static func order(for currency: InvestmentCurrency) -> [InvestmentQuoteSource] {
        currency == .cny ? [.tushare, .twelveData] : [.twelveData, .tushare]
    }

    private struct TwelveCredentialResponse: Decodable {
        let code: Int?
        let current_usage: Int?
        let plan_limit: Int?
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
            var request = URLRequest(url: URL(string: "https://api.twelvedata.com/api_usage")!, timeoutInterval: 15)
            request.setValue("apikey " + key, forHTTPHeaderField: "Authorization")
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
            let asset = InvestmentAsset(name: names[code] ?? code, code: code, market: InvestmentContractExchange.binance.rawValue, kind: .crypto, currency: .usd)
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

    func publicSpotUSDQuote(for asset: InvestmentAsset, usdtUSD: InvestmentQuote?) async throws -> InvestmentQuote {
        guard asset.kind == .crypto else { throw InvestmentError.invalid("无效的现货币种") }
        try asset.validateMarket(settlingIn: .usd)
        if let usdtUSD, usdtUSD.price > 0, usdtUSD.day == InvestmentBook.day() {
            if asset.code == "USDT" { return usdtUSD }
            do {
                return try await binanceSpotUSDQuote(code: asset.code, usdtUSD: usdtUSD.price)
            } catch {
                try Task.checkCancellation()
            }
        }
        return try await coinbaseSpotUSDQuote(code: asset.code)
    }

    private func binanceSpotUSDQuote(code: String, usdtUSD: Decimal) async throws -> InvestmentQuote {
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
        return InvestmentQuote(day: InvestmentBook.day(), price: price * usdtUSD, source: "Binance 现货")
    }

    func searchInstruments(_ search: InvestmentInstrumentSearch, keys: [InvestmentQuoteSource: String]) async throws -> [InvestmentAsset] {
        guard !search.query.isEmpty, !search.kind.isManual else { return [] }
        let asset = search.exactAsset
        let symbol = InvestmentQuoteSymbol(asset)
        var lastError: Error?
        if search.currency == .cny, search.kind == .stock, !search.stockConnect {
            do {
                let results = try await mainlandStocks(search, symbol: symbol)
                try Task.checkCancellation()
                if !results.isEmpty { return results }
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        for source in Self.order(for: asset.currency) {
            try Task.checkCancellation()
            guard let key = keys[source] else { continue }
            do {
                let results: [InvestmentAsset]
                switch source {
                case .tushare:
                    results = try await tushareInstruments(search, symbol: symbol, key: key)
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

    private struct MainlandStockSearch: Decodable {
        struct Table: Decodable {
            struct Entry: Decodable {
                let Code: String
                let Name: String
                let Classify: String
                let MktNum: String
            }
            let Data: [Entry]?
            let Status: Int
        }
        let QuotationCodeTable: Table
    }

    private func mainlandStocks(_ search: InvestmentInstrumentSearch, symbol: InvestmentQuoteSymbol) async throws -> [InvestmentAsset] {
        var url = URLComponents(string: "https://searchapi.eastmoney.com/api/suggest/get")!
        url.queryItems = [.init(name: "input", value: symbol.twelveSymbol ?? search.query),
                          .init(name: "type", value: "14"), .init(name: "count", value: "100")]
        guard let endpoint = url.url else { throw URLError(.badURL) }
        let (data, response) = try await send(URLRequest(url: endpoint, timeoutInterval: 10), [])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status) }
        let table = try JSONDecoder().decode(MainlandStockSearch.self, from: data).QuotationCodeTable
        guard table.Status == 0 else { throw InvestmentError.invalid("A 股搜索暂不可用") }
        var seen = Set<String>()
        return (table.Data ?? []).compactMap { entry in
            guard entry.Classify == "AStock", !entry.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let asset = InvestmentAsset(name: entry.Name, code: entry.Code, market: "", kind: .stock, currency: .cny)
            guard let mainland = asset.mainlandSymbol,
                  ["SH": "1", "SZ": "0", "BJ": "0"][mainland.venue] == entry.MktNum else { return nil }
            let code = mainland.base + "." + mainland.venue
            guard symbol.tushareSymbol == nil || symbol.tushareSymbol == code else { return nil }
            let result = InvestmentAsset(name: entry.Name, code: code, market: "", kind: .stock, currency: .cny)
            guard search.includes(result), seen.insert(code).inserted else { return nil }
            return result
        }
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

    private func twelveInstruments(_ search: InvestmentInstrumentSearch, symbol: InvestmentQuoteSymbol, key: String) async throws -> [InvestmentAsset] {
        let acceptedTypes: Set<String>
        switch search.kind {
        case .stock:
            acceptedTypes = ["common stock", "preferred stock", "american depositary receipt",
                             "depositary receipt", "global depositary receipt", "reit", "limited partnership"]
        case .etf: acceptedTypes = ["etf"]
        case .fund: acceptedTypes = ["mutual fund"]
        case .crypto: acceptedTypes = ["digital currency", "cryptocurrency"]
        case .future, .option, .insurance, .wealth, .deposit, .certificate, .cryptoContract: return []
        }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.twelvedata.com"
        url.path = "/symbol_search"
        let query = search.kind == .crypto ? search.query : symbol.twelveSymbol ?? search.query
        url.queryItems = [.init(name: "symbol", value: query), .init(name: "outputsize", value: "120")]
        guard let url = url.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("apikey " + key, forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request, [key])
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let result = try? JSONDecoder().decode(TwelveInstrumentSearch.self, from: data)
        guard status == 200, let instruments = result?.data else { throw Self.failure(result?.code ?? status) }

        return instruments.compactMap { entry in
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
            return asset
        }
    }

    private func tushareInstruments(_ search: InvestmentInstrumentSearch, symbol: InvestmentQuoteSymbol, key: String) async throws -> [InvestmentAsset] {
        let code = symbol.tushareSymbol
        let api: String
        let nameFields: [String]
        var params = code.map { ["ts_code": $0] } ?? [:]
        switch symbol.tushareAPI {
        case "daily": (api, nameFields) = ("stock_basic", ["name"])
        case "fund_nav":
            (api, nameFields) = ("fund_basic", ["name"])
            params["market"] = code?.hasSuffix(".OF") == true ? "O" : "E"
        case "fund_daily": (api, nameFields) = ("etf_basic", ["extname", "csname", "cname"])
        case "hk_daily": (api, nameFields) = ("hk_basic", ["name"])
        case "us_daily", "us_etf_daily":
            api = search.kind == .etf ? "us_etf_basic" : "us_basic"
            nameFields = ["name", "enname"]
        case "opt_daily": (api, nameFields) = ("opt_basic", ["name"])
        case "fut_daily":
            (api, nameFields) = ("fut_basic", ["name"])
            guard let code else { return [] }
            let parts = code.split(separator: ".")
            let exchanges = ["SHF": "SHFE", "DCE": "DCE", "ZCE": "CZCE", "CFX": "CFFEX", "INE": "INE", "GFE": "GFEX"]
            guard parts.count == 2, let exchange = exchanges[String(parts[1])] else { return [] }
            params = ["exchange": exchange]
            let product = parts[0].prefix { $0.isLetter }
            if !product.isEmpty { params["fut_code"] = String(product) }
        default:
            guard search.currency == .cny, search.kind == .stock, search.query.unicodeScalars.contains(where: { $0.value > 127 }) else { return [] }
            (api, nameFields) = ("stock_basic", ["name"])
            params = ["name": search.query]
        }
        let currencyField = api == "hk_basic" ? ["curr_type"] : []
        let exchangeFields = api == "us_basic" ? ["exchange", "list_status"] : api == "us_etf_basic" ? ["exchange"] : []
        if api == "us_etf_basic" { params["list_status"] = "L" }
        let table = try await tushareTable(api: api, params: params, fields: ["ts_code"] + nameFields + currencyField + exchangeFields, key: key)
        guard let codeIndex = table.fields.firstIndex(of: "ts_code") else { return [] }
        let nameIndices = nameFields.compactMap { table.fields.firstIndex(of: $0) }
        let currencyIndex = table.fields.firstIndex(of: "curr_type")
        let exchangeIndex = table.fields.firstIndex(of: "exchange")
        let statusIndex = table.fields.firstIndex(of: "list_status")
        return table.items.compactMap { row in
            guard row.count > codeIndex, let ticker = row[codeIndex]?.string?.uppercased(),
                  code == nil || ticker == code else { return nil }
            if api == "hk_basic" {
                guard let currencyIndex, row.count > currencyIndex,
                      row[currencyIndex]?.string?.uppercased() == search.currency.rawValue else { return nil }
            }
            let name = nameIndices.lazy.compactMap { index -> String? in
                guard index < row.count, let name = row[index]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                return name
            }.first
            guard let name, code != nil || name.localizedCaseInsensitiveContains(search.query) else { return nil }
            var market = search.stockConnect ? InvestmentAsset.stockConnectMarket : ""
            if !exchangeFields.isEmpty {
                let venues = ["NASDAQ": "XNAS", "NYSE": "XNYS", "AMEX": "XASE", "NYSEARCA": "ARCX", "BZX": "BATS", "OTC": "XOTC"]
                guard let exchangeIndex, row.count > exchangeIndex, let exchange = row[exchangeIndex]?.string?.uppercased(),
                      let venue = venues[exchange] else { return nil }
                if api == "us_basic" {
                    guard let statusIndex, row.count > statusIndex, row[statusIndex]?.string == "L" else { return nil }
                }
                market = venue
            }
            let asset = InvestmentAsset(name: name, code: ticker, market: market,
                                        kind: search.kind, currency: search.currency)
            guard (try? asset.validateMarket(settlingIn: asset.settlementCurrency)) != nil else { return nil }
            return asset
        }
    }

    func watchQuotes(for asset: InvestmentAsset, keys: [InvestmentQuoteSource: String],
                     through today: Date = InvestmentBook.day()) async throws -> [InvestmentQuote] {
        guard InvestmentKind.watchKinds(in: asset.currency).contains(asset.kind) else {
            throw InvestmentError.invalid("该报价币种不支持关注此资产类型。")
        }
        try asset.validateMarket(settlingIn: asset.settlementCurrency)
        do {
            let quotes = try await history(asset: asset, start: InvestmentBook.addDays(-375, to: today),
                                           through: today, cached: nil, keys: keys)
            if let latest = quotes.last, latest.day >= InvestmentBook.addDays(-14, to: today) { return quotes }
            throw InvestmentError.invalid("没有获取到近 14 天的报价。")
        } catch {
            try Task.checkCancellation()
            guard asset.kind == .crypto else { throw error }
        }
        let usdtUSD = try? await coinbaseSpotUSDQuote(code: "USDT")
        try Task.checkCancellation()
        return [try await publicSpotUSDQuote(for: asset, usdtUSD: usdtUSD)]
    }

    func history(asset: InvestmentAsset, start: Date, through today: Date, cached: Date?,
                 keys: [InvestmentQuoteSource: String], now: Date = .now) async throws -> [InvestmentQuote] {
        let symbol = InvestmentQuoteSymbol(asset)
        let cutoff = max(cached ?? start, InvestmentBook.addDays(-7, to: today))
        var best: [InvestmentQuote] = []
        var failures: [String] = []
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
                if asset.kind != .crypto {
                    let usEquity = asset.usesUSEquityClose
                    let ledgerDay = InvestmentBook.day(now)
                    for index in result.indices {
                        let day = result[index].day
                        result[index].isDailyClose = usEquity
                            ? InvestmentBook.usEquityClose(on: day) <= now
                            : day < ledgerDay || asset.kind == .fund
                    }
                }
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

    private struct TwelveResponse: Decodable {
        struct Meta: Decodable {
            var currency: String?
            var type: String?
            var symbol: String?
            var currency_quote: String?
        }
        struct Bar: Decodable { var datetime: String; var close: String? }
        var meta: Meta?
        var values: [Bar]?
        var code: Int?
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
        if !market.isEmpty { url.queryItems?.append(.init(name: "mic_code", value: market)) }
        if kind == .etf { url.queryItems?.append(.init(name: "type", value: "ETF")) }
        if kind == .fund { url.queryItems?.append(.init(name: "type", value: "Mutual Fund")) }
        guard let url = url.url else { throw InvestmentError.invalid("标的代码无效") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("apikey " + key, forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request, [key])
        let payload = try? JSONDecoder().decode(TwelveResponse.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let bars = payload?.values else { throw Self.failure(payload?.code ?? status) }
        if kind == .crypto {
            guard payload?.meta?.symbol?.uppercased() == symbol,
                  payload?.meta?.currency_quote.map({ ["USD", "US DOLLAR"].contains($0.uppercased()) }) ?? true else {
                throw InvestmentError.invalid("返回的加密货币交易对不匹配")
            }
        } else if let currency, payload?.meta?.currency?.uppercased() != currency.rawValue {
            throw InvestmentError.invalid("返回的报价币种不匹配")
        }
        if kind == .fund, payload?.meta?.type?.lowercased() != "mutual fund" {
            throw InvestmentError.invalid("没有核实到该基金的净值序列")
        }
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
                rates[.cny]?[day].map { InvestmentQuote(day: day, price: $0 / rate, source: "欧洲央行") }
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
