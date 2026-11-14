import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct InvestmentContractListing: Identifiable {
    let asset: InvestmentAsset
    let settlementCode: String
    var id: UUID { asset.id }

    func validateSelection(_ selected: InvestmentAsset, settlement: String) throws {
        try selected.validateCatalogIdentity(asset)
        guard selected.kind == .cryptoContract, selected.code == asset.code, selected.market == asset.market,
              selected.currency == asset.currency, selected.basis == asset.basis else {
            throw InvestmentError.invalid("合约代码、交易所或本位与交易所目录不一致，请重新搜索并选择真实合约。")
        }
        guard selected.multiplier == asset.multiplier else {
            throw InvestmentError.invalid("交易所合约乘数 / 面值为 \(NSDecimalNumber(decimal: asset.multiplier).stringValue)，与当前标的不一致。请先核对数量口径，不能仅修改行情关联。")
        }
        guard settlement == settlementCode else {
            throw InvestmentError.invalid("该交易所合约使用 \(settlementCode) 结算，请核对结算币种。")
        }
    }
}

enum InvestmentEntryQuoteRequest: Equatable {
    case settlement(code: String, day: Date)

    func fetch(using provider: InvestmentQuoteProvider = .init()) async throws -> InvestmentQuote {
        switch self {
        case .settlement(let code, let day):
            return try await provider.coinbaseSpotUSDQuote(code: code, on: day)
        }
    }
}

struct InvestmentEntryQuoteState {
    var request: InvestmentEntryQuoteRequest?
    var quote: InvestmentQuote?
    var failure: String?
    var loading = false

    func quote(for request: InvestmentEntryQuoteRequest?) -> InvestmentQuote? {
        guard let request, self.request == request, !loading else { return nil }
        return quote
    }
}

extension InvestmentQuoteProvider {
    private struct BinanceCatalog: Decodable {
        struct Contract: Decodable {
            let symbol: String
            let baseAsset: String
            let quoteAsset: String
            let marginAsset: String
            let contractType: String
            let status: String?
            let contractStatus: String?
            let contractSize: Decimal?
        }
        let symbols: [Contract]
    }

    private struct HTXCatalog: Decodable {
        struct Contract: Decodable {
            let symbol: String
            let contract_code: String
            let contract_size: Decimal
            let contract_status: Int
            let delivery_date: String?
            let trade_partition: String?
        }
        let status: String
        let data: [Contract]?
    }

    func contractCatalog(_ exchange: InvestmentContractExchange, basis: InvestmentContractBasis) async throws -> [InvestmentContractListing] {
        guard basis != .usd else { return [] }
        switch exchange {
        case .binance:
            let (host, path) = binanceEndpoint(basis)
            let data = try await publicMarketData(host: host, path: path + "/exchangeInfo")
            let response = try JSONDecoder().decode(BinanceCatalog.self, from: data)
            return response.symbols.compactMap { row in
                guard (row.contractStatus ?? row.status) == "TRADING", row.contractType == "PERPETUAL" else { return nil }
                let size: Decimal
                if basis == .coin {
                    guard row.quoteAsset == "USD", row.baseAsset == row.marginAsset,
                          let faceValue = row.contractSize, faceValue > 0 else { return nil }
                    size = faceValue
                } else {
                    guard row.quoteAsset == row.marginAsset, ["USDT", "USDC"].contains(row.marginAsset) else { return nil }
                    size = 1
                }
                return contractListing(code: row.symbol, pair: row.baseAsset + "/" + row.quoteAsset,
                                       exchange: exchange, basis: basis, size: size, settlement: row.marginAsset)
            }
        case .htx:
            if basis == .stablecoin {
                return try await htxCatalog(path: "/linear-swap-api/v1/swap_contract_info",
                                            query: [.init(name: "business_type", value: "swap")], basis: basis)
            }
            return try await htxCatalog(path: "/swap-api/v1/swap_contract_info", basis: basis)
        }
    }

