import SwiftUI

struct QinglongView: View {
    @StateObject private var store = QinglongStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = "tasks"
    @State private var settings = false
    @State private var visible = false

    var body: some View {
        TabView(selection: $tab) {
            QinglongResourceView(store: store, resource: .tasks, active: visible && scenePhase == .active && tab == "tasks" && !settings)
                .tabItem { Label("任务", systemImage: "checklist") }.tag("tasks")
            QinglongResourceView(store: store, resource: .scripts, active: visible && scenePhase == .active && tab == "scripts" && !settings)
                .tabItem { Label("脚本", systemImage: "doc.text") }.tag("scripts")
            QinglongResourceView(store: store, resource: .subscriptions, active: visible && scenePhase == .active && tab == "subscriptions" && !settings)
                .tabItem { Label("订阅", systemImage: "arrow.triangle.branch") }.tag("subscriptions")
            more.tabItem { Label("更多", systemImage: "square.grid.2x2") }.tag("more")
        }
        .tint(.primary)
        .navigationTitle("青龙面板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("青龙连接设置").disabled(store.busy)
            }
        }
        .sheet(isPresented: $settings) { QinglongConnectionsView(store: store) }
        .onAppear { visible = true; store.load() }
        .onDisappear { visible = false }
    }

    private var more: some View {
        List {
            QinglongConnectionSection(store: store)
            Section("面板资源") {
                ForEach([QinglongResource.envs, .configs, .dependencies, .logs]) { resource in
                    NavigationLink {
                        QinglongResourceView(store: store, resource: resource, active: scenePhase == .active)
                            .navigationTitle(resource.title).navigationBarTitleDisplayMode(.inline)
                    } label: { Label(resource.title, systemImage: resource.symbol) }
                }
            }
            Section("连接与权限") {
                Button { settings = true } label: { Label("连接设置", systemImage: "slider.horizontal.3") }.disabled(store.busy)
                NavigationLink { QinglongPermissionsView(store: store) } label: { Label("应用权限", systemImage: "checkmark.shield") }
            }
            if let error = store.configurationError { Section { Text(error).foregroundStyle(.orange); Button("重新读取") { store.load() } } }
        }
    }
}

struct QinglongConnectionSection: View {
    @ObservedObject var store: QinglongStore
    var body: some View {
        Section {
            if let connection = store.connection {
                if store.configuration.connections.count > 1 {
                    Picker("面板", selection: Binding(get: { connection.id }, set: { id in
                        do { try store.select(id) } catch { store.message = error.localizedDescription }
                    })) {
                        ForEach(store.configuration.connections) { Text($0.name).tag($0.id) }
                    }.disabled(store.busy)
                } else { Label(connection.name, systemImage: "server.rack") }
            } else { Text("尚未配置青龙连接").foregroundStyle(.secondary) }
        }
    }
}

