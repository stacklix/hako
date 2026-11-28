import SwiftUI

enum DeviceManagementApplicationModule {
    static let module = HakoApplicationModule(
        application: .devices, category: .management, subtitle: "设备在线状态 · 能力调用", icon: .asset("DevicesIcon"),
        destination: { AnyView(DeviceMonitorView()) }, register: { registration in
        registration.registerSetting(.agents) { AnyView(AgentSettingsSheet()) }
    })
}
