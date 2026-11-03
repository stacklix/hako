import SwiftUI

enum QinglongMoreRoute: Hashable, Identifiable {
    case resource(QinglongResource), settings, permissions
    var id: String {
        switch self { case .resource(let resource): return "resource:" + resource.rawValue; case .settings: return "settings"; case .permissions: return "permissions" }
    }
}

enum QinglongTab: String, CaseIterable {
    case tasks = "任务", scripts = "脚本", subscriptions = "订阅", more = "更多"
    var symbol: String { switch self { case .tasks: return "checklist"; case .scripts: return "doc.text"; case .subscriptions: return "arrow.triangle.branch"; case .more: return "square.grid.2x2" } }
    var resource: QinglongResource? { switch self { case .tasks: return .tasks; case .scripts: return .scripts; case .subscriptions: return .subscriptions; case .more: return nil } }
}

private enum QinglongDestination: Identifiable {
    case connection, newScript, detail(QinglongItem), edit(QinglongResource, QinglongItem?), file(QinglongItem, Bool), log(QinglongItem), action(QinglongItem, String), scriptRun(QinglongItem)
    var id: String {
        switch self {
        case .connection: return "connection"
        case .newScript: return "new-script"
        case .detail(let item): return "detail:" + item.id
        case .edit(let resource, let item): return "edit:" + resource.rawValue + (item?.id ?? "new")
        case .file(let item, let creating): return "file:" + item.id + String(creating)
        case .log(let item): return "log:" + item.id
        case .action(let item, let action): return action + item.id
        case .scriptRun(let item): return "run:" + item.id
        }
    }
}

