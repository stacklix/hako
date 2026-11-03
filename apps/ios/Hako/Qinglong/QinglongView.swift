import SwiftUI

private enum QinglongTab: String, CaseIterable {
    case tasks = "任务", scripts = "脚本", subscriptions = "订阅", more = "更多"
    var symbol: String { switch self { case .tasks: return "checklist"; case .scripts: return "doc.text"; case .subscriptions: return "arrow.triangle.branch"; case .more: return "square.grid.2x2" } }
    var resource: QinglongResource? { switch self { case .tasks: return .tasks; case .scripts: return .scripts; case .subscriptions: return .subscriptions; case .more: return nil } }
}

private enum QinglongDestination: Identifiable {
    case connection, instances, permissions, detail(QinglongItem), edit(QinglongResource, QinglongItem?), file(QinglongItem, Bool), log(QinglongItem), action(QinglongItem, String), scriptRun(QinglongItem), resource(QinglongResource)
    var id: String {
        switch self {
        case .connection: return "connection"; case .instances: return "instances"; case .permissions: return "permissions"
        case .detail(let item): return "detail:" + item.id
        case .edit(let resource, let item): return "edit:" + resource.rawValue + (item?.id ?? "new")
        case .file(let item, let creating): return "file:" + item.id + String(creating)
        case .log(let item): return "log:" + item.id
        case .action(let item, let action): return action + item.id
        case .scriptRun(let item): return "run:" + item.id
        case .resource(let resource): return resource.rawValue
        }
    }
}

