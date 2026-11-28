import SwiftUI

enum RouterApplicationModule {
    static let module = HakoApplicationModule(
        application: .router, category: .management, subtitle: "TP-LINK · 接入设备 · IP/MAC 绑定", icon: .asset("RouterIcon"),
        destination: { AnyView(RouterView()) })
}
