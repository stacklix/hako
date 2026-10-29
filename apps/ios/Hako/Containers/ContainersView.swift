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
    private var initialLoading: Bool { store.loading && store.updatedAt == nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.connection == nil {
                    VStack(spacing: 12) {
                        ContentUnavailableView("连接你的 Arcane", systemImage: "shippingbox", description: Text("填写已有 Arcane 服务地址和 API Key，即可查看和管理 Docker 容器。"))
                        Button("配置 Arcane 连接") { showingSettings = true }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    controls.padding(.bottom, 6)
                    operationSummary
                    if initialLoading && store.containers.isEmpty {
                        ProgressView("正在读取容器…").frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    if let environment = store.environment {
                        containerSections(environment: environment)
                    }
                }
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.top, 16)
                }
                if store.operationMessage != nil { ArcaneOperationSection(store: store).padding(.top, 16) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .animation(nil, value: store.updatedAt)
        .navigationTitle("容器管理")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Arcane 连接设置").disabled(store.operationRunning || store.fileSaveRunning)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(operation.containerName).font(.subheadline.weight(.semibold))
                ArcaneOperationBadge(status: status)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 12).padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func containerSections(environment: ArcaneEnvironment) -> some View {
        containerListHeader
        if groupByProject && !filtered.isEmpty {
            ForEach(projects, id: \.self) { project in
                Text(project).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 3).padding(.top, project == projects.first ? 4 : 16).padding(.bottom, 8)
                containerRows(filtered.filter { ($0.project ?? "独立容器") == project }, environment: environment)
            }
        } else {
            if filtered.isEmpty && !initialLoading {
                ContentUnavailableView("没有符合条件的容器", systemImage: "shippingbox", description: Text("可调整搜索或筛选条件，或下拉刷新。"))
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                containerRows(filtered, environment: environment)
            }
        }
    }

    private func containerRows(_ containers: [ArcaneContainer], environment: ArcaneEnvironment) -> some View {
        ForEach(containers) { container in
            containerLink(container, environment: environment,
                first: container.id == containers.first?.id, last: container.id == containers.last?.id)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            environmentSelector.padding(.bottom, 16)
            searchField.padding(.bottom, 8)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(ContainerFilter.allCases) { option in filterButton(option) }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .frame(height: filterRowHeight)
        }
    }

    private var containerListHeader: some View {
        HStack {
            Text("容器")
            Spacer(minLength: 8)
            composeCheckbox
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(minHeight: 36)
        .padding(.horizontal, 3)
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
                .frame(minHeight: 36)
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
            .disabled(initialLoading)
            .accessibilityLabel(initialLoading ? "正在读取容器" : "刷新容器")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: 36)
                .background(background, in: Capsule())
                .foregroundStyle(foreground)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func containerLink(_ container: ArcaneContainer, environment: ArcaneEnvironment, first: Bool, last: Bool) -> some View {
        let operation = store.operationStatus(environmentID: environment.id, containerID: container.id)
        return NavigationLink {
            ArcaneContainerView(store: store, environment: environment, container: container)
        } label: {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 30, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
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
                    VStack(alignment: .trailing, spacing: 4) {
                        if let cpu = sample.cpuPercent { Text("CPU \(cpu, specifier: "%.1f")%") }
                        if let memory = sample.memoryUsageBytes { Text(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)) }
                    }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 13).padding(.vertical, 15)
            .frame(minHeight: 85)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: UnevenRoundedRectangle(
            topLeadingRadius: first ? 16 : 0, bottomLeadingRadius: last ? 16 : 0,
            bottomTrailingRadius: last ? 16 : 0, topTrailingRadius: first ? 16 : 0))
        .overlay(alignment: .bottom) {
            if !last { Color(uiColor: .separator).frame(height: 0.5).padding(.horizontal, 13).allowsHitTesting(false) }
        }
    }
}

struct ArcaneOperationSection: View {
    @ObservedObject var store: ArcaneStore
    var body: some View {
        if let message = store.operationMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text("容器操作").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 3)
                VStack(alignment: .leading, spacing: 12) {
                    if let pending = store.pending {
                        Text("\(pending.environmentName) · \(pending.containerName)").font(.subheadline)
                    }
                    if store.operationRunning { ProgressView() }
                    Text(message).font(.footnote).textSelection(.enabled)
                    if !store.operationLogs.isEmpty {
                        DisclosureGroup("操作日志") {
                            Text(store.operationLogs.joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if store.pending != nil && !store.operationRunning {
                        Button("刷新容器状态") { Task { await store.refresh() } }.frame(minHeight: 44)
                        Button("已核对状态，清除此提示") { store.acknowledgeUnknownOperation() }.frame(minHeight: 44)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
