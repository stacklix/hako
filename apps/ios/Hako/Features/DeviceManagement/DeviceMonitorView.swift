import SwiftUI

struct DeviceMonitorView: View {
    private enum Selection {
        case automatic, device(String)
    }
    private enum Sheet: String, Identifiable {
        case addAgent, settings
        var id: String { rawValue }
    }

    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hako.deviceMonitor.lastAgents") private var savedLastAgents = Data()
    @State private var selection = Selection.automatic
    @State private var resolvedEntryScope: String?
    @State private var sheet: Sheet?
    @State private var addingAgentFromSettings = false
    @State private var editingAgents = false
    @State private var agentToEdit: ConsoleAgent?

    private var scope: String { client.serverURL + "\n" + client.username }
    private var lastAgentID: String? { DeviceAgentHistory.agentID(in: savedLastAgents, scope: scope) }
    private var requestedAgentID: String? {
        switch selection {
        case .automatic: lastAgentID
        case .device(let id): id
        }
    }
    private var selectedAgent: ConsoleAgent? {
        guard client.authenticated || client.hasSavedSession, !client.logoutPending else { return nil }
        return client.selectedAgent(id: requestedAgentID)
    }
    private var awaitingEntry: Bool {
        resolvedEntryScope != scope && !client.serverURL.isEmpty && !client.logoutPending
            && (requestedAgentID != nil || client.agents.isEmpty)
    }
    private func pageOrderStorage(for agent: ConsoleAgent) -> DeviceCardOrder.Storage {
        DeviceCardOrder.Storage(server: client.serverURL, account: client.username, agent: agent.id)
    }

