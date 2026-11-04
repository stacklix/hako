import SwiftUI

@main struct HakoApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    @ObservedObject private var console = ConsoleClient.shared
    @StateObject private var notifications = HakoNotificationsStore()
    @State private var loginLink: HakoLoginLink?
    private struct HakoLoginLink: Identifiable { let id = UUID(); let payload: String }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HakoMark()
                            .stroke(.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            .frame(width: 86, height: 100)
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                        Text("你的日常，收进一个盒子。").font(.title3.bold())
                        Text("HAKO · 个人工具箱").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section("应用") {
                    NavigationLink { HeadplaneView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("组网管理").font(.headline)
                            Text("Headplane · 设备 · 路由与访问控制").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "network").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { QinglongView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("青龙面板").font(.headline)
                            Text("定时任务 · 脚本 · 订阅管理").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: {
                            Image("QinglongLogo").renderingMode(.template)
                                .resizable().scaledToFit().frame(width: 28, height: 28)
                                .foregroundStyle(.primary).accessibilityHidden(true)
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { CloudServersView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("云服务器").font(.headline)
                            Text("阿里云 ECS · 监控 · 进程与终端").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "server.rack").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { ContainersView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("容器管理").font(.headline)
                            Text("Arcane · 容器状态 · 日志与更新").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "shippingbox").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { DeviceMonitorView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("设备监控").font(.headline)
                            Text("设备在线状态 · 能力调用").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "desktopcomputer").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { SportsView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("运动记录").font(.headline)
                            Text("运动趋势 · 每次记录 · GitHub 归档").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "figure.run").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { UsageEntry() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("使用时间").font(.headline)
                            Text("每日概览 · Top 5 · GitHub 归档").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "chart.bar.xaxis").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                Section("工具") {
                    NavigationLink { HakoLogsView() } label: {
                        Label("日志", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationTitle("Hako")
            .toolbar {
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
}
