import SwiftUI

struct QinglongRecordDetail: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    @State private var editing = false
    @State private var logging = false
    @State private var action: String?
    @State private var taskAction: QinglongTaskAction?
    @State private var openedRevision: UUID?
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    private var current: QinglongItem { store.items[item.resource]?.first { $0.id == item.id } ?? item }
    var body: some View {
        QinglongSheet("任务详情", disabled: store.busy) {
            HStack { Text(current.title).font(.headline); Spacer(); QinglongStatus(item: current, outcome: store.outcomes[item.id]) }
            Text(current.raw["command"].text).qinglongCode()
            VStack(spacing: 0) {
                detail("定时规则", current.raw["schedule"].text)
                detail("最近执行", store.outcomes[item.id]?.summary ?? current.lastRunText)
            }
            Button(current.running ? "停止任务" : "立即运行") {
                taskAction = QinglongTaskAction(item: current, action: current.running ? "stop" : "run", revision: openedRevision ?? store.revision)
            }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(store.busy || current.disabled)
            Button("查看执行日志") { logging = true }.buttonStyle(QinglongSecondaryButtonStyle())
            VStack(spacing: 0) {
                QinglongMenuRow(title: "编辑任务") { editing = true }
                QinglongMenuRow(title: current.disabled ? "启用任务" : "禁用任务") { action = current.disabled ? "enable" : "disable" }
                QinglongMenuRow(title: "删除任务", destructive: true, last: true) { action = "delete" }
            }.qinglongCard(padding: 0).disabled(store.busy)
        }
        .qinglongTaskAction(store: store, request: $taskAction)
        .sheet(isPresented: $editing) { QinglongRecordEditor(store: store, resource: item.resource, item: current) }
        .sheet(isPresented: $logging) { QinglongExecutionLog(store: store, item: current) }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
            if let action { QinglongActionSheet(store: store, item: current, action: action, completed: { if action == "delete" { dismiss() } }) }
        }
        .onAppear { visible = true; if openedRevision == nil { openedRevision = store.revision } }.onDisappear { visible = false }
        .task(id: "\(visible && phase == .active && !editing && !logging && action == nil):\(store.revision)") {
            guard visible, phase == .active, !editing, !logging, action == nil else { return }
            while !Task.isCancelled && (openedRevision == nil || openedRevision == store.revision) {
                await store.refresh(item.resource)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) { HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.subheadline).padding(.vertical, 12); Divider() }
    }
}

