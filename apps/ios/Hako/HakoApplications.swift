import SwiftUI

enum HakoApplications {
    enum Category: String, CaseIterable {
        case it = "IT工具", finance = "金融", life = "生活"

        var applications: [Application] {
            switch self {
            case .it: [.headplane, .qinglong, .cloudServers, .containers, .devices]
            case .finance: [.investment, .crypto]
            case .life: [.sports, .usage]
            }
        }
    }

    enum Application: String, Identifiable {
        case headplane = "组网管理", qinglong = "青龙面板", cloudServers = "云服务器"
        case containers = "容器管理", devices = "设备监控", sports = "运动记录", usage = "使用时间"
        case investment = "投资记账", crypto = "加密资产"

        var id: Self { self }
        var subtitle: String {
            switch self {
            case .headplane: "Headplane · 设备 · 路由与访问控制"
            case .qinglong: "定时任务 · 脚本 · 订阅管理"
            case .cloudServers: "阿里云 ECS · 监控 · 进程与终端"
            case .containers: "Arcane · 容器状态 · 日志与更新"
            case .devices: "设备在线状态 · 能力调用"
            case .sports: "运动趋势 · 每次记录 · GitHub 归档"
            case .usage: "每日概览 · Top 5 · GitHub 归档"
            case .investment: "账户 · 持仓 · 定投"
            case .crypto: "HTX · Binance · 链上资产与私有归档"
            }
        }
        var symbol: String {
            switch self {
            case .headplane: "network"
            case .qinglong: "checklist"
            case .cloudServers: "server.rack"
            case .containers: "shippingbox"
            case .devices: "desktopcomputer"
            case .sports: "figure.run"
            case .usage: "chart.bar.xaxis"
            case .investment: "chart.line.uptrend.xyaxis"
            case .crypto: "bitcoinsign.circle"
            }
        }
        @MainActor @ViewBuilder var destination: some View {
            switch self {
            case .headplane: HeadplaneView()
            case .qinglong: QinglongView()
            case .cloudServers: CloudServersView()
            case .containers: ContainersView()
            case .devices: DeviceMonitorView()
            case .sports: SportsView()
            case .usage: UsageEntry()
            case .investment: InvestmentView()
            case .crypto: CryptoView()
            }
        }

        @MainActor fileprivate func registerShortcuts(in registry: HakoShortcutRegistry) {
            switch self {
            case .usage: UsageShortcutContributor.registerShortcuts(in: registry)
            case .crypto: CryptoShortcutContributor.registerShortcuts(in: registry)
            default: break
            }
        }
    }

    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        for application in Category.allCases.flatMap(\.applications) {
            application.registerShortcuts(in: registry)
        }
    }
}
