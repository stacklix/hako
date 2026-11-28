import SwiftUI

enum HakoApplications {
    // The only host list of child entry points. Capabilities live in each module.
    static let modules: [HakoApplicationModule] = {
        let modules: [HakoApplicationModule] = [
            CodeWorkshopApplicationModule.module,
            SwissArmyKnifeApplicationModule.module,
            HeadplaneApplicationModule.module,
            RouterApplicationModule.module,
            QinglongApplicationModule.module,
            CloudServersApplicationModule.module,
            ContainersApplicationModule.module,
            DeviceManagementApplicationModule.module,
            InvestmentApplicationModule.module,
            CryptoApplicationModule.module,
            StockTradeApplicationModule.module,
            SportsApplicationModule.module,
            UsageApplicationModule.module,
            HTTPProxyApplicationModule.module,
            NotificationManagementApplicationModule.module
        ]
        let applications = modules.compactMap(\.application)
        precondition(Set(applications) == Set(Application.allCases) && applications.count == Application.allCases.count,
                     "Every application must have exactly one module entry")
        precondition(modules.allSatisfy { $0.application == nil || ($0.category != nil && $0.destination != nil) },
                     "Visible applications must provide a category and page")
        return modules
    }()

    static var credentialDeclarations: [HakoCredentialDeclaration] {
        modules.compactMap { module in
            guard !module.credentials.isEmpty else { return nil }
            guard let application = module.application, let id = module.applicationID else {
                preconditionFailure("Credential declarations require an application identity")
            }
            return HakoCredentialDeclaration(application: id, applicationName: application.rawValue,
                                             credentials: module.credentials)
        }
    }

    @MainActor private static let registration: HakoApplicationRegistration = {
        let registration = HakoApplicationRegistration()
        for module in modules { module.register(registration) }
        return registration
    }()
    @MainActor static var credentialValidators: HakoCredentialValidatorRegistry { registration.credentialValidators }
    @MainActor static func agentSettings() -> some View { registration.setting(.agents) }
    @MainActor static func httpProxySettings() -> some View { registration.setting(.httpProxy) }
    @MainActor static func webhookSettings() -> some View { registration.setting(.webhooks) }

    enum Category: String, CaseIterable {
        // Raw values identify saved application orders; titles are the visible category names.
        case development = "开发工具", management = "IT工具", finance = "金融", life = "生活"

        var title: String { self == .management ? "管理面板" : rawValue }

        var applications: [Application] {
            HakoApplications.modules.compactMap { $0.category == self ? $0.application : nil }
        }
    }

    enum Application: String, CaseIterable, Identifiable {
        case headplane = "组网管理", qinglong = "青龙面板", cloudServers = "云服务器"
        case containers = "容器管理", devices = "设备管理", sports = "运动记录", usage = "使用时间"
        case investment = "投资记账", crypto = "加密资产", stockTrade = "A 股选股"
        case codeWorkshop = "代码工坊"
        case router = "路由器"
        case swissArmyKnife = "瑞士军刀"

        var id: Self { self }
        private var module: HakoApplicationModule {
            guard let module = HakoApplications.modules.first(where: { $0.application == self }) else {
                preconditionFailure("Application entry is not registered")
            }
            return module
        }
        var subtitle: String { module.subtitle }
        var icon: HakoApplicationIconSource? { module.icon }
        @MainActor var destination: AnyView {
            guard let destination = module.destination else { preconditionFailure("Application page is not registered") }
            return destination()
        }
    }

    @MainActor static let notifications: ApplicationNotificationRegistry<WorkshopPushNotice, AnyView> = {
        let registry = ApplicationNotificationRegistry<WorkshopPushNotice, AnyView>()
        for contribute in registration.notifications { contribute(registry) }
        return registry
    }()

    @MainActor static let pins: HakoPinRegistry = {
        let registry = HakoPinRegistry()
        for contribute in registration.pins { contribute(registry) }
        return registry
    }()

    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        for contribute in registration.shortcuts { contribute(registry) }
    }

    @MainActor static func registerBackupScopes(in cloud: HakoCloudSettings) {
        for contribute in registration.backups { contribute(cloud) }
    }
}
