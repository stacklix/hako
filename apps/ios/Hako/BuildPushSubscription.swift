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
    private let idKey = "hako.buildPush.id"
    private var busy = false

    @Published var settingsRequested = false
    @Published private(set) var settingsRequestID = 0

    private init() { }

    func requestSettings() {
        settingsRequested = true
        settingsRequestID += 1
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
            } catch {
                HakoLog.record(.hako, .error, "无法请求构建通知权限")
                return
            }
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return
        @unknown default:
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func register(_ token: Data) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let hexToken = token.map { String(format: "%02x", $0) }.joined()
        let id = defaults.string(forKey: idKey)
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: idKey)
        var request = URLRequest(url: Self.subscriptionURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "token": hexToken])
            let (_, response) = try await HTTPTransport.data(for: request, using: URLSession.shared, secrets: [hexToken])
            guard (response as? HTTPURLResponse)?.statusCode == 204 else {
                throw URLError(.badServerResponse)
            }
        } catch {
            HakoLog.record(.hako, .error, "构建通知订阅暂未同步，下次打开 Hako 时会重试")
        }
    }
}

final class BuildPushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await BuildPushSubscription.shared.register(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        HakoLog.record(.hako, .error, "构建通知设备登记失败，下次打开 Hako 时会重试")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let opensSettings = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            && (response.notification.request.content.userInfo["type"] as? String) == "build_completed"
        DispatchQueue.main.async {
            // UIKit updates its scene snapshot when the response completes.
            defer { completionHandler() }
            guard opensSettings else { return }
            HakoLog.record(.hako, "收到构建通知点按")
            BuildPushSubscription.shared.requestSettings()
        }
    }
}
