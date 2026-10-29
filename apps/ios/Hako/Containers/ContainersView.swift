import SwiftUI

struct ContainersView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ArcaneStore.shared
    @State private var showingSettings = false
    @State private var visible = false
    @State private var search = ""
    @State private var filter = ContainerFilter.all
    @State private var groupByProject = false
    @State private var environmentRevision = UUID()
    @ScaledMetric(relativeTo: .subheadline) private var filterRowHeight = 44

    private enum ContainerFilter: String, CaseIterable, Identifiable {
        case all = "全部", abnormal = "异常", stopped = "已停止", updates = "有更新"
        var id: String { rawValue }

        func includes(_ container: ArcaneContainer) -> Bool {
            switch self {
            case .all: return true
            case .abnormal: return container.abnormal
            case .stopped: return container.stopped
            case .updates: return container.update?.hasUpdate == true && container.update?.error?.isEmpty != false
            }
        }
    }
    private var filtered: [ArcaneContainer] {
        store.containers.filter { item in
            let matches = search.isEmpty || [item.name, item.image ?? "", item.project ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
            return matches && filter.includes(item)
        }.sorted {
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var pollKey: String {
        "\(visible && scenePhase == .active && !showingSettings)-\(store.connection?.id ?? "")-\(environmentRevision)"
    }
    private var projects: [String] {
        Array(Set(filtered.map { $0.project ?? "独立容器" })).sorted()
    }

    var body: some View {
        List {
            if store.connection == nil {
                Section {
                    ContentUnavailableView("连接你的 Arcane", systemImage: "shippingbox", description: Text("填写已有 Arcane 服务地址和 API Key，即可查看和管理 Docker 容器。"))
                    Button("配置 Arcane 连接") { showingSettings = true }
                }
            } else {
                controls
                operationSummary
                if store.loading && store.containers.isEmpty { Section { ProgressView("正在读取容器…") } }
                if let environment = store.environment {
                    containerSections(environment: environment)
                }
            }
            if let error = store.error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() }
            }
            ArcaneOperationSection(store: store)
        }
        .listSectionSpacing(8)
        .navigationTitle("容器管理")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Arcane 连接设置").disabled(store.operationRunning)
            }
        }
        .refreshable { await store.refresh(forceEnvironments: true) }
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

    @ViewBuilder private var operationSummary: some View {
        if let operation = store.activeOperation ?? store.pending,
           let status = store.operationStatus(environmentID: store.environmentID, containerID: operation.containerID) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(operation.containerName).font(.subheadline.weight(.semibold))
                    ArcaneOperationBadge(status: status)
                }.arcaneRowSeparators()
            }
        }
    }

    @ViewBuilder
    private func containerSections(environment: ArcaneEnvironment) -> some View {
        if groupByProject && !filtered.isEmpty {
            ForEach(projects, id: \.self) { project in
                Section {
                    ForEach(filtered.filter { ($0.project ?? "独立容器") == project }) { container in
                        containerLink(container, environment: environment)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        if project == projects.first { containerListHeader }
                        Text(project)
                    }
                    .textCase(nil)
                }
            }
        } else {
            Section {
                if filtered.isEmpty && !store.loading {
                    ContentUnavailableView("没有符合条件的容器", systemImage: "shippingbox", description: Text("可调整搜索或筛选条件，或下拉刷新。"))
                } else {
                    ForEach(filtered) { container in containerLink(container, environment: environment) }
                }
            } header: {
                containerListHeader
            }
        }
    }

    private var controls: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                environmentSelector
                searchField
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(ContainerFilter.allCases) { option in filterButton(option) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .frame(height: filterRowHeight + 8)
            }
            // Keep the filters above the inset-grouped row's bottom corner mask.
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if store.loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在刷新容器…")
                    }
                }
                if let updatedAt = store.updatedAt {
                    Text("最近更新：\(updatedAt.formatted(date: .omitted, time: .standard)) · 每 10 秒刷新")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
            .textCase(nil)
        }
    }

    private var containerListHeader: some View {
        HStack {
            Text("容器")
            Spacer(minLength: 8)
            composeCheckbox
        }
        .textCase(nil)
    }

    private var composeCheckbox: some View {
        Button { groupByProject.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: groupByProject ? "checkmark.square.fill" : "square")
                Text("Compose 分组")
            }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle("按 Compose 项目分组", isOn: $groupByProject).toggleStyle(.switch)
        }
    }

    private var environmentSelector: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").font(.title3).foregroundStyle(.secondary)
            Menu {
                Picker("Docker 环境", selection: Binding(get: { store.environmentID }, set: {
                    guard $0 != store.environmentID else { return }
                    store.selectEnvironment($0)
                    environmentRevision = UUID()
                })) {
                    ForEach(store.environments) { environment in
                        Text("\(environment.displayName) · \(environment.statusText)").tag(environment.id)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(store.environment?.displayName ?? "选择 Docker 环境")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Circle().fill(environmentStatusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(store.environment?.statusText ?? "状态未知")
                        Text("·")
                        Text(store.connection?.name ?? "Arcane").lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(store.containers.count) 个容器").fixedSize()
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(store.environments.isEmpty)
            .accessibilityLabel("Docker 环境，\(store.environment?.displayName ?? "尚未选择")")
            Button { Task { await store.refresh(forceEnvironments: true) } } label: {
                Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(store.loading)
            .accessibilityLabel(store.loading ? "正在刷新容器" : "刷新容器")
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var environmentStatusColor: Color {
        guard store.environment?.enabled != false else { return .secondary }
        switch store.environment?.status?.lowercased() {
        case "online", "connected": return .green
        case "standby": return .orange
        case "offline", "disconnected", "error": return .red
        default: return .secondary
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索容器、镜像或项目", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).accessibilityLabel("搜索容器、镜像或项目")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private func filterButton(_ option: ContainerFilter) -> some View {
        let selected = filter == option
        let foreground = selected ? Color(uiColor: .systemBackground) : Color.primary
        let background = selected ? Color.primary : Color(uiColor: .secondarySystemGroupedBackground)
        return Button { filter = option } label: {
            Text(option.rawValue)
                .font(.subheadline)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(background, in: Capsule())
                .foregroundStyle(foreground)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func containerLink(_ container: ArcaneContainer, environment: ArcaneEnvironment) -> some View {
        let operation = store.operationStatus(environmentID: environment.id, containerID: container.id)
        return NavigationLink {
            ArcaneContainerView(store: store, environment: environment, container: container)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(container.name).font(.headline)
                    Text(container.image ?? "镜像未知").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: container.abnormal ? "exclamationmark.circle.fill" : container.state == "running" ? "circle.fill" : "stop.circle")
                                .font(.caption2)
                            Text(container.abnormal ? "\(container.stateText) · 不健康或异常" : container.stateText)
                        }
                        .foregroundStyle(container.abnormal ? Color.red : container.state == "running" ? Color.green : Color.gray)
                        if operation?.action != .redeploy, let update = container.update, update.hasUpdate == true, update.error?.isEmpty != false {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                                Text("有更新")
                            }
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .font(.caption)
                    if let operation { ArcaneOperationBadge(status: operation) }
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
        .arcaneRowSeparators()
    }
}

struct ArcaneOperationSection: View {
    @ObservedObject var store: ArcaneStore
    var body: some View {
        if let message = store.operationMessage {
            Section("容器操作") {
                if let pending = store.pending {
                    Text("\(pending.environmentName) · \(pending.containerName)").font(.subheadline).arcaneRowSeparators()
                }
                if store.operationRunning {
                    ProgressView().arcaneRowSeparators()
                }
                Text(message).font(.footnote).textSelection(.enabled).arcaneRowSeparators()
                if !store.operationLogs.isEmpty {
                    DisclosureGroup("操作日志") {
                        Text(store.operationLogs.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled).arcaneRowSeparators()
                    }
                    .arcaneRowSeparators()
                }
                if store.pending != nil && !store.operationRunning {
                    Button("刷新容器状态") { Task { await store.refresh() } }.arcaneRowSeparators()
                    Button("已核对状态，清除此提示") { store.acknowledgeUnknownOperation() }.arcaneRowSeparators()
                }
            }
        }
    }
}
