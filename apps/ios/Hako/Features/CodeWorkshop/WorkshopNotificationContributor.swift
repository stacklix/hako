import SwiftUI

@MainActor
enum WorkshopNotificationContributor {
    static func registerNotifications(in registry: ApplicationNotificationRegistry<WorkshopPushNotice, AnyView>) {
        registry.register(for: .codeWorkshop,
            isViewing: { WorkshopRuntime.shared.isViewing($0) },
            preview: { notice, onOpen in
                AnyView(WorkshopNotificationPreview(notice: notice, onSwitch: onOpen))
            })
    }
}
