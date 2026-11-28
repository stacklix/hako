import SwiftUI

enum UsageApplicationModule {
    static let module = HakoApplicationModule(
        application: .usage, category: .life, subtitle: "每日概览 · Top 5 · GitHub 归档", icon: .asset("UsageIcon"),
        destination: { AnyView(UsageEntry()) }, register: { registration in
        registration.shortcuts.append(UsageShortcutContributor.registerShortcuts)
    })
}
