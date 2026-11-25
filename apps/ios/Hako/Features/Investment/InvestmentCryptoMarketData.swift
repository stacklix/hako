import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentQuoteProvider {
    // Crypto valuations use Binance USDT prices at USD parity and Beijing-day closes.
    func cryptoPriceHistory(code: String, from start: Date, through end: Date,
                            now: Date = .now) async throws -> [InvestmentQuote] {
        let last = min(InvestmentBook.day(end), InvestmentBook.addDays(-1, to: InvestmentBook.day(now)))
        let first = InvestmentBook.day(start)
        guard first <= last else { return [] }
        let values = try await binanceSpotDailyQuotes(for: code, from: first, through: last)
        try Task.checkCancellation()
        guard !values.isEmpty else { throw InvestmentError.invalid("没有可用的 Binance 历史日价。") }
        return values
    }

    // USDT is valued at one USD by the user's selected valuation policy.
    func binanceSpotDailyQuotes(for code: String, from start: Date, through end: Date) async throws -> [InvestmentQuote] {
        if code == "USDT" {
            var day = InvestmentBook.day(start)
            let last = min(InvestmentBook.day(end), InvestmentBook.addDays(-1, to: InvestmentBook.day()))
            var values: [InvestmentQuote] = []
            while day <= last {
                try Task.checkCancellation()
                values.append(InvestmentQuote(day: day, price: 1, source: "USDT 固定估值（1:1）", isDailyClose: true))
                day = InvestmentBook.addDays(1, to: day)
            }
            return values
        }
        return try await binanceDailyCloses(host: "data-api.binance.vision", path: "/api/v3/klines", symbol: code + "USDT",
            interval: "1d", from: start, through: end, source: "Binance 日价（USDT≈USD）")
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

    private static func closingQuote(_ value: String, at boundary: Date, within days: ClosedRange<Date>,
                                     source: String) -> InvestmentQuote? {
        guard boundary == InvestmentBook.day(boundary),
              let price = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), price > 0 else { return nil }
        let day = InvestmentBook.addDays(-1, to: boundary)
        guard days.contains(day) else { return nil }
        return InvestmentQuote(day: day, price: price, source: source, isDailyClose: true)
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
