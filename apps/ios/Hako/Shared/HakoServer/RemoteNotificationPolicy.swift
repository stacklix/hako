import Foundation

enum RemoteNotificationDestination: Equatable {
    case settings, codeWorkshop
}

enum RemoteNotificationPolicy {
    static func presentsInForeground(_ info: [AnyHashable: Any]) -> Bool {
        (info["type"] as? String) != "workshop_terminal"
    }
    static func destination(_ info: [AnyHashable: Any], defaultAction: Bool) -> RemoteNotificationDestination? {
        guard defaultAction else { return nil }
        switch info["type"] as? String {
        case "workshop_terminal": return .codeWorkshop
        case "build_completed": return .settings
        default: return nil
        }
    }
}