struct QinglongView: View {
    @StateObject private var store = QinglongStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = QinglongTab.tasks
    @State private var destination: QinglongDestination?
    @State private var taskAction: QinglongTaskAction?
    @State private var page: QinglongMoreRoute?
    private var resource: QinglongResource? { tab.resource }
    private var lastUpdated: Date? { resource.flatMap { store.updated[$0] } ?? store.updated.values.max() }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let resource {
                QinglongResourceView(store: store, resource: resource,
                    active: scenePhase == .active && destination == nil && taskAction == nil && page == nil,
                    open: open, create: { create(resource) }, configure: { destination = .connection }, showsCreate: true)
                    .id(resource)
            } else { more }
        }
        .background(QinglongStyle.background).foregroundStyle(QinglongStyle.text).tint(QinglongStyle.text)
        .safeAreaInset(edge: .bottom, spacing: 0) { QinglongTabBar(selection: tab) { tab = $0 } }
        .overlay(alignment: .bottom) { toast.padding(.horizontal, 20).padding(.bottom, 72) }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { page = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("青龙面板设置").disabled(store.busy)
            }
        }
        .toolbarBackground(QinglongStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(item: $page) { route in
            Group {
                switch route {
                case .settings: QinglongSettingsView(store: store)
                case .permissions: QinglongPermissionsView(store: store, embedded: true)
                case .resource(let resource): QinglongMoreResourcePage(store: store, resource: resource)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                QinglongTabBar(selection: tab) { tab = $0; page = nil }
            }
        }
        .qinglongTaskAction(store: store, request: $taskAction)
        .sheet(item: $destination) { target in
            switch target {
            case .connection: QinglongConnectionEditor(store: store, initial: store.connection ?? QinglongConnection())
            case .newScript: QinglongNewScriptFlow(store: store)
            case .detail(let item): QinglongRecordDetail(store: store, item: item)
            case .edit(let resource, let item): QinglongRecordEditor(store: store, resource: resource, item: item)
            case .file(let item, let creating): QinglongFileEditor(store: store, item: item, creating: creating)
            case .log(let item): QinglongExecutionLog(store: store, item: item)
            case .action(let item, let action): QinglongActionSheet(store: store, item: item, action: action)
            case .scriptRun(let item): QinglongScriptRunner(store: store, item: item)
            }
        }
        .onAppear { store.load() }
        .task(id: "\(store.busy):\(store.message ?? "")") {
            guard let message = store.message, !store.busy else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if store.message == message { store.message = nil }
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("青龙面板").font(.system(size: 28, weight: .bold)).tracking(-0.7)
                HStack(spacing: 6) {
                    Circle().fill(lastUpdated != nil ? QinglongStyle.success : QinglongStyle.muted).frame(width: 5, height: 5)
                    Text(store.connection.map { $0.name + " · " + (lastUpdated.map { "已同步 " + $0.formatted(date: .omitted, time: .shortened) } ?? "等待读取") } ?? "尚未配置面板")
                        .font(.system(size: 11)).foregroundStyle(QinglongStyle.muted)
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
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
                Text("面板资源").font(.system(size: 14, weight: .semibold))
                VStack(spacing: 0) {
                    ForEach([QinglongResource.envs, .configs, .dependencies, .logs]) { resource in
                        QinglongPageLink(title: resource.title, symbol: resource.symbol, last: resource == .logs) { page = .resource(resource) }
                    }
                }.qinglongCard(padding: 0)
                Text("面板管理").font(.system(size: 14, weight: .semibold))
                VStack(spacing: 0) {
                    QinglongPageLink(title: "设置", symbol: "slider.horizontal.3") { page = .settings }
                    QinglongPageLink(title: "应用权限", symbol: "checkmark.shield", last: true) { page = .permissions }
                }.qinglongCard(padding: 0)
                if let error = store.configurationError { QinglongNotice(text: error, error: true); Button("重新读取连接") { store.load() }.buttonStyle(QinglongSecondaryButtonStyle()) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
    }
    private func create(_ resource: QinglongResource) {
        destination = resource == .scripts ? .newScript : .edit(resource, nil)
    }
    private func open(_ item: QinglongItem, _ action: String) {
        if item.resource == .tasks && ["run", "stop"].contains(action) {
            taskAction = QinglongTaskAction(item: item, action: action, revision: store.revision); return
        }
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

struct QinglongTabBar: View {
    let selection: QinglongTab
    let select: (QinglongTab) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(QinglongTab.allCases, id: \.self) { tab in
                Button { select(tab) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 21))
                        Text(tab.rawValue).font(.system(size: 11, weight: tab == selection ? .semibold : .regular))
                    }.foregroundStyle(tab == selection ? QinglongStyle.text : QinglongStyle.muted)
                        .frame(maxWidth: .infinity).frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(tab == selection ? .isSelected : [])
            }
        }.padding(.horizontal, 12).padding(.top, 5).background(QinglongStyle.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(QinglongStyle.line).frame(height: 1) }
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
    var showsCreate = false
    @State private var search = ""
    @State private var filter = "全部"
    private var values: [QinglongItem] { store.items[resource] ?? [] }
    private var filtered: [QinglongItem] {
        values.filter { item in
            (search.isEmpty || (item.title + " " + item.subtitle).localizedCaseInsensitiveContains(search))
            && (filter == "全部" || filter == "运行中" && item.running || filter == "已禁用" && item.disabled || filter == "失败" && store.outcomes[item.id]?.failed == true)
        }
    }
    private struct RefreshKey: Equatable {
        let active: Bool
        let resource: QinglongResource
        let revision: UUID
        let connectionID: String?
    }
    private var canCreate: Bool { [.tasks, .scripts, .subscriptions, .envs].contains(resource) }

    var body: some View {
        let refreshKey = RefreshKey(active: active, resource: resource, revision: store.revision, connectionID: store.connection?.id)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let back { Button(action: back) { Label("更多", systemImage: "chevron.left") }.buttonStyle(QinglongInlineButtonStyle()) }
                if store.connection == nil { emptyConnection }
                else {
                    if resource == .tasks { summary }
                    if resource != .subscriptions { searchField }
                    sectionHeader
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.horizontal, 16) }
                            if resource == .envs || resource == .scripts { card(item) }
                            else { card(item).padding(.horizontal, 16).padding(.vertical, 16) }
                        }
                    }.qinglongCard(padding: 0)
                    if store.loading.contains(resource) && store.items[resource] == nil { ProgressView("正在读取\(resource.title)…").frame(maxWidth: .infinity).padding() }
                    if filtered.isEmpty && !store.loading.contains(resource) && store.errors[resource] == nil {
                        Text(search.isEmpty ? "暂无\(resource.title)" : "没有匹配的\(resource.title)").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if let error = store.errors[resource] { QinglongNotice(text: error, error: true); Button("重新读取") { Task { await store.refresh(resource) } }.buttonStyle(QinglongSecondaryButtonStyle()) }
                    if let time = store.updated[resource] { Text("\(time.formatted(date: .omitted, time: .standard)) 更新\(resource == .tasks ? " · 按面板时区执行" : "")").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }
                if let error = store.configurationError { QinglongNotice(text: error, error: true); Button("重新读取连接") { store.load() }.buttonStyle(QinglongSecondaryButtonStyle()) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively).refreshable { await store.refresh(resource) }
        .task(id: refreshKey) { [refreshKey] in
            guard refreshKey.active, refreshKey.connectionID != nil else { return }
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
            Text(resource == .tasks ? "定时任务" : resource == .scripts ? "脚本管理" : resource == .subscriptions ? "订阅管理" : resource.title).font(.system(size: 14, weight: .semibold))
            if resource != .tasks { Text(values.count.formatted()).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if resource == .tasks { filters }
            if canCreate && showsCreate { Button(resource == .envs || resource == .subscriptions ? "新增" : "新建", systemImage: "plus", action: create).buttonStyle(QinglongPrimaryButtonStyle(compact: true)).disabled(store.busy) }
        }
    }
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
            TextField(resource == .tasks ? "搜索任务名称或命令" : resource == .scripts ? "搜索脚本名称或目录" : "搜索\(resource.title)", text: $search)
                .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("搜索\(resource.title)")
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
        }.padding(.horizontal, 12).frame(minHeight: 44).background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(QinglongStyle.line, lineWidth: 1) }
    }
    private var filters: some View {
        Menu {
            Picker("任务状态", selection: $filter) { ForEach(["全部", "运行中", "失败", "已禁用"], id: \.self) { Text($0) } }
        } label: {
            HStack(spacing: 8) { Text(filter); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .font(.system(size: 12)).padding(.horizontal, 10).frame(minHeight: 36)
                .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(QinglongStyle.line, lineWidth: 1) }
        }.accessibilityLabel("任务状态，" + filter)
    }
    private var summary: some View {
        HStack(spacing: 0) {
            metric("全部任务", value: values.count.formatted()); Divider().frame(height: 36)
            metric("正在运行", value: values.filter(\.running).count.formatted()); Divider().frame(height: 36)
            metric("最近失败", value: !store.outcomesComplete ? "—" : store.outcomes.values.filter(\.failed).count.formatted())
        }.padding(.vertical, 16).background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(spacing: 8) { Text(title).font(.system(size: 11)).foregroundStyle(QinglongStyle.muted); HStack(alignment: .firstTextBaseline, spacing: 3) { Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit(); Text("项").font(.system(size: 11)).foregroundStyle(QinglongStyle.muted) } }.frame(maxWidth: .infinity).padding(.horizontal, 10)
    }
    @ViewBuilder private func card(_ item: QinglongItem) -> some View {
        switch resource {
        case .tasks: taskCard(item)
        case .scripts: scriptCard(item)
        case .subscriptions: subscriptionCard(item)
        case .envs: environmentCard(item)
        default:
            Button { open(item, "file") } label: {
                HStack { VStack(alignment: .leading, spacing: 6) { Text(item.title).font(.subheadline.weight(.semibold)); Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }.buttonStyle(.plain)
        }
    }
    private func taskCard(_ item: QinglongItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open(item, "detail") } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        QinglongStatus(item: item, outcome: store.outcomes[item.id])
                    }
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.bottom, 10).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("查看任务详情")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { taskDetailSummary(item); taskActions(item) }
                VStack(alignment: .leading, spacing: 3) { taskDetailSummary(item); HStack { Spacer(); taskActions(item) } }
            }
        }
    }
    private func taskDetailSummary(_ item: QinglongItem) -> some View {
        Button { open(item, "detail") } label: {
            Text(store.outcomes[item.id]?.summary ?? item.lastRunText).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("查看任务详情")
    }
    private func taskActions(_ item: QinglongItem) -> some View {
        HStack(spacing: 14) {
            Button("日志", systemImage: "doc.text") { open(item, "log") }
            Button(item.running ? "停止" : "运行", systemImage: item.running ? "stop" : "play") { open(item, item.running ? "stop" : "run") }.disabled(store.busy)
        }.buttonStyle(QinglongInlineButtonStyle())
    }
    private func scriptCard(_ item: QinglongItem) -> some View {
        HStack(spacing: 0) {
            Button { open(item, "file") } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("编辑脚本 \(item.filePath)")
            Button("运行", systemImage: "play") { open(item, "run-script") }
                .buttonStyle(QinglongInlineButtonStyle()).padding(.trailing, 16).disabled(store.busy)
                .accessibilityLabel("运行脚本 \(item.title)")
        }
    }
    private func subscriptionCard(_ item: QinglongItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { cardTitle(item, action: "edit"); Spacer(minLength: 8); QinglongStatus(item: item) }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack { Text(item.raw["schedule"].text.isEmpty ? "间隔计划" : item.raw["schedule"].text).font(.caption).foregroundStyle(.secondary); Spacer(); Button(item.running ? "停止拉取" : "立即拉取", systemImage: item.running ? "stop" : "arrow.clockwise") { open(item, item.running ? "stop" : "run") }.buttonStyle(QinglongInlineButtonStyle()).disabled(store.busy || item.disabled) }
            HStack { Text(item.lastRunText).font(.caption).foregroundStyle(.secondary); Spacer(); Button("查看日志") { open(item, "log") }.buttonStyle(QinglongInlineButtonStyle()) }
        }
    }
    private func environmentCard(_ item: QinglongItem) -> some View {
        Button { open(item, "edit") } label: {
            Text(item.title).font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("编辑变量 \(item.title)")
    }
    private func cardTitle(_ item: QinglongItem, action: String) -> some View {
        Button { open(item, action) } label: { Text(item.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) }.buttonStyle(.plain)
    }
}

