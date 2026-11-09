import SwiftUI

struct DeviceMonitorView: View {
    private enum SheetRoute: String, Identifiable {
        case addAgent, server
        var id: String { rawValue }
    }
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: SheetRoute?
    @State private var isVisible = false

    var body: some View {
        List {
            if client.serverURL.isEmpty {
                Section {
                    ContentUnavailableView("尚未配置服务器", systemImage: "server.rack", description: Text("点击右上角设置，在“服务器与登录”中导出本机公钥并填写连接信息。"))
                }
            } else if client.authenticated {
                Section {
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
                    if client.agents.isEmpty {
                        Button { sheet = .addAgent } label: { Label("添加 Agent", systemImage: "plus") }
                            .disabled(client.busy)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                } header: {
                    HStack {
                        Text("设备")
                        Spacer()
                        if !client.agents.isEmpty {
                            Button { sheet = .addAgent } label: {
                                Image(systemName: "plus").font(.body.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain).foregroundStyle(.primary)
                            .accessibilityLabel("添加 Agent").disabled(client.busy)
                        }
                    }
                }
            } else if client.hasSavedSession {
                Section {
                    Text(client.busy ? "正在验证已保存的登录凭据…" : "已保存本机登录凭据，暂未完成服务端验证。请检查网络后重试。")
                        .foregroundStyle(.secondary)
                    Button("验证并继续") { Task { await refreshDevices() } }
                    Text("可在右上角设置中检查服务器与登录。").font(.footnote).foregroundStyle(.secondary)
                }.disabled(client.busy)
            } else {
                Section("服务器连接") {
                    LabeledContent("账号", value: client.username)
                    Text(client.logoutPending ? "本机已退出，等待联网后撤销服务端会话。可在右上角设置的“服务器与登录”中重试。" : "在右上角设置的“服务器与登录”中导出本机公钥，手工登记到服务端后登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let message = client.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("设备监控")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .server } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("服务器与登录设置")
            }
        }
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
    private enum CodexTab: String, CaseIterable { case sessions = "处理中会话", usage = "最近 7 天" }
    let agent: ConsoleAgent
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var liveContext: String?
    @State private var liveStatus: String?
    @State private var targetURL = ""
    @State private var codexTab: CodexTab = .sessions
    @State private var listenerTab: ConsoleListenerGroup = .user
    @State private var showingCodexNotes = false
    private var currentAgent: ConsoleAgent { client.agents.first { $0.id == agent.id } ?? agent }
    private var state: ConsoleDeviceData { client.deviceData[agent.id] ?? ConsoleDeviceData() }
    private var check: ConsoleHTTPCheckState { client.httpChecks[agent.id] ?? ConsoleHTTPCheckState() }
    private var liveTaskContext: String? {
        guard scenePhase == .active, client.authenticated, !client.logoutPending,
              liveContext == client.requestContext else { return nil }
        return liveContext
    }
    private func orderKey(_ group: String) -> String {
        DeviceCardOrder.storageKey(server: client.serverURL, account: client.username, agent: agent.id,
                                  group: group)
    }
    private var initialOrder: [String] {
        ["query", "action"].flatMap { group in
            guard let data = UserDefaults.standard.data(forKey: orderKey(group)),
                  let names = try? JSONDecoder().decode([String].self, from: data) else { return [String]() }
            return names
        }
    }
    var body: some View {
        DeviceCapabilityPages(capabilities: (currentAgent.capabilities ?? []).filter {
                $0.name != "action.xkode.tasks.manage" && !DeviceGitCommand.supporting.contains($0.name)
            },
            storageKey: orderKey("all"),
            emptyMessage: currentAgent.capabilities == nil ? "尚未获取设备能力，请刷新数据。" : "此设备暂无可用能力。",
            initialOrder: initialOrder, title: capabilityTitle, tabTitle: capabilityTabTitle) {
            deviceOverview
        } content: { capability in
            if capability.name == "query.system.metrics", capability.version == 1 {
                metricsContent(capability)
            } else if capability.name == DeviceGitCommand.list, capability.version == 1 {
                DeviceGitRepositoriesView(agent: currentAgent,
                    cacheFile: DeviceGitInventory.cacheFile(server: client.serverURL, account: client.username, agent: currentAgent.id))
                    .id(client.requestContext)
            } else {
                VStack(alignment: .leading, spacing: 14) { capabilityContent(capability) }
                    .devicePagePanel()
            }
        }
        .id(orderKey("all"))
        .refreshable { if client.authenticated { await client.query(currentAgent) } }
        .navigationTitle("设备详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HakoStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { if client.authenticated { await client.query(currentAgent) } }
        .task(id: liveTaskContext) {
            if let context = liveTaskContext { await refreshLive(context: context) }
        }
        .onChange(of: client.requestContext) { _, _ in
            liveContext = nil
            liveStatus = nil
        }
    }
    private var deviceOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentAgent.name).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("设备 ID · \(currentAgent.id)").font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Label(currentAgent.online ? "在线" : "离线", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(currentAgent.online ? Color.green : Color.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background((currentAgent.online ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
                        .fixedSize()
                    Button {
                        liveContext = liveContext == nil ? client.requestContext : nil
                        liveStatus = nil
                    } label: {
                        Label("实时刷新", systemImage: liveContext == nil ? "square" : "checkmark.square.fill")
                            .font(.caption)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!client.authenticated || client.logoutPending)
                    .accessibilityAddTraits(liveContext == nil ? [] : .isSelected)
                    .accessibilityValue(liveContext == nil ? "关闭" : "开启")
                }
            }
            if let liveStatus { Text(liveStatus).font(.caption).foregroundStyle(.secondary) }
            if let error = state.error {
                statusMessage(state.loaded ? "刷新失败 · 保留上次数据" : "无法获取设备数据", detail: error)
            }
        }
    }

    private func refreshLive(context: String) async {
        var retry = 1
        while !Task.isCancelled, context == liveTaskContext {
            do {
                try await client.watchLive(currentAgent) {
                    liveStatus = nil
                    retry = 1
                }
            } catch {
                guard !Task.isCancelled, context == liveTaskContext else { return }
                if let failure = error as? ServerHTTPError {
                    switch failure.code {
                    case "socket_unavailable":
                        liveContext = nil
                        liveStatus = "服务端暂不支持实时刷新，请更新服务端。"
                        return
                    case "agent_offline", "agent_disconnected":
                        liveStatus = "等待设备重新连接…"
                    default:
                        liveStatus = "实时连接中断，正在重连…"
                    }
                } else {
                    liveStatus = "实时连接中断，正在重连…"
                }
            }
            do { try await Task.sleep(for: .seconds(retry)) }
            catch { return }
            retry = min(retry * 2, 15)
        }
    }
    private func statusMessage(_ title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    private func metrics(for capability: ConsoleAgentCapability) -> ConsoleMetrics? {
        guard let entry = state.entries[capability.name], entry.version == capability.version,
              entry.error == nil, let value = entry.result?.decode(ConsoleMetrics.self), value.isValid else { return nil }
        return value
    }
    private func codexUsage(for capability: ConsoleAgentCapability) -> ConsoleCodexUsage? {
        guard let entry = state.entries[capability.name], entry.version == capability.version,
              entry.error == nil, let value = entry.result?.decode(ConsoleCodexUsage.self), value.isValid else { return nil }
        return value
    }
    private func capabilityTabTitle(_ capability: ConsoleAgentCapability) -> String {
        switch (capability.name, capability.version) {
        case ("query.system.metrics", 1): return "系统"
        case ("query.codex.usage", 1): return "Codex"
        case ("query.network.listeners", 1): return "端口"
        case ("action.network.http.check", 1): return "检测"
        case (DeviceGitCommand.list, 1): return "Git"
        default: return capability.name.split(separator: ".").last.map(String.init) ?? capability.name
        }
    }
    @ViewBuilder private func capabilityContent(_ capability: ConsoleAgentCapability) -> some View {
        switch (capability.name, capability.version) {
        case ("query.codex.usage", 1): codexContent(capability)
        case ("query.network.listeners", 1): listenersContent(capability)
        case ("action.network.http.check", 1): httpContent
        default:
            if capability.name.hasPrefix("query.") {
                queryStatus(capability)
                if let entry = state.entries[capability.name], entry.version == capability.version, let value = entry.result {
                    ScrollView(.horizontal) {
                        Text(value.formatted).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else { Text("当前客户端暂不支持此操作或版本。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func capabilityTitle(_ capability: ConsoleAgentCapability) -> String {
        switch (capability.name, capability.version) {
        case ("query.system.metrics", 1): return "系统指标"
        case ("query.codex.usage", 1): return "Codex 活动"
        case ("query.network.listeners", 1): return "监听端口"
        case ("action.network.http.check", 1): return "URL 连通性检测"
        case (DeviceGitCommand.list, 1): return "Git 仓库"
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
    private func listeners(for capability: ConsoleAgentCapability) -> ConsoleListenerSnapshot? {
        guard let entry = state.entries[capability.name], entry.version == capability.version,
              entry.error == nil, let value = entry.result?.decode(ConsoleListenerSnapshot.self), value.isValid else { return nil }
        return value
    }
    @ViewBuilder private func listenersContent(_ capability: ConsoleAgentCapability) -> some View {
        queryStatus(capability)
        if let snapshot = listeners(for: capability) {
            HakoUnderlineTabs(title: "监听端口分类", options: ConsoleListenerGroup.allCases, selection: $listenerTab) {
                "\($0.rawValue) (\(snapshot.ports(in: $0).count))"
            }
            Text("Windows 自带程序归系统，第三方程序及其后台服务归用户。")
                .font(.caption).foregroundStyle(.secondary)
            Text("同协议同端口的 IPv4 / IPv6 地址已合并，展开端口查看进程和监听 IP。UDP 显示绑定端口。")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.hasUnclassifiedProcesses {
                Text("部分进程未提供分类，暂列于用户页签；旧版 Agent 请更新后刷新。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if snapshot.ports(in: listenerTab).isEmpty {
                Text("暂无\(listenerTab.rawValue)监听端口").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(snapshot.ports(in: listenerTab)) { port in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(port.processes) { process in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(process.displayName).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                                LabeledContent("PID", value: "\(process.processId)")
                                if let launch = process.launch {
                                    LabeledContent("启动方式", value: launch.title)
                                    if let target = launch.target {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(launch.kind == "script" ? "脚本路径" : "模块名称").foregroundStyle(.secondary)
                                            Text(target).font(.footnote.monospaced()).textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    if launch.kind == "unavailable" {
                                        Text("无法读取启动信息，可能是权限受限或进程已退出。")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if process.category == nil { Text("分类暂不可用").foregroundStyle(.orange) }
                                LabeledContent("启动时间", value: process.startedAt.map(sampleTime) ?? "暂不可用")
                                LabeledContent("运行时长", value: process.formattedUptime)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("监听 IP").foregroundStyle(.secondary)
                                    Text(process.addresses.joined(separator: "\n")).font(.footnote.monospaced()).textSelection(.enabled)
                                }
                            }.font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(port.protocol) \(port.port)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text(port.processes.map(\.displayName).joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
            }
            ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.footnote).foregroundStyle(.orange)
            }
            Text("采集于 \(sampleTime(snapshot.collectedAt)) · 运行时长为采集时的进程存活时间。")
                .font(.caption2).foregroundStyle(.secondary)
        } else if let entry = state.entries[capability.name], entry.result != nil, entry.error == nil, entry.version == 1 {
            Text("设备返回的监听端口格式无效。").font(.footnote).foregroundStyle(.red)
        }
    }
    private func metricsContent(_ capability: ConsoleAgentCapability) -> some View {
        let entry = state.entries[capability.name]
        let metrics = metrics(for: capability)
        return VStack(alignment: .leading, spacing: 10) {
            if entry != nil || state.loaded { queryStatus(capability) }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 18) { resourceMetrics(metrics) }
                    .devicePagePanel()
            } else {
                HStack(alignment: .top, spacing: 18) { resourceMetrics(metrics) }
                    .devicePagePanel()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("网卡实时速率").font(.subheadline.weight(.semibold))
                networkContent(metrics)
            }
            .devicePagePanel()
            VStack(alignment: .leading, spacing: 12) {
                Text("磁盘监控").font(.subheadline.weight(.semibold))
                diskContent(metrics)
            }
            .devicePagePanel()
            Text(metrics.map { "\(sampleTime($0.sampledAt)) 采样 · 窗口 \($0.sampleWindowMs) ms" } ?? "尚无采样信息")
                .font(.caption2).foregroundStyle(.secondary)
            if entry?.result != nil && metrics == nil && entry?.error == nil && entry?.version == 1 {
                Text("设备返回的系统指标格式无效。").font(.footnote).foregroundStyle(.red)
            }
        }
    }
    @ViewBuilder private func resourceMetrics(_ metrics: ConsoleMetrics?) -> some View {
        HakoUsageGauge(title: "CPU 使用率", percent: metrics?.cpuUsagePercent, color: .blue,
            detail: metrics.map { "采样窗口 \($0.sampleWindowMs) ms" } ?? "—")
        HakoUsageGauge(title: "内存使用率", percent: metrics?.memoryUsagePercent, color: .purple,
            detail: metrics.map { String(format: "%.1f / %.1f GiB", Double($0.memoryUsedBytes) / 1_073_741_824,
                                         Double($0.memoryTotalBytes) / 1_073_741_824) } ?? "已用 / 总容量")
    }
    @ViewBuilder private func networkContent(_ metrics: ConsoleMetrics?) -> some View {
        if let network = metrics?.network, network.isValid {
            if network.available {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 18) { networkRates(network) }
                } else {
                    HStack(alignment: .top, spacing: 18) { networkRates(network) }
                }
                Text("\(network.interfaceCount) 个物理网卡合计 · 含局域网流量")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label(network.message ?? "网络速率暂不可用，请下拉刷新。", systemImage: "network")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text(metrics == nil ? "等待网络采样数据" : metrics?.networkReported == true ? "设备返回的网络数据格式无效。" : "更新 Windows Agent 后可查看网络上下行速度。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func networkRates(_ network: ConsoleNetworkMetrics) -> some View {
        dataRate("下行", symbol: "arrow.down", value: network.downloadBytesPerSecond)
        dataRate("上行", symbol: "arrow.up", value: network.uploadBytesPerSecond)
    }
    @ViewBuilder private func diskContent(_ metrics: ConsoleMetrics?) -> some View {
        if let disk = metrics?.disk, disk.isValid {
            if disk.volumes.isEmpty {
                Text("磁盘容量暂不可用。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(disk.volumes) { volume in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(volume.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(String(format: "%.1f%%", volume.usagePercent)).font(.subheadline.monospacedDigit())
                    }
                    ProgressView(value: volume.usagePercent, total: 100)
                        .tint(.orange).accessibilityHidden(true)
                    Text(String(format: "已用 %.1f / %.1f GiB", Double(volume.usedBytes) / 1_073_741_824,
                                Double(volume.totalBytes) / 1_073_741_824))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            if disk.readBytesPerSecond != nil || disk.writeBytesPerSecond != nil {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                layout {
                    dataRate("读取", symbol: "arrow.down", value: disk.readBytesPerSecond)
                    dataRate("写入", symbol: "arrow.up", value: disk.writeBytesPerSecond)
                }
                Text("物理磁盘合计").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("磁盘读写速度暂不可用。").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text(metrics == nil ? "等待磁盘采样数据" : metrics?.diskReported == true ? "设备返回的磁盘数据格式无效。" : "更新 Windows Agent 后可查看磁盘监控。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func dataRate(_ title: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value.map(formatByteRate) ?? "—").font(.title3.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func formatByteRate(_ bytes: Double) -> String {
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
        var value = bytes
        var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
    private var httpContent: some View {
        Group {
            Text("目标地址").font(.subheadline.weight(.medium))
            TextField("https://example.com", text: $targetURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("检测目标 URL")
                .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            Text("由此设备访问目标地址，检测结果反映设备所在网络的连通情况。")
                .font(.caption).foregroundStyle(.secondary)
            Button { Task { await client.checkHTTP(currentAgent, url: targetURL) } } label: {
                HStack {
                    Spacer()
                    if check.loading { ProgressView().tint(Color(uiColor: .systemBackground)) }
                    Text(check.loading ? "正在检测…" : "开始检测")
                    Spacer()
                }.padding(.vertical, 4)
            }.disabled(check.loading || !client.authenticated || targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent).tint(.primary)
            if let error = check.error {
                statusMessage(check.result != nil ? "检测失败 · 以下为上次结果" : "检测失败", detail: error)
            }
            if let result = check.result {
                Divider()
                Label(result.reachable ? "地址可达" : "未获得 HTTP 响应",
                    systemImage: result.reachable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.headline).foregroundStyle(result.reachable ? Color.green : Color.orange)
                Text(result.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12) {
                    LabeledContent("HTTP 状态", value: result.statusCode.map(String.init) ?? "—")
                    LabeledContent("请求结果", value: result.httpSuccess ? "成功" : result.reachable ? "目标返回非 2xx 状态" : "检测失败")
                    LabeledContent("耗时", value: "\(result.elapsedMs) ms")
                }.font(.subheadline)
                Text("检测于 \(sampleTime(result.checkedAt))").font(.caption).foregroundStyle(.secondary)
                if let failure = result.failure { Text(failure.localizedDescription).font(.footnote).foregroundStyle(.red) }
            }
        }
    }
    @ViewBuilder private func codexContent(_ capability: ConsoleAgentCapability) -> some View {
        let entry = state.entries[capability.name]
        let usage = codexUsage(for: capability)
        queryStatus(capability)
        if let usage {
            HakoUnderlineTabs(title: "Codex 数据", options: CodexTab.allCases, selection: $codexTab) {
                $0.rawValue
            }
            if codexTab == .sessions { runningSessionsContent(usage) }
            else { CodexUsageChart(usage: usage) }
            if !usage.available { Text("未检测到本机 Codex 日志，显示的是此前采集的数据。").font(.footnote).foregroundStyle(.secondary) }
            DisclosureGroup(isExpanded: $showingCodexNotes) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(usage.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(codexWarning(warning)).font(.footnote).foregroundStyle(.orange)
                    }
                    Text("采集于 \(sampleTime(usage.collectedAt))").font(.footnote).foregroundStyle(.secondary)
                    Text("设备时区：\(usage.timeZone)").font(.footnote).foregroundStyle(.secondary)
                    Text("每次发送任务或消息计 1 次调用，不累计内部多轮模型调用。Token 总量含缓存输入与推理输出。开启实时刷新后，设备在任务状态变化时推送数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.top, 12)
            } label: {
                HStack {
                    Text("数据说明")
                    Spacer()
                    if !usage.warnings.isEmpty {
                        Text("\(usage.warnings.count) 条提示").font(.caption).foregroundStyle(.orange)
                    }
                }
            }.font(.subheadline)
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
