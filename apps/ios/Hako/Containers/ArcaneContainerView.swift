import SwiftUI

struct ArcaneContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: ArcaneStore
    let environment: ArcaneEnvironment
    let container: ArcaneContainer
    @StateObject private var live = ArcaneLiveData()
    @StateObject private var data = ArcaneContainerData()
    @State private var containerID: String
    @State private var update: ArcaneContainerUpdate?
    @State private var error: String?
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
        _update = State(initialValue: container.update)
    }
    private var details: ArcaneContainerDetails? { data.details }
    private var loading: Bool { data.loading }
    private var resourceSample: ArcaneResourceSample? {
        live.sample ?? (containerID == container.id ? container.resourceSample : nil)
    }
    private var active: Bool { visible && scenePhase == .active && !store.operationRunning }
    private var taskKey: String { "\(active)-\(containerID)" }
    private var status: String { details?.state?.status ?? container.state ?? "" }
    private var isRunning: Bool { details?.state?.running ?? (status == "running") }
    private var isAbnormal: Bool {
        guard let state = details?.state else { return container.abnormal }
        return state.health?.status == "unhealthy" || ["dead", "restarting"].contains(status)
    }
    private var statsKey: String { taskKey + "-\(isRunning)-\(revision)" }
    private var logsKey: String { taskKey + "-\(tab)-\(following)-\(revision)" }
    private var managementProtected: Bool { details?.redeployDisabled ?? container.redeployDisabled ?? false }
    private var canAct: Bool { details != nil && !managementProtected && !loading && !store.operationRunning && !store.fileSaveRunning && store.pending == nil && !checkingUpdate && !exporting }
    private var operationStatus: ArcaneOperationStatus? {
        store.operationStatus(environmentID: environment.id, containerID: containerID)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            detailList { proxy.scrollTo($0, anchor: .top) }
        }
    }

    private func detailList(scrollToFile: @escaping (String) -> Void) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Text(details?.displayName ?? container.name).font(.title2.bold())
                    Label(environment.displayName, systemImage: "server.rack").font(.caption).foregroundStyle(.secondary)
                    statusBadge
                    if let operationStatus { ArcaneOperationBadge(status: operationStatus) }
                }.padding(.vertical, 6).arcaneRowSeparators()
            }.listSectionSpacing(12)
            Section {
                detailTabs
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }.listSectionSpacing(12)
            if loading && details == nil { Section { ProgressView("正在读取容器…").arcaneRowSeparators() } }
            if let error = error ?? data.error { Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() } }
            if tab == "overview" { overview }
            else if tab == "logs" { logs }
            else {
                ArcaneProjectFilesSection(store: store, environment: environment.id,
                    projectName: details?.project ?? container.project,
                    workingDir: details?.composeInfo?.workingDir ?? container.labels?["com.docker.compose.project.working_dir"], refreshID: revision,
                    scrollToFile: scrollToFile)
            }
            if let details, !managementProtected {
                Section {
                    if details.state?.status == "running" {
                        HStack(spacing: 16) {
                            Button { confirming = .restart } label: {
                                Text("重启").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderless)
                            Button(role: .destructive) { confirming = .stop } label: {
                                Text("停止").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderless)
                        }.disabled(!canAct).arcaneRowSeparators()
                    } else if ["exited", "created"].contains(details.state?.status ?? "") {
                        Button("启动") { confirming = .start }
                            .buttonStyle(.borderless).disabled(!canAct).arcaneRowSeparators()
                    } else {
                        Text("请在 Arcane 中处理当前容器状态。").foregroundStyle(.secondary).arcaneRowSeparators()
                    }
                    Button { confirming = .redeploy } label: {
                        Label("拉取镜像并重新部署", systemImage: "arrow.triangle.2.circlepath")
                    }.disabled(!canAct || details.redeployDisabled == true).arcaneRowSeparators()
                    Button("删除容器", role: .destructive) { confirming = .delete }
                        .disabled(!canAct || !["exited", "created", "dead"].contains(details.state?.status ?? ""))
                        .arcaneRowSeparators()
                } header: {
                    Text("管理")
                } footer: {
                    Text(details.redeployDisabled == true ? "Arcane 禁止重新部署此容器，请使用服务端对应的管理入口。" : "删除前需先停止容器；删除时保留数据卷。所有操作以 Arcane 实际授权和状态校验为准。")
                }
            }
        }
    }

    private var detailTabs: some View {
        HakoUnderlineTabs(title: "详情页签", options: ["overview", "logs", "files"], selection: $tab) {
            switch $0 {
            case "overview": return "概览"
            case "logs": return "日志"
            default: return "文件"
            }
        }
    }

    private var statusBadge: some View {
        let text = ArcaneContainerState.text(status)
        let title = isAbnormal ? "\(text) · 不健康或异常" : text
        let icon = isAbnormal ? "exclamationmark.circle.fill" : isRunning ? "circle.fill" : "stop.circle"
        let color: Color = isAbnormal ? .red : isRunning ? .green : .gray
        return Label(title, systemImage: icon).font(.caption).foregroundStyle(color)
    }

    var body: some View {
        content
        .navigationTitle("容器详情")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if tab != "files" { await refreshDetails() }
            revision = UUID()
        }
        .alert(confirming?.confirmationTitle ?? "确认容器操作", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { action in
            if let details {
                Button(action.title, role: action == .delete || action == .stop ? .destructive : nil) {
                    store.start(action, container: details, environment: environment)
                    confirming = nil
                }
            }
            Button("取消", role: .cancel) { confirming = nil }
        } message: { action in
            Text(verbatim: confirmationMessage(action))
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; removeExport() }
        .onChange(of: store.lastChange?.id) { _, _ in
            guard let change = store.lastChange, change.environmentID == environment.id, change.originalID == containerID else { return }
            guard let replacement = change.replacementID else { dismiss(); return }
            containerID = replacement; data.reset(); update = nil; showVariableValues = false
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
            guard active, isRunning else { return }
            do { await live.stats(client: try store.client(), environment: environment.id, container: containerID) }
            catch { self.error = error.localizedDescription }
        }
        .task(id: logsKey) {
            guard active, tab == "logs", following else { return }
            do { await live.logStream(client: try store.client(), environment: environment.id, container: containerID) }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private var overview: some View {
        resourceSection
        if let details {
            if details.state?.health?.status == "unhealthy" {
                Section { Label("健康检查未通过，建议先查看日志。", systemImage: "exclamationmark.circle").foregroundStyle(.red).arcaneRowSeparators() }
            }
            Section("容器信息") {
                LabeledContent("镜像", value: details.image ?? "未知").arcaneRowSeparators()
                LabeledContent("容器 ID", value: String(details.id.prefix(12))).arcaneRowSeparators()
                if let project = details.project { LabeledContent("Compose 项目", value: project).arcaneRowSeparators() }
                if let policy = details.hostConfig?.restartPolicy { LabeledContent("重启策略", value: policy).arcaneRowSeparators() }
                if let started = details.state?.startedAt, !started.hasPrefix("0001") { LabeledContent("启动时间", value: started).arcaneRowSeparators() }
                if let exit = details.state?.exitCode, !isRunning { LabeledContent("退出码", value: String(exit)).arcaneRowSeparators() }
                if let ports = details.portsText {
                    LabeledContent("端口") {
                        Text(verbatim: ports)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }.arcaneRowSeparators()
                }
            }.font(.subheadline).textSelection(.enabled)
            Section("镜像更新") {
                LabeledContent("更新状态", value: update?.text ?? "尚未检查").arcaneRowSeparators()
                if let current = update?.currentVersion, !current.isEmpty { LabeledContent("当前版本", value: current).arcaneRowSeparators() }
                if let latest = update?.latestVersion, !latest.isEmpty { LabeledContent("可用版本", value: latest).arcaneRowSeparators() }
                if let digest = update?.latestDigest, !digest.isEmpty {
                    LabeledContent("可用摘要", value: String(digest.prefix(24)) + "…").arcaneRowSeparators()
                }
                if let time = update?.checkTime { Text("检查时间：\(time)").font(.caption).foregroundStyle(.secondary).arcaneRowSeparators() }
                if update?.error?.isEmpty == false { Text("镜像检查失败，请在 Arcane 中核对镜像仓库凭据及更新策略。").font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() }
                Button {
                    Task { await checkUpdate() }
                } label: {
                    HStack { Text("检查更新"); Spacer(); if checkingUpdate { ProgressView() } }
                }.disabled(checkingUpdate || store.operationRunning).arcaneRowSeparators()
            }
            Section("配置") {
                DisclosureGroup("挂载与存储（\(details.mounts?.count ?? 0)）") {
                    ForEach(Array((details.mounts ?? []).enumerated()), id: \.offset) { _, mount in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mount.destination ?? "未知路径")
                            Text(mount.name ?? mount.source ?? "临时挂载").foregroundStyle(.secondary)
                            Text(mount.rw == true ? "读写" : "只读").font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled).arcaneRowSeparators()
                    }
                }.arcaneRowSeparators()
                DisclosureGroup("网络") {
                    ForEach(Array((details.networkSettings?.networks ?? [:]).keys).sorted(), id: \.self) { name in
                        let network = details.networkSettings?.networks?[name]
                        LabeledContent(name, value: [network?.ipAddress, network?.globalIPv6Address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")).arcaneRowSeparators()
                    }
                }.arcaneRowSeparators()
                DisclosureGroup("环境变量（\(details.config?.env?.count ?? 0)）") {
                    Toggle("显示变量值", isOn: $showVariableValues).arcaneRowSeparators()
                    ForEach(Array((details.config?.env ?? []).enumerated()), id: \.offset) { _, variable in
                        let parts = variable.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(parts.first ?? "")).font(.caption.monospaced())
                            Text(showVariableValues ? String(parts.dropFirst().first ?? "") : "••••••••")
                                .foregroundStyle(.secondary).textSelection(.enabled).privacySensitive()
                        }.arcaneRowSeparators()
                    }
                }.arcaneRowSeparators()
            }.font(.subheadline)
        } else {
            Section("容器信息") {
                LabeledContent("镜像", value: container.image ?? "未知").arcaneRowSeparators()
                LabeledContent("容器 ID", value: String(containerID.prefix(12))).arcaneRowSeparators()
                if let project = container.project { LabeledContent("Compose 项目", value: project).arcaneRowSeparators() }
                Text(data.error == nil ? "正在读取完整配置…" : "完整配置读取失败，请下拉重试。")
                    .font(.caption).foregroundStyle(.secondary).arcaneRowSeparators()
            }.font(.subheadline).textSelection(.enabled)
        }
    }

    private var resourceSection: some View {
        Section("资源") {
            if let sample = resourceSample, isRunning {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) { resourceMetrics(sample) }.arcaneRowSeparators()
                } else {
                    HStack(alignment: .top, spacing: 12) { resourceMetrics(sample) }.arcaneRowSeparators()
                }
                if let traffic = live.networkTraffic, let received = traffic.receivedBytes, let sent = traffic.transmittedBytes {
                    DisclosureGroup("网络累计流量") {
                        LabeledContent("上行", value: ByteCountFormatter.string(fromByteCount: sent, countStyle: .decimal)).arcaneRowSeparators()
                        LabeledContent("下行", value: ByteCountFormatter.string(fromByteCount: received, countStyle: .decimal)).arcaneRowSeparators()
                    }.font(.caption).arcaneRowSeparators()
                }
                if let date = live.sampleAt {
                    Text("最近采样：\(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary).arcaneRowSeparators()
                } else {
                    Text("列表采样 · 正在连接实时数据…").font(.caption).foregroundStyle(.secondary).arcaneRowSeparators()
                }
            } else {
                Text(isRunning ? "等待资源采样…" : "容器未运行").foregroundStyle(.secondary).arcaneRowSeparators()
            }
            if let error = live.statsError { Text(error).font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() }
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
            Toggle("实时跟随", isOn: $following).arcaneRowSeparators()
            if let error = live.logsError { Text(error).font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() }
            if live.logs.isEmpty {
                Text(live.logsConnected ? "暂时没有日志输出。" : following ? "等待日志输出…" : "已暂停跟随。")
                    .foregroundStyle(.secondary).arcaneRowSeparators()
            } else {
                ForEach(live.logs) { line in
                    Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
                        .listRowSeparator(.hidden)
                }
            }
            Button("重新连接日志") { revision = UUID(); following = true }.arcaneRowSeparators()
            Button {
                Task { await exportLogs() }
            } label: {
                HStack { Label("导出日志", systemImage: "square.and.arrow.up"); Spacer(); if exporting { ProgressView() } }
            }.disabled(exporting).arcaneRowSeparators()
            if let exportedLog { ShareLink("分享日志文件", item: exportedLog).arcaneRowSeparators() }
        } header: {
            Text(live.logsConnected && following ? "容器日志 · 已连接" : "容器日志")
        } footer: {
            Text("重连读取最近 100 行，最多保留 500 行。导出包含 Docker 仍保留的完整日志，可能包含敏感信息。")
        }
    }

    private func refreshDetails() async {
        guard !store.operationRunning else { return }
        do {
            if let value = await data.refresh(client: try store.client(), environment: environment.id, container: containerID) {
                update = value.updateInfo?.forContainer(value.id); error = nil
            }
        } catch { self.error = error.localizedDescription }
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

    private func confirmationMessage(_ action: ArcaneAction) -> String {
        let name: String = details?.displayName ?? container.name
        let target: String = "\(environment.displayName) · \(name)"
        return target + "\n" + confirmationText(action)
    }

    private func confirmationText(_ action: ArcaneAction) -> String {
        switch action {
        case .start: return "按现有配置启动容器。"
        case .stop:
            return details?.hostConfig?.autoRemove == true ? "停止此容器。此容器启用了自动移除，Docker 可能删除容器及其匿名卷。" : "停止此容器，服务将中断，数据卷保留。"
        case .restart:
            return details?.hostConfig?.autoRemove == true ? "重启此容器。此容器启用了自动移除，重启过程中的停止可能导致 Docker 删除容器及其匿名卷。" : "重启此容器，服务会短暂中断，数据卷保留。"
        case .delete: return "删除容器，保留数据卷。此操作不能撤销。"
        case .redeploy: return details?.project == nil ? "拉取镜像并重建容器，服务会短暂中断。" : "由 Arcane 依据 Compose 项目配置更新此服务，关联副本也可能重建，服务会短暂中断。"
        }
    }
}