struct QinglongStatus: View {
    let item: QinglongItem
    var outcome: QinglongOutcome? = nil
    private var state: String { item.disabled || item.running || item.queued ? item.stateText : outcome?.stateText ?? item.stateText }
    private var color: Color { if item.running || item.queued { return QinglongStyle.warning }; if item.disabled { return .secondary }; if outcome?.failed == true { return QinglongStyle.failure }; if outcome?.succeeded == true || item.resource == .envs { return QinglongStyle.success }; return .secondary }
    var body: some View { Text("· " + state).font(.caption2).foregroundStyle(color).fixedSize() }
}

struct QinglongFileResourceList: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    @Environment(\.scenePhase) private var phase
    @State private var selected: QinglongItem?
    private var values: [QinglongItem] { store.items[resource] ?? [] }
    private var loading: Bool { store.loading.contains(resource) }
    private var countText: String {
        if resource == .dependencies {
            let failures = values.filter { $0.dependencyStatus?.failed == true }.count
            return "\(values.count) 项依赖" + (failures > 0 ? " · \(failures) 项失败" : "")
        }
        return "\(values.count) 个\(resource == .logs ? "日志文件" : "文件")"
    }
    private struct RefreshKey: Equatable {
        let revision: UUID
        let active: Bool
        let connectionID: String?
    }
    var body: some View {
        let key = RefreshKey(revision: store.revision, active: phase == .active && selected == nil, connectionID: store.connection?.id)
        content
        .task(id: key) {
            guard key.active, key.connectionID != nil else { return }
            await store.refresh(resource)
        }
        .sheet(item: $selected) { QinglongFileEditor(store: store, item: $0) }
    }
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                if !values.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(values.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.leading, 63) }
                            if resource == .dependencies { row(item).accessibilityElement(children: .combine) }
                            else {
                                Button { selected = item } label: { row(item) }
                                    .buttonStyle(QinglongFileRowButtonStyle())
                                    .accessibilityLabel("\(resource == .logs ? "查看" : "编辑") \(item.filePath)")
                            }
                        }
                    }.background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                if loading && store.items[resource] == nil {
                    ProgressView("正在读取\(resource.title)…").frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                if let error = store.errors[resource] {
                    QinglongNotice(text: error, error: true)
                } else if values.isEmpty && !loading && store.connection != nil && store.items[resource] != nil {
                    ContentUnavailableView("暂无\(resource.title)", systemImage: resource.symbol)
                }
                if let error = store.configurationError { QinglongNotice(text: error, error: true) }
                if store.connection == nil {
                    Text("请先在青龙面板设置中配置连接。").font(.subheadline).foregroundStyle(QinglongStyle.muted)
                }
                if let time = store.updated[resource] {
                    Text("\(time.formatted(date: .omitted, time: .standard)) 更新").font(.caption)
                        .foregroundStyle(QinglongStyle.muted).frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 26)
        }
        .refreshable { await store.refresh(resource) }
        .background(QinglongStyle.background).foregroundStyle(QinglongStyle.text)
        .navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QinglongStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(resource.title).font(.system(size: 28, weight: .bold)).tracking(-0.7)
                Text(store.items[resource] == nil ? "等待读取" : countText).font(.system(size: 13)).foregroundStyle(QinglongStyle.muted)
            }
            Spacer(minLength: 0)
            Button { Task { await store.refresh(resource) } } label: {
                Group {
                    if loading { ProgressView().tint(QinglongStyle.text) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 18)) }
                }.frame(width: 44, height: 44).background(QinglongStyle.surface, in: Circle())
            }.buttonStyle(.plain).disabled(loading || store.connection == nil)
                .accessibilityLabel("刷新\(resource.title)")
        }
    }
    private func row(_ item: QinglongItem) -> some View {
        HStack(spacing: 13) {
            Image(systemName: resource == .dependencies ? "shippingbox" : "doc.text")
                .font(.system(size: 25, weight: .light)).foregroundStyle(QinglongStyle.muted)
                .frame(width: 34, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(resource == .dependencies ? item.title : item.filename).font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(subtitle(item)).font(.caption).foregroundStyle(QinglongStyle.muted)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if resource == .dependencies {
                dependencyState(item)
            } else {
                if resource == .configs {
                    Text(fileType(item)).font(.system(.caption2, design: .monospaced)).foregroundStyle(QinglongStyle.muted)
                        .padding(.horizontal, 5).padding(.vertical, 3).background(QinglongStyle.code, in: RoundedRectangle(cornerRadius: 5))
                }
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(QinglongStyle.muted).accessibilityHidden(true)
            }
        }.padding(.horizontal, 16).padding(.vertical, 17).frame(minHeight: 78).contentShape(Rectangle())
    }
    private func subtitle(_ item: QinglongItem) -> String {
        guard resource == .configs else { return item.subtitle }
        switch item.filename {
        case "config.sh": return "基础配置"
        case "extra.sh": return "自定义扩展"
        case "task_after.sh", "task_after.js", "task_after.py": return "任务后置脚本"
        case "task_before.sh", "task_before.js", "task_before.py": return "任务前置脚本"
        default: return item.language == "文本" ? "配置文件" : item.language + " 脚本"
        }
    }
    private func fileType(_ item: QinglongItem) -> String {
        let value = (item.filename as NSString).pathExtension
        return value.isEmpty ? "TXT" : value.uppercased()
    }
    private func dependencyState(_ item: QinglongItem) -> some View {
        let status = item.dependencyStatus
        let color: Color = status?.failed == true ? QinglongStyle.failure : status == .installed ? QinglongStyle.success
            : [.installing, .removing, .queued].contains(status) ? QinglongStyle.warning : QinglongStyle.muted
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 4, height: 4).accessibilityHidden(true)
            Text(status?.title ?? "未知状态").font(.caption).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(color)
    }
}

private struct QinglongFileRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity)
            .background(configuration.isPressed ? QinglongStyle.code : Color.clear)
    }
}

struct QinglongMoreResourcePage: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    @Environment(\.scenePhase) private var phase
    @State private var selected: QinglongItem?
    @State private var creating = false
    @State private var configuring = false
    var body: some View {
        Group {
            if resource == .envs {
                QinglongResourceView(store: store, resource: resource, active: phase == .active && selected == nil && !creating && !configuring,
                    open: { item, _ in selected = item }, create: { creating = true }, configure: { configuring = true }, showsCreate: true)
                    .navigationTitle(resource.title).navigationBarTitleDisplayMode(.inline)
            } else { QinglongFileResourceList(store: store, resource: resource) }
        }.background(QinglongStyle.background).tint(QinglongStyle.text)
        .sheet(item: $selected) { QinglongRecordEditor(store: store, resource: resource, item: $0) }
        .sheet(isPresented: $creating) { QinglongRecordEditor(store: store, resource: resource, item: nil) }
        .sheet(isPresented: $configuring) { QinglongConnectionEditor(store: store, initial: store.connection ?? QinglongConnection()) }
    }
}
