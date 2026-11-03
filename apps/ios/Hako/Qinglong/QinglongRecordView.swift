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
        QinglongSheet("任务详情", disabled: store.busy, usesForm: false) {
            HStack(alignment: .top, spacing: 12) {
                Text(current.title).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                QinglongStatus(item: current, outcome: store.outcomes[item.id])
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            Text(current.raw["command"].text).qinglongCode()
            VStack(spacing: 0) {
                detail("定时规则", current.raw["schedule"].text)
                detail("执行计划", current.scheduleDescription)
                detail("时区", current.raw["timezone"].text.isEmpty ? "跟随面板设置" : current.raw["timezone"].text)
                detail("最近执行", store.outcomes[item.id]?.summary ?? current.lastRunText)
            }
            Button(current.running ? "停止任务" : "立即运行") {
                taskAction = QinglongTaskAction(item: current, action: current.running ? "stop" : "run", revision: openedRevision ?? store.revision)
            }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(store.busy || current.disabled)
            Button("查看执行日志") { logging = true }.buttonStyle(QinglongSecondaryButtonStyle())
            VStack(spacing: 0) {
                QinglongMenuRow(title: "编辑任务") { editing = true }
                QinglongMenuRow(title: current.disabled ? "启用任务" : "禁用任务") { action = current.disabled ? "enable" : "disable" }
                QinglongMenuRow(title: "删除任务", destructive: true, last: true, trailingSymbol: "trash") { action = "delete" }
            }.qinglongCard(padding: 0).disabled(store.busy)
        }
        .qinglongTaskAction(store: store, request: $taskAction)
        .sheet(isPresented: $editing) { QinglongRecordEditor(store: store, resource: item.resource, item: current) }
        .sheet(isPresented: $logging) { QinglongExecutionLog(store: store, item: current) }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
            if let action { QinglongActionSheet(store: store, item: current, action: action, completed: { if action == "delete" { dismiss() } }) }
        }
        .onAppear { visible = true; if openedRevision == nil { openedRevision = store.revision } }.onDisappear { visible = false }
        .task(id: "\(visible && phase == .active && !editing && !logging && action == nil && taskAction == nil):\(store.revision)") {
            guard visible, phase == .active, !editing, !logging, action == nil, taskAction == nil else { return }
            while !Task.isCancelled && (openedRevision == nil || openedRevision == store.revision) {
                await store.refresh(item.resource)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                Text(title).foregroundStyle(QinglongStyle.muted).fixedSize()
                Spacer(minLength: 0)
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.system(size: 13)).padding(.vertical, 12)
            Rectangle().fill(QinglongStyle.line).frame(height: 1)
        }
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
            if resource == .envs { field("变量值", "value"); field("备注", "remarks") }
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
                Button(role: .destructive) { action = "delete" } label: {
                    Text("删除\(resource.title)").font(.subheadline).frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(QinglongStyle.failure)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden).disabled(store.busy)
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
    let initialAction: String?
    private let revision: UUID
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var text = ""
    @State private var error: String?
    @State private var loading = false
    @State private var submitted = false
    @State private var attempted = false
    @State private var performing = false
    @State private var actionError: String?
    @State private var actionMessage: String?
    @State private var stopping = false
    @State private var refreshed: Date?
    init(store: QinglongStore, item: QinglongItem, initialAction: String? = nil, revision: UUID? = nil) {
        self.store = store; self.item = item; self.initialAction = initialAction; self.revision = revision ?? store.revision
    }
    private var current: QinglongItem { store.items[item.resource]?.first { $0.id == item.id } ?? item }
    private var monitoring: Bool { initialAction == nil || submitted || attempted }
    private var live: Bool { visible && scenePhase == .active && monitoring && revision == store.revision }
    private var key: String { "\(live):\(store.revision)" }
    private var title: String { initialAction == nil ? "执行日志" : monitoring ? "任务执行" : initialAction == "stop" ? "停止任务" : "运行任务" }
    var body: some View {
        QinglongSheet(title, disabled: performing || store.busy, usesForm: false) {
            HStack(alignment: .top, spacing: 12) {
                Text(current.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                QinglongStatus(item: current, outcome: store.outcomes[item.id])
            }.qinglongCard()
            if !monitoring, let initialAction {
                Text(initialAction == "stop" ? "停止此任务当前的执行？" : "立即运行此任务？").font(.subheadline)
                Text(current.raw["command"].text).qinglongCode()
                Button(performing ? "正在提交…" : initialAction == "stop" ? "确认停止" : "立即运行") {
                    Task { await perform(initialAction) }
                }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(performing || store.busy || revision != store.revision || initialAction == "run" && current.disabled)
            }
            if let actionMessage { QinglongNotice(text: actionMessage) }
            if let actionError { QinglongNotice(text: actionError, error: true) }
            if monitoring {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近一次执行 · 最多显示末尾 256 KiB").font(.caption).foregroundStyle(QinglongStyle.muted)
                    HStack(spacing: 6) {
                        if loading { ProgressView().controlSize(.mini) }
                        Text(refreshed.map { "日志更新于 " + $0.formatted(date: .omitted, time: .standard) } ?? "等待执行输出…")
                            .font(.caption).foregroundStyle(QinglongStyle.muted)
                        Spacer(minLength: 0)
                        if live { Text("自动刷新").font(.caption).foregroundStyle(QinglongStyle.muted) }
                    }
                }
                if let error { QinglongNotice(text: error, error: true) }
                Text(text.isEmpty ? "暂无执行输出，正在等待日志…" : text).qinglongCode()
                Button("刷新日志", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .buttonStyle(QinglongSecondaryButtonStyle()).disabled(loading || revision != store.revision)
                if current.resource == .tasks && current.running {
                    Button("停止此任务") { stopping = true }
                        .buttonStyle(QinglongSecondaryButtonStyle(destructive: true)).disabled(performing || store.busy || revision != store.revision)
                }
            }
            if revision != store.revision {
                QinglongNotice(text: "连接已改变，请返回列表重新打开。", error: true)
            }
        }
        .confirmationDialog("停止当前任务执行？", isPresented: $stopping, titleVisibility: .visible) {
            Button("停止任务", role: .destructive) { Task { await perform("stop") } }
        }
        .onAppear { visible = true }.onDisappear { visible = false }
        .onChange(of: store.revision) { _, _ in text = ""; refreshed = nil; error = nil; actionMessage = nil }
        .refreshable { await refresh() }
        .task(id: key) {
            guard live else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: key) {
            guard live else { return }
            while !Task.isCancelled {
                await store.refresh(item.resource)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    private func perform(_ action: String) async {
        guard !performing, !store.busy, revision == store.revision else { return }
        performing = true; actionError = nil
        defer { performing = false }
        let message = action == "stop" ? "停止请求已提交，正在刷新日志和状态。" : "运行请求已提交，正在等待本次执行输出。"
        let success = await store.perform(item.resource, success: message) { api in
            try await api.action(action, item: current)
            submitted = true; actionMessage = message
        }
        attempted = true
        if !success { actionError = store.message ?? "请求未完成，请核对任务状态后再操作。" }
    }
    private func refresh() async {
        guard monitoring, revision == store.revision, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await store.client().log(item)
            guard !Task.isCancelled, revision == store.revision else { return }
            text = result; error = nil; refreshed = .now
        } catch { if !Task.isCancelled && revision == store.revision { self.error = error.localizedDescription } }
    }
}
