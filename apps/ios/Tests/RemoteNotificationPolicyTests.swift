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
        let question: [AnyHashable: Any] = ["type": "workshop_question", "notificationId": "notice", "computerId": "PC",
            "operationId": "11111111-1111-4111-8111-111111111111", "threadId": "22222222-2222-4222-8222-222222222222",
            "aps": ["alert": ["title": "代码工坊 · hako", "subtitle": "迭代", "body": "需要你回答"]]]
        precondition(!RemoteNotificationPolicy.presentsInForeground(question))
        precondition(RemoteNotificationPolicy.isWorkshop(question))
        precondition(RemoteNotificationPolicy.destination(question, defaultAction: true) == .codeWorkshop)
        let notice = WorkshopPushNotice(question)!
        precondition(notice.computerId == "PC" && notice.subtitle == "迭代" && notice.body == "需要你回答")
        precondition(WorkshopPushNotice(["type": "workshop_question"]) == nil)
        precondition(notice.belongsToConversation(computerId: "PC", threadId: notice.threadId, operationId: nil))
        precondition(notice.belongsToConversation(computerId: "PC", threadId: notice.threadId, operationId: "another-turn"),
            "Another turn in the visible conversation must still suppress the banner")
        precondition(!notice.belongsToConversation(computerId: "PC", threadId: "another-conversation", operationId: notice.operationId))
        precondition(!notice.belongsToConversation(computerId: "another-PC", threadId: notice.threadId, operationId: notice.operationId))
        precondition(notice.belongsToConversation(computerId: "PC", threadId: nil, operationId: notice.operationId),
            "A newly created visible conversation can match by its stable request ID")
        precondition(!notice.belongsToConversation(computerId: "PC", threadId: nil, operationId: nil))
        let build: [AnyHashable: Any] = ["type": "build_completed"]
        precondition(RemoteNotificationPolicy.presentsInForeground(build))
        precondition(RemoteNotificationPolicy.destination(build, defaultAction: true) == .settings)
        precondition(RemoteNotificationPolicy.destination(["type": "ilinker_notification"], defaultAction: true) == nil)
        precondition(RemoteNotificationPolicy.destination([:], defaultAction: true) == nil)
        print("PASS: workshop foreground suppression, background notification tap routing and existing build notification behavior")
    }
}