    private func htxCatalog(path: String, query: [URLQueryItem] = [], basis: InvestmentContractBasis) async throws -> [InvestmentContractListing] {
        let data = try await publicMarketData(host: "api.hbdm.com", path: path, query: query)
        let response = try JSONDecoder().decode(HTXCatalog.self, from: data)
        guard response.status == "ok", let contracts = response.data else { throw InvestmentError.invalid("HTX 合约目录暂不可用") }
        return contracts.compactMap { row in
            guard row.contract_status == 1, row.contract_size > 0, (row.delivery_date ?? "").isEmpty else { return nil }
            let quote: String
            if basis == .coin {
                quote = "USD"
            } else {
                guard let currency = row.trade_partition, ["USDT", "USDC"].contains(currency) else { return nil }
                quote = currency
            }
            return contractListing(code: row.contract_code, pair: row.symbol + "/" + quote, exchange: .htx, basis: basis,
                                   size: row.contract_size, settlement: basis == .coin ? row.symbol : quote)
        }
    }

    private func contractListing(code: String, pair: String, exchange: InvestmentContractExchange, basis: InvestmentContractBasis,
                                 size: Decimal, settlement: String) -> InvestmentContractListing {
        let asset = InvestmentAsset(name: pair + " 永续", code: code, market: exchange.rawValue,
                                    kind: .cryptoContract, currency: .usd, multiplier: size, contractBasis: basis)
        return InvestmentContractListing(asset: asset, settlementCode: settlement)
    }

    private struct BinanceMark: Decodable {
        let symbol: String
        let markPrice: String
        let time: Int64
    }

    private struct HTXMark: Decodable {
        struct Bar: Decodable {
            let id: Int64
            let close: String
        }
        let status: String
        let ch: String?
        let data: [Bar]?
    }

    func contractMark(_ asset: InvestmentAsset, now: Date = .now) async throws -> InvestmentQuote {
        guard let exchange = InvestmentContractExchange(asset: asset) else {
            throw InvestmentError.invalid("没有适用的合约报价交易所")
        }
        let sample: (price: String, time: Date)
        switch exchange {
        case .binance:
            let (host, path) = binanceEndpoint(asset.basis)
            let data = try await publicMarketData(host: host, path: path + "/premiumIndex",
                                                  query: [.init(name: "symbol", value: asset.code)])
            let marks = asset.basis == .coin ? try JSONDecoder().decode([BinanceMark].self, from: data)
                : [try JSONDecoder().decode(BinanceMark.self, from: data)]
            guard let mark = marks.first(where: { $0.symbol == asset.code }) else {
                throw InvestmentError.invalid("合约报价代码不匹配")
            }
            sample = (mark.markPrice, Date(timeIntervalSince1970: Double(mark.time) / 1_000))
        case .htx:
            guard let bar = try await htxMarks(asset, period: "1min", size: 1).first else {
                throw InvestmentError.invalid("没有匹配的 HTX 合约标记价格")
            }
            sample = (bar.close, Date(timeIntervalSince1970: Double(bar.id)))
        }
        guard let price = Decimal(string: sample.price, locale: Locale(identifier: "en_US_POSIX")), price > 0,
              (-120...300).contains(now.timeIntervalSince(sample.time)) else {
            throw InvestmentError.invalid("合约标记价格无效或已过期")
        }
        return InvestmentQuote(day: InvestmentBook.day(sample.time), price: price, source: exchange.title + " 标记价格")
    }

    private func htxMarks(_ asset: InvestmentAsset, period: String, size: Int) async throws -> [HTXMark.Bar] {
        let path = asset.basis == .stablecoin ? "linear_swap_mark_price_kline" : "swap_mark_price_kline"
        let data = try await publicMarketData(host: "api.hbdm.com", path: "/index/market/history/" + path, query: [
            .init(name: "contract_code", value: asset.code), .init(name: "period", value: period), .init(name: "size", value: String(size))
        ])
        let mark = try JSONDecoder().decode(HTXMark.self, from: data)
        guard mark.status == "ok", mark.ch?.uppercased() == "MARKET." + asset.code + ".MARK_PRICE." + period.uppercased(),
              let bars = mark.data else { throw InvestmentError.invalid("没有匹配的 HTX 合约标记价格") }
        return bars
    }

