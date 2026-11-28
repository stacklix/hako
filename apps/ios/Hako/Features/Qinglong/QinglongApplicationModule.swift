import SwiftUI

enum QinglongApplicationModule {
    static let module = HakoApplicationModule(
        application: .qinglong, category: .management, subtitle: "定时任务 · 脚本 · 订阅管理", icon: .asset("QinglongIcon"),
        destination: { AnyView(QinglongView()) }, register: { registration in
        registration.backups.append { $0.registerBackupScopes(QinglongBackup.scopes) }
    })
}
