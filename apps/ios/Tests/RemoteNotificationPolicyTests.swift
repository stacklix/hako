import Foundation

@main struct RemoteNotificationPolicyTests {
    static func main() {
        let task: [AnyHashable: Any] = ["type": "workshop_terminal", "state": "completed"]
        precondition(!RemoteNotificationPolicy.presentsInForeground(task))
        precondition(RemoteNotificationPolicy.destination(task, defaultAction: true) == .codeWorkshop)
        precondition(RemoteNotificationPolicy.destination(task, defaultAction: false) == nil)
        for state in ["failed", "interrupted", "unknown"] {
            precondition(!RemoteNotificationPolicy.presentsInForeground(["type": "workshop_terminal", "state": state]))
        }
        let build: [AnyHashable: Any] = ["type": "build_completed"]
        precondition(RemoteNotificationPolicy.presentsInForeground(build))
        precondition(RemoteNotificationPolicy.destination(build, defaultAction: true) == .settings)
        precondition(RemoteNotificationPolicy.destination(["type": "ilinker_notification"], defaultAction: true) == nil)
        precondition(RemoteNotificationPolicy.destination([:], defaultAction: true) == nil)
        print("PASS: workshop foreground suppression, background notification tap routing and existing build notification behavior")
    }
}
