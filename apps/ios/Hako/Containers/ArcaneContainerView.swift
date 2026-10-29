import SwiftUI

struct ArcaneContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: ArcaneStore
    let environment: ArcaneEnvironment
    let container: ArcaneContainer
    @StateObject private var live = ArcaneLiveData()
    @State private var containerID: String
    @State private var details: ArcaneContainerDetails?
    @State private var update: ArcaneContainerUpdate?
    @State private var error: String?
    @State private var loading = false
    @State private var checkingUpdate = false
    @State private var visible = false
    @State private var following = true
    @State private var showVariableValues = false
    @State private var tab = "overview"
    @State private var revision = UUID()
    @State private var confirming: ArcaneAction?
    @State private var exportedLog: URL?
    @State private var exporting = false

    init(store: ArcaneStore, environment: ArcaneEnvironment, container: ArcaneContainer) {
        self.store = store; self.environment = environment; self.container = container
        _containerID = State(initialValue: container.id)
    }
    private var active: Bool { visible && scenePhase == .active && !store.operationRunning }
    private var taskKey: String { "\(active)-\(containerID)-\(revision)" }
    private var statsKey: String { taskKey + "-\(details?.state?.running == true)" }
    private var logsKey: String { taskKey + "-\(tab)-\(following)" }
    private var canAct: Bool { details != nil && !loading && !store.operationRunning && store.pending == nil && !checkingUpdate && !exporting }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Text(details?.displayName ?? container.name).font(.title2.bold())
                    Label(environment.displayName, systemImage: "server.rack").font(.caption).foregroundStyle(.secondary)
                    if let state = details?.state {
                        Label(ArcaneContainerState.text(state.status ?? ""), systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(state.health?.status == "unhealthy" ? Color.orange : Color.secondary)
                    }
                }.padding(.vertical, 6)
                Picker("详情页签", selection: $tab) {
                    Text("概览").tag("overview")
                    Text("日志").tag("logs")
                }.pickerStyle(.segmented)
            }
            if loading && details == nil { Section { ProgressView("正在读取容器…") } }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) } }
            if tab == "overview" { overview }
            else { logs }
            if let details {
                Section("管理") {
                    HStack {
                        if details.state?.status == "running" {
                            Button("重启") { confirming = .restart }
                            Spacer()
                            Button("停止", role: .destructive) { confirming = .stop }
                        } else if ["exited", "created"].contains(details.state?.status ?? "") {
                            Button("启动") { confirming = .start }
                        } else { Text("请在 Arcane 中处理当前容器状态。 ").foregroundStyle(.secondary) }
                    }.disabled(!canAct)
                    Button { confirming = .redeploy } label: {
                        Label("拉取镜像并重新部署", systemImage: "arrow.triangle.2.circlepath")
                    }.disabled(!canAct || details.redeployDisabled == true)
                    Button("删除容器", role: .destructive) { confirming = .delete }
                        .disabled(!canAct || !["exited", "created", "dead"].contains(details.state?.status ?? ""))
                } footer: {
                    Text(details.redeployDisabled == true ? "Arcane 禁止重新部署此容器，请使用服务端对应的管理入口。" : "删除前需先停止容器；删除时保留数据卷。所有操作以 Arcane 实际授权和状态校验为准。")
                }
            }
            ArcaneOperationSection(store: store)
        }
        .navigationTitle("容器详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { revision = UUID() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("刷新容器并重新连接实时数据").disabled(store.operationRunning)
        }
        .refreshable { await refreshDetails() }
        .confirmationDialog("确认容器操作", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming, let details {
                Button(action.title, role: action == .delete || action == .stop ? .destructive : nil) {
                    store.start(action, container: details, environment: environment)
                    confirming = nil
                }
            }
            Button("取消", role: .cancel) { confirming = nil }
        } message: {
            if let action = confirming {
                Text("\(environment.displayName) · \(details?.displayName ?? container.name)\n" + confirmationText(action))
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; removeExport() }
        .onChange(of: store.lastChange?.id) { _, _ in
            guard let change = store.lastChange, change.environmentID == environment.id, change.originalID == containerID else { return }
            guard let replacement = change.replacementID else { dismiss(); return }
            containerID = replacement; details = nil; update = nil; showVariableValues = false
            live.reset(); revision = UUID()
        }
        .task(id: taskKey) {
            guard active else { return }
            while !Task.isCancelled {
                await refreshDetails()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .task(id: statsKey) {
            guard active, details?.state?.running == true else { return }
            do { await live.stats(client: try store.client(), environment: environment.id, container: containerID) }
            catch { error = error.localizedDescription }
        }
        .task(id: logsKey) {
            guard active, tab == "logs", following else { return }
            do { await live.logStream(client: try store.client(), environment: environment.id, container: containerID) }
            catch { error = error.localizedDescription }
        }
    }

    @ViewBuilder private var overview: some View {
        if let details {
            if details.state?.health?.status == "unhealthy" {
                Section { Label("健康检查未通过，建议先查看日志。", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            Section("资源") {
                if let sample = live.sample, details.state?.running == true {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 16) { resourceMetrics(sample) }
                    } else {
                        HStack(alignment: .top, spacing: 12) { resourceMetrics(sample) }
                    }
                    if let traffic = live.networkTraffic, let received = traffic.receivedBytes, let sent = traffic.transmittedBytes {
                        DisclosureGroup("网络累计流量") {
                            LabeledContent("上行", value: ByteCountFormatter.string(fromByteCount: sent, countStyle: .decimal))
                            LabeledContent("下行", value: ByteCountFormatter.string(fromByteCount: received, countStyle: .decimal))
                        }.font(.caption)
                    }
                    if let date = live.sampleAt { Text("最近采样：\(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                } else { Text(details.state?.running == true ? "等待资源采样…" : "容器未运行").foregroundStyle(.secondary) }
                if let error = live.statsError { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            Section("容器信息") {
                LabeledContent("镜像", value: details.image ?? "未知")
                LabeledContent("容器 ID", value: String(details.id.prefix(12)))
                if let project = details.project { LabeledContent("Compose 项目", value: project) }
                if let policy = details.hostConfig?.restartPolicy { LabeledContent("重启策略", value: policy) }
                if let started = details.state?.startedAt, !started.hasPrefix("0001") { LabeledContent("启动时间", value: started) }
                if let exit = details.state?.exitCode, details.state?.running != true { LabeledContent("退出码", value: String(exit)) }
                ForEach(Array((details.ports ?? []).enumerated()), id: \.offset) { _, port in
                    LabeledContent("端口", value: port.text)
                }
            }.font(.subheadline).textSelection(.enabled)
            Section("镜像更新") {
                LabeledContent("更新状态", value: update?.text ?? "尚未检查")
                if let current = update?.currentVersion, !current.isEmpty { LabeledContent("当前版本", value: current) }
                if let latest = update?.latestVersion, !latest.isEmpty { LabeledContent("可用版本", value: latest) }
                if let digest = update?.latestDigest, !digest.isEmpty {
                    LabeledContent("可用摘要", value: String(digest.prefix(24)) + "…")
                }
                if let time = update?.checkTime { Text("检查时间：\(time)").font(.caption).foregroundStyle(.secondary) }
                if update?.error?.isEmpty == false { Text("镜像检查失败，请在 Arcane 中核对镜像仓库凭据及更新策略。").font(.footnote).foregroundStyle(.orange) }
                Button {
                    Task { await checkUpdate() }
                } label: {
                    HStack { Text("检查更新"); Spacer(); if checkingUpdate { ProgressView() } }
                }.disabled(checkingUpdate || store.operationRunning)
            }
            Section("配置") {
                DisclosureGroup("挂载与存储（\(details.mounts?.count ?? 0)）") {
                    ForEach(Array((details.mounts ?? []).enumerated()), id: \.offset) { _, mount in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mount.destination ?? "未知路径")
                            Text(mount.name ?? mount.source ?? "临时挂载").foregroundStyle(.secondary)
                            Text(mount.rw == true ? "读写" : "只读").font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                }
                DisclosureGroup("网络") {
                    ForEach(Array((details.networkSettings?.networks ?? [:]).keys).sorted(), id: \.self) { name in
                        let network = details.networkSettings?.networks?[name]
                        LabeledContent(name, value: [network?.ipAddress, network?.globalIPv6Address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                }
                DisclosureGroup("环境变量（\(details.config?.env?.count ?? 0)）") {
                    Toggle("显示变量值", isOn: $showVariableValues)
                    ForEach(Array((details.config?.env ?? []).enumerated()), id: \.offset) { _, variable in
                        let parts = variable.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(parts.first ?? "")).font(.caption.monospaced())
                            Text(showVariableValues ? String(parts.dropFirst().first ?? "") : "••••••••")
                                .foregroundStyle(.secondary).textSelection(.enabled).privacySensitive()
                        }
                    }
                }
            }.font(.subheadline)
        }
    }

    @ViewBuilder private func resourceMetrics(_ sample: ArcaneResourceSample) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CPU").font(.caption).foregroundStyle(.secondary)
            Text(sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "采样中")
                .font(.headline).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 7) {
            Text("内存使用率").font(.caption).foregroundStyle(.secondary)
            Text(sample.memoryPercent.map { String(format: "%.1f%%", $0) } ?? "不可用")
                .font(.headline).monospacedDigit()
            Text(sample.memoryUsageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 7) {
            Text("网络").font(.caption).foregroundStyle(.secondary)
            if sample.networkRxBytes == nil || sample.networkTxBytes == nil {
                Text("未提供网络计数").foregroundStyle(.secondary)
            } else {
                Label(ArcaneNetworkTraffic.speed(live.networkTraffic?.uploadBytesPerSecond), systemImage: "arrow.up")
                    .accessibilityLabel("上行速率，\(ArcaneNetworkTraffic.speed(live.networkTraffic?.uploadBytesPerSecond))")
                Label(ArcaneNetworkTraffic.speed(live.networkTraffic?.downloadBytesPerSecond), systemImage: "arrow.down")
                    .accessibilityLabel("下行速率，\(ArcaneNetworkTraffic.speed(live.networkTraffic?.downloadBytesPerSecond))")
            }
        }.font(.caption.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logs: some View {
        Section {
            Toggle("实时跟随", isOn: $following)
            if let error = live.logsError { Text(error).font(.footnote).foregroundStyle(.orange) }
            if live.logs.isEmpty {
                Text(live.logsConnected ? "暂时没有日志输出。" : following ? "等待日志输出…" : "已暂停跟随。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(live.logs) { line in
                    Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
                        .listRowSeparator(.hidden)
                }
            }
            Button("重新连接日志") { revision = UUID(); following = true }
            Button {
                Task { await exportLogs() }
            } label: {
                HStack { Label("导出日志", systemImage: "square.and.arrow.up"); Spacer(); if exporting { ProgressView() } }
            }.disabled(exporting)
            if let exportedLog { ShareLink("分享日志文件", item: exportedLog) }
        } header: {
            Text(live.logsConnected && following ? "容器日志 · 已连接" : "容器日志")
        } footer: {
            Text("重连读取最近 100 行，最多保留 500 行。导出包含 Docker 仍保留的完整日志，可能包含敏感信息。")
        }
    }

    private func refreshDetails() async {
        guard !loading, !store.operationRunning else { return }
        let id = containerID
        loading = true
        defer { loading = false }
        do {
            let value = try await store.client().details(environment.id, id: id)
            try Task.checkCancellation()
            guard id == containerID else { return }
            details = value; update = value.updateInfo?.forContainer(value.id); error = nil
        } catch is CancellationError { }
        catch { if id == containerID { self.error = error.localizedDescription } }
    }

    private func checkUpdate() async {
        guard let image = details?.image, !image.isEmpty, !checkingUpdate else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        do {
            update = try await store.client().checkUpdate(environment.id, image: image, containerID: containerID)
            error = nil
            await store.refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func exportLogs() async {
        exporting = true
        defer { exporting = false }
        do {
            let url = try await store.client().downloadLogs(environment.id, id: containerID)
            guard visible else { try? FileManager.default.removeItem(at: url); return }
            removeExport(); exportedLog = url
        } catch { self.error = error.localizedDescription }
    }

    private func removeExport() {
        if let exportedLog { try? FileManager.default.removeItem(at: exportedLog) }
        exportedLog = nil
    }

    private func confirmationText(_ action: ArcaneAction) -> String {
        switch action {
        case .start: return "按现有配置启动容器。"
        case .stop, .restart:
            return details?.hostConfig?.autoRemove == true ? "此容器启用了自动移除，停止时 Docker 可能删除容器及其匿名卷。" : "服务将中断，数据卷保留。"
        case .delete: return "删除容器，保留数据卷。此操作不能撤销。"
        case .redeploy: return details?.project == nil ? "拉取镜像并重建容器，服务会短暂中断。" : "由 Arcane 依据 Compose 项目配置更新此服务，关联副本也可能重建，服务会短暂中断。"
        }
    }
}
