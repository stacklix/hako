import SwiftUI

struct QinglongRecordDetail: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    @State private var editing = false
    @State private var logging = false
    @State private var action: String?
    @State private var didDelete = false
    @State private var taskAction: QinglongTaskAction?
    @State private var requestedEnabled: Bool?
    @State private var updatingEnabled = false
    @State private var enableError: String?
    @State private var revision: UUID
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    init(store: QinglongStore, item: QinglongItem) {
        self.store = store; self.item = item
        _revision = State(initialValue: store.revision)
    }
    private var current: QinglongItem { store.items[item.resource]?.first { $0.id == item.id } ?? item }
    private var connectionChanged: Bool { revision != store.revision }
    private var controlsDisabled: Bool { store.busy || updatingEnabled || connectionChanged }
    var body: some View {
        QinglongSheet("任务详情", disabled: store.busy || updatingEnabled, usesForm: false, showsClose: false) {
            VStack(alignment: .leading, spacing: 16) {
                QinglongTaskHeader(item: current, outcome: store.outcomes[item.id])
                Rectangle().fill(QinglongStyle.line).frame(height: 1)
                Toggle(isOn: Binding(get: { requestedEnabled ?? !current.disabled }, set: setEnabled)) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动执行").font(.subheadline)
                            Text("关闭后仍可手动运行").font(.caption).foregroundStyle(QinglongStyle.muted)
                        }
                        if updatingEnabled { ProgressView().controlSize(.mini) }
                    }
                }.toggleStyle(.switch).tint(.green).disabled(controlsDisabled)
            }.qinglongCard(padding: 16, cornerRadius: 16)
            if connectionChanged { QinglongNotice(text: "连接已改变，请返回列表重新打开任务。", error: true) }
            else if let enableError { QinglongNotice(text: enableError, error: true) }
            VStack(alignment: .leading, spacing: 10) {
                Text("调度信息").font(.system(size: 13, weight: .semibold))
                VStack(spacing: 0) {
                    detail("定时规则", current.raw["schedule"].text)
                    detail("执行计划", current.scheduleDescription)
                    detail("时区", current.raw["timezone"].text.isEmpty ? "跟随面板设置" : current.raw["timezone"].text)
                    detail("最近执行", store.outcomes[item.id]?.summary ?? current.lastRunText, last: true)
                }.qinglongCard(padding: 0, cornerRadius: 16)
            }
            Button {
                taskAction = QinglongTaskAction(item: current, action: current.running ? "stop" : "run", revision: revision)
            } label: {
                Label(current.running ? "停止任务" : "立即运行", systemImage: current.running ? "stop" : "play")
            }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(controlsDisabled)
            VStack(spacing: 0) {
                QinglongMenuRow(title: "执行日志", symbol: "doc.text") { logging = true }
                QinglongMenuRow(title: "编辑任务", symbol: "pencil", last: true) { editing = true }
            }.qinglongCard(padding: 0, cornerRadius: 16).disabled(controlsDisabled)
            HakoDeleteButton(title: "删除任务", systemImage: "trash") { action = "delete" }
                .disabled(controlsDisabled)
        }
        .qinglongTaskAction(store: store, request: $taskAction)
        .sheet(isPresented: $editing) { QinglongRecordEditor(store: store, resource: item.resource, item: current) }
        .sheet(isPresented: $logging) { QinglongExecutionLog(store: store, item: current) }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), onDismiss: {
            if didDelete { dismiss() }
        }) {
            if let action { QinglongActionSheet(store: store, item: current, action: action, completed: { didDelete = true }) }
        }
        .onAppear { visible = true }.onDisappear { visible = false }
        .onChange(of: current.disabled) { _, _ in if !updatingEnabled { enableError = nil } }
        .task(id: "\(visible && phase == .active && !editing && !logging && action == nil && taskAction == nil && !updatingEnabled):\(store.revision)") {
            guard visible, phase == .active, !editing, !logging, action == nil, taskAction == nil, !updatingEnabled else { return }
            while !Task.isCancelled && !connectionChanged {
                await store.refresh(item.resource)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    private func setEnabled(_ enabled: Bool) {
        guard !controlsDisabled, enabled != !current.disabled else { return }
        let target = current
        requestedEnabled = enabled; updatingEnabled = true; enableError = nil
        Task {
            defer { requestedEnabled = nil; updatingEnabled = false }
            guard !connectionChanged else { return }
            let success = await store.perform(item.resource, success: "任务\(enabled ? "启用" : "禁用")请求已提交。") {
                try await $0.action(enabled ? "enable" : "disable", item: target)
            }
            guard !connectionChanged else { return }
            if !success { enableError = store.message ?? "状态更新失败，请刷新后核对。" }
            else if current.disabled == enabled {
                enableError = "请求已提交，但尚未确认最新状态。当前显示上次读取的状态，请稍后刷新核对。"
            }
        }
    }
    private func detail(_ title: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                Text(title).foregroundStyle(QinglongStyle.muted).fixedSize()
                Spacer(minLength: 0)
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.system(size: 13)).padding(.horizontal, 16).padding(.vertical, 14)
            if !last { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.leading, 16) }
        }
    }
}

