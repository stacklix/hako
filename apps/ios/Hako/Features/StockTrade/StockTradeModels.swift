import Foundation

// Original rule payloads are intentionally retained: the Python backend owns
// scoring, risk gates and their snake_case fields, not the phone.
enum StockTradeValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([Self]), object([String: Self]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n.formatted(.number.precision(.fractionLength(0...3)))
        case .bool(let b): b ? "是" : "否"
        case .array(let a): a.map(\.text).joined(separator: " · ")
        case .object(let o): o.keys.sorted().map { "\($0)：\(o[$0]!.text)" }.joined(separator: "；")
        case .null: "—"
        }
    }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
}

struct StockTradeRecord: Codable, Equatable, Identifiable, Sendable {
    let fields: [String: StockTradeValue]
    init(fields: [String: StockTradeValue]) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: StockTradeValue].self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    subscript(_ field: String) -> StockTradeValue { fields[field] ?? .null }
    func string(_ field: String) -> String { if case .string(let v) = self[field] { return v }; return "" }
    var symbol: String { string("symbol") }
    var name: String { string("name").isEmpty ? symbol : string("name") }
    var id: String { string("alertId").isEmpty ? (string("monitorId").isEmpty ? symbol : string("monitorId")) : string("alertId") }
    var rank: Double? { self["rank_score"].number }
    var reason: String {
        let text = string("rank_reason")
        return text.isEmpty ? string("comment") : text
    }
    var emailStatus: String { Self.emailLabel(self["channels"].object["email"]?.object["status"]?.text) }
    static func emailLabel(_ value: String?) -> String {
        switch value {
        case "sent": "邮件已发送"
        case "pending": "邮件等待发送"
        case "failed": "邮件失败 · 等待后台重试"
        case nil, "—": "邮件状态未提供"
        default: "邮件：" + (value ?? "—")
        }
    }
    var monitorLabel: String {
        switch string("status") {
        case "watch": "规则观察"
        case "open": "模拟持有"
        case "closed": "模拟结束"
        default: "规则状态未提供"
        }
    }
}

struct StockTradePage<Item: Decodable & Sendable>: Decodable, Sendable {
    let snapshotId, revision, publishedAt: String
    let dataAsOf: String?
    let stale: Bool
    let items: [Item]
    let nextCursor: String?
    let total: Int
    let mode: String?
}

struct StockTradeDetail: Decodable, Sendable {
    let snapshotId, revision, publishedAt: String
    let dataAsOf: String?
    let stale: Bool
    let item: StockTradeRecord
}

struct StockTradeRun: Decodable, Sendable {
    let snapshotId, revision, publishedAt, dataAsOf, runId, status: String
    let stale: Bool
    let candidateCount, reviewCount, recommendationCount: Int
    let thresholds: [String: StockTradeValue]
}

struct StockTradeMeta: Decodable, Sendable {
    struct Auth: Decodable, Sendable {
        let configured: Bool
        let issuer, clientId, applicationOrigin: String
        let refreshSupported, deviceBoundRefresh: Bool
        let sessionAuthority: String
    }
    let apiVersion, timezone: String
    let auth: Auth
    let features: [String: StockTradeValue]
}

struct StockTradeBar: Decodable, Equatable, Identifiable, Sendable {
    let date: String
    let open, high, low, close, volume: Double
    let amount: Double?
    let isComplete: Bool
    let firstTradeDate, lastTradeDate: String?
    var id: String { date }
    var valid: Bool {
        [open, high, low, close, volume].allSatisfy(\.isFinite)
            && low > 0 && low <= min(open, close) && high >= max(open, close) && volume >= 0
    }
}

struct StockTradeBars: Decodable, Sendable {
    let snapshotId, revision, publishedAt, dataAsOf, symbol, period, adjustment, adjustmentBasis: String
    let stale, adjustmentVerified, isComplete: Bool
    let weeklyAnchor: String?
    let units: [String: StockTradeValue]
    let coverageStart, coverageEnd, order: String
    let items: [StockTradeBar]
    let nextCursor: String?
    let total: Int
    func validated(symbol expected: String, period expectedPeriod: String, snapshot: String) throws -> Self {
        guard symbol == expected, period == expectedPeriod, snapshotId == snapshot,
              order == "date_desc", adjustment == "qfq", adjustmentBasis == "source_cache",
              units["price"]?.text == "CNY", units["volume"]?.text == "hand",
              units["sharesPerHand"]?.number == 100, units["amount"]?.text == "CNY_thousand",
              expectedPeriod != "1w" || weeklyAnchor == "W-FRI",
              items.allSatisfy(\.valid), Set(items.map(\.date)).count == items.count,
              zip(items, items.dropFirst()).allSatisfy({ $0.date > $1.date }) else {
            throw StockTradeFailure.invalidResponse
        }
        return self
    }
}

enum StockTradePool: String, CaseIterable, Identifiable {
    case recommendations, candidates, near_miss, strong_watchlist, aggressive_watchlist, above_threshold, excluded_details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recommendations: "正式推荐"
        case .candidates: "全部候选"
        case .near_miss: "近门槛观察"
        case .strong_watchlist: "强势观察"
        case .aggressive_watchlist: "进取观察"
        case .above_threshold: "达到分数门槛"
        case .excluded_details: "排除明细"
        }
    }
}