    var body: some View {
        let showsDetail = selectedAgent != nil || (awaitingEntry && requestedAgentID != nil)
        Group {
            if let agent = selectedAgent {
                let order = pageOrderStorage(for: agent)
                DeviceMetricsView(agent: agent, order: order)
                    .id(order.key)
            } else if awaitingEntry {
                HakoStyle.background
                    .toolbarBackground(HakoStyle.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            } else {
                deviceList
            }
        }
        .navigationTitle(showsDetail ? "设备详情" : "设备管理")
        .navigationBarTitleDisplayMode(showsDetail ? .inline : .automatic)
        .toolbar {
            if client.authenticated, !client.logoutPending {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("设备管理设置")
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAgent:
                AddAgentSheet()
            case .settings:
                settings
            }
        }
        .onChange(of: scope) { _, _ in
            selection = .automatic
            resolvedEntryScope = nil
            sheet = nil
            editingAgents = false
            agentToEdit = nil
            addingAgentFromSettings = false
        }
        .onChange(of: sheet) { _, value in
            if value != .settings { editingAgents = false }
        }
        .task(id: "\(scenePhase)-\(sheet == .addAgent)-\(scope)") {
            guard scenePhase == .active, sheet != .addAgent, !Task.isCancelled else { return }
            let entryScope = scope
            await client.restore()
            guard !Task.isCancelled, scope == entryScope else { return }
            if client.authenticated { await refreshDevices() }
            while !Task.isCancelled, scope == entryScope {
                if resolvedEntryScope != entryScope, !client.busy {
                    resolvedEntryScope = entryScope
                }
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                await refreshDevices()
            }
        }
    }

    private var deviceList: some View {
        List {
            if client.serverURL.isEmpty {
                Section {
                    ContentUnavailableView("尚未配置服务器", systemImage: "server.rack", description: Text("请前往 Hako 首页的「设置 → 服务器与登录」，导出本机公钥并填写连接信息。"))
                }
            } else if (client.authenticated || client.hasSavedSession), !client.logoutPending {
                Section {
                    if client.agents.isEmpty {
                        if client.hasFetchedAgents {
                            Text("暂无登记的设备，点击“添加 Agent”登记设备公钥。").foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView("暂时无法获取设备", systemImage: "wifi.slash",
                                description: Text("请检查网络后重试，连接失败不会移除已登记的设备。"))
                            Button("重新连接") { Task { await refreshDevices() } }
                                .buttonStyle(HakoActionButtonStyle())
                                .disabled(client.busy)
                        }
                    }
                    ForEach(client.agents) { agent in
                        Button { openAgent(agent.id) } label: {
                            deviceRow(agent, current: false)
                        }
                        .buttonStyle(.plain)
                    }
                    if client.agents.isEmpty, client.hasFetchedAgents {
                        Button { sheet = .addAgent } label: { Label("添加 Agent", systemImage: "plus") }
                            .disabled(client.busy)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                } header: {
                    HStack {
                        Text("设备")
                        Spacer()
                        if !client.agents.isEmpty, client.authenticated {
                            Button { sheet = .addAgent } label: {
                                Image(systemName: "plus").font(.body.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain).foregroundStyle(.primary)
                            .accessibilityLabel("添加 Agent").disabled(client.busy)
                        }
                    }
                }
            } else {
                Section("服务器连接") {
                    LabeledContent("账号", value: client.username)
                    Text(client.logoutPending ? "本机已退出，等待联网后撤销服务端会话。可在 Hako 首页的「设置 → 服务器与登录」中重试。" : "请前往 Hako 首页的「设置 → 服务器与登录」，导出本机公钥并在服务端登记后登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let message = client.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .refreshable { await refreshDevices() }
    }

    private var settings: some View {
        SettingsSheet(title: "设备管理设置") {
            List {
                Section {
                    if client.agents.isEmpty {
                        Text(client.hasFetchedAgents ? "暂无登记的设备" : "暂时无法获取设备列表").foregroundStyle(.secondary)
                    }
                    ForEach(client.agents) { agent in
                        Button {
                            if editingAgents { agentToEdit = agent }
                            else { openAgent(agent.id); sheet = nil }
                        } label: {
                            HStack(spacing: 8) {
                                deviceRow(agent, current: !editingAgents && agent.id == selectedAgent?.id)
                                if editingAgents {
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((editingAgents ? "编辑 " : "切换到 ") + agent.name)
                        .accessibilityAddTraits(!editingAgents && agent.id == selectedAgent?.id ? .isSelected : [])
                    }
                    Button { addingAgentFromSettings = true } label: {
                        Label("添加 Agent", systemImage: "plus")
                    }
                    .disabled(client.busy || !client.authenticated || client.logoutPending)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                } header: {
                    HStack {
                        Text("切换 Agent")
                        Spacer()
                        Button(editingAgents ? "完成" : "编辑") { editingAgents.toggle() }
                            .textCase(nil)
                            .disabled(client.agents.isEmpty || client.busy)
                            .accessibilityLabel(editingAgents ? "完成编辑 Agent 列表" : "编辑 Agent 列表")
                    }
                } footer: {
                    if editingAgents { Text("点击 Agent 编辑设备信息。") }
                }
                if let agent = selectedAgent {
                    DeviceDataQueryPermissionSection(client: client, agent: agent)
                        .id(scope + "\n" + agent.id)
                    let order = pageOrderStorage(for: agent)
                    DevicePageOrderSection(agent: agent, capabilities: agent.monitorPages, order: order)
                        .id(order.key)
                        .environment(\.editMode, .constant(.active))
                }
                Section {
                    NavigationLink { about } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
        .sheet(isPresented: $addingAgentFromSettings) {
            AddAgentSheet()
        }
        .sheet(item: $agentToEdit) { agent in
            EditAgentSheet(agent: agent)
                .id(client.requestContext + "\n" + agent.id)
        }
    }

    private var about: some View {
        List {
            if let agent = selectedAgent {
                DeviceAgentVersionSection(agent: agent)
                    .id(client.requestContext + "\n" + agent.id)
            } else {
                Section("Agent 版本信息") {
                    Text("选择一个 Agent 后查看版本信息。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deviceRow(_ agent: ConsoleAgent, current: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name)
                Text("设备 ID · " + agent.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(agent.online ? "在线" : "离线").font(.caption)
                .foregroundStyle(agent.online ? Color.green : Color.secondary)
            if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true) }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    private func openAgent(_ id: String) {
        savedLastAgents = DeviceAgentHistory.remember(id, scope: scope, in: savedLastAgents)
        selection = .device(id)
    }

    @MainActor private func refreshDevices() async {
        guard !Task.isCancelled, !client.busy, !client.serverURL.isEmpty, !client.logoutPending else { return }
        if !client.authenticated, client.hasSavedSession { await client.restore() }
        let context = client.requestContext
        guard client.authenticated, await client.fetchAgents(),
              !Task.isCancelled, context == client.requestContext else { return }
        // Only a successful list can establish that a device was removed.
        // Offline registered devices keep their last selection.
        if let lastAgentID, !client.agents.contains(where: { $0.id == lastAgentID }) {
            savedLastAgents = DeviceAgentHistory.remember(nil, scope: scope, in: savedLastAgents)
            selection = .automatic
        }
    }
}

struct DeviceMetricsView: View {
    private enum CodexTab: String, CaseIterable { case sessions = "处理中会话", usage = "最近 7 天" }
    let agent: ConsoleAgent
    let order: DeviceCardOrder.Storage
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
    private var sshAccount: String {
        DeviceCardOrder.storageKey(server: client.serverURL, account: client.username, agent: agent.id,
                                  group: "ssh")
    }
    var body: some View {
        DeviceCapabilityPages(capabilities: currentAgent.monitorPages,
            order: order,
            emptyMessage: currentAgent.capabilities == nil ? "尚未获取设备能力，请刷新数据。" : "此设备暂无可用能力。",
            tabTitle: capabilityTabTitle,
            refresh: refreshDevice) {
            deviceOverview
        } content: { capability in
            if capability.name == "query.system.metrics", capability.version == 1 {
                metricsContent(capability)
            } else if capability.name == DeviceProcessCommand.status, capability.version == 1 {
                DeviceProcessesView(agent: currentAgent, entry: state.entries[capability.name],
                    metrics: metrics(for: .init(name: "query.system.metrics", version: 1)), loaded: state.loaded)
            } else if capability.name == DeviceGitCommand.list, capability.version == 1 {
                DeviceGitRepositoriesView(agent: currentAgent,
                    cacheFile: DeviceGitInventory.cacheFile(server: client.serverURL, account: client.username, agent: currentAgent.id))
                    .id(client.requestContext)
            } else if capability.name == DeviceServiceCommand.status, capability.version == 1 {
                DeviceServicesView(agent: currentAgent, entry: state.entries[capability.name], loaded: state.loaded)
                    .id(client.requestContext)
            } else if capability.name == KageAndroidCommand.list, capability.version == 1 {
                DeviceKageAndroidView(agent: currentAgent, entry: state.entries[capability.name])
                    .id(client.requestContext + currentAgent.id)
            } else if capability.version == 1, AndroidDeviceCommand.names.contains(capability.name) {
                androidContent(capability)
                    .id(client.requestContext + currentAgent.id + capability.name)
            } else {
                VStack(alignment: .leading, spacing: 14) { capabilityContent(capability) }
                    .devicePagePanel()
            }
        } terminal: { selected, fullScreen in
            DeviceSSHTerminalView(agentID: agent.id, account: sshAccount, selected: selected, fullScreen: fullScreen)
                .id(client.requestContext)
        }
        .toolbarBackground(HakoStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: currentAgent.online) { if currentAgent.online { await client.query(currentAgent) } }
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
                    Text(client.transportLabel(currentAgent)).font(.caption).foregroundStyle(.secondary)
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
            } else if let message = client.message {
                statusMessage("连接提示", detail: message)
            } else if !currentAgent.online {
                Text(client.hasFetchedAgents ? "等待设备重新连接…" : "尚未连接服务器，暂时无法确认设备状态。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !currentAgent.online {
                Button("重新连接") { Task { await refreshDevice() } }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(client.busy)
            }
        }
    }

    @MainActor private func refreshDevice() async {
        guard !client.busy, !client.logoutPending else { return }
        if !client.authenticated { await client.restore() }
        let context = client.requestContext
        guard client.authenticated, await client.fetchAgents(), !Task.isCancelled,
              context == client.requestContext else { return }
        if let refreshed = client.agents.first(where: { $0.id == agent.id }), refreshed.online {
            await client.query(refreshed)
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
        case (AndroidDeviceCommand.status, 1): return "状态"
        case (AndroidDeviceCommand.storage, 1): return "存储"
        case (AndroidDeviceCommand.battery, 1): return "电池"
        case (AndroidDeviceCommand.wifi, 1): return "Wi-Fi"
        case (AndroidDeviceCommand.screen, 1): return "屏幕"
        case (AndroidDeviceCommand.sims, 1): return "SIM 卡"
        case (AndroidDeviceCommand.messages, 1), (AndroidDeviceCommand.send, 1): return "短信"
        case (AndroidDeviceCommand.calls, 1), (AndroidDeviceCommand.call, 1): return "通话"
        case (AndroidDeviceCommand.operation, 1): return "操作结果"
        case ("query.system.metrics", 1): return "系统"
        case (DeviceProcessCommand.status, 1): return "进程"
        case ("query.codex.usage", 1): return "Codex"
        case ("query.network.listeners", 1): return "端口"
        case (DeviceServiceCommand.status, 1): return "服务"
        case ("action.network.http.check", 1): return "检测"
        case (DeviceGitCommand.list, 1): return "Git"
        case (KageAndroidCommand.list, 1): return "Android"
        default: return capability.name.split(separator: ".").last.map(String.init) ?? capability.name
        }
    }
    @ViewBuilder private func androidContent(_ capability: ConsoleAgentCapability) -> some View {
        switch capability.name {
        case AndroidDeviceCommand.status:
            DeviceAndroidStatusView(entry: state.entries[capability.name],
                storageEntry: state.entries[AndroidDeviceCommand.storage],
                showsStorage: supportsAndroidCommand(AndroidDeviceCommand.storage),
                batteryEntry: state.entries[AndroidDeviceCommand.battery], wifiEntry: state.entries[AndroidDeviceCommand.wifi],
                showsBattery: supportsAndroidCommand(AndroidDeviceCommand.battery), showsWifi: supportsAndroidCommand(AndroidDeviceCommand.wifi),
                screenEntry: state.entries[AndroidDeviceCommand.screen], showsScreen: supportsAndroidCommand(AndroidDeviceCommand.screen))
        case AndroidDeviceCommand.storage:
            DeviceAndroidStorageView(entry: state.entries[capability.name])
        case AndroidDeviceCommand.battery:
            DeviceAndroidBatteryView(entry: state.entries[capability.name])
        case AndroidDeviceCommand.wifi:
            DeviceAndroidWifiView(entry: state.entries[capability.name])
        case AndroidDeviceCommand.screen:
            DeviceAndroidScreenView(entry: state.entries[capability.name]).devicePagePanel()
        case AndroidDeviceCommand.sims:
            DeviceAndroidSimsView(entry: state.entries[capability.name])
        case AndroidDeviceCommand.messages, AndroidDeviceCommand.send:
            DeviceAndroidTelephonyView(agent: currentAgent, sms: true)
        case AndroidDeviceCommand.calls, AndroidDeviceCommand.call:
            DeviceAndroidTelephonyView(agent: currentAgent, sms: false)
        case AndroidDeviceCommand.operation:
            DeviceAndroidOperationLookupView(agent: currentAgent)
        default: EmptyView()
        }
    }
    private func supportsAndroidCommand(_ name: String) -> Bool {
        currentAgent.capabilities?.contains { $0.name == name && $0.version == 1 } == true
    }
    @ViewBuilder private func capabilityContent(_ capability: ConsoleAgentCapability) -> some View {
        switch (capability.name, capability.version) {
        case ("query.codex.usage", 1): codexContent(capability)
        case ("query.network.listeners", 1): listenersContent(capability)
        case ("action.network.http.check", 1): httpContent
        default:
            if capability.name.hasPrefix("query.") {
                Button("查询数据") { Task { await client.refreshCapability(currentAgent, capability: capability) } }
                    .buttonStyle(HakoActionButtonStyle(primary: false))
                queryStatus(capability)
                if let entry = state.entries[capability.name], entry.version == capability.version, let value = entry.result {
                    ScrollView(.horizontal) {
                        Text(value.formatted).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else { Text("当前客户端暂不支持此操作或版本。").font(.footnote).foregroundStyle(.secondary) }
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

private struct DeviceDataQueryPermissionSection: View {
    @ObservedObject var client: DeviceMonitorClient
    let agent: ConsoleAgent
    @State private var saving = false
    @State private var confirmsEnabling = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("允许查询投资账本", isOn: Binding(get: { agent.dataQueryEnabled == true }, set: { enabled in
                if enabled { confirmsEnabling = true }
                else { Task { await save(false) } }
            }))
            .disabled(saving || client.busy || !client.hasFetchedAgents || agent.dataQueryEnabled == nil)
            .frame(maxWidth: .infinity)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            Text(agent.name + " · " + agent.id).font(.footnote).foregroundStyle(.secondary)
            if saving { ProgressView("正在更新权限") }
            if agent.dataQueryEnabled == nil {
                Text("尚未获取权限状态，请刷新设备列表，并确认服务端已升级。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("线上数据查询")
        } footer: {
            Text("允许此 Agent 通过 CLI 读取线上全部投资账本数据和表结构，仅支持只读查询。默认关闭；修改后下一次查询立即生效，离线设备也可配置。")
        }
        .confirmationDialog("允许「" + agent.name + "」查询线上投资数据？", isPresented: $confirmsEnabling, titleVisibility: .visible) {
            Button("开启查询权限") { Task { await save(true) } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此设备将能够读取全部投资账户、交易、行情、汇率及快照。不会授予修改数据或访问其他数据库的权限。")
        }
    }

    private func save(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do { try await client.setDataQueryPermission(agentID: agent.id, enabled: enabled) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription + " 请刷新设备列表确认实际权限后再重试。" }
    }
}

private extension ConsoleAgent {
    var monitorPages: [ConsoleAgentCapability] {
        let supported = Set((capabilities ?? []).filter { $0.version == 1 }.map(\.name))
        let grouped = AndroidDeviceCommand.pageNames(supported)
        return (capabilities ?? []).filter {
            ($0.version != 1 || grouped.contains($0.name)) &&
            $0.name != "action.xkode.tasks.manage" && !DeviceGitCommand.supporting.contains($0.name)
                && $0.name != DeviceServiceCommand.start
                && $0.name != DeviceAgentVersions.command
                && $0.name != AgentLanDescriptor.command
                && !KageAndroidCommand.supporting.contains($0.name)
        }
    }
}
