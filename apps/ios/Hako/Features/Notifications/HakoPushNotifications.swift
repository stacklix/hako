import Foundation
import Combine
import UserNotifications

@MainActor final class HakoPushNotifications: ObservableObject {
    static let shared = HakoPushNotifications()
    private static let storageKey = "hako.notifications.applePush.v1"
    private let defaults: UserDefaults
    @Published private var history: HakoPushHistory
    var items: [HakoPushNotification] { history.items.filter { $0.expiresAt > .now } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(HakoPushHistory.self, from: $0) } ?? HakoPushHistory()
        if history.prune() { save() }
    }

    func record(_ notification: UNNotification) {
        guard let notice = Self.notice(notification) else { return }
        var next = history
        if next.record(notice) { history = next; save() }
    }

    // Background alerts may arrive while the app isn't running. Import the
    // notifications actually delivered by iOS whenever Hako becomes active.
    func syncDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        var next = history
        next.prune()
        for notification in delivered.sorted(by: { $0.date < $1.date }) {
            if let notice = Self.notice(notification) { next.record(notice) }
        }
        if next != history { history = next; save() }
    }

    func clear(_ notices: [HakoPushNotification]) {
        var next = history
        for notice in notices { next.clear(notice) }
        if next != history { history = next; save() }
    }

    private static func notice(_ notification: UNNotification) -> HakoPushNotification? {
        guard notification.request.trigger is UNPushNotificationTrigger else { return nil }
        return HakoPushNotification(userInfo: notification.request.content.userInfo,
            identifier: notification.request.identifier, receivedAt: notification.date)
    }
    private func save() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.storageKey) }
    }
}
