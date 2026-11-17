import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentQuoteProvider {
    // The chart uses the same USD and Beijing-day closes as crypto valuations.
    func cryptoPriceHistory(code: String, from start: Date, through end: Date,
                            now: Date = .now) async throws -> [InvestmentQuote] {
        let last = min(InvestmentBook.day(end), InvestmentBook.addDays(-1, to: InvestmentBook.day(now)))
        let first = InvestmentBook.day(start)
        guard first <= last else { return [] }
        do {
            let rates = try await coinbaseUSDDailyQuotes(for: "USDT", from: first, through: last)
            try Task.checkCancellation()
            let values = try await binanceSpotDailyQuotes(for: code, from: first, through: last,
                                                         usdtUSD: Dictionary(rates.map { ($0.day, $0.price) }, uniquingKeysWith: { _, new in new }))
            if !values.isEmpty { return values }
        } catch {
            try Task.checkCancellation()
        }
        let values = try await coinbaseUSDDailyQuotes(for: code, from: first, through: last)
        try Task.checkCancellation()
        guard !values.isEmpty else { throw InvestmentError.invalid("没有可用的加密货币历史美元日价。") }
        return values
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