private struct QinglongTaskHeader: View {
    let item: QinglongItem
    let outcome: QinglongOutcome?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Text(item.title).font(.system(size: 21, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                QinglongStatus(item: item, outcome: outcome)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("执行命令").font(.caption).foregroundStyle(QinglongStyle.muted)
                Text(item.raw["command"].text).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
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
        if item == nil && resource == .subscriptions { fields["schedule"] = "0 2 * * *" }
        _fields = State(initialValue: fields)
        _enabled = State(initialValue: !(item?.disabled ?? false))
        _persistedItem = State(initialValue: item)
    }
    @State private var action: String?
    @State private var didDelete = false
    var body: some View {
        Group {
            if resource == .tasks { QinglongTaskEditor(store: store, item: item) }
            else { recordForm }
        }
    }
    private var recordForm: some View {
        QinglongSheet("\(item == nil ? "新建" : "编辑")\(resource == .envs ? "变量" : resource == .subscriptions ? "订阅" : "任务")", disabled: store.busy, saveDisabled: saveBlocked, save: { Task { await save() } }) {
            Section {
            field(resource == .envs ? "变量名" : "订阅名称", "name")
            if resource == .envs { field("变量值", "value"); field("备注", "remarks") }
            if resource == .subscriptions {
                field("仓库地址", "url"); field("别名", "alias")
                if item == nil || item?.raw["schedule_type"].text == "crontab" { field("Cron 表达式", "schedule") }
                DisclosureGroup("更多选项") { field("分支", "branch"); field("包含关键词", "whitelist"); field("排除关键词", "blacklist") }
            }
            }
            if resource == .envs { Section { Toggle("启用此变量", isOn: $enabled).font(.subheadline) } }
            if let error { QinglongNotice(text: error, error: true) }
            if let item = persistedItem {
                if resource != .envs { Button(item.disabled ? "启用" : "禁用") { action = item.disabled ? "enable" : "disable" }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(store.busy) }
                HakoDeleteButton(title: "删除\(resource.title)") { action = "delete" }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden).disabled(store.busy)
            }
        }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), onDismiss: {
            if didDelete { dismiss() }
        }) {
            if let item = persistedItem, let action { QinglongActionSheet(store: store, item: item, action: action, completed: { didDelete = action == "delete" }) }
        }
    }
    private func field(_ title: String, _ key: String, secure: Bool = false) -> some View {
        QinglongTextField(title, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }), secure: secure)
    }
    private func save() async {
        guard revision == store.revision else { error = "连接已改变，请关闭后重新编辑。"; return }
        var payload: [String: String]
        switch resource {
        case .envs: payload = fields.filter { ["name", "value", "remarks"].contains($0.key) }
        case .subscriptions:
            payload = fields.filter { ["name", "url", "alias", "branch", "whitelist", "blacklist"].contains($0.key) }
            if item == nil || item?.raw["schedule_type"].text == "crontab" { payload["schedule"] = fields["schedule"] }
            if item == nil { payload["type"] = "public-repo"; payload["schedule_type"] = "crontab" }
        default: return
        }
        let required = resource == .envs ? ["name", "value"] : ["url", "alias"]
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

private struct QinglongTaskEditor: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem?
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String]
    @State private var baseline: [String: String]
    @State private var enabled: Bool
    @State private var confirmedEnabled: Bool
    @State private var persistedItem: QinglongItem?
    @State private var statePending = false
    @State private var saveBlocked = false
    @State private var error: String?
    @State private var deleting = false
    @State private var discarding = false
    @State private var revision: UUID
    init(store: QinglongStore, item: QinglongItem?) {
        self.store = store; self.item = item
        let fields = ["name": item?.raw["name"].text ?? "", "command": item?.raw["command"].text ?? "", "schedule": item?.raw["schedule"].text ?? "0 2 * * *"]
        _fields = State(initialValue: fields); _baseline = State(initialValue: fields)
        _enabled = State(initialValue: !(item?.disabled ?? false))
        _confirmedEnabled = State(initialValue: !(item?.disabled ?? false))
        _persistedItem = State(initialValue: item); _revision = State(initialValue: store.revision)
    }
    private var changed: Bool { fields != baseline || enabled != confirmedEnabled || statePending }
    private var connectionChanged: Bool { revision != store.revision }
    private var valid: Bool { ["command", "schedule"].allSatisfy { !(fields[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var body: some View {
        QinglongSheet(item == nil ? "新建任务" : "编辑任务", disabled: store.busy,
                      saveDisabled: !valid || saveBlocked || connectionChanged, usesForm: false,
                      close: requestClose, save: { Task { await save() } }) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("任务信息")
                    VStack(spacing: 0) {
                        field("任务名称", key: "name")
                        separator
                        field("执行命令", key: "command", multiline: true)
                    }.qinglongCard(padding: 0, cornerRadius: 16)
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("执行计划")
                    VStack(spacing: 0) {
                        field("Cron 表达式", key: "schedule")
                        separator
                        Toggle(isOn: $enabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("自动执行").font(.subheadline)
                                Text("关闭后仍可手动运行").font(.caption).foregroundStyle(QinglongStyle.muted)
                            }
                        }.toggleStyle(.switch).tint(.green).padding(16)
                    }.qinglongCard(padding: 0, cornerRadius: 16)
                    Text("按青龙面板时区执行，修改在保存后生效。").font(.caption).foregroundStyle(QinglongStyle.muted).padding(.horizontal, 3)
                }
                if connectionChanged { QinglongNotice(text: "连接已改变，请关闭后重新编辑。", error: true) }
                else if let error { QinglongNotice(text: error, error: true) }
                if persistedItem != nil {
                    HakoDeleteButton(title: "删除任务", systemImage: "trash") { deleting = true }
                }
            }.disabled(store.busy || connectionChanged)
        }
        .interactiveDismissDisabled(store.busy || changed)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) { dismiss() }
        } message: { Text("当前修改尚未保存。") }
        .hakoDeleteConfirmation(Text("删除任务？"), isPresented: $deleting, message: Text("此操作无法撤销。"),
                                disabled: connectionChanged || store.busy) {
            Task {
                guard !connectionChanged, !store.busy, let saved = persistedItem else { return }
                if await store.delete(saved) { dismiss() } else { error = store.message }
            }
        }
    }
    private var separator: some View { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.horizontal, 16) }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(QinglongStyle.muted).padding(.horizontal, 3) }
    private func field(_ title: String, key: String, multiline: Bool = false) -> some View {
        let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if multiline {
                TextField("", text: binding, axis: .vertical).lineLimit(3...12)
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 72, alignment: .topLeading)
                    .accessibilityLabel(title)
            } else {
                TextField("", text: binding).font(key == "schedule" ? .system(.body, design: .monospaced) : .body)
                    .accessibilityLabel(title)
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
    }
    private func requestClose() { if changed { discarding = true } else { dismiss() } }
    private func save() async {
        guard valid, !store.busy, !saveBlocked, !connectionChanged else { return }
        let submitted = fields, desired = enabled
        let updateState: Bool? = statePending || desired != confirmedEnabled ? desired : nil
        if let result = await store.saveTask(persistedItem, fields: submitted, enabled: updateState) {
            persistedItem = result.item; saveBlocked = result.item == nil
            baseline = submitted
            if let error = result.stateError { statePending = true; self.error = error }
            else { confirmedEnabled = desired; statePending = false; dismiss() }
        } else { error = store.message }
    }
}