    func contractDailyQuotes(for asset: InvestmentAsset, from start: Date, through end: Date) async throws -> [InvestmentQuote] {
        switch InvestmentContractExchange(asset: asset) {
        case .binance:
            let (host, path) = binanceEndpoint(asset.basis)
            // The 08:00 UTC bar closes at midnight in the ledger's UTC+8 calendar.
            return try await binanceDailyCloses(host: host, path: path + "/markPriceKlines", symbol: asset.code,
                                               interval: "8h", from: start, through: end, source: "Binance 标记价格日线")
        case .htx:
            let span = InvestmentBook.calendar.dateComponents([.day], from: start, to: InvestmentBook.day()).day ?? 0
            let bars = try await htxMarks(asset, period: "1day", size: max(1, min(span + 1, 2_000)))
            return bars.compactMap { bar in
                let date = Date(timeIntervalSince1970: Double(bar.id))
                guard InvestmentBook.day(date) == date else { return nil }
                return Self.closingQuote(bar.close, at: InvestmentBook.addDays(1, to: date), within: start...end,
                                         source: "HTX 标记价格日线")
            }.sorted { $0.day < $1.day }
        case nil:
            return []
        }
    }

    func binanceSpotDailyQuotes(for code: String, from start: Date, through end: Date,
                                usdtUSD: [Date: Decimal]) async throws -> [InvestmentQuote] {
        if code == "USDT" {
            return usdtUSD.filter { (start...end).contains($0.key) }.map {
                InvestmentQuote(day: $0.key, price: $0.value, source: "Coinbase 美元日价", isDailyClose: true)
            }.sorted { $0.day < $1.day }
        }
        guard !usdtUSD.isEmpty else { return [] }
        let bars = try await binanceDailyCloses(host: "data-api.binance.vision", path: "/api/v3/klines", symbol: code + "USDT",
                                               interval: "1d", from: start, through: end, source: "Binance 美元日价")
        return bars.compactMap { bar in
            guard let rate = usdtUSD[bar.day] else { return nil }
            var quote = bar
            quote.price *= rate
            return quote
        }
    }

    private struct BinanceCandle: Decodable {
        let close: String
        let closeTime: Int64

        init(from decoder: Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            _ = try fields.decode(Int64.self)
            for _ in 0..<3 { _ = try fields.decode(String.self) }
            close = try fields.decode(String.self)
            _ = try fields.decode(String.self)
            closeTime = try fields.decode(Int64.self)
        }
    }

    private func binanceDailyCloses(host: String, path: String, symbol: String, interval: String,
                                    from start: Date, through end: Date, source: String) async throws -> [InvestmentQuote] {
        var quotes: [InvestmentQuote] = []
        var cursor = start
        while cursor <= end {
            let boundary = InvestmentBook.addDays(1, to: min(end, InvestmentBook.addDays(179, to: cursor)))
            var query: [URLQueryItem] = [
                .init(name: "symbol", value: symbol), .init(name: "interval", value: interval), .init(name: "limit", value: "600"),
                .init(name: "startTime", value: String(Int64(cursor.timeIntervalSince1970 * 1_000))),
                .init(name: "endTime", value: String(Int64(boundary.timeIntervalSince1970 * 1_000) - 1))
            ]
            if interval == "1d" { query.append(.init(name: "timeZone", value: "8")) }
            let data = try await publicMarketData(host: host, path: path, query: query)
            let bars = try JSONDecoder().decode([BinanceCandle].self, from: data)
            quotes += bars.compactMap {
                let close = Date(timeIntervalSince1970: (Double($0.closeTime) + 1) / 1_000)
                return Self.closingQuote($0.close, at: close, within: cursor...InvestmentBook.addDays(-1, to: boundary), source: source)
            }
            cursor = boundary
        }
        return quotes
    }

