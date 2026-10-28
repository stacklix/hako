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
                                    Text(agent.online ? "在线" : "离线").font(.caption).foregroundStyle(agent.online ? Color.green : Color.secondary)
                                    Text("设备 ID：" + agent.id)
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.vertical, 5)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                }
                Section {
                    Button { addingAgent = true } label: { Label("添加 Agent", systemImage: "plus") }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { ConsoleWebLoginView() } label: {
                        Label("扫码登录", systemImage: "qrcode.viewfinder")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
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
    @State private var targetURL = ""
    private var currentAgent: ConsoleAgent { client.agents.first { $0.id == agent.id } ?? agent }
    private var state: ConsoleDeviceData { client.deviceData[agent.id] ?? ConsoleDeviceData() }
    private var check: ConsoleHTTPCheckState { client.httpChecks[agent.id] ?? ConsoleHTTPCheckState() }
    private var canQuery: Bool { currentAgent.capabilities?.contains { $0.name.hasPrefix("query.") } ?? true }
    var body: some View {
        List {
            Section {
                LabeledContent("设备", value: currentAgent.name)
                LabeledContent("设备 ID") {
                    Text(currentAgent.id).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let capabilities = currentAgent.capabilities {
                if capabilities.isEmpty { Section { Text("此设备尚未提供能力。").foregroundStyle(.secondary) } }
                ForEach(capabilities) { capability in
                    if capability.name == "query.system.metrics" && capability.version == 1 {
                        metricsSection(capability)
                    } else if capability.name == "action.network.http.check" && capability.version == 1 {
                        httpSection
                    } else {
                        Section(capability.name + " · v\(capability.version)") {
                            if capability.name.hasPrefix("query.") {
                                queryStatus(capability)
                                if let entry = state.entries[capability.name], entry.version == capability.version,
                                   let value = entry.result {
                                    Text(value.formatted).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            } else { Text("当前客户端暂不支持此操作或版本。").foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                Section("设备能力") {
                    if state.loading { ProgressView("正在获取能力与数据…") }
                    else { Text("尚未获取设备能力，请刷新数据。").foregroundStyle(.secondary) }
                }
            }
            if let error = state.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if state.loaded { Text("当前显示上次查询结果，尚未刷新成功。").foregroundStyle(.secondary) }
                }.font(.footnote)
            }
        }
        .navigationTitle("设备监控")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await client.query(currentAgent) } } label: {
                    Label("刷新设备数据", systemImage: "arrow.clockwise")
                }.disabled(state.loading || !client.authenticated || !canQuery)
            }
        }
        .refreshable { if client.authenticated { await client.query(currentAgent) } }
        .task { if client.authenticated { await client.query(currentAgent) } }
    }
    @ViewBuilder private func queryStatus(_ capability: ConsoleAgentCapability) -> some View {
        if state.loading { ProgressView("正在查询…") }
        if let entry = state.entries[capability.name] {
            if let error = entry.error { Text(error.localizedDescription).font(.footnote).foregroundStyle(.red) }
            else if entry.version != capability.version { Text("返回的数据版本与能力清单不一致。").foregroundStyle(.red) }
        } else if state.loaded && !state.loading {
            Text("未返回数据").foregroundStyle(.secondary)
        } else if !state.loading { Text("等待查询数据").foregroundStyle(.secondary) }
    }
    private func metricsSection(_ capability: ConsoleAgentCapability) -> some View {
        let entry = state.entries[capability.name]
        let decoded = entry?.version == 1 ? entry?.result?.decode(ConsoleMetrics.self) : nil
        let metrics = decoded?.isValid == true ? decoded : nil
        return Section("系统指标") {
            queryStatus(capability)
            LabeledContent("CPU 使用率", value: metrics.map { String(format: "%.1f%%", $0.cpuUsagePercent) } ?? "—")
            ProgressView(value: metrics?.cpuUsagePercent ?? 0, total: 100).opacity(metrics == nil ? 0.3 : 1)
            LabeledContent("内存使用率", value: metrics.map { String(format: "%.1f%%", $0.memoryUsagePercent) } ?? "—")
            ProgressView(value: metrics?.memoryUsagePercent ?? 0, total: 100).opacity(metrics == nil ? 0.3 : 1)
            LabeledContent("已用 / 总内存", value: metrics.map { String(format: "%.1f / %.1f GiB", Double($0.memoryUsedBytes)/1_073_741_824, Double($0.memoryTotalBytes)/1_073_741_824) } ?? "—")
            LabeledContent("采样时间", value: metrics.map { sampleTime($0.sampledAt) } ?? "—")
            LabeledContent("采样窗口", value: metrics.map { "\($0.sampleWindowMs) ms" } ?? "—")
            if entry?.result != nil && metrics == nil && entry?.error == nil && entry?.version == 1 {
                Text("设备返回的系统指标格式无效。").font(.footnote).foregroundStyle(.red)
            }
        }
    }
    private var httpSection: some View {
        Section("URL 连通性检测") {
            TextField("https://example.com", text: $targetURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button { Task { await client.checkHTTP(currentAgent, url: targetURL) } } label: {
                Label("检测", systemImage: "network")
            }.disabled(check.loading || !client.authenticated || targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if check.loading { ProgressView("正在从设备检测…") }
            if let error = check.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                if check.result != nil { Text("以下为上次检测结果。").font(.footnote).foregroundStyle(.secondary) }
            }
            if let result = check.result {
                LabeledContent("地址", value: result.url).textSelection(.enabled)
                LabeledContent("连通状态", value: result.reachable ? "地址可达" : "未获得 HTTP 响应")
                LabeledContent("请求结果", value: result.httpSuccess ? "成功" : result.reachable ? "目标返回非 2xx 状态" : "检测失败")
                LabeledContent("HTTP 状态", value: result.statusCode.map(String.init) ?? "—")
                LabeledContent("耗时", value: "\(result.elapsedMs) ms")
                LabeledContent("检测时间", value: sampleTime(result.checkedAt))
                if let failure = result.failure { Text(failure.localizedDescription).font(.footnote).foregroundStyle(.red) }
            } else if !check.loading { Text("输入 URL 后点击检测，由此设备发起访问。").font(.footnote).foregroundStyle(.secondary) }
        }
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
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
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
