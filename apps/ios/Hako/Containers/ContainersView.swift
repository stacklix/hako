import SwiftUI

struct ContainersView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ArcaneStore.shared
    @State private var showingSettings = false
    @State private var visible = false
    @State private var search = ""
    @State private var filter = ContainerFilter.all
    @State private var groupByProject = false

    private enum ContainerFilter: String, CaseIterable, Identifiable {
        case all = "全部", abnormal = "异常", stopped = "已停止", updates = "有更新"
        var id: String { rawValue }
    }
    private var filtered: [ArcaneContainer] {
        store.containers.filter { item in
            let matches = search.isEmpty || [item.name, item.image ?? "", item.project ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
            guard matches else { return false }
            switch filter {
            case .all: return true
            case .abnormal: return item.abnormal
            case .stopped: return item.stopped
            case .updates: return item.update?.hasUpdate == true && item.update?.error?.isEmpty != false
            }
        }.sorted {
            if $0.abnormal != $1.abnormal { return $0.abnormal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var pollKey: String {
        "\(visible && scenePhase == .active && !showingSettings)-\(store.connection?.id ?? "")-\(store.environmentID)"
    }

    var body: some View {
        List {
            if store.connection == nil {
                Section {
                    ContentUnavailableView("连接你的 Arcane", systemImage: "shippingbox", description: Text("填写已有 Arcane 服务地址和 API Key，即可查看和管理 Docker 容器。"))
                    Button("配置 Arcane 连接") { showingSettings = true }
                }
            } else {
                Section {
                    if !store.environments.isEmpty {
                        Picker("Docker 环境", selection: Binding(get: { store.environmentID }, set: { store.selectEnvironment($0) })) {
                            ForEach(store.environments) { environment in
                                Text("\(environment.displayName) · \(environment.statusText)").tag(environment.id)
                            }
                        }
                    }
                    LabeledContent(store.connection?.name ?? "Arcane", value: "\(store.containers.count) 个容器")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("筛选", selection: $filter) {
                        ForEach(ContainerFilter.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("按 Compose 项目分组", isOn: $groupByProject)
                        .font(.subheadline)
                } footer: {
                    if let updatedAt = store.updatedAt { Text("最近更新：\(updatedAt.formatted(date: .omitted, time: .standard)) · 每 10 秒刷新") }
                }
                if store.loading && store.containers.isEmpty { Section { ProgressView("正在读取容器…") } }
                if let environment = store.environment {
                    if filtered.isEmpty && !store.loading {
                        ContentUnavailableView("没有符合条件的容器", systemImage: "shippingbox", description: Text("可调整搜索或筛选条件，或下拉刷新。"))
                    } else if groupByProject {
                        ForEach(Array(Set(filtered.map { $0.project ?? "独立容器" })).sorted(), id: \.self) { project in
                            Section(project) {
                                ForEach(filtered.filter { ($0.project ?? "独立容器") == project }) { container in
                                    containerLink(container, environment: environment)
                                }
                            }
                        }
                    } else {
                        Section("容器 · 异常优先") {
                            ForEach(filtered) { container in containerLink(container, environment: environment) }
                        }
                    }
                }
            }
            if let error = store.error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
            }
            ArcaneOperationSection(store: store)
        }
        .navigationTitle("容器管理")
        .searchable(text: $search, prompt: "搜索容器、镜像或项目")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Arcane 连接设置").disabled(store.operationRunning)
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showingSettings) { ArcaneSettingsSheet(store: store) }
        .onAppear { visible = true; store.loadConfiguration() }
        .onDisappear { visible = false }
        .task(id: pollKey) {
            guard visible, scenePhase == .active, !showingSettings else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private func containerLink(_ container: ArcaneContainer, environment: ArcaneEnvironment) -> some View {
        NavigationLink {
            ArcaneContainerView(store: store, environment: environment, container: container)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(container.name).font(.headline)
                    Text(container.image ?? "镜像未知").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: container.abnormal ? "exclamationmark.circle.fill" : container.state == "running" ? "circle.fill" : "stop.circle")
                            .font(.caption2)
                        Text(container.abnormal ? "\(container.stateText) · 不健康或异常" : container.stateText)
                    }.font(.caption).foregroundStyle(container.abnormal ? Color.orange : Color.secondary)
                    if let update = container.update, update.hasUpdate == true, update.error?.isEmpty != false {
                        Label("有更新", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 2)
                if let sample = container.resourceSample {
                    VStack(alignment: .trailing, spacing: 5) {
                        if let cpu = sample.cpuPercent { Text("CPU \(cpu, specifier: "%.1f")%") }
                        if let memory = sample.memoryUsageBytes { Text(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)) }
                    }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding(.vertical, 5)
        }
    }
}

struct ArcaneOperationSection: View {
    @ObservedObject var store: ArcaneStore
    var body: some View {
        if let message = store.operationMessage {
            Section("容器操作") {
                if let pending = store.pending {
                    Text("\(pending.environmentName) · \(pending.containerName)").font(.subheadline)
                }
                if store.operationRunning {
                    if let value = store.operationProgress { ProgressView(value: Double(value), total: 100) }
                    else { ProgressView() }
                }
                Text(message).font(.footnote).textSelection(.enabled)
                if !store.operationLogs.isEmpty {
                    DisclosureGroup("操作日志") {
                        Text(store.operationLogs.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if store.pending != nil && !store.operationRunning {
                    Button("刷新容器状态") { Task { await store.refresh() } }
                    Button("已核对状态，清除此提示") { store.acknowledgeUnknownOperation() }
                }
            }
        }
    }
}