struct QinglongRecordEditor: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    let item: QinglongItem?
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String]
    @State private var error: String?
    @State private var enabled: Bool
    @State private var persistedItem: QinglongItem?
    @State private var saveBlocked = false
    private let revision: UUID
    init(store: QinglongStore, resource: QinglongResource, item: QinglongItem?) {
        self.store = store; self.resource = resource; self.item = item; revision = store.revision
        var fields = [String: String]()
        for key in ["name", "command", "schedule", "value", "remarks", "url", "alias", "branch", "whitelist", "blacklist"] { fields[key] = item?.raw[key].text ?? "" }
        if item == nil && resource != .envs { fields["schedule"] = "0 2 * * *" }
        _fields = State(initialValue: fields)
        _enabled = State(initialValue: !(item?.disabled ?? false))
        _persistedItem = State(initialValue: item)
    }
    @State private var action: String?
    var body: some View {
        QinglongSheet("\(item == nil ? "新建" : "编辑")\(resource == .envs ? "变量" : resource == .subscriptions ? "订阅" : "任务")", disabled: store.busy, saveDisabled: saveBlocked, save: { Task { await save() } }) {
            Section {
            field(resource == .envs ? "变量名" : resource == .subscriptions ? "订阅名称" : "任务名称", "name")
            if resource == .tasks {
                VStack(alignment: .leading, spacing: 6) {
                    Text("执行命令").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { fields["command"] ?? "" }, set: { fields["command"] = $0 }))
                        .frame(minHeight: 86).scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("执行命令")
                }
                field("Cron 表达式", "schedule")
            }
            if resource == .envs { field("变量值", "value", secure: true); field("备注", "remarks") }
            if resource == .subscriptions {
                field("仓库地址", "url"); field("别名", "alias")
                if item == nil || item?.raw["schedule_type"].text == "crontab" { field("Cron 表达式", "schedule") }
                DisclosureGroup("更多选项") { field("分支", "branch"); field("包含关键词", "whitelist"); field("排除关键词", "blacklist") }
            }
            }
            if resource == .envs { Section { Toggle("启用此变量", isOn: $enabled).font(.subheadline) } }
            if resource == .tasks { Text("按面板时区执行。").font(.caption).foregroundStyle(.secondary) }
            if let error { QinglongNotice(text: error, error: true) }
            if let item = persistedItem {
                if resource != .envs { Button(item.disabled ? "启用" : "禁用") { action = item.disabled ? "enable" : "disable" }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(store.busy) }
                Button("删除\(resource.title)", role: .destructive) { action = "delete" }.buttonStyle(QinglongSecondaryButtonStyle(destructive: true)).disabled(store.busy)
            }
        }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
            if let item = persistedItem, let action { QinglongActionSheet(store: store, item: item, action: action, completed: { if action == "delete" { dismiss() } }) }
        }
    }
    private func field(_ title: String, _ key: String, secure: Bool = false) -> some View {
        QinglongTextField(title, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }), secure: secure)
    }
    private func save() async {
        guard revision == store.revision else { error = "连接已改变，请关闭后重新编辑。"; return }
        var payload: [String: String]
        switch resource {
        case .tasks: payload = fields.filter { ["name", "command", "schedule"].contains($0.key) }
        case .envs: payload = fields.filter { ["name", "value", "remarks"].contains($0.key) }
        case .subscriptions:
            payload = fields.filter { ["name", "url", "alias", "branch", "whitelist", "blacklist"].contains($0.key) }
            if item == nil || item?.raw["schedule_type"].text == "crontab" { payload["schedule"] = fields["schedule"] }
            if item == nil { payload["type"] = "public-repo"; payload["schedule_type"] = "crontab" }
        default: return
        }
        let required = resource == .tasks ? ["command", "schedule"] : resource == .envs ? ["name", "value"] : ["url", "alias"]
        guard required.allSatisfy({ !(payload[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            error = "请填写所有必填内容。"; return
        }
        if resource == .envs {
            guard !saveBlocked else { return }
            if let result = await store.saveEnvironment(persistedItem, fields: payload, enabled: enabled) {
                persistedItem = result.item; saveBlocked = result.item == nil
                if let error = result.stateError { self.error = error } else { dismiss() }
            } else { error = store.message }
        }
        else if await store.saveRecord(resource, item: item, fields: payload) { dismiss() }
        else { error = store.message }
    }
}

struct QinglongExecutionLog: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var text = ""
    @State private var error: String?
    @State private var loading = false
    @State private var openedRevision: UUID?
    @State private var taskAction: QinglongTaskAction?
    private var current: QinglongItem { store.items[item.resource]?.first { $0.id == item.id } ?? item }
    private var key: String { "\(visible && scenePhase == .active):\(store.revision)" }
    var body: some View {
        QinglongSheet("执行日志") {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(current.title).font(.headline); Spacer(); QinglongStatus(item: current, outcome: store.outcomes[item.id]) }
                Text("最近一次执行 · 最多显示末尾 256 KiB").font(.caption).foregroundStyle(.secondary)
                if loading && text.isEmpty { ProgressView("正在读取日志…") }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                Text(text.isEmpty ? "暂无执行输出" : text).qinglongCode()
                Button("刷新日志", systemImage: "arrow.clockwise") { Task { await refresh() } }.buttonStyle(QinglongSecondaryButtonStyle())
                if current.resource == .tasks && current.running {
                    Button("停止此任务") { taskAction = QinglongTaskAction(item: current, action: "stop", revision: openedRevision ?? store.revision) }
                        .buttonStyle(QinglongSecondaryButtonStyle(destructive: true)).disabled(store.busy)
                }
            }
        }
        .qinglongTaskAction(store: store, request: $taskAction)
        .navigationTitle("执行日志").navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true; if openedRevision == nil { openedRevision = store.revision } }.onDisappear { visible = false }
        .refreshable { await refresh() }
        .task(id: key) {
            guard visible, scenePhase == .active else { return }
            var tick = 0
            while !Task.isCancelled {
                if tick % 2 == 0, openedRevision == store.revision { await store.refresh(item.resource) }
                await refresh()
                tick += 1
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func refresh() async {
        guard openedRevision == nil || openedRevision == store.revision else { text = ""; error = "连接已改变，请返回列表重新打开日志。"; return }
        guard !loading else { return }
        loading = true; let revision = store.revision
        defer { loading = false }
        do {
            let result = try await store.client().log(item)
            guard !Task.isCancelled, revision == store.revision else { return }
            text = result; error = nil
        } catch { if !Task.isCancelled && revision == store.revision { self.error = error.localizedDescription } }
    }
}
