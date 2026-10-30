import SwiftUI
import Charts

struct CloudServersView: View {
    @StateObject private var store = ECSStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = ECSPage.overview
    @State private var settings = false
    @State private var visible = false
    @State private var networkPage = "流量"
    @State private var interface = ""
    @State private var group = ECSProcessGroup.all
    @State private var memorySort = false

    private var taskKey: String { "\(visible && scenePhase == .active && !settings)|\(store.revision)|\(page.rawValue)" }
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
                if page == .terminal {
                    ECSTerminalView(connection: connection, active: visible && scenePhase == .active && !settings).id(store.revision)
                } else {
                    List {
                        if let error = store.error { Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) } }
                        if store.busy { Section { ProgressView("正在查询…") } }
                        switch page {
                        case .overview: overview
                        case .network: network
                        case .processes: processes(connection)
                        case .terminal: EmptyView()
                        }
                    }.refreshable { await store.refresh(page) }
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
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: taskKey) {
            store.load()
            guard visible, scenePhase == .active, !settings, store.connection != nil, page != .terminal else { return }
            while !Task.isCancelled {
                await store.refresh(page)
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    @ViewBuilder private var overview: some View {
        if let latest = store.monitor.last {
            Section("资源使用 · 1 分钟均值") {
                if let cpu = latest.cpu { LabeledContent("CPU", value: String(format: "%.1f%%", cpu)) }
                if let read = latest.readBytesPerSecond { LabeledContent("磁盘读取", value: ECSFormat.rate(read)) }
                if let write = latest.writeBytesPerSecond { LabeledContent("磁盘写入", value: ECSFormat.rate(write)) }
                Text(latest.time, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let snapshot = store.overview {
            if let total = snapshot.memoryTotal, let available = snapshot.memoryAvailable, total > 0 {
                Section("内存") {
                    LabeledContent("已用 / 总量", value: "\(ECSFormat.bytes(max(0, total - available))) / \(ECSFormat.bytes(total))")
                    ProgressView(value: min(1, max(0, (total - available) / total)))
                }
            }
            if let disks = snapshot.disks, !disks.isEmpty {
                Section("磁盘") {
                    ForEach(disks) { disk in
                        VStack(alignment: .leading, spacing: 7) {
                            LabeledContent(disk.mount, value: "\(ECSFormat.bytes(disk.used)) / \(ECSFormat.bytes(disk.total))")
                            if disk.total > 0 { ProgressView(value: min(1, max(0, disk.used / disk.total))) }
                            Text(disk.filesystem).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("系统信息") {
                if let os = store.instance?.os, !os.isEmpty { LabeledContent("操作系统", value: os) }
                if let kernel = snapshot.kernel { LabeledContent("内核", value: kernel) }
                if let architecture = snapshot.architecture { LabeledContent("架构", value: architecture) }
                if let cpu = store.instance?.cpu { LabeledContent("处理器", value: "\(cpu) vCPU") }
                if let uptime = snapshot.uptime { LabeledContent("运行时长", value: ECSFormat.duration(uptime)) }
                if let load = snapshot.load, !load.isEmpty { LabeledContent("负载 1 / 5 / 15 分", value: load.map { String(format: "%.2f", $0) }.joined(separator: " / ")) }
                if let id = store.connection?.instanceID { LabeledContent("实例 ID", value: id) }
            }
            snapshotFooter(snapshot)
        }
    }

    @ViewBuilder private var network: some View {
        let sockets = store.network?.sockets
        Section {
            Picker("网络视图", selection: $networkPage) {
                Text("流量").tag("流量")
                if sockets != nil { Text("监听端口").tag("监听端口"); Text("当前连接").tag("当前连接") }
            }.pickerStyle(.segmented)
        }
        if networkPage == "流量" || sockets == nil {
            if !store.monitor.isEmpty {
                Section("实例内网 · 最近 1 小时") {
                    Chart {
                        ForEach(store.monitor) { point in
                            if let value = point.receiveBytesPerSecond { LineMark(x: .value("时间", point.time), y: .value("KiB/s", value / 1024)).foregroundStyle(by: .value("方向", "接收")) }
                            if let value = point.sendBytesPerSecond { LineMark(x: .value("时间", point.time), y: .value("KiB/s", value / 1024)).foregroundStyle(by: .value("方向", "发送")) }
                        }
                    }.chartYAxisLabel("KiB/s").frame(height: 175)
                    if let last = store.monitor.last {
                        if let value = last.receiveBytesPerSecond { LabeledContent("平均接收", value: ECSFormat.rate(value)) }
                        if let value = last.sendBytesPerSecond { LabeledContent("平均发送", value: ECSFormat.rate(value)) }
                        Text("监控时间：\(last.time.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("1 分钟均值").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let interfaces = store.network?.interfaces, !interfaces.isEmpty {
                Section("网卡 · 短时采样") {
                    let selected = interfaces.first { $0.name == interface } ?? interfaces[0]
                    Picker("网卡", selection: Binding(get: { selected.name }, set: { interface = $0 })) {
                        ForEach(interfaces) { Text($0.name).tag($0.name) }
                    }
                    if let value = selected.receiveRate { LabeledContent("接收速率", value: ECSFormat.rate(value)) }
                    if let value = selected.sendRate { LabeledContent("发送速率", value: ECSFormat.rate(value)) }
                    LabeledContent("累计接收", value: ECSFormat.bytes(selected.receive))
                    LabeledContent("累计发送", value: ECSFormat.bytes(selected.send))
                    LabeledContent("接收 / 发送丢包", value: "\(Int64(selected.receiveDrops)) / \(Int64(selected.sendDrops))")
                    Text("累计来自系统网卡计数，重建网卡或重启可能重置。").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let sockets {
            let rows = sockets.filter { $0.listening == (networkPage == "监听端口") }
            Section("\(networkPage) · \(rows.count)") {
                ForEach(rows) { row in
                    NavigationLink { ECSSocketDetails(socket: row) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(row.local).font(.system(.subheadline, design: .monospaced)); Spacer(); Text(row.protocolName.uppercased()).font(.caption).foregroundStyle(.secondary) }
                            if !row.listening { Text("对端 \(row.peer)").font(.caption).foregroundStyle(.secondary) }
                            Text([row.process, row.pid.map { "PID \($0)" }, row.state].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if rows.isEmpty { Text("当前快照没有此类记录。").foregroundStyle(.secondary) }
            }
        }
        if let snapshot = store.network { snapshotFooter(snapshot) }
    }

    @ViewBuilder private func processes(_ connection: ECSConnection) -> some View {
        if let snapshot = store.processes {
            Section {
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
            } header: { processHeader }
            Section { Text("CPU 按单核 100% 计；内存为 RSS。分类按启动来源推断，无法确认的保留为未分类。").font(.caption).foregroundStyle(.secondary) }
            snapshotFooter(snapshot)
        }
    }

    private var processHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("进程").font(.headline).foregroundStyle(.primary)
                    Text(processRows.count, format: .number).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
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

private struct ECSSocketDetails: View {
    let socket: ECSSocket
    var body: some View {
        List {
            Section("连接信息") {
                LabeledContent("协议", value: socket.protocolName.uppercased())
                LabeledContent("状态", value: socket.state)
                LabeledContent("本机", value: socket.local)
                if !socket.listening { LabeledContent("对端", value: socket.peer) }
                if let name = socket.process { LabeledContent("进程", value: name) }
                if let pid = socket.pid { LabeledContent("PID", value: String(pid)) }
            }
        }.textSelection(.enabled).navigationTitle(socket.listening ? "监听端口" : "连接详情")
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
            if busy { ProgressView("正在读取进程…") }
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
