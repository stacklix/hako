import SwiftUI

enum CloudServersApplicationModule {
    static let module = HakoApplicationModule(
        application: .cloudServers, category: .management, subtitle: "阿里云 ECS · 监控 · 进程与终端", icon: .asset("CloudServersIcon"),
        destination: { AnyView(CloudServersView()) })
}
