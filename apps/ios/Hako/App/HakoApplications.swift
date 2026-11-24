import SwiftUI

enum HakoApplications {
    @MainActor static func agentSettings() -> some View { AgentSettingsSheet() }
    @MainActor static func httpProxySettings() -> some View { HTTPProxySettingsSheet() }
    @MainActor static func webhookSettings() -> some View { NotificationManagementView() }

    enum Category: String, CaseIterable {
        // Raw values identify saved application orders; titles are the visible category names.
        case development = "开发工具", management = "IT工具", finance = "金融", life = "生活"

        var title: String { self == .management ? "管理面板" : rawValue }

        var applications: [Application] {
            switch self {
            case .development: [.codeWorkshop, .swissArmyKnife]
            case .management: [.headplane, .router, .qinglong, .cloudServers, .containers, .devices]
            case .finance: [.investment, .crypto, .stockTrade]
            case .life: [.sports, .usage]
            }
        }
    }

    enum Application: String, Identifiable {
        case headplane = "组网管理", qinglong = "青龙面板", cloudServers = "云服务器"
        case containers = "容器管理", devices = "设备管理", sports = "运动记录", usage = "使用时间"
        case investment = "投资记账", crypto = "加密资产", stockTrade = "A 股选股"
        case codeWorkshop = "代码工坊"
        case router = "路由器"
        case swissArmyKnife = "瑞士军刀"

        var id: Self { self }
        var subtitle: String {
            switch self {
            case .headplane: "Headplane · 设备 · 路由与访问控制"
            case .router: "TP-LINK · 接入设备 · IP/MAC 绑定"
            case .qinglong: "定时任务 · 脚本 · 订阅管理"
            case .cloudServers: "阿里云 ECS · 监控 · 进程与终端"
            case .containers: "Arcane · 容器状态 · 日志与更新"
            case .devices: "设备在线状态 · 能力调用"
            case .codeWorkshop: "Codex 会话 · 编程任务 · 原型预览"
            case .swissArmyKnife: "实用小工具 · 随机字符串与二维码扫描"
            case .sports: "运动趋势 · 每次记录 · GitHub 归档"
            case .usage: "每日概览 · Top 5 · GitHub 归档"
            case .investment: "账户 · 持仓 · 定投"
            case .crypto: "HTX · Binance · 链上资产与私有归档"
            case .stockTrade: "Cerno · 每日推荐 · 日周 K 线与规则监控"
            }
        }
        var symbol: String {
            switch self {
            case .headplane: "network"
            case .router: "wifi.router"
            case .qinglong: "checklist"
            case .cloudServers: "server.rack"
            case .containers: "shippingbox"
            case .devices: "desktopcomputer"
            case .codeWorkshop: "terminal"
            case .swissArmyKnife: "wrench.and.screwdriver"
            case .sports: "figure.run"
            case .usage: "chart.bar.xaxis"
            case .investment: "chart.line.uptrend.xyaxis"
            case .crypto: "bitcoinsign.circle"
            case .stockTrade: "chart.xyaxis.line"
            }
        }
        @MainActor @ViewBuilder var destination: some View {
            switch self {
            case .headplane: HeadplaneView()
            case .router: RouterView()
            case .qinglong: QinglongView()
            case .cloudServers: CloudServersView()
            case .containers: ContainersView()
            case .devices: DeviceMonitorView()
            case .codeWorkshop: CodeWorkshopView()
            case .swissArmyKnife: SwissArmyKnifeView()
            case .sports: SportsView()
            case .usage: UsageEntry()
            case .investment: InvestmentView()
            case .crypto: CryptoView()
            case .stockTrade: StockTradeView()
            }
        }

        @MainActor fileprivate func registerShortcuts(in registry: HakoShortcutRegistry) {
            switch self {
            case .usage: UsageShortcutContributor.registerShortcuts(in: registry)
            case .crypto: CryptoShortcutContributor.registerShortcuts(in: registry)
            case .investment: InvestmentShortcutContributor.registerShortcuts(in: registry)
            default: break
            }
        }

        @MainActor fileprivate func registerNotifications(in registry: ApplicationNotificationRegistry<WorkshopPushNotice, AnyView>) {
            switch self {
            case .codeWorkshop: WorkshopNotificationContributor.registerNotifications(in: registry)
            default: break
            }
        }
    }

    @MainActor static let notifications: ApplicationNotificationRegistry<WorkshopPushNotice, AnyView> = {
        let registry = ApplicationNotificationRegistry<WorkshopPushNotice, AnyView>()
        for application in Category.allCases.flatMap(\.applications) {
            application.registerNotifications(in: registry)
        }
        return registry
    }()

    @MainActor static let pins: HakoPinRegistry = {
        let registry = HakoPinRegistry()
        WorkshopPinContributor.register(in: registry)
        ArcanePinContributor.register(in: registry)
        return registry
    }()

    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        for application in Category.allCases.flatMap(\.applications) {
            application.registerShortcuts(in: registry)
        }
    }

    @MainActor static func registerBackupScopes(in cloud: HakoCloudSettings) {
        for application in Category.allCases.flatMap(\.applications) {
            switch application {
            case .codeWorkshop: cloud.registerBackupScopes(WorkshopBackup.scopes)
            case .investment: cloud.registerBackupScopes(InvestmentBackup.scopes)
            case .qinglong: cloud.registerBackupScopes(QinglongBackup.scopes)
            default: break
            }
        }
    }

}
