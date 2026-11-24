import Foundation

enum HakoNotificationChannel: String, Codable, CaseIterable, Identifiable {
    case wechat, apns
    var id: String { rawValue }
    var title: String { self == .wechat ? "微信" : "Apple Push" }
}

struct HakoWebhook: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let botId: String?
    let apnsEnabled: Bool
    let enabled: Bool
    let tokenHint: String
    let rateLimit: Int
    let expiresAt: Int64?
    let createdAt: Int64
    let requestCount: Int
    let failureCount: Int
    let lastUsedAt: Int64?

    var channels: [HakoNotificationChannel] {
        HakoNotificationChannel.allCases.filter { $0 == .wechat ? botId != nil : apnsEnabled }
    }
    var expired: Bool { expiresAt.map { $0 <= Int64(Date.now.timeIntervalSince1970 * 1000) } ?? false }
    var status: String { !enabled ? "已停用" : expired ? "已过期" : "已启用" }
    var canSend: Bool { enabled && !expired }
}

struct HakoNotificationWechat: Decodable {
    struct Connection: Decodable {
        let id: String
        let name: String
        let status: String
        let accountId: String?
        let lastError: String?
    }
    let connection: Connection?
}

struct HakoWebhookCreation: Decodable {
    let webhook: HakoWebhook
    let path: String
}

struct HakoWebhookRotation: Decodable { let path: String }
struct HakoNotificationAcknowledgement: Decodable { let ok: Bool }

struct HakoWebhookDraft: Equatable {
    var name = ""
    var botId: String?
    var apnsEnabled = true
    var rateLimit = "60"
    var hasExpiry = false
    var expiry = Date.now.addingTimeInterval(86_400)

    init(webhook: HakoWebhook? = nil) {
        guard let webhook else { return }
        name = webhook.name; botId = webhook.botId; apnsEnabled = webhook.apnsEnabled
        rateLimit = String(webhook.rateLimit)
        hasExpiry = webhook.expiresAt != nil
        if let value = webhook.expiresAt { expiry = Date(timeIntervalSince1970: Double(value) / 1000) }
    }

    var validation: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.utf16.count > 80 { return "名称需为 1–80 个字符。" }
        if botId == nil && !apnsEnabled { return "请至少选择一个允许的渠道。" }
        guard let rate = Int(rateLimit), (1...600).contains(rate) else { return "每分钟调用上限应为 1–600 次。" }
        return nil
    }

    var payload: [String: Any] {
        ["name": name.trimmingCharacters(in: .whitespacesAndNewlines),
         "botId": botId.map { $0 as Any } ?? NSNull(), "apnsEnabled": apnsEnabled,
         "rateLimit": Int(rateLimit) ?? 60,
         "expiresAt": hasExpiry ? Int64(expiry.timeIntervalSince1970 * 1000) as Any : NSNull()]
    }
}

enum HakoNotificationPresentation {
    static func fullAddress(origin: String, path: String) throws -> String {
        guard let server = URLComponents(string: origin), server.scheme == "https", server.host != nil,
              server.user == nil, server.password == nil, server.query == nil, server.fragment == nil,
              server.path.isEmpty || server.path == "/",
              path.range(of: #"^/webhook/notifications/hk_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            throw HakoNotificationError(message: "服务器返回的 Webhook 地址无效。")
        }
        var address = server
        address.path = path
        guard let url = address.url else { throw HakoNotificationError(message: "Webhook 地址无效。") }
        return url.absoluteString
    }
}

struct HakoNotificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
