import SwiftUI

struct CloudServersView: View {
    @StateObject private var store = ECSStore()
    @StateObject private var access = ECSAccessStore()
    @StateObject private var terminal = ECSTerminalData()
    @ObservedObject private var console = ConsoleClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = ECSPage.overview
    @State private var settings = false
    @State private var visible = false
    @State private var terminalPrepared = false
    @State private var group = ECSProcessGroup.all
    @State private var memorySort = false
    @State private var selectedConnection: ECSNetworkConnectionSelection?

    private var taskKey: String { "\(visible && scenePhase == .active && !settings)|\(store.revision)" }
    private var accessTaskKey: String { taskKey + "|\(console.serverURL)|\(console.username)|\(console.authenticated)|\(console.logoutPending)" }
    private var processRows: [ECSProcess] {
        (store.processes?.processes ?? []).filter { group == .all || $0.group == group }.sorted {
            let left = memorySort ? $0.memory : ($0.cpu ?? -1), right = memorySort ? $1.memory : ($1.cpu ?? -1)
            return left == right ? $0.pid < $1.pid : left > right
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let connection = store.connection {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(connection.name).font(.title2.bold())
                        Spacer()
                        if let status = store.instance?.status { Text(status == "Running" ? "运行中" : status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text([connection.region, store.instance?.address ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.horizontal, 18).padding(.top, 12)
                HakoUnderlineTabs(title: "云服务器功能", options: ECSPage.allCases, selection: $page, label: { $0.rawValue })
                    .padding(.horizontal, 18)
                ZStack {
                    ECSTerminalView(connection: connection, active: visible && !settings && page == .terminal, data: terminal)
                        .opacity(page == .terminal ? 1 : 0)
                        .allowsHitTesting(page == .terminal)
                        .accessibilityHidden(page != .terminal)
                    if page != .terminal {
                        List {
                            if let error = store.error { Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) } }
                            switch page {
                            case .overview: overview
                            case .network: network
                            case .processes: processes(connection)
                            case .terminal: EmptyView()
                            }
                        }
                        .contentMargins(.top, 24, for: .scrollContent)
                        .refreshable {
                            async let instance: Void = store.refresh(page)
                            if page == .overview { await access.refresh(client: console) }
                            await instance
                        }
                    }
                }
            } else {
                ContentUnavailableView("连接你的云服务器", systemImage: "server.rack", description: Text("配置阿里云实例和 RAM 凭据，通过会话管理访问无公网 IP 的 Linux ECS。"))
                Button("配置 ECS 连接") { settings = true }.padding(.bottom, 24)
                if let error = store.error { Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
            }
        }
        .navigationTitle("云服务器").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("ECS 连接设置")
            }
        }
        .sheet(isPresented: $settings) { ECSSettingsSheet(store: store) }
        .navigationDestination(item: $selectedConnection) { selection in
            ECSNetworkConnectionsView(direction: selection.direction, snapshot: selection.snapshot)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; terminalPrepared = false; terminal.disconnect() }
        .onChange(of: settings) { _, showing in if showing { terminalPrepared = false; terminal.disconnect() } }
        .onChange(of: store.revision) { _, _ in terminalPrepared = false; terminal.disconnect() }
        .task(id: taskKey) {
            store.load()
            guard visible, scenePhase == .active, !settings, store.connection != nil else { return }
            while !Task.isCancelled {
                await store.refreshAll(includeOverview: false)
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task(id: taskKey) {
            store.load()
            guard visible, scenePhase == .active, !settings, store.connection != nil else { return }
            await store.pollUsage()
        }
        .task(id: taskKey) {
            store.load()
            guard visible, scenePhase == .active, !settings, !terminalPrepared, let connection = store.connection else { return }
            while terminal.cleaning {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            terminalPrepared = true
            terminal.connect(connection)
        }
        .task(id: accessTaskKey) {
            guard visible, scenePhase == .active, !settings else { return }
            store.load()
            guard store.connection != nil else { return }
            if !console.authenticated, !console.serverURL.isEmpty { await console.restore() }
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                await access.refresh(client: console)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    @ViewBuilder private var overview: some View {
        let usage = ECSOverviewUsage(snapshot: store.overview, monitor: store.monitor)
        Section {
            HStack(alignment: .top, spacing: 12) {
                ECSUsageGauge(title: "CPU 使用率", percent: usage.cpu, color: .blue,
                              detail: usage.cpu == nil ? "—" : usage.cpuIsSampled ? "约 1 秒采样" : "1 分钟均值")
                ECSUsageGauge(title: "内存使用率", percent: usage.memory, color: .purple,
                              detail: capacity(used: usage.memoryUsed, total: usage.memoryTotal))
                ECSUsageGauge(title: "磁盘使用率", percent: usage.disk, color: .orange,
                              detail: capacity(used: usage.diskUsed, total: usage.diskTotal))
            }.padding(.vertical, 8)
        }
        if store.connection != nil {
            Section("网站访问 · 近 24 小时") {
                NavigationLink { ECSAccessView() } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("访问统计").font(.headline); Spacer(); Text("查看详情").font(.caption).foregroundStyle(.secondary) }
                        if console.authenticated, !console.logoutPending, let summary = access.summary {
                            if summary.status.enabled {
                                let totals = summary.counts(domains: summary.domains)
                                ECSAccessMetrics(visits: totals.reduce(0) { $0 + $1.visits }, notFound: totals.reduce(0) { $0 + $1.notFound })
                                ECSAccessFreshness(status: summary.status)
                                Text("全部域名 · \(summary.domains.count) 个").font(.caption).foregroundStyle(.secondary)
                            } else { Text("服务端尚未启用访问日志统计").font(.subheadline).foregroundStyle(.secondary) }
                        } else if access.busy || console.authenticated {
                            HStack { LabeledContent("HTTP 请求", value: "—"); LabeledContent("404", value: "—") }
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else { Text(access.error ?? "请先登录 Hako 服务器以读取统计").font(.footnote).foregroundStyle(.secondary) }
                        if let error = access.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 4)
                }
            }
        }
        Section("系统信息") {
            LabeledContent("操作系统", value: store.instance?.os ?? "—")
            LabeledContent("内核", value: store.overview?.kernel ?? "—")
            LabeledContent("架构", value: store.overview?.architecture ?? "—")
            LabeledContent("处理器", value: store.instance?.cpu.map { "\($0) vCPU" } ?? "—")
            LabeledContent("运行时长", value: store.overview?.uptime.map(ECSFormat.duration) ?? "—")
            LabeledContent("负载 1 / 5 / 15 分", value: store.overview?.load.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " / ") } ?? "—")
            LabeledContent("实例 ID", value: store.connection?.instanceID ?? "—")
        }
    }

    private func capacity(used: Double?, total: Double?) -> String {
        guard let used, let total, used.isFinite, total.isFinite, used >= 0, total > 0, used <= total else { return "—" }
        return "\(ECSFormat.bytes(used)) / \(ECSFormat.bytes(total))"
    }

    @ViewBuilder private var network: some View {
        ECSNetworkSections(snapshot: store.network, monitor: store.monitor) { direction, snapshot in
            selectedConnection = ECSNetworkConnectionSelection(direction: direction, snapshot: snapshot)
        }
        if let snapshot = store.network { snapshotFooter(snapshot) }
    }

    @ViewBuilder private func processes(_ connection: ECSConnection) -> some View {
        Section {
            if let snapshot = store.processes {
                ForEach(processRows) { process in
                    NavigationLink { ECSProcessDetails(initial: process, initialTime: snapshot.time, connection: connection) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.name).font(.system(.subheadline, design: .monospaced))
                                Text("\(process.pid) · \(process.user)").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(alignment: .top, spacing: 16) {
                                Text(process.cpu.map { String(format: "CPU %.1f%%", $0) } ?? "CPU —")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("内存 \(ECSFormat.bytes(process.memory))").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }
                if processRows.isEmpty { Text("本次返回记录中没有此类进程。").foregroundStyle(.secondary) }
            } else {
                HStack { Text("进程"); Spacer(); Text("CPU —     内存 —").foregroundStyle(.secondary) }
            }
        } header: { processHeader }
        Section { Text("CPU 按单核 100% 计；内存为 RSS。分类按启动来源推断，无法确认的保留为未分类。").font(.caption).foregroundStyle(.secondary) }
        if let snapshot = store.processes { snapshotFooter(snapshot) }
    }

    private var processHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("进程").font(.headline).foregroundStyle(.primary)
                    Text(store.processes == nil ? "—" : processRows.count.formatted()).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Menu {
                    Picker("排序方式", selection: $memorySort) {
                        Text("CPU 从高到低").tag(false)
                        Text("内存从高到低").tag(true)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(memorySort ? "内存 ↓" : "CPU ↓").font(.subheadline)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("进程排序")
                .accessibilityValue(memorySort ? "内存从高到低" : "CPU 从高到低")
            }
            HStack(spacing: 6) {
                ForEach(ECSProcessGroup.allCases) { option in
                    let selected = group == option
                    Button { group = option } label: {
                        Text(option.rawValue)
                            .font(.subheadline).fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? Color.primary : .secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Color(uiColor: .secondarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.rawValue)进程")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("进程分类")
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }

    private func snapshotFooter(_ snapshot: ECSSnapshot) -> some View {
        Section {
            Text("快照：\(Date(timeIntervalSince1970: snapshot.time).formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
            if snapshot.truncated == true { Text("结果较多，本次仅返回部分记录。").font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct ECSProcessDetails: View {
    let initial: ECSProcess
    let initialTime: Double
    let connection: ECSConnection
    @Environment(\.scenePhase) private var scenePhase
    @State private var fresh: ECSProcess?
    @State private var busy = false
    @State private var error: String?
    @State private var updated: Double?
    private var process: ECSProcess { fresh ?? initial }
    var body: some View {
        List {
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            Section("资源") {
                if let cpu = process.cpu { LabeledContent("CPU · 单核 100%", value: String(format: "%.1f%%", cpu)) }
                LabeledContent("内存 RSS", value: ECSFormat.bytes(process.memory))
                if let read = process.read { LabeledContent("累计磁盘读取", value: ECSFormat.bytes(read)) }
                if let write = process.write { LabeledContent("累计磁盘写入", value: ECSFormat.bytes(write)) }
            }
            Section("进程") {
                LabeledContent("PID / 父进程", value: "\(process.pid) / \(process.parent)")
                LabeledContent("所属用户", value: "\(process.user) · UID \(process.uid)")
                LabeledContent("线程数", value: String(process.threads))
                LabeledContent("运行时长", value: ECSFormat.duration(process.elapsed))
                LabeledContent("分类", value: process.group.rawValue)
                Text(process.source).font(.caption).foregroundStyle(.secondary)
                if let executable = process.executable { LabeledContent("可执行文件", value: executable) }
            }
            Section { Text("快照：\(Date(timeIntervalSince1970: updated ?? initialTime).formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(process.name).textSelection(.enabled)
            .refreshable { await refresh() }
            .task(id: scenePhase) { if scenePhase == .active { await refresh() } }
    }
    private func refresh() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await ECSClient(connection: connection).snapshot(mode: "process", pid: initial.pid)
            try Task.checkCancellation()
            guard let item = value.processes?.first else { error = "进程已结束，或当前用户无法读取此进程。"; return }
            fresh = item
            updated = value.time
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
