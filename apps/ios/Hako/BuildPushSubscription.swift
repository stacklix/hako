import Combine
import UIKit
import UserNotifications

@MainActor
final class BuildPushSubscription: ObservableObject {
    static let shared = BuildPushSubscription()
    static let installPage = URL(string: "https://nux.luckyqiao.com/chore/ios/hako/")!
    private static let subscriptionURL = installPage
        .appendingPathComponent("push")
        .appendingPathComponent("subscription")
    private let defaults = UserDefaults.standard
    private let enabledKey = "hako.buildPush.enabled"
    private let idKey = "hako.buildPush.id"
    private let removalKey = "hako.buildPush.pendingRemoval"

    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    private init() {
        enabled = defaults.bool(forKey: enabledKey)
    }

    func setEnabled(_ requested: Bool) async {
        guard !busy else { return }
        if requested {
            busy = true
            defer { busy = false }
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    message = "请在系统设置中允许 Hako 发送通知。"
                    return
                }
                defaults.set(true, forKey: enabledKey)
                enabled = true
                defaults.removeObject(forKey: removalKey)
                message = "正在登记设备…"
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                message = "无法请求通知权限。"
            }
        } else {
            defaults.set(true, forKey: removalKey)
            defaults.set(false, forKey: enabledKey)
            enabled = false
            await refresh()
        }
    }

    func refresh() async {
        guard !busy else { return }
        if defaults.bool(forKey: removalKey) {
            await update(token: nil)
        } else if enabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func register(_ token: Data) async {
        guard enabled, !busy else { return }
        await update(token: token.map { String(format: "%02x", $0) }.joined())
    }

    func registrationFailed() {
        if enabled { message = "设备登记失败，下次打开 Hako 时会重试。" }
    }

    private func update(token: String?) async {
        busy = true
        defer { busy = false }
        let id = defaults.string(forKey: idKey)
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: idKey)
        var request = URLRequest(url: Self.subscriptionURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let value: Any = token.map { $0 as Any } ?? NSNull()
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "token": value])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 204 else {
                throw URLError(.badServerResponse)
            }
            if token == nil { defaults.removeObject(forKey: removalKey) }
            message = nil
        } catch {
            message = token == nil ? "退订暂未同步，下次打开 Hako 时会重试。"
                : "订阅暂未同步，下次打开 Hako 时会重试。"
        }
    }
}

final class BuildPushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await BuildPushSubscription.shared.register(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        BuildPushSubscription.shared.registrationFailed()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let url = response.notification.request.content.userInfo["url"] as? String
        await MainActor.run {
            if url == BuildPushSubscription.installPage.absoluteString {
                UIApplication.shared.open(BuildPushSubscription.installPage)
            }
        }
    }
}
