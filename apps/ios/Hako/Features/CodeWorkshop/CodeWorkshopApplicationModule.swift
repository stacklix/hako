import SwiftUI

enum CodeWorkshopApplicationModule {
    static let module = HakoApplicationModule(
        application: .codeWorkshop, category: .development, subtitle: "Codex 会话 · 编程任务 · 原型预览", icon: .asset("CodeWorkshopIcon"),
        destination: { AnyView(CodeWorkshopView()) }, register: { registration in
        registration.notifications.append(WorkshopNotificationContributor.registerNotifications)
        registration.pins.append(WorkshopPinContributor.register)
        registration.backups.append { $0.registerBackupScopes(WorkshopBackup.scopes) }
    })
}