struct QinglongResourceView: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    var active = true
    @State private var visible = false
    @State private var search = ""
    @State private var filter = "全部"
    @State private var creating = false
    @State private var pending: QinglongPendingAction?
    @State private var connectionSettings = false
    private var values: [QinglongItem] { store.items[resource] ?? [] }
    private var filtered: [QinglongItem] {
        values.filter {
            (search.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(search))
            && (filter == "全部" || filter == "运行中" && $0.running || filter == "已禁用" && $0.disabled)
        }
    }
    private var pollKey: String { "\(active && visible && !creating && !connectionSettings):\(store.revision)" }
    private var canCreate: Bool { [.tasks, .scripts, .subscriptions, .envs].contains(resource) }

    var body: some View {
        List {
            QinglongConnectionSection(store: store)
            if store.connection == nil {
                Section {
                    ContentUnavailableView("连接你的青龙", systemImage: "server.rack", description: Text("配置面板地址和应用凭据，管理任务、脚本与订阅。"))
                    Button("配置青龙连接") { connectionSettings = true }
                }
            } else {
                if resource == .tasks { summary }
                Section {
                    if resource == .tasks {
                        Picker("状态", selection: $filter) {
                            ForEach(["全部", "运行中", "已禁用"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented)
                    }
                    if store.loading.contains(resource) && store.items[resource] == nil { ProgressView("正在读取\(resource.title)…") }
                    ForEach(filtered) { item in itemRow(item) }
                    if filtered.isEmpty && !store.loading.contains(resource) && store.errors[resource] == nil {
                        ContentUnavailableView("没有\(resource.title)", systemImage: resource.symbol, description: Text(search.isEmpty ? "当前面板尚无记录。" : "试试其他关键词。"))
                    }
                } header: {
                    HStack {
                        Text("\(resource.title) · \(values.count)")
                        Spacer()
                        if canCreate { Button("新建", systemImage: "plus") { creating = true }.disabled(store.busy) }
                    }
                }
                if let error = store.errors[resource] {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange); Button("重新读取") { Task { await store.refresh(resource) } } }
                }
                if let time = store.updated[resource] {
                    Section { Text("更新于 \(time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error = store.configurationError { Section { Text(error).foregroundStyle(.orange); Button("重新读取连接") { store.load() } } }
            QinglongOperationSection(store: store)
        }
        .searchable(text: $search, prompt: "搜索\(resource.title)")
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refresh(resource) }
        .onAppear { visible = true }.onDisappear { visible = false }
        .task(id: pollKey) {
            guard active, visible, !creating, !connectionSettings else { return }
            repeat {
                await store.refresh(resource)
                guard resource == .tasks || resource == .subscriptions, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            } while !Task.isCancelled
        }
        .sheet(isPresented: $connectionSettings) { QinglongConnectionsView(store: store) }
        .sheet(isPresented: $creating) {
            if resource == .scripts { QinglongFileEditor(store: store, item: QinglongItem(resource: .scripts, raw: .null), creating: true) }
            else { QinglongRecordEditor(store: store, resource: resource, item: nil) }
        }
        .confirmationDialog(pending?.title ?? "确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let action = pending {
                Button(action.title, role: action.action == "stop" ? .destructive : nil) {
                    pending = nil; Task { await store.action(action.action, item: action.item) }
                }
            }
        }
    }

    private var summary: some View {
        Section {
            HStack {
                metric("全部任务", count: values.count)
                Divider()
                metric("正在运行", count: values.filter(\.running).count)
                Divider()
                metric("已禁用", count: values.filter(\.disabled).count)
            }.padding(.vertical, 6)
        }
    }
    private func metric(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(count.formatted()).font(.title2.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func itemRow(_ item: QinglongItem) -> some View {
        if resource == .scripts || resource == .configs || resource == .logs {
            NavigationLink { QinglongFileEditor(store: store, item: item) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.headline)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        } else if resource == .dependencies {
            VStack(alignment: .leading, spacing: 6) { Text(item.title).font(.headline); Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink { QinglongRecordDetail(store: store, item: item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(item.title).font(.headline); Spacer(); QinglongStatus(item: item) }
                        if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
                if resource != .envs {
                    HStack {
                        NavigationLink { QinglongExecutionLog(store: store, item: item) } label: { Label("日志", systemImage: "doc.text.magnifyingglass") }
                        Spacer()
                        Button(item.running ? "停止" : resource == .subscriptions ? "拉取" : "运行", systemImage: item.running ? "stop" : "play") {
                            pending = QinglongPendingAction(item: item, action: item.running ? "stop" : "run")
                        }.disabled(store.busy || item.disabled)
                    }.font(.subheadline).buttonStyle(.borderless).frame(minHeight: 36)
                }
            }.padding(.vertical, 8)
        }
    }
}

struct QinglongPendingAction {
    let item: QinglongItem
    let action: String
    var title: String { "\(action == "stop" ? "停止" : action == "run" ? "运行" : action == "disable" ? "禁用" : "启用")「\(item.title)」" }
}

struct QinglongStatus: View {
    let item: QinglongItem
    var body: some View {
        Text(item.stateText).font(.caption)
            .foregroundStyle(item.running ? Color.orange : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct QinglongOperationSection: View {
    @ObservedObject var store: QinglongStore
    var body: some View {
        if store.busy || store.message != nil {
            Section("操作结果") {
                if store.busy { ProgressView("正在处理…") }
                if let message = store.message { Text(message).font(.footnote).textSelection(.enabled) }
                if !store.busy { Button("清除提示") { store.message = nil } }
            }
        }
    }
}
