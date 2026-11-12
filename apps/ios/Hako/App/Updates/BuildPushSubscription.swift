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
    private var hakoToken: Data?
    private var syncingHako = false

    @Published var settingsRequested = false
    @Published private(set) var settingsRequestID = 0
    @Published var workshopRequested = false
    @Published private(set) var workshopNavigationID = UUID()
    @Published var workshopLink: WorkshopPushNotice?
    @Published private(set) var workshopBanner: WorkshopPushNotice?
    private var bannerDismissal: Task<Void, Never>?
    private var displayedNotices: Set<String> = []

    func presentWorkshopNotice(_ notice: WorkshopPushNotice) {
        guard displayedNotices.insert(notice.id).inserted else { return }
        if displayedNotices.count > 200 { displayedNotices = [notice.id] }
        // Retained conversations do not count; only the foreground page suppresses its own banner.
        guard !WorkshopRuntime.shared.isViewing(notice) else { return }
        bannerDismissal?.cancel()
        workshopBanner = notice
        bannerDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if self?.workshopBanner?.id == notice.id { self?.workshopBanner = nil }
        }
    }
    func dismissWorkshopNotice() { bannerDismissal?.cancel(); workshopBanner = nil }
    func openWorkshopNotice(_ notice: WorkshopPushNotice?) {
        dismissWorkshopNotice()
        workshopLink = notice
        workshopNavigationID = UUID()
        workshopRequested = true
    }

    private init() { }

    // Called only after the user explicitly enables a sub-app's notifications.
    func prepareHakoRegistration() async throws {
        let context = ConsoleClient.shared.requestContext
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw URLError(.userAuthenticationRequired) }
        } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional && settings.authorizationStatus != .ephemeral {
            throw URLError(.userAuthenticationRequired)
        }
        UIApplication.shared.registerForRemoteNotifications()
        let deadline = Date().addingTimeInterval(10)
        while hakoToken == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard ConsoleClient.shared.requestContext == context else { throw CancellationError() }
        }
        guard let token = hakoToken, ConsoleClient.shared.requestContext == context else { throw URLError(.timedOut) }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        _ = try await ConsoleClient.shared.send("/api/v1/notifications/device", method: "PUT",
            body: ["token": hex, "environment": "production"], logSource: .hako)
    }

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

    func registerWithHako(_ token: Data) async {
        hakoToken = token
        await syncHako()
    }

    func syncHako() async {
        let console = ConsoleClient.shared
        guard !syncingHako, console.authenticated, !console.logoutPending, let token = hakoToken else { return }
        syncingHako = true
        defer { syncingHako = false }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        do {
            // Hako's signed App uses the production APS environment.
            _ = try await console.send("/api/v1/notifications/device", method: "PUT",
                body: ["token": hex, "environment": "production"], logSource: .hako)
        } catch let error as ServerHTTPError where error.status == 404 {
            // The configured Hako server is running a release without notification registration.
        } catch is CancellationError {
        } catch {
            HakoLog.record(.hako, .error, "Hako 通知设备登记暂未同步，下次打开 Hako 时会重试")
        }
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
        Task { await BuildPushSubscription.shared.registerWithHako(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        HakoLog.record(.hako, .error, "构建通知设备登记失败，下次打开 Hako 时会重试")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if !RemoteNotificationPolicy.presentsInForeground(notification.request.content.userInfo) {
            let notice = WorkshopPushNotice(notification.request.content.userInfo)
            await MainActor.run { if let notice { BuildPushSubscription.shared.presentWorkshopNotice(notice) } }
            return []
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let destination = RemoteNotificationPolicy.destination(response.notification.request.content.userInfo,
            defaultAction: response.actionIdentifier == UNNotificationDefaultActionIdentifier)
        DispatchQueue.main.async {
            // UIKit updates its scene snapshot when the response completes.
            defer { completionHandler() }
            if destination == .codeWorkshop {
                BuildPushSubscription.shared.openWorkshopNotice(WorkshopPushNotice(response.notification.request.content.userInfo))
                return
            }
            guard destination == .settings else { return }
            HakoLog.record(.hako, "收到构建通知点按")
            BuildPushSubscription.shared.requestSettings()
        }
    }
}