struct QinglongView: View {
    @StateObject private var store = QinglongStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = QinglongTab.tasks
    @State private var secondaryResource: QinglongResource?
    @State private var destination: QinglongDestination?
    @State private var visible = false
    private var resource: QinglongResource? { secondaryResource ?? tab.resource }
    private var lastUpdated: Date? { resource.flatMap { store.updated[$0] } ?? store.updated.values.max() }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let resource {
                QinglongResourceView(store: store, resource: resource,
                    active: visible && scenePhase == .active && destination == nil,
                    back: secondaryResource == nil ? nil : { secondaryResource = nil },
                    open: open, create: { create(resource) }, configure: { destination = .connection })
                    .id(resource)
            } else { more }
        }
        .background(QinglongStyle.background).tint(.primary)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .overlay(alignment: .bottom) { toast.padding(.horizontal, 20).padding(.bottom, 76) }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { destination = .connection } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("青龙连接设置").disabled(store.busy)
            }
        }
        .sheet(item: $destination) { target in
            switch target {
            case .connection: QinglongConnectionEditor(store: store, initial: store.connection ?? QinglongConnection())
            case .instances: QinglongInstancesView(store: store)
            case .permissions: QinglongPermissionsView(store: store)
            case .detail(let item): QinglongRecordDetail(store: store, item: item)
            case .edit(let resource, let item): QinglongRecordEditor(store: store, resource: resource, item: item)
            case .file(let item, let creating): QinglongFileEditor(store: store, item: item, creating: creating)
            case .log(let item): QinglongExecutionLog(store: store, item: item)
            case .action(let item, let action): QinglongActionSheet(store: store, item: item, action: action)
            case .scriptRun(let item): QinglongScriptRunner(store: store, item: item)
            case .resource(let resource): QinglongResourceSheet(store: store, resource: resource)
            }
        }
        .onAppear { visible = true; store.load() }.onDisappear { visible = false }
        .onChange(of: store.revision) { _, _ in secondaryResource = nil }
        .task(id: store.message) {
            guard let message = store.message, !store.busy else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if store.message == message { store.message = nil }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) { title; Spacer(minLength: 0); instancePicker }
                VStack(alignment: .leading, spacing: 8) { title; instancePicker }
            }
            Text(store.connection == nil ? "尚未配置面板" : lastUpdated.map { "已连接 · \($0.formatted(date: .omitted, time: .shortened)) 更新" } ?? "已配置 · 等待读取")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 16)
    }
    private var title: some View { Text("青龙面板").font(.system(size: 30, weight: .semibold)).accessibilityAddTraits(.isHeader) }
    private var instancePicker: some View {
        Button { destination = .instances } label: {
            HStack(spacing: 7) {
                Circle().fill(lastUpdated != nil ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(store.connection?.name ?? "添加面板").font(.system(size: 13)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11))
            }.padding(.horizontal, 11).frame(minHeight: 40)
                .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(store.busy).accessibilityLabel("切换面板，\(store.connection?.name ?? "尚未配置")")
    }
    private var tabBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(QinglongTab.allCases, id: \.self) { option in
                    Button { tab = option; secondaryResource = nil } label: {
                        VStack(spacing: 4) {
                            Image(systemName: option.symbol).font(.system(size: 20))
                            Text(option.rawValue).font(.system(size: 11, weight: tab == option ? .semibold : .regular))
                        }.foregroundStyle(tab == option ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity).frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == option ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
        }.background(QinglongStyle.surface.ignoresSafeArea(edges: .bottom))
    }
    @ViewBuilder private var toast: some View {
        if store.busy || store.message != nil {
            HStack(spacing: 10) {
                if store.busy { ProgressView().tint(Color(uiColor: .systemBackground)) }
                Text(store.busy ? "正在处理…" : store.message ?? "").font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !store.busy { Button { store.message = nil } label: { Image(systemName: "xmark").frame(width: 28, height: 32) }.buttonStyle(.plain).accessibilityLabel("关闭操作提示") }
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(Color(uiColor: .systemBackground)).background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var more: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("面板资源").font(.headline)
                VStack(spacing: 0) {
                    ForEach([QinglongResource.envs, .configs, .dependencies, .logs]) { resource in
                        QinglongMenuRow(title: resource.title, symbol: resource.symbol, last: resource == .logs) {
                            if resource == .envs { secondaryResource = resource } else { destination = .resource(resource) }
                        }
                    }
                }.qinglongCard(padding: 0)
                Text("连接与权限").font(.headline)
                VStack(spacing: 0) {
                    QinglongMenuRow(title: "连接设置", symbol: "slider.horizontal.3") { destination = .connection }
                    QinglongMenuRow(title: "应用权限", symbol: "checkmark.shield", last: true) { destination = .permissions }
                }.qinglongCard(padding: 0)
                Text("凭据保存在本机 Keychain。日志不记录变量值、认证头或 Client Secret。").font(.caption).foregroundStyle(.secondary)
                if let error = store.configurationError { QinglongNotice(text: error, error: true); Button("重新读取连接") { store.load() }.buttonStyle(QinglongSecondaryButtonStyle()) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
    }
    private func create(_ resource: QinglongResource) {
        destination = resource == .scripts ? .file(QinglongItem(resource: .scripts, raw: .null), true) : .edit(resource, nil)
    }
    private func open(_ item: QinglongItem, _ action: String) {
        switch action {
        case "log": destination = .log(item)
        case "edit": destination = .edit(item.resource, item)
        case "file": destination = .file(item, false)
        case "run-script": destination = .scriptRun(item)
        case "detail": destination = .detail(item)
        default: destination = .action(item, action)
        }
    }
}

struct QinglongResourceView: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    var active = true
    var back: (() -> Void)? = nil
    let open: (QinglongItem, String) -> Void
    let create: () -> Void
    let configure: () -> Void
    @State private var visible = false
    @State private var search = ""
    @State private var filter = "全部"
    @State private var revealed = Set<String>()
    private var values: [QinglongItem] { store.items[resource] ?? [] }
    private var filtered: [QinglongItem] {
        values.filter { item in
            (search.isEmpty || (item.title + " " + item.subtitle).localizedCaseInsensitiveContains(search))
            && (filter == "全部" || filter == "运行中" && item.running || filter == "已禁用" && item.disabled || filter == "失败" && store.outcomes[item.id]?.failed == true)
        }
    }
    private var pollKey: String { "\(active && visible):\(store.revision)" }
    private var canCreate: Bool { [.tasks, .scripts, .subscriptions, .envs].contains(resource) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let back { Button(action: back) { Label("更多", systemImage: "chevron.left") }.buttonStyle(QinglongInlineButtonStyle()) }
                if store.connection == nil { emptyConnection }
                else {
                    if resource == .tasks { summary }
                    if resource != .subscriptions { searchField }
                    sectionHeader
                    if resource == .tasks { filters }
                    LazyVStack(spacing: 10) { ForEach(filtered) { item in card(item) } }
                    if store.loading.contains(resource) && store.items[resource] == nil { ProgressView("正在读取\(resource.title)…").frame(maxWidth: .infinity).padding() }
                    if filtered.isEmpty && !store.loading.contains(resource) && store.errors[resource] == nil {
                        Text(search.isEmpty ? "暂无\(resource.title)" : "没有匹配的\(resource.title)").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if let error = store.errors[resource] { QinglongNotice(text: error, error: true); Button("重新读取") { Task { await store.refresh(resource) } }.buttonStyle(QinglongSecondaryButtonStyle()) }
                    if resource == .envs { Text("变量值默认隐藏，点击眼睛可查看。").font(.caption).foregroundStyle(.secondary) }
                    if let time = store.updated[resource] { Text("\(time.formatted(date: .omitted, time: .standard)) 更新\(resource == .tasks ? " · 按面板时区执行" : "")").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }
                if let error = store.configurationError { QinglongNotice(text: error, error: true); Button("重新读取连接") { store.load() }.buttonStyle(QinglongSecondaryButtonStyle()) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively).refreshable { await store.refresh(resource) }
        .onAppear { visible = true }.onDisappear { visible = false }
        .onChange(of: store.revision) { _, _ in revealed = [] }
        .task(id: pollKey) {
            guard active, visible else { return }
            repeat {
                await store.refresh(resource)
                guard resource == .tasks || resource == .subscriptions, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private var emptyConnection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接你的青龙面板").font(.headline)
            Text("填写面板地址与应用凭据，开始管理任务、脚本和订阅。").font(.subheadline).foregroundStyle(.secondary)
            Button("配置连接", action: configure).buttonStyle(QinglongPrimaryButtonStyle())
        }.qinglongCard()
    }
    private var sectionHeader: some View {
        HStack {
            Text(resource == .tasks ? "定时任务" : resource == .scripts ? "脚本管理" : resource == .subscriptions ? "订阅管理" : resource.title).font(.system(size: 16, weight: .semibold))
            if resource != .tasks { Text(values.count.formatted()).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if canCreate { Button(resource == .envs || resource == .subscriptions ? "新增" : "新建", systemImage: "plus", action: create).buttonStyle(QinglongPrimaryButtonStyle(compact: true)).disabled(store.busy) }
        }
    }
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
            TextField(resource == .tasks ? "搜索任务名称或命令" : resource == .scripts ? "搜索脚本名称或目录" : "搜索\(resource.title)", text: $search)
                .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("搜索\(resource.title)")
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
        }.padding(.horizontal, 12).frame(minHeight: 44).background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { filterButtons }
            VStack(alignment: .leading, spacing: 6) { filterButtons }
        }
    }
    @ViewBuilder private var filterButtons: some View {
        ForEach(["全部", "运行中", "失败", "已禁用"], id: \.self) { option in
            Button { filter = option } label: {
                Text(option).font(.caption).padding(.horizontal, 12).frame(minHeight: 36)
                    .foregroundStyle(filter == option ? Color(uiColor: .systemBackground) : .secondary)
                    .background(filter == option ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).accessibilityAddTraits(filter == option ? .isSelected : [])
        }
    }
    private var summary: some View {
        HStack(spacing: 0) {
            metric("全部任务", value: values.count.formatted()); Divider().frame(height: 36)
            metric("正在运行", value: values.filter(\.running).count.formatted()); Divider().frame(height: 36)
            metric("最近失败", value: !store.outcomesComplete ? "—" : store.outcomes.values.filter(\.failed).count.formatted())
        }.padding(.vertical, 16).background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 23, weight: .semibold)).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
    }
    @ViewBuilder private func card(_ item: QinglongItem) -> some View {
        switch resource {
        case .tasks: taskCard(item)
        case .scripts: scriptCard(item)
        case .subscriptions: subscriptionCard(item)
        case .envs: environmentCard(item)
        default:
            Button { open(item, "file") } label: {
                HStack { VStack(alignment: .leading, spacing: 6) { Text(item.title).font(.subheadline.weight(.semibold)); Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.qinglongCard()
            }.buttonStyle(.plain)
        }
    }
    private func taskCard(_ item: QinglongItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { cardTitle(item, action: "detail"); Spacer(minLength: 8); QinglongStatus(item: item, outcome: store.outcomes[item.id]) }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Text(store.outcomes[item.id]?.summary ?? item.lastRunText).font(.caption).foregroundStyle(.secondary); Spacer(minLength: 0); taskActions(item) }
                VStack(alignment: .leading, spacing: 3) { Text(store.outcomes[item.id]?.summary ?? item.lastRunText).font(.caption).foregroundStyle(.secondary); HStack { Spacer(); taskActions(item) } }
            }
        }.qinglongCard()
    }
    private func taskActions(_ item: QinglongItem) -> some View {
        HStack(spacing: 14) {
            Button("日志", systemImage: "doc.text") { open(item, "log") }
            Button(item.running ? "停止" : "运行", systemImage: item.running ? "stop" : "play") { open(item, item.running ? "stop" : "run") }.disabled(store.busy || item.disabled)
        }.buttonStyle(QinglongInlineButtonStyle())
    }
    private func scriptCard(_ item: QinglongItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { cardTitle(item, action: "file"); Spacer(minLength: 8); Text(item.language).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(QinglongStyle.code, in: RoundedRectangle(cornerRadius: 6)) }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("查看与编辑", systemImage: "pencil") { open(item, "file") }
                Spacer()
                Button("运行", systemImage: "play") { open(item, "run-script") }.disabled(store.busy)
            }.buttonStyle(QinglongInlineButtonStyle())
        }.qinglongCard()
    }
    private func subscriptionCard(_ item: QinglongItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { cardTitle(item, action: "edit"); Spacer(minLength: 8); QinglongStatus(item: item) }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack { Text(item.raw["schedule"].text.isEmpty ? "间隔计划" : item.raw["schedule"].text).font(.caption).foregroundStyle(.secondary); Spacer(); Button(item.running ? "停止拉取" : "立即拉取", systemImage: item.running ? "stop" : "arrow.clockwise") { open(item, item.running ? "stop" : "run") }.buttonStyle(QinglongInlineButtonStyle()).disabled(store.busy || item.disabled) }
            Divider()
            HStack { Text(item.lastRunText).font(.caption).foregroundStyle(.secondary); Spacer(); Button("查看日志") { open(item, "log") }.buttonStyle(QinglongInlineButtonStyle()) }
        }.qinglongCard()
    }
    private func environmentCard(_ item: QinglongItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { cardTitle(item, action: "edit"); Spacer(minLength: 8); QinglongStatus(item: item) }
            HStack {
                Text(revealed.contains(item.id) ? item.raw["value"].text : "••••••••••••").font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button { if revealed.contains(item.id) { revealed.remove(item.id) } else { revealed.insert(item.id) } } label: { Image(systemName: revealed.contains(item.id) ? "eye.slash" : "eye").frame(width: 44, height: 36) }.buttonStyle(.plain).accessibilityLabel(revealed.contains(item.id) ? "隐藏变量值" : "显示变量值")
            }
            Divider()
            HStack { Text(item.subtitle).font(.caption).foregroundStyle(.secondary); Spacer(); Button("编辑") { open(item, "edit") }.buttonStyle(QinglongInlineButtonStyle()) }
        }.qinglongCard()
    }
    private func cardTitle(_ item: QinglongItem, action: String) -> some View {
        Button { open(item, action) } label: { Text(item.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) }.buttonStyle(.plain)
    }
}

