import Foundation

@main struct StockTradeModelsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try decoder.decode(type, from: Data(text.utf8)) }
        let missing = try decoded(StockTradeRecord.self, #"{"symbol":"600519.SH","rank_score":null,"risk_flags":[{"code":"risk","severity":"high"}]}"#)
        precondition(missing.rank == nil, "Missing scores must not become zero")
        precondition(missing["risk_flags"].text.contains("high"))
        let roundTrip = try decoder.decode(StockTradeRecord.self, from: JSONEncoder().encode(missing))
        precondition(roundTrip == missing)
        let page = try decoded(StockTradePage<StockTradeRecord>.self, #"{"snapshotId":"snapshot","revision":"rev","publishedAt":"2026-11-24T16:00:00+08:00","dataAsOf":null,"stale":false,"items":[],"nextCursor":null,"total":0}"#)
        precondition(page.dataAsOf == nil && page.nextCursor == nil)
        let connection = try StockTradeConnection(origin: " HTTPS://TRADE.example.com:443/ ", clientID: " client ").normalized()
        precondition(connection.origin == "https://trade.example.com" && connection.clientID == "client")
        for bad in ["http://trade.example.com", "https://user:password@trade.example.com", "https://trade.example.com/path", "https://trade.example.com?token=secret", "https://trade.example.com#part", "https://trade.example.com:99999"] {
            precondition(StockTradeConnection.httpsOrigin(bad) == nil)
        }
        let fixture = #"{"snapshotId":"snap","revision":"rev","publishedAt":"2026-11-24T16:00:00+08:00","dataAsOf":"2026-11-23","stale":false,"symbol":"600519.SH","period":"1d","adjustment":"qfq","adjustmentBasis":"source_cache","adjustmentVerified":false,"weeklyAnchor":null,"units":{"price":"CNY","volume":"hand","sharesPerHand":100,"amount":"CNY_thousand"},"coverageStart":"2026-11-20","coverageEnd":"2026-11-23","order":"date_desc","isComplete":true,"items":[{"date":"2026-11-23","open":10,"high":12,"low":9,"close":11,"volume":100,"amount":null,"lines":{"short":11,"long":null},"isComplete":true},{"date":"2026-11-20","open":9,"high":11,"low":8,"close":10,"volume":200,"amount":null,"lines":{"short":11,"long":null},"isComplete":true}],"nextCursor":null,"total":2}"#
        let bars = try decoded(StockTradeBars.self, fixture)
        _ = try bars.validated(symbol: "600519.SH", period: "1d", snapshot: "snap")
        precondition(bars.items.first?.amount == nil)
        func reject(_ text: String, symbol: String = "600519.SH", period: String = "1d", snapshot: String = "snap") throws {
            let value = try decoded(StockTradeBars.self, text)
            do { _ = try value.validated(symbol: symbol, period: period, snapshot: snapshot); preconditionFailure("Invalid chart contract accepted") }
            catch StockTradeFailure.invalidResponse { }
        }
        try reject(fixture, snapshot: "another")
        try reject(fixture, symbol: "000001.SZ")
        try reject(fixture.replacingOccurrences(of: "date_desc", with: "date_asc"))
        try reject(fixture.replacingOccurrences(of: #""volume":"hand""#, with: #""volume":"share""#))
        try reject(fixture.replacingOccurrences(of: #""low":9"#, with: #""low":99"#))
        try reject(fixture.replacingOccurrences(of: #""period":"1d""#, with: #""period":"1w""#), period: "1w")
        let ascending = Array(bars.items.reversed())
        let ma = StockTradeChartData.movingAverage(ascending, count: 2)
        precondition(ma[0] == nil && ma[1] == 10.5)
        let range = StockTradeChartData.range(ascending)
        precondition(range.lowerBound < 8 && range.upperBound > 12)
        var preference = StockTradeNotificationPreferences()
        precondition(preference.valid, "Cross-midnight quiet hours must be valid")
        preference.quietEnd = preference.quietStart; precondition(!preference.valid)
        preference.quiet = false; precondition(preference.valid)
        preference.duplicateMinutes = 0; precondition(!preference.valid)
        precondition(StockTradeTime.date("2026-11-24T14:00:00.123456+00:00") != nil)
        precondition(StockTradeTime.date("2026-11-24T14:00:00Z") != nil)
        precondition(StockTradeFailure.api(status: 401, code: "session_invalid", requestID: "r", retryable: false).invalidatesSession)
        precondition(!StockTradeFailure.api(status: 503, code: "hako_unavailable", requestID: "r", retryable: true).invalidatesSession)
        print("StockTrade model, snapshot, chart and notification preference tests passed")
    }
}
