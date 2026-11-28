import Foundation

@main struct StockTradeModelsTests {
    static func entryStateChecks() {
        func state(session: Bool = false, snapshot: Bool = false, pending: Bool = true,
                   busy: Bool = false, error: Bool = false, loggedOut: Bool = false,
                   configured: Bool = true) -> StockTradeEntryState {
            .resolve(configured: configured, hasSession: session, hasSnapshot: snapshot,
                     initialActivationPending: pending, busy: busy, hasError: error,
                     explicitlyLoggedOut: loggedOut)
        }
        precondition(state() == .loading, "The first frame must not assume login is required")
        precondition(state(session: true, busy: true) == .loading, "Restored credentials must not flash the first-run empty state")
        precondition(state(session: true, pending: false, busy: true) == .loading, "A retry still needs an initial result")
        precondition(state(session: true, snapshot: true, busy: true) == .content, "Keep an existing result visible during refresh")
        precondition(state(session: true, pending: false) == .content, "A confirmed empty result must remain available")
        precondition(state(pending: false) == .login, "An authentication attempt without a session must settle on login")
        precondition(state(busy: true, error: true) == .login, "Authentication errors must not be hidden behind a loader")
        precondition(state(session: true, busy: true, error: true) == .content, "Snapshot errors must be presented on the results page")
        precondition(state(loggedOut: true) == .login, "Explicit logout must not reopen the startup loader")
        precondition(state(configured: false) == .connection)

        func results(snapshot: Bool = false, busy: Bool = false, missing: Bool = false,
                     error: Bool = false) -> StockTradeResultsState {
            .resolve(hasSnapshot: snapshot, busy: busy, missingSnapshot: missing, hasError: error)
        }
        precondition(results() == .loading, "Before the first read starts, absence of a result must not expose the start-screening button")
        precondition(results(busy: true) == .loading, "The initial read must not expose a confirmed-empty action")
        precondition(results(snapshot: true, busy: true) == .loaded, "Cached results must remain visible while refreshing")
        precondition(results(missing: true, error: true) == .missing, "Only a confirmed unavailable snapshot offers first screening")
        precondition(results(busy: true, missing: true) == .loading, "Retrying a previously empty result must hide the empty action until the response")
        precondition(results(error: true) == .unavailable, "A network failure is not proof that no published result exists")
        precondition(results(snapshot: true, error: true) == .loaded, "Refresh errors must retain a loaded publication")
    }
    static func main() throws {
        entryStateChecks()
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