struct StockTradeUser: Codable, Equatable, Sendable { let id, issuer, subject, username: String }
struct StockTradeSession: Codable, Sendable {
    let accessToken, tokenType, expiresAt: String
    let deviceId, deviceToken: String
    let user: StockTradeUser
    var renewable: Bool {
        deviceId.utf8.count == 32 && deviceId.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && (32...128).contains(deviceToken.utf8.count)
            && deviceToken.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    var valid: Bool { renewable && tokenType == "Bearer" && !accessToken.isEmpty && accessToken.utf8.count <= 4096 && accessToken.utf8.allSatisfy { (33...126).contains($0) } && StockTradeTime.date(expiresAt).map { $0 > .now } == true }
}
struct StockTradeLoginStart: Decodable, Sendable {
    let loginId, requestId, issuer, clientId, application, applicationOrigin, nonce, expiresAt, codeChallenge, codeChallengeMethod: String
}

struct StockTradeConnection: Codable, Equatable, Sendable {
    var origin = ""
    var clientID = ""
    func normalized() throws -> Self {
        guard let origin = Self.httpsBaseURL(origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StockTradeFailure.configuration }
        return Self(origin: origin, clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // The persisted address includes the application path. Authorization still
    // binds to the HTTPS origin and the separately configured client ID.
    var applicationOrigin: String? {
        guard let base = Self.httpsBaseURL(origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              var parts = URLComponents(string: base) else { return nil }
        parts.percentEncodedPath = ""
        return parts.string.flatMap(Self.httpsOrigin)
    }
    static func httpsBaseURL(_ text: String) -> String? {
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }), !text.contains("\\"),
              var parts = URLComponents(string: text), parts.query == nil, parts.fragment == nil else { return nil }
        var path = parts.percentEncodedPath
        guard !path.contains("//") else { return nil }
        if path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = ""
        guard let root = parts.string.flatMap(Self.httpsOrigin) else { return nil }
        if path.isEmpty { return root }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var segments: [String] = []
        for segment in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding, !decoded.isEmpty,
                  decoded != ".", decoded != "..",
                  !decoded.contains(where: { "/\\%?#".contains($0) || $0.isWhitespace || $0.isNewline }),
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let encoded = decoded.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            segments.append(encoded)
        }
        return root + "/" + segments.joined(separator: "/")
    }
    static func httpsOrigin(_ text: String) -> String? {
        guard let p = URLComponents(string: text), p.scheme?.lowercased() == "https",
              let host = p.host?.lowercased(), !host.isEmpty, p.user == nil, p.password == nil,
              p.path.isEmpty || p.path == "/", p.query == nil, p.fragment == nil,
              p.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "https://" + address + (p.port == nil || p.port == 443 ? "" : ":\(p.port!)")
    }
}

enum StockTradeTime {
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func display(_ text: String) -> String {
        guard let date = date(text) else { return text.isEmpty ? "未提供" : text }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

enum StockTradeFailure: Error, LocalizedError {
    case configuration, invalidResponse, sessionRequired, changedContext
    case api(status: Int, code: String, requestID: String, retryable: Bool)
    var errorDescription: String? {
        switch self {
        case .configuration: "请填写有效的 HTTPS 后端基础地址和 Hako 应用 ID；不要包含账号、查询参数、片段或路径跳转。"
        case .invalidResponse: "Cerno 响应与接口契约不符，已停止使用这份数据。"
        case .sessionRequired: "Cerno 会话已失效，请重新使用 Hako 登录。"
        case .changedContext: "账号或连接已切换，请重新进入。"
        case .api(let status, let code, let id, _):
            switch code {
            case "login_finished": "登录兑换已结束或结果不确定，请重新登录。"
            case "login_expired", "hako_request_unavailable": "登录请求已过期，请重新登录。"
            case "hako_binding_mismatch", "hako_invalid_response": "应用登记与登录响应不一致，请检查后台配置。"
            case "hako_unavailable": "暂时无法核验 Hako 授权，请稍后重试。"
            case "auth_not_configured": "Cerno 后台尚未配置 Hako 登录。"
            case "snapshot_unavailable": "Cerno 尚未发布完整选股快照，请先在后台完成数据发布，再刷新。"
            case "monitor_unavailable": "Cerno 尚未发布规则监控快照，请先在后台发布监控数据，再刷新。"
            case "snapshot_expired": "此快照已不可用，请刷新首屏。"
            case "stock_not_found": "此快照没有该股票的行情。"
            case "review_not_found": "此运行没有该股票的复评。"
            case "rate_limited", "login_capacity": "请求过于频繁，请稍后重试。"
            default: "Cerno 请求失败（\(status) · \(code)），关联号：\(id)。"
            }
        }
    }
    var invalidatesSession: Bool {
        if case .api(let status, _, _, _) = self { return status == 401 }
        return false
    }
}

enum StockTradeChartData {
    static func movingAverage(_ bars: [StockTradeBar], count: Int) -> [Double?] {
        guard count > 0 else { return Array(repeating: nil, count: bars.count) }
        var sum = 0.0
        return bars.indices.map { index in
            sum += bars[index].close
            if index >= count { sum -= bars[index - count].close }
            return index + 1 >= count ? sum / Double(count) : nil
        }
    }
    static func range(_ bars: [StockTradeBar]) -> ClosedRange<Double> {
        let low = bars.map(\.low).min() ?? 0, high = bars.map(\.high).max() ?? 1
        let padding = max((high - low) * 0.08, max(abs(high) * 0.002, 0.01))
        return (low - padding)...(high + padding)
    }
}


struct StockTradeNotificationPreferences: Codable, Equatable {
    var email = true
    var daily = true
    var rule = true
    var risk = true
    var health = false
    var tradingDays = true
    var quiet = true
    var quietStart = 22 * 60
    var quietEnd = 8 * 60
    var duplicateMinutes = 30
    var valid: Bool {
        (0..<1440).contains(quietStart) && (0..<1440).contains(quietEnd)
            && (!quiet || quietStart != quietEnd) && [15, 30, 60].contains(duplicateMinutes)
    }
}