    private struct CoinbaseCandles: Decodable {
        struct Candle: Decodable {
            let start: String
            let close: String
        }
        let candles: [Candle]
    }

    func coinbaseUSDDailyQuotes(for code: String, from start: Date, through end: Date) async throws -> [InvestmentQuote] {
        var quotes: [InvestmentQuote] = []
        var cursor = start
        while cursor <= end {
            let boundary = InvestmentBook.addDays(1, to: min(end, InvestmentBook.addDays(49, to: cursor)))
            let data = try await publicMarketData(host: "api.coinbase.com", path: "/api/v3/brokerage/market/products/" + code + "-USD/candles", query: [
                .init(name: "granularity", value: "FOUR_HOUR"), .init(name: "limit", value: "350"),
                .init(name: "start", value: String(Int64(cursor.timeIntervalSince1970))),
                .init(name: "end", value: String(Int64(boundary.timeIntervalSince1970) - 1))
            ])
            let bars = try JSONDecoder().decode(CoinbaseCandles.self, from: data).candles
            quotes += bars.compactMap {
                guard let start = Int64($0.start) else { return nil }
                let close = Date(timeIntervalSince1970: Double(start) + 4 * 3_600)
                return Self.closingQuote($0.close, at: close, within: cursor...InvestmentBook.addDays(-1, to: boundary), source: "Coinbase 美元日价")
            }
            cursor = boundary
        }
        return quotes.sorted { $0.day < $1.day }
    }

    private static func closingQuote(_ value: String, at boundary: Date, within days: ClosedRange<Date>,
                                     source: String) -> InvestmentQuote? {
        guard boundary == InvestmentBook.day(boundary),
              let price = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), price > 0 else { return nil }
        let day = InvestmentBook.addDays(-1, to: boundary)
        guard days.contains(day) else { return nil }
        return InvestmentQuote(day: day, price: price, source: source, isDailyClose: true)
    }

    private struct CoinbaseSpot: Decodable {
        struct Price: Decodable {
            let amount: String
            let base: String
            let currency: String
        }
        let data: Price
    }

    func coinbaseSpotUSDQuote(code: String, on date: Date = InvestmentBook.day()) async throws -> InvestmentQuote {
        let day = InvestmentBook.day(date)
        guard day <= InvestmentBook.day() else { throw InvestmentError.invalid("不能查询未来的美元报价。") }
        let historical = day < InvestmentBook.day()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = InvestmentBook.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let query: [URLQueryItem] = historical
            ? [.init(name: "date", value: formatter.string(from: day))] : []
        let data = try await publicMarketData(host: "api.coinbase.com", path: "/v2/prices/" + code + "-USD/spot", query: query)
        let price = try JSONDecoder().decode(CoinbaseSpot.self, from: data).data
        guard price.base == code, price.currency == "USD",
              let amount = Decimal(string: price.amount, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
            throw InvestmentError.invalid("没有有效的现货美元报价")
        }
        return InvestmentQuote(day: day, price: amount, source: historical ? "Coinbase 历史现货（UTC 日价）" : "Coinbase 现货")
    }

    private func binanceEndpoint(_ basis: InvestmentContractBasis) -> (String, String) {
        basis == .coin ? ("dapi.binance.com", "/dapi/v1") : ("fapi.binance.com", "/fapi/v1")
    }

    private func publicMarketData(host: String, path: String, query: [URLQueryItem] = []) async throws -> Data {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = path
        if !query.isEmpty { url.queryItems = query }
        guard let endpoint = url.url else { throw URLError(.badURL) }
        let (data, response) = try await send(URLRequest(url: endpoint, timeoutInterval: 10), [])
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw InvestmentError.invalid(host + " 行情接口暂不可用")
        }
        return data
    }
}