struct QinglongExecutionLog: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    let initialAction: String?
    @State private var revision: UUID
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var text = ""
    @State private var error: String?
    @State private var loading = false
    @State private var submitted = false
    @State private var attempted = false
    @State private var autoRunStarted = false
    @State private var performing = false
    @State private var actionError: String?
    @State private var actionMessage: String?
    @State private var stopping = false
    @State private var refreshed: Date?
    init(store: QinglongStore, item: QinglongItem, initialAction: String? = nil, revision: UUID? = nil) {
        self.store = store; self.item = item; self.initialAction = initialAction
        _revision = State(initialValue: revision ?? store.revision)
    }
    private var current: QinglongItem { store.items[item.resource]?.first { $0.id == item.id } ?? item }
    private var monitoring: Bool { initialAction == nil || initialAction == "run" || submitted || attempted }
    private var live: Bool { visible && scenePhase == .active && monitoring && revision == store.revision }
    private var key: String { "\(live):\(store.revision)" }
    private var title: String { initialAction == nil ? "执行日志" : monitoring ? "任务执行" : initialAction == "stop" ? "停止任务" : "运行任务" }
    var body: some View {
        QinglongSheet(title, disabled: performing || store.busy, usesForm: false, showsClose: false) {
            QinglongTaskHeader(item: current, outcome: store.outcomes[item.id]).qinglongCard(padding: 16, cornerRadius: 16)
            if !monitoring, initialAction == "stop" {
                Text("停止此任务当前的执行？").font(.subheadline)
                Button(performing ? "正在提交…" : "确认停止") {
                    Task { await perform("stop") }
                }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(performing || store.busy || revision != store.revision)
            }
            if performing { Text("正在提交请求…").font(.caption).foregroundStyle(QinglongStyle.muted) }
            else if let actionMessage, text.isEmpty { Text(actionMessage).font(.caption).foregroundStyle(QinglongStyle.muted) }
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
                Text(text.isEmpty ? "暂无执行输出，正在等待日志…" : text)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                    .qinglongCard(padding: 16, cornerRadius: 16)
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
        .task {
            // The first read belongs to the sheet lifetime, not the changing polling key.
            if initialAction == nil {
                await refresh()
                return
            }
            guard initialAction == "run", !autoRunStarted, !Task.isCancelled else { return }
            // Claim the automatic submission before awaiting: redraws and reappearances must never run it twice.
            autoRunStarted = true
            await perform("run")
        }
        .task(id: key) {
            guard live else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await refresh()
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
        guard revision == store.revision else { actionError = "连接已改变，请返回列表重新打开。"; return }
        guard !performing else { return }
        guard !store.busy else { actionError = "当前有其他操作正在处理，本次请求未提交。请稍后重新打开。"; return }
        performing = true; attempted = true; actionError = nil
        defer { performing = false }
        let message = action == "stop" ? "停止请求已提交，正在刷新日志和状态。" : "运行请求已提交，正在等待本次执行输出。"
        let success = await store.perform(item.resource, success: message) { api in
            try await api.action(action, item: current)
            submitted = true; actionMessage = message
        }
        if !success { actionError = store.message ?? "请求未完成，请核对任务状态后再操作。" }
        await refresh()
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
