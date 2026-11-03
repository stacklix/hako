import SwiftUI

struct QinglongRecordDetail: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    @State private var editing = false
    @State private var deleting = false
    @State private var pending: QinglongPendingAction?
    @State private var reveal = false
    @State private var openedRevision: UUID?
    @Environment(\.dismiss) private var dismiss
    private var current: QinglongItem { store.items[item.resource]?.first { $0.id == item.id } ?? item }
    var body: some View {
        List {
            if let openedRevision, openedRevision != store.revision { Section { Text("连接已改变，请返回列表重新打开。").foregroundStyle(.orange) } }
            Section {
                HStack { Text(current.title).font(.headline); Spacer(); QinglongStatus(item: current) }
                if item.resource == .envs {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("变量值").font(.subheadline).foregroundStyle(.secondary)
                        if reveal { Text(current.raw["value"].text).textSelection(.enabled).font(.body.monospaced()) }
                        else { Text("••••••••••••") }
                        Button(reveal ? "隐藏变量值" : "显示变量值", systemImage: reveal ? "eye.slash" : "eye") { reveal.toggle() }
                    }
                    LabeledContent("备注", value: current.raw["remarks"].text)
                } else {
                    if item.resource == .tasks { value("执行命令", current.raw["command"].text) }
                    else { value("仓库地址", current.raw["url"].text); value("别名", current.raw["alias"].text) }
                    value("定时规则", current.raw["schedule"].text)
                    if let time = current.raw["last_running_time"].int, time > 0 {
                        LabeledContent("最近启动", value: Date(timeIntervalSince1970: Double(time)).formatted(date: .abbreviated, time: .standard))
                    }
                }
            }
            Section {
                Button("编辑", systemImage: "pencil") { editing = true }
                if item.resource != .envs {
                    Button(current.running ? "停止" : item.resource == .subscriptions ? "立即拉取" : "立即运行", systemImage: current.running ? "stop" : "play") {
                        pending = QinglongPendingAction(item: current, action: current.running ? "stop" : "run")
                    }.disabled(current.disabled)
                    NavigationLink { QinglongExecutionLog(store: store, item: current) } label: { Label("执行日志", systemImage: "doc.text.magnifyingglass") }
                }
                Button(current.disabled ? "启用" : "禁用") { pending = QinglongPendingAction(item: current, action: current.disabled ? "enable" : "disable") }
                Button("删除", role: .destructive) { deleting = true }
            }.disabled(store.busy || openedRevision != store.revision)
            QinglongOperationSection(store: store)
        }
        .navigationTitle(item.resource == .envs ? "变量详情" : item.resource == .tasks ? "任务详情" : "订阅详情").navigationBarTitleDisplayMode(.inline)
        .onAppear { if openedRevision == nil { openedRevision = store.revision } }
        .sheet(isPresented: $editing) { QinglongRecordEditor(store: store, resource: item.resource, item: current) }
        .confirmationDialog("删除「\(current.title)」？此操作无法撤销。", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { if await store.delete(current) { dismiss() } } }
        }
        .confirmationDialog(pending?.title ?? "确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let pending { Button(pending.title) { self.pending = nil; Task { await store.action(pending.action, item: pending.item) } } }
        }
    }
    private func value(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(name).font(.subheadline).foregroundStyle(.secondary); Text(text.isEmpty ? "未设置" : text).textSelection(.enabled) }
    }
}

struct QinglongRecordEditor: View {
    @ObservedObject var store: QinglongStore
    let resource: QinglongResource
    let item: QinglongItem?
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String]
    @State private var error: String?
    private let revision: UUID
    init(store: QinglongStore, resource: QinglongResource, item: QinglongItem?) {
        self.store = store; self.resource = resource; self.item = item; revision = store.revision
        var fields = [String: String]()
        for key in ["name", "command", "schedule", "value", "remarks", "url", "alias", "branch", "whitelist", "blacklist"] { fields[key] = item?.raw[key].text ?? "" }
        if item == nil && resource != .envs { fields["schedule"] = "0 2 * * *" }
        _fields = State(initialValue: fields)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(resource == .envs ? "变量名" : "名称", "name")
                    if resource == .tasks { field("执行命令", "command"); field("Cron 表达式", "schedule") }
                    if resource == .envs { field("变量值", "value", secure: true); field("备注", "remarks") }
                    if resource == .subscriptions {
                        field("仓库地址", "url"); field("别名", "alias")
                        if item == nil || item?.raw["schedule_type"].text == "crontab" { field("Cron 表达式", "schedule") }
                        field("分支", "branch"); field("包含关键词", "whitelist"); field("排除关键词", "blacklist")
                    }
                }
                if resource == .subscriptions && item == nil { Section { Text("创建公开 Git 仓库订阅，按 Cron 计划拉取。").font(.footnote).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
            }
            .navigationTitle("\(item == nil ? "新建" : "编辑")\(resource.title)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(store.busy) }
            }
            .disabled(store.busy).interactiveDismissDisabled(store.busy)
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
        if await store.saveRecord(resource, item: item, fields: payload) { dismiss() }
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
    private var key: String { "\(visible && scenePhase == .active):\(store.revision)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.title).font(.headline)
                Text("最近一次执行 · 最多显示末尾 256 KiB").font(.caption).foregroundStyle(.secondary)
                if loading && text.isEmpty { ProgressView("正在读取日志…") }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                Text(text.isEmpty ? "暂无执行输出" : text).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding()
        }
        .navigationTitle("执行日志").navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true; if openedRevision == nil { openedRevision = store.revision } }.onDisappear { visible = false }
        .refreshable { await refresh() }
        .task(id: key) {
            guard visible, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
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
