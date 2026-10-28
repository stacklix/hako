import SwiftUI

struct DeviceMonitorView: View {
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var addingAgent = false

    var body: some View {
        List {
            if client.serverURL.isEmpty {
                Section {
                    ContentUnavailableView("尚未配置服务器", systemImage: "server.rack", description: Text("可在设备监控设置中先导出本机公钥，再填写服务器地址和账号。"))
                    NavigationLink("配置服务器") { DeviceMonitorSettingsView() }
                }
            } else if client.authenticated {
                Section("设备") {
                    if client.agents.isEmpty { Text("暂无登记的设备，点击“添加 Agent”登记设备公钥。").foregroundStyle(.secondary) }
                    ForEach(client.agents) { agent in
                        NavigationLink { DeviceMetricsView(agent: agent) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(agent.name)
                                    Text(agent.online ? "在线 · Windows" : "离线 · Windows").font(.caption).foregroundStyle(agent.online ? Color.green : Color.secondary)
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section {
                    Button { addingAgent = true } label: { Label("添加 Agent", systemImage: "plus") }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink("扫码登录") { ConsoleWebLoginView() }
                }.disabled(client.busy)
            } else if client.hasSavedSession {
                Section {
                    Text("已保存本机登录凭据，等待服务端验证。网络恢复后可继续使用。").foregroundStyle(.secondary)
                    Button("验证并继续") { Task { await client.restore() } }
                }.disabled(client.busy)
            } else {
                Section("服务器连接") {
                    LabeledContent("账号", value: client.username)
                    Text(client.logoutPending ? "本机已退出，等待联网后撤销服务端会话。可在设备监控设置中重试。" : "在设备监控设置中导出本机公钥，手工登记到服务端后登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("设置与登录") { DeviceMonitorSettingsView() }
                }
            }
            if client.busy { Section { ProgressView("正在处理…") } }
            if let message = client.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("设备监控")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await refreshDevices() }
                } label: {
                    Label("刷新设备列表", systemImage: "arrow.clockwise")
                }
                .disabled(client.busy || client.logoutPending || (!client.authenticated && !client.hasSavedSession))
                NavigationLink { DeviceMonitorSettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("设备监控设置")
            }
        }
        .refreshable { await refreshDevices() }
        .sheet(isPresented: $addingAgent) { AddAgentSheet() }
        .task { await client.restore() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await client.restore() } } }
    }

    @MainActor private func refreshDevices() async {
        guard !client.serverURL.isEmpty, !client.logoutPending else { return }
        if client.authenticated { await client.fetchAgents() }
        else if client.hasSavedSession { await client.restore() }
    }
}

struct DeviceMetricsView: View {
    let agent: ConsoleAgent
    @ObservedObject private var client = ConsoleClient.shared
    private var currentAgent: ConsoleAgent { client.agents.first { $0.id == agent.id } ?? agent }
    private var canQuery: Bool { currentAgent.online && currentAgent.methods.contains { $0.name == "system.metrics" && $0.version == 1 } }
    var body: some View {
        List {
            Section {
                LabeledContent("设备", value: agent.name)
                if !currentAgent.online { Text("设备当前离线。").foregroundStyle(.secondary) }
                else if !canQuery { Text("设备未提供支持的系统指标采集动作。").foregroundStyle(.secondary) }
            }
            if let metrics = client.metrics[agent.id] {
                Section("CPU") {
                    LabeledContent("使用率", value: String(format: "%.1f%%", metrics.cpuUsagePercent))
                    ProgressView(value: metrics.cpuUsagePercent, total: 100)
                }
                Section("物理内存") {
                    LabeledContent("使用率", value: String(format: "%.1f%%", metrics.memoryUsagePercent))
                    ProgressView(value: metrics.memoryUsagePercent, total: 100)
                    LabeledContent("已用 / 总量", value: String(format: "%.1f / %.1f GiB", Double(metrics.memoryUsedBytes)/1_073_741_824, Double(metrics.memoryTotalBytes)/1_073_741_824))
                }
                Section {
                    Text("采样于 \(sampleTime(metrics.sampledAt))")
                    Text("采样窗口 \(metrics.sampleWindowMs) ms")
                }.font(.footnote).foregroundStyle(.secondary)
            } else if !client.busy {
                ContentUnavailableView("尚无本次采样结果", systemImage: "chart.bar", description: Text("查询会通过服务端转发到电脑，不持续上传历史数据。"))
            }
            if client.busy { ProgressView("正在查询设备…") }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("设备监控")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await client.query(currentAgent) }
                } label: {
                    Label("刷新设备数据", systemImage: "arrow.clockwise")
                }
                .disabled(client.busy || !client.authenticated)
            }
        }
        .refreshable { if client.authenticated { await client.query(currentAgent) } }
        .task { if client.authenticated { await client.query(currentAgent) } }
    }
    private func sampleTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .numeric, time: .standard) ?? value
    }
}

struct ConsoleSessionsView: View {
    @ObservedObject private var client = ConsoleClient.shared
    var body: some View {
        List {
            ForEach(client.remoteSessions) { session in
                VStack(alignment: .leading, spacing: 8) {
                    Label(session.type == .web ? "网页管理端 · \(session.browser ?? "网页浏览器")" : session.current ? "当前 iPhone" : "管理客户端",
                          systemImage: session.type == .web ? "globe" : "iphone")
                    if let deviceId = session.deviceId {
                        Text(deviceId).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("登录时间：\(sessionTime(session.createdAt))").font(.caption).foregroundStyle(.secondary)
                    if let lastUsedAt = session.lastUsedAt {
                        Text("最近活动：\(sessionTime(lastUsedAt))").font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.current {
                        Button(session.type == .web ? "移除网页登录" : "撤销此设备的登录", role: .destructive) {
                            Task { await client.revoke(session) }
                        }.disabled(client.busy)
                    }
                }.padding(.vertical, 5)
            }
            if client.busy { ProgressView() }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("已登录设备")
            .task { await client.fetchSessions() }
            .refreshable { await client.fetchSessions() }
    }
    private func sessionTime(_ value: String) -> String {
        ISO8601DateFormatter().date(from: value)?.formatted(date: .numeric, time: .shortened) ?? value
    }
}
