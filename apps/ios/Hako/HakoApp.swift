import SwiftUI

@main struct HakoApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    private enum Category: String, CaseIterable {
        case it = "IT工具", finance = "金融", life = "生活"

        var applications: [Application] {
            switch self {
            case .it: [.headplane, .qinglong, .cloudServers, .containers, .devices]
            case .finance: [.crypto]
            case .life: [.sports, .usage]
            }
        }
    }

    private enum Application: String, Identifiable {
        case headplane = "组网管理", qinglong = "青龙面板", cloudServers = "云服务器"
        case containers = "容器管理", devices = "设备监控", sports = "运动记录", usage = "使用时间"
        case crypto = "加密资产"

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
            case .crypto: "bitcoinsign.circle"
            }
        }
        @ViewBuilder var destination: some View {
            switch self {
            case .headplane: HeadplaneView()
            case .qinglong: QinglongView()
            case .cloudServers: CloudServersView()
            case .containers: ContainersView()
            case .devices: DeviceMonitorView()
            case .sports: SportsView()
            case .usage: UsageEntry()
            case .crypto: CryptoView()
            }
        }
    }

    @ObservedObject private var console = ConsoleClient.shared
    @StateObject private var notifications = HakoNotificationsStore()
    @State private var loginLink: HakoLoginLink?
    @State private var category = Category.it
    private struct HakoLoginLink: Identifiable { let id = UUID(); let payload: String }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的日常，收进一个盒子。")
                            .font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        Text("HAKO · 个人工具箱")
                            .font(.system(size: 11)).tracking(1.1).foregroundStyle(HakoStyle.muted)
                    }
                    .padding(.bottom, 23)
                    categoryTabs
                    applications
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
            }
            .background(HakoStyle.background)
            .foregroundStyle(HakoStyle.text)
            .navigationTitle("Hako")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HakoStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Hako").font(.system(size: 26, weight: .bold)).tracking(-1)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { NotificationsView(store: notifications) } label: {
                        if notifications.notifications.isEmpty {
                            Image(systemName: "bell")
                        } else {
                            Image(systemName: "bell.badge")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.red, .primary)
                        }
                    }.accessibilityLabel("通知，\(notifications.notifications.count) 条待处理")
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
                }
            }
        }.tint(.primary)
            .onOpenURL { url in
                // Accept only the existing exact Hako login structure and configured HTTPS server.
                guard let _ = try? ConsoleWebLoginPayload(url.absoluteString, origin: ConsoleClient.shared.serverURL) else { return }
                loginLink = HakoLoginLink(payload: url.absoluteString)
            }
            .sheet(item: $loginLink) { link in ConsoleWebLoginView(initialPayload: link.payload) }
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                HakoLog.record(.hako, "应用进入前台")
                await ConsoleClient.shared.restore()
            }
            .task(id: "\(scenePhase)-\(console.requestContext)") {
                guard scenePhase == .active, console.authenticated, !console.logoutPending else { return }
                await notifications.run()
            }
    }

    private var categoryTabs: some View {
        HStack(spacing: 25) {
            ForEach(Category.allCases, id: \.self) { option in
                Button { category = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 14, weight: category == option ? .semibold : .regular))
                        .foregroundStyle(category == option ? HakoStyle.text : HakoStyle.muted)
                        .padding(.horizontal, 1).frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(category == option ? HakoStyle.text : .clear).frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == option ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Rectangle().fill(HakoStyle.line).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("子应用分类")
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(category.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(HakoStyle.text)
                Spacer()
                Text("\(category.applications.count) 个应用").font(.system(size: 12))
            }
            .foregroundStyle(HakoStyle.muted)
            .padding(.top, 20)

            if category.applications.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "building.columns")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(HakoStyle.muted)
                        .padding(.bottom, 6).accessibilityHidden(true)
                    Text("暂无金融应用").font(.system(size: 17, weight: .semibold))
                    Text("后续金融应用将收录在这里。")
                        .font(.system(size: 13)).foregroundStyle(HakoStyle.muted)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 75)
            } else {
                VStack(spacing: 0) {
                    ForEach(category.applications) { app in
                        if app != category.applications.first {
                            Rectangle().fill(HakoStyle.line).frame(height: 1).accessibilityHidden(true)
                        }
                        NavigationLink { app.destination } label: {
                            applicationRow(app)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func applicationRow(_ app: Application) -> some View {
        HStack(spacing: 13) {
            Group {
                if app == .qinglong {
                    Image("QinglongLogo").renderingMode(.template).resizable().scaledToFit()
                } else {
                    Image(systemName: app.symbol).font(.system(size: 22, weight: .regular))
                }
            }
            .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.rawValue).font(.system(size: 16, weight: .semibold))
                Text(app.subtitle).font(.system(size: 11)).foregroundStyle(HakoStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                .foregroundStyle(HakoStyle.muted.opacity(0.65)).accessibilityHidden(true)
        }
        .padding(.vertical, 19).frame(minHeight: 78).contentShape(Rectangle())
    }
}
