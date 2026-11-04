import Foundation

@main struct NotificationTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = String(repeating: "A", count: 43)
        let nonce = String(repeating: "B", count: 43)
        func notification(id: String, expires: TimeInterval, purpose: String = "oidc", scopes: String = "openid profile", application: String = "Example") -> HakoNotification {
            HakoNotification(loginRequest: ConsoleLoginPrompt(id: id, origin: "https://hako.example", application: application,
                applicationOrigin: application.isEmpty ? "" : "https://client.example", scopes: scopes, browser: "Safari", clientIP: "198.51.100.1",
                requestedAt: ISO8601DateFormatter().string(from: now), expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(expires)), nonce: nonce, purpose: purpose))
        }
        let login = notification(id: id, expires: 60)
        precondition(login.id == "login:" + id && login.category == .loginRequests)
        precondition(login.title == "Example 请求登录" && login.summary == "申请访问账号标识与账号名称")
        let admin = notification(id: id, expires: 60, purpose: "", scopes: "", application: "")
        precondition(admin.title == "Hako 管理控制台" && admin.summary == "新的网页登录请求")
        let bind = notification(id: id, expires: 60, purpose: "bind", scopes: "")
        precondition(bind.title == "Example 请求绑定")
        let scope = NotificationDismissals.scope(server: "https://hako.example", account: "owner")
        let otherServer = NotificationDismissals.scope(server: "https://other.example", account: "owner")
        let otherAccount = NotificationDismissals.scope(server: "https://hako.example", account: "another")
        var ledger = NotificationDismissals()
        ledger.clear(login, scope: scope, now: now)
        precondition(ledger.contains(login.id, scope: scope, now: now))
        precondition(!ledger.contains(login.id, scope: otherServer, now: now))
        precondition(!ledger.contains(login.id, scope: otherAccount, now: now))
        precondition(!ledger.contains("login:" + String(repeating: "C", count: 43), scope: scope, now: now))
        ledger.clear(login, scope: scope, now: now)
        precondition(ledger.entries.count == 1, "Repeated clear must not grow local records")
        let data = try JSONEncoder().encode(ledger)
        let json = String(decoding: data, as: UTF8.self)
        precondition(!json.contains(nonce) && !json.contains("198.51.100.1") && !json.contains("confirmationCode") && !json.contains("Safari"))
        var restored = try JSONDecoder().decode(NotificationDismissals.self, from: data)
        let refreshed = notification(id: id, expires: 60)
        precondition(restored.contains(refreshed.id, scope: scope, now: now.addingTimeInterval(30)), "A refreshed request or app restart must not restore a cleared reminder")
        precondition(!restored.contains(login.id, scope: scope, now: now.addingTimeInterval(60)))
        precondition(restored.prune(now: now.addingTimeInterval(60)) && restored.entries.isEmpty)
        restored.clear(notification(id: id, expires: -1), scope: scope, now: now)
        precondition(restored.entries.isEmpty, "Expired notifications must not create dismissal records")
        ledger.clear(notification(id: id, expires: 120), scope: otherServer, now: now)
        ledger.prune(now: now.addingTimeInterval(60))
        precondition(ledger.entries.count == 1 && ledger.contains(login.id, scope: otherServer, now: now.addingTimeInterval(60)))
        print("PASS: notification presentation, stable identity, clear persistence, refresh/restart, scope isolation, expiry cleanup and credential-free storage")
    }
}
