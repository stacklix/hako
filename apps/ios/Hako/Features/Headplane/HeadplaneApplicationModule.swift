import SwiftUI

enum HeadplaneApplicationModule {
    static let module = HakoApplicationModule(
        application: .headplane, category: .management, subtitle: "Headplane · 设备 · 路由与访问控制", icon: .asset("HeadplaneIcon"),
        destination: { AnyView(HeadplaneView()) })
}