struct QinglongStatus: View {
    let item: QinglongItem
    var outcome: QinglongOutcome? = nil
    private var state: String { item.disabled || item.running ? item.stateText : outcome?.stateText ?? item.stateText }
    private var color: Color { if item.disabled { return .secondary }; if item.running { return .orange }; if outcome?.failed == true { return .red }; if outcome?.succeeded == true || item.resource == .envs { return .green }; return .secondary }
    var body: some View { Text(state).font(.caption2).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6)).fixedSize() }
}

struct QinglongResourceSheet: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    @State private var selected: QinglongItem?
    var body: some View {
        QinglongSheet(resource.title) {
            if store.loading.contains(resource) { ProgressView("正在读取…") }
            if let error = store.errors[resource] { QinglongNotice(text: error, error: true) }
            ForEach(store.items[resource] ?? []) { item in
                Button { selected = item } label: { HStack { Text(item.title).font(.subheadline); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.qinglongCard() }.buttonStyle(.plain)
            }
            if (store.items[resource] ?? []).isEmpty && !store.loading.contains(resource) { Text("暂无\(resource.title)").font(.subheadline).foregroundStyle(.secondary) }
            Button("刷新") { Task { await store.refresh(resource) } }.buttonStyle(QinglongSecondaryButtonStyle())
        }
        .task(id: store.revision) { await store.refresh(resource) }
        .sheet(item: $selected) { item in
            if resource == .dependencies { QinglongSheet(item.title) { Text(item.subtitle).font(.subheadline); Text("安装状态：\(item.raw["status"].text)").font(.caption).foregroundStyle(.secondary) } }
            else { QinglongFileEditor(store: store, item: item) }
        }
    }
}
