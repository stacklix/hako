import Foundation

@main struct NotificationManagementTests {
    static func main() throws {
        let data = Data(#"{"id":"webhook_1","name":"部署通知","botId":null,"apnsEnabled":true,"enabled":true,"tokenHint":"hk_abcd12","rateLimit":60,"expiresAt":null,"createdAt":1000,"requestCount":2,"failureCount":1,"lastUsedAt":null}"#.utf8)
        let hook = try JSONDecoder().decode(HakoWebhook.self, from: data)
        precondition(hook.channels == [.apns] && hook.canSend && hook.status == "已启用")
        var draft = HakoWebhookDraft(webhook: hook)
        precondition(draft.validation == nil)
        draft.apnsEnabled = false
        precondition(draft.validation != nil)
        draft.botId = "bot_test"
        precondition(draft.validation == nil && draft.payload["botId"] as? String == "bot_test")
        draft.rateLimit = "601"
        precondition(draft.validation != nil)
        draft.rateLimit = "0"
        precondition(draft.validation != nil)
        draft.rateLimit = "30"
        draft.name = String(repeating: "😀", count: 41)
        precondition(draft.validation != nil)
        draft.name = "  通知  "
        precondition(draft.validation == nil && draft.payload["name"] as? String == "通知")
        precondition(draft.payload["expiresAt"] is NSNull)
        draft.hasExpiry = true; draft.expiry = Date(timeIntervalSince1970: 1234)
        precondition(draft.payload["expiresAt"] as? Int64 == 1_234_000)
        let path = "/webhook/notifications/hk_" + String(repeating: "a", count: 43)
        let address = try HakoNotificationPresentation.fullAddress(origin: "https://sora.example.com/", path: path)
        precondition(address == "https://sora.example.com" + path)
        for invalid in ["https://evil.example/token", "//evil.example/token", path + "?q=1", path + "/extra"] {
            do { _ = try HakoNotificationPresentation.fullAddress(origin: "https://sora.example.com", path: invalid); preconditionFailure("Untrusted address accepted") }
            catch is HakoNotificationError { }
        }
        for origin in ["http://sora.example.com", "https://user:password@sora.example.com", "https://sora.example.com/path", "https://sora.example.com?q=1", "https://sora.example.com/#fragment"] {
            do { _ = try HakoNotificationPresentation.fullAddress(origin: origin, path: path); preconditionFailure("Invalid server origin accepted") }
            catch is HakoNotificationError { }
        }
        let expiredData = Data(#"{"id":"expired","name":"过期通知","botId":"bot_1","apnsEnabled":false,"enabled":true,"tokenHint":"hk_abcd12","rateLimit":60,"expiresAt":1,"createdAt":0,"requestCount":0,"failureCount":0,"lastUsedAt":null}"#.utf8)
        let expired = try JSONDecoder().decode(HakoWebhook.self, from: expiredData)
        precondition(expired.channels == [.wechat] && !expired.canSend && expired.status == "已过期")
        let expiredDraft = HakoWebhookDraft(webhook: expired)
        precondition(expiredDraft.hasExpiry && expiredDraft.payload["expiresAt"] as? Int64 == 1)
        print("Webhook models, channel validation, expiry and secret address boundaries passed")
    }
}
