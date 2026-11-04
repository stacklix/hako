import Foundation

struct HakoNotification: Identifiable, Equatable {
    enum Category: String, CaseIterable { case loginRequests
        var title: String { "登录请求" }
        var footer: String { "左滑可清除提醒，不会批准或拒绝登录。请求到期后自动移除。" }
    }
    enum Content: Equatable { case loginRequest(ConsoleLoginPrompt) }
    let content: Content
    init(loginRequest: ConsoleLoginPrompt) { content = .loginRequest(loginRequest) }
    var id: String { switch content { case .loginRequest(let prompt): return "login:" + prompt.id } }
    var category: Category { switch content { case .loginRequest: return .loginRequests } }
    var createdAt: Date? { switch content { case .loginRequest(let prompt): return ISO8601DateFormatter().date(from: prompt.requestedAt) } }
    var expiresAt: Date { switch content { case .loginRequest(let prompt): return prompt.expiry ?? .distantPast } }
    var title: String {
        switch content {
        case .loginRequest(let prompt):
            if !prompt.isApplication { return prompt.title }
            return prompt.title + (prompt.effectivePurpose == "bind" ? " 请求绑定" : " 请求登录")
        }
    }
    var summary: String {
        switch content {
        case .loginRequest(let prompt):
            if !prompt.isApplication { return "新的网页登录请求" }
            if prompt.effectivePurpose == "bind" { return "绑定已有应用管理员账号" }
            if prompt.effectivePurpose == "oidc" {
                return prompt.scopes.split(separator: " ").contains("profile") ? "申请访问账号标识与账号名称" : "申请访问账号标识"
            }
            return "使用 Hako 账号登录"
        }
    }
    var symbol: String { switch content { case .loginRequest(let prompt): return prompt.isApplication ? "square.stack.3d.up" : "desktopcomputer" } }
    var clearFeedback: String { switch content { case .loginRequest: return "已清除提醒，登录请求仍按原期限到期。" } }
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
