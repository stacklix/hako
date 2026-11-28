import SwiftUI

enum ContainersApplicationModule {
    static let module = HakoApplicationModule(
        application: .containers, category: .management, subtitle: "Arcane · 容器状态 · 日志与更新", icon: .asset("ContainersIcon"),
        destination: { AnyView(ContainersView()) }, register: { registration in
        registration.pins.append(ArcanePinContributor.register)
    })
}
