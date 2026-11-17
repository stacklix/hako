import Foundation

struct HakoNotification: Identifiable, Equatable {
    enum Category: String, CaseIterable { case loginRequests, applePush
        var title: String { self == .loginRequests ? "登录请求" : "Apple 推送" }
        var footer: String { self == .loginRequests ? "左滑可清除提醒，不会批准或拒绝登录。请求到期后自动移除。" : "此设备收到的推送保留 30 天，左滑可清除。" }
    }
    enum Content: Equatable { case loginRequest(ConsoleLoginPrompt), push(HakoPushNotification) }
    let content: Content
    init(loginRequest: ConsoleLoginPrompt) { content = .loginRequest(loginRequest) }
    init(push: HakoPushNotification) { content = .push(push) }
    var id: String { switch content { case .loginRequest(let prompt): return "login:" + prompt.id; case .push(let push): return push.id } }
    var category: Category { switch content { case .loginRequest: return .loginRequests; case .push: return .applePush } }
    var createdAt: Date? { switch content { case .loginRequest(let prompt): return ISO8601DateFormatter().date(from: prompt.requestedAt); case .push(let push): return push.receivedAt } }
    var expiresAt: Date { switch content { case .loginRequest(let prompt): return prompt.expiry ?? .distantPast; case .push(let push): return push.expiresAt } }
    var title: String {
        switch content {
        case .push(let push): return push.title
        case .loginRequest(let prompt):
            if !prompt.isApplication { return prompt.title }
            return prompt.title + (prompt.effectivePurpose == "bind" ? " 请求绑定" : " 请求登录")
        }
    }
    var summary: String {
        switch content {
        case .push(let push): return [push.subtitle, push.body].filter { !$0.isEmpty }.joined(separator: "\n")
        case .loginRequest(let prompt):
            if !prompt.isApplication { return "新的网页登录请求" }
            if prompt.effectivePurpose == "bind" { return "绑定已有应用管理员账号" }
            if prompt.effectivePurpose == "oidc" {
                return prompt.scopes.split(separator: " ").contains("profile") ? "申请访问账号标识与账号名称" : "申请访问账号标识"
            }
            return "使用 Hako 账号登录"
        }
    }
    var symbol: String { switch content { case .loginRequest(let prompt): return prompt.isApplication ? "square.stack.3d.up" : "desktopcomputer"; case .push(let push): return push.symbol } }
    var clearFeedback: String { switch content { case .loginRequest: return "已清除提醒，登录请求仍按原期限到期。"; case .push: return "已清除推送。" } }
}

// Archive display fields only; login nonces, device tokens and the full payload
// never become part of notification history.
struct HakoPushNotification: Codable, Equatable, Identifiable, Sendable {
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let body: String
    let receivedAt: Date
    var expiresAt: Date { receivedAt.addingTimeInterval(Self.retention) }
    var source: String {
        switch kind {
        case "agent_update": "Agent 升级"
        case "build_completed": "构建更新"
        case "workshop_terminal", "workshop_question": "代码工坊"
        default: "Apple 推送"
        }
    }
    var symbol: String {
        switch kind {
        case "agent_update": "arrow.triangle.2.circlepath"
        case "build_completed": "hammer"
        case "workshop_terminal", "workshop_question": "chevron.left.forwardslash.chevron.right"
        default: "bell"
        }
    }
    init?(userInfo: [AnyHashable: Any], identifier: String, receivedAt: Date) {
        guard let aps = userInfo["aps"] as? [String: Any] else { return nil }
        let alert = aps["alert"] as? [String: Any]
        let title = alert?["title"] as? String ?? ""
        let subtitle = alert?["subtitle"] as? String ?? ""
        let body = alert?["body"] as? String ?? aps["alert"] as? String ?? ""
        guard !title.isEmpty || !subtitle.isEmpty || !body.isEmpty else { return nil }
        let customID = userInfo["notificationId"] as? String ?? ""
        let key = !customID.isEmpty && customID.count <= 256 ? customID : identifier
        guard !key.isEmpty, key.count <= 256 else { return nil }
        kind = String((userInfo["type"] as? String ?? "notification").prefix(64))
        id = "apple:" + kind + ":" + key
        self.title = title.isEmpty ? "Hako" : String(title.prefix(200))
        self.subtitle = String(subtitle.prefix(200))
        self.body = String(body.prefix(4000))
        self.receivedAt = receivedAt
    }
}

struct HakoPushHistory: Codable, Equatable {
    private(set) var items: [HakoPushNotification] = []
    private var cleared: [String: Date] = [:]

    @discardableResult mutating func prune(now: Date = .now) -> Bool {
        let old = self
        items.removeAll { $0.expiresAt <= now }
        cleared = cleared.filter { $0.value > now }
        return old != self
    }
    @discardableResult mutating func record(_ notice: HakoPushNotification, now: Date = .now) -> Bool {
        let pruned = prune(now: now)
        guard notice.expiresAt > now, notice.receivedAt <= now.addingTimeInterval(300),
              cleared[notice.id] == nil, !items.contains(where: { $0.id == notice.id }) else { return pruned }
        items.append(notice)
        items.sort { $0.receivedAt != $1.receivedAt ? $0.receivedAt > $1.receivedAt : $0.id < $1.id }
        if items.count > 200 { items = Array(items.prefix(200)) }
        return true
    }
    mutating func clear(_ notice: HakoPushNotification, now: Date = .now) {
        prune(now: now)
        items.removeAll { $0.id == notice.id }
        if notice.expiresAt > now { cleared[notice.id] = notice.expiresAt }
        if cleared.count > 2048 { cleared = Dictionary(uniqueKeysWithValues: cleared.sorted { $0.value > $1.value }.prefix(2048).map { ($0.key, $0.value) }) }
    }
}

// Persist only local dismissal metadata, never a confirmation code, nonce or
// login credential. The scope prevents one server/account from hiding another.
struct NotificationDismissals: Codable {
    struct Entry: Codable { let scope: String; let id: String; let expiresAt: Date }
    private(set) var entries: [Entry] = []

    static func scope(server: String, account: String) -> String { server + "\n" + account }
    @discardableResult mutating func prune(now: Date = .now) -> Bool {
        let before = entries.count
        entries.removeAll { $0.expiresAt <= now }
        return entries.count != before
    }
    func contains(_ id: String, scope: String, now: Date = .now) -> Bool {
        entries.contains { $0.scope == scope && $0.id == id && $0.expiresAt > now }
    }
    mutating func clear(_ notification: HakoNotification, scope: String, now: Date = .now) {
        prune(now: now)
        guard notification.expiresAt > now else { return }
        entries.removeAll { $0.scope == scope && $0.id == notification.id }
        entries.append(Entry(scope: scope, id: notification.id, expiresAt: notification.expiresAt))
        if entries.count > 2048 { entries = Array(entries.sorted { $0.expiresAt > $1.expiresAt }.prefix(2048)) }
    }
}
