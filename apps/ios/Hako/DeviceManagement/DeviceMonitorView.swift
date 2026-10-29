import SwiftUI

struct DeviceMonitorView: View {
    private enum SheetRoute: String, Identifiable {
        case addAgent, server
        var id: String { rawValue }
    }
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: SheetRoute?
    @State private var isVisible = false

    var body: some View {
        List {
            if client.serverURL.isEmpty {
                Section {
                    ContentUnavailableView("尚未配置服务器", systemImage: "server.rack", description: Text("可在 Hako 设置的“服务器与登录”中先导出本机公钥，再填写服务器地址和账号。"))
                    Button("配置服务器") { sheet = .server }
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
                                    HStack(spacing: 10) {
                                        Text("设备 ID：" + agent.id)
                                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(agent.online ? "在线" : "离线")
                                            .font(.caption).foregroundStyle(agent.online ? Color.green : Color.secondary)
                                            .fixedSize()
                                    }
                                }
                            }.padding(.vertical, 5)
                        }
                        .disabled(!agent.online)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                }
                Section {
                    Button { sheet = .addAgent } label: { Label("添加 Agent", systemImage: "plus") }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Button { sheet = .server } label: {
                        Label("服务器与登录", systemImage: "server.rack")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }.disabled(client.busy)
            } else if client.hasSavedSession {
                Section {
                    Text(client.busy ? "正在验证已保存的登录凭据…" : "已保存本机登录凭据，暂未完成服务端验证。请检查网络后重试。")
                        .foregroundStyle(.secondary)
                    Button("验证并继续") { Task { await refreshDevices() } }
                    Button("服务器与登录") { sheet = .server }
                }.disabled(client.busy)
            } else {
                Section("服务器连接") {
                    LabeledContent("账号", value: client.username)
                    Text(client.logoutPending ? "本机已退出，等待联网后撤销服务端会话。可在 Hako 设置的“服务器与登录”中重试。" : "在 Hako 设置的“服务器与登录”中导出本机公钥，手工登记到服务端后登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("服务器与登录") { sheet = .server }
                }
            }
            if let message = client.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("设备监控")
        .refreshable { await refreshDevices() }
        .sheet(item: $sheet) { route in
            switch route {
            case .addAgent: AddAgentSheet()
            case .server: ServerSettingsView()
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: "\(isVisible)-\(scenePhase)-\(sheet?.rawValue ?? "none")") {
            guard isVisible, scenePhase == .active, sheet == nil, !Task.isCancelled else { return }
            await client.restore()
            if client.authenticated { await refreshDevices() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await refreshDevices()
            }
        }
    }

    @MainActor private func refreshDevices() async {
        guard !Task.isCancelled, !client.busy, !client.serverURL.isEmpty, !client.logoutPending else { return }
        if !client.authenticated, client.hasSavedSession { await client.restore() }
        if client.authenticated { await client.fetchAgents() }
    }
}

struct DeviceMetricsView: View {
    private enum DetailTab: String, CaseIterable { case query = "查询", action = "操作" }
    let agent: ConsoleAgent
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshButtonActive = false
    @State private var targetURL = ""
    @State private var selectedTab: DetailTab = .query
    @State private var expandedCapability: String? = "query.system.metrics"
    @State private var showingCodexNotes = false
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
                let visible = capabilities.filter { selectedTab == .query ? $0.name.hasPrefix("query.") : !$0.name.hasPrefix("query.") }
                Section {
                    if visible.isEmpty {
                        Text(selectedTab == .query ? "此设备暂无查询能力。" : "此设备暂无操作能力。").foregroundStyle(.secondary)
                    }
                    ForEach(visible) { capability in
                        DisclosureGroup(isExpanded: expansion(for: capability.name)) {
                            if capability.name == "query.system.metrics" && capability.version == 1 {
                                metricsContent(capability)
                            } else if capability.name == "query.codex.usage" && capability.version == 1 {
                                codexContent(capability)
                            } else if capability.name == "action.network.http.check" && capability.version == 1 {
                                httpContent
                            } else {
                                if capability.name.hasPrefix("query.") {
                                    queryStatus(capability)
                                    if let entry = state.entries[capability.name], entry.version == capability.version,
                                       let value = entry.result {
                                        Text(value.formatted).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                } else { Text("当前客户端暂不支持此操作或版本。").foregroundStyle(.secondary) }
                            }
                        } label: {
                            Text(capabilityTitle(capability)).foregroundStyle(.primary)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                }
            } else {
                Section("设备能力") {
                    Text("尚未获取设备能力，请刷新数据。").foregroundStyle(.secondary)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Picker("设备详情", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
        .onChange(of: selectedTab) { _, _ in expandedCapability = nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !refreshButtonActive else { return }
                    refreshButtonActive = true
                    Task { await refreshFromButton() }
                } label: {
                    MonitorRefreshIcon(isRefreshing: state.loading || refreshButtonActive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新设备数据")
                .accessibilityValue(state.loading || refreshButtonActive ? "正在刷新" : "")
                .disabled(refreshButtonActive || state.loading || !client.authenticated || !canQuery)
            }
        }
        .refreshable { if client.authenticated { await client.query(currentAgent) } }
        .task { if client.authenticated { await client.query(currentAgent) } }
    }
    @MainActor private func refreshFromButton() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        defer { refreshButtonActive = false }
        await client.query(currentAgent)
        // Keep feedback visible for one turn without delaying the query or its results.
        if !reduceMotion {
            let remaining = Duration.milliseconds(800) - startedAt.duration(to: clock.now)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
    }
    private func expansion(for name: String) -> Binding<Bool> {
        Binding(get: { expandedCapability == name }, set: { expanded in
            withAnimation(.easeInOut(duration: 0.2)) {
                if expanded { expandedCapability = name }
                else if expandedCapability == name { expandedCapability = nil }
            }
        })
    }
    private func capabilityTitle(_ capability: ConsoleAgentCapability) -> String {
        switch (capability.name, capability.version) {
        case ("query.system.metrics", 1): return "系统指标"
        case ("query.codex.usage", 1): return "Codex"
        case ("action.network.http.check", 1): return "URL 连通性检测"
        default: return capability.name + " · v\(capability.version)"
        }
    }
    @ViewBuilder private func queryStatus(_ capability: ConsoleAgentCapability) -> some View {
        if let entry = state.entries[capability.name] {
            if let error = entry.error { Text(error.localizedDescription).font(.footnote).foregroundStyle(.red) }
            else if entry.version != capability.version { Text("返回的数据版本与能力清单不一致。").foregroundStyle(.red) }
        } else if state.loaded {
            Text("未返回数据").foregroundStyle(.secondary)
        } else { Text("等待查询数据").foregroundStyle(.secondary) }
    }
    private func metricsContent(_ capability: ConsoleAgentCapability) -> some View {
        let entry = state.entries[capability.name]
        let decoded = entry?.version == 1 ? entry?.result?.decode(ConsoleMetrics.self) : nil
        let metrics = decoded?.isValid == true ? decoded : nil
        return Group {
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
    private var httpContent: some View {
        Group {
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
    @ViewBuilder private func codexContent(_ capability: ConsoleAgentCapability) -> some View {
        let entry = state.entries[capability.name]
        let decoded = entry?.version == 1 ? entry?.result?.decode(ConsoleCodexUsage.self) : nil
        let usage = decoded?.isValid == true ? decoded : nil
        queryStatus(capability)
        if let usage {
            runningSessionsContent(usage).listRowSeparator(.hidden)
            Text("最近 7 天").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            CodexUsageChart(usage: usage).listRowSeparator(.hidden)
            if !usage.available { Text("未检测到本机 Codex 日志，显示的是此前采集的数据。").font(.footnote).foregroundStyle(.secondary) }
            DisclosureGroup(isExpanded: $showingCodexNotes) {
                ForEach(Array(usage.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(codexWarning(warning)).font(.footnote).foregroundStyle(.orange)
                }
                Text("采集于 \(sampleTime(usage.collectedAt))").font(.footnote).foregroundStyle(.secondary)
                Text("设备时区：\(usage.timeZone)").font(.footnote).foregroundStyle(.secondary)
                Text("每次发送任务或消息计 1 次调用，不累计内部多轮模型调用。Token 总量含缓存输入与推理输出。设备每分钟采集，刷新可读取最新统计。")
                    .font(.footnote).foregroundStyle(.secondary)
            } label: {
                HStack {
                    Text("数据说明")
                    Spacer()
                    if !usage.warnings.isEmpty {
                        Text("\(usage.warnings.count) 条提示").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } else if entry?.result != nil && entry?.error == nil && entry?.version == 1 {
            Text("设备返回的 Codex 统计格式无效。").font(.footnote).foregroundStyle(.red)
        }
    }
    private func runningSessionsContent(_ usage: ConsoleCodexUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("处理中会话").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(usage.runningSessions.map { "\($0) 个" } ?? "—")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Spacer()
            }
            if let sessions = usage.runningSessionDetails, !sessions.isEmpty {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(session.projectName)
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        Text(session.title)
                            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            } else if usage.runningSessions == 0 {
                Text("暂无处理中会话").font(.footnote).foregroundStyle(.secondary)
            } else if let count = usage.runningSessions, count > 0 {
                Text("此 Agent 未提供会话信息，更新后可查看项目与标题。").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("当前会话状态暂不可用").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
    private func codexWarning(_ warning: String) -> String {
        switch warning {
        case "部分旧版 token 用量来自日志更新记录，可能不完整。":
            return "部分历史 Token 记录可能缺失，统计值可能低于实际消耗。"
        case "部分旧版记录只有 token 总量，输入/输出明细不完整。":
            return "部分历史记录仅有 Token 总量，已记录的总量仍会展示，但无法准确拆分输入与输出。"
        default: return warning
        }
    }
    private func sampleTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .numeric, time: .standard) ?? value
    }
}

private struct MonitorRefreshIcon: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationStartedAt = Date.now
    private var isRotating: Bool { isRefreshing && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRotating)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(rotationStartedAt))
            let degrees = isRotating ? elapsed.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360 : 0
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(degrees))
                .frame(width: 32, height: 32)
        }
        .onChange(of: isRotating) { _, rotating in
            if rotating { rotationStartedAt = .now }
        }
    }
}
