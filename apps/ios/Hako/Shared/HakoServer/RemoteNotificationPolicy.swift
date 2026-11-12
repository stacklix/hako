import Foundation

enum RemoteNotificationDestination: Equatable {
    case settings, codeWorkshop
}

enum RemoteNotificationPolicy {
    static func isWorkshop(_ info: [AnyHashable: Any]) -> Bool {
        ["workshop_terminal", "workshop_question"].contains(info["type"] as? String ?? "")
    }
    static func presentsInForeground(_ info: [AnyHashable: Any]) -> Bool {
        !isWorkshop(info)
    }
    static func destination(_ info: [AnyHashable: Any], defaultAction: Bool) -> RemoteNotificationDestination? {
        guard defaultAction else { return nil }
        switch info["type"] as? String {
        case "workshop_terminal", "workshop_question": return .codeWorkshop
        case "build_completed": return .settings
        default: return nil
        }
    }
}

struct WorkshopPushNotice: Equatable, Identifiable, Sendable {
    let id: String
    let computerId: String
    let threadId: String
    let operationId: String
    let title: String
    let subtitle: String
    let body: String

    func belongsToConversation(computerId: String, threadId: String?, operationId: String?) -> Bool {
        guard self.computerId == computerId else { return false }
        if let threadId, !threadId.isEmpty, !self.threadId.isEmpty {
            return self.threadId.caseInsensitiveCompare(threadId) == .orderedSame
        }
        return operationId?.caseInsensitiveCompare(self.operationId) == .orderedSame
    }

    init?(_ info: [AnyHashable: Any]) {
        guard RemoteNotificationPolicy.isWorkshop(info), let id = info["notificationId"] as? String,
              let computer = info["computerId"] as? String, !computer.isEmpty,
              let operation = info["operationId"] as? String, UUID(uuidString: operation) != nil else { return nil }
        self.id = id; computerId = computer; operationId = operation
        threadId = info["threadId"] as? String ?? ""
        let alert = (info["aps"] as? [String: Any])?["alert"] as? [String: Any]
        title = alert?["title"] as? String ?? "代码工坊"
        subtitle = alert?["subtitle"] as? String ?? ""
        body = alert?["body"] as? String ?? "打开会话查看消息"
    }
}
