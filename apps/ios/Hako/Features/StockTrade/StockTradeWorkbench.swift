import SwiftUI

struct StockTradeWorkbench: View {
    @ObservedObject var store: StockTradeStore
    var showResults: () -> Void
    var newTaskRequested = false
    var requestConsumed: () -> Void = { }
    @State private var panel: Panel?
    @State private var notifications = false
    private enum Panel: Identifiable {
        case create(StockTradeWorkflowKind), task(StockTradeWorkflowTask), tasks, publications, operations
        var id: String {
            switch self {
            case .create(let kind): "create-" + kind.rawValue
            case .task(let task): task.id
            case .tasks: "tasks"
            case .publications: "publications"
            case .operations: "operations"
            }
        }
    }
    var body: some View {
        List {
            if let error = store.workflowError { Section { StockTradeMessage(text: error) } }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("完整选股并发布").font(.title3.weight(.semibold))
                    Text("抓取行情 → 初选 → 复评 → 发布").font(.subheadline).foregroundStyle(.secondary)
                    Text("后台执行，离开应用后仍会继续。").font(.footnote).foregroundStyle(.secondary)
                    if let task = store.activeWorkflow {
                        Button("查看进行中的任务") { panel = .task(task) }.buttonStyle(HakoActionButtonStyle())
                    } else {
                        Button("启动完整选股") { panel = .create(.full) }.buttonStyle(HakoActionButtonStyle())
                    }
                }.padding(.vertical, 5).stockTradeSeparator()
            }
            Section("任务与数据") {
                Button("任务记录") { panel = .tasks }.stockTradeSeparator()
                Button("发布记录") { panel = .publications }.stockTradeSeparator()
                Button("分步操作") { panel = .operations }.stockTradeSeparator()
            }
            Section("运行管理") {
                NavigationLink("调度与后台状态") { StockTradeHealthView(store: store) }.stockTradeSeparator()
                Button("通知配置") { notifications = true }.stockTradeSeparator()
                LabeledContent("手动任务服务", value: store.workflowOnline ? "在线" : "尚未确认在线").stockTradeSeparator()
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshWorkflows() }
        .sheet(item: $panel) { selected in
            switch selected {
            case .create(let kind): StockTradeWorkflowForm(store: store, kind: kind, showResults: showResults)
            case .task(let task): SettingsSheet(title: task.kind.title) { StockTradeWorkflowDetail(store: store, initial: task, showResults: showResults) }
            case .tasks: SettingsSheet(title: "任务记录") { taskList }
            case .publications: SettingsSheet(title: "发布记录") { StockTradePublications(store: store, showResults: showResults) }
            case .operations: SettingsSheet(title: "分步操作") { operations }
            }
        }
        .sheet(isPresented: $notifications) { StockTradeNotificationSettings(store: store) }
        .onAppear { if newTaskRequested { panel = .create(.full); requestConsumed() } }
    }
    private var taskList: some View {
        List {
            if let error = store.workflowError { StockTradeMessage(text: error) }
            ForEach(store.workflowTasks) { task in
                NavigationLink {
                    StockTradeWorkflowDetail(store: store, initial: task, showResults: showResults)
                } label: { StockTradeWorkflowRow(task: task) }.stockTradeSeparator()
            }
            if store.workflowTasks.isEmpty { Text("暂无任务记录。").foregroundStyle(.secondary) }
            if store.workflowCursor != nil { Button("加载更早任务") { Task { await store.refreshWorkflows(append: true) } } }
        }.refreshable { await store.refreshWorkflows() }
    }
    private var operations: some View {
        List {
            ForEach(StockTradeWorkflowKind.allCases.filter { $0 != .full }) { kind in
                NavigationLink(kind.title) { StockTradeWorkflowFormContent(store: store, kind: kind, showResults: showResults) }.stockTradeSeparator()
            }
            Section { Text("分步任务与完整选股共用执行队列，不会自动执行后续步骤。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct StockTradeWorkflowRow: View {
    let task: StockTradeWorkflowTask
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(task.kind.title).font(.headline); Spacer(); Text(task.state.title).foregroundStyle(task.state == .failed ? .orange : .secondary) }
            Text(StockTradeTime.display(task.createdAt) + " · " + StockTradeWorkflowKind.phaseTitle(task.phase)).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

private struct StockTradeWorkflowForm: View {
    @ObservedObject var store: StockTradeStore
    let kind: StockTradeWorkflowKind
    let showResults: () -> Void
    var body: some View {
        SettingsSheet(title: kind.title) { StockTradeWorkflowFormContent(store: store, kind: kind, showResults: showResults) }
    }
}

private struct StockTradeWorkflowFormContent: View {
    @ObservedObject var store: StockTradeStore
    let kind: StockTradeWorkflowKind
    let showResults: () -> Void
    @State private var useDate = false
    @State private var date = Date()
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var submitting = false
    @State private var submitted: StockTradeWorkflowTask?
    @State private var error: String?
    @State private var openedScope: UUID?
    var body: some View {
        Group {
            if let submitted { StockTradeWorkflowDetail(store: store, initial: submitted, showResults: showResults) }
            else {
                Form {
                    Section {
                        Text(kind.explanation)
                        if kind == .full || kind == .preselect {
                            Toggle("指定选股日期", isOn: $useDate).stockTradeSeparator()
                            if useDate { DatePicker("选股日期", selection: $date, in: ...Date(), displayedComponents: .date).stockTradeSeparator() }
                            else { LabeledContent("选股日期", value: "最新可用交易日").stockTradeSeparator() }
                        }
                        LabeledContent("股票范围", value: "沿用后台配置").stockTradeSeparator()
                        LabeledContent("策略参数", value: "沿用后台当前规则").stockTradeSeparator()
                    }
                    Section("执行流程") {
                        ForEach(kind.phases, id: \.self) { phase in Text(StockTradeWorkflowKind.phaseTitle(phase)).stockTradeSeparator() }
                    }
                    if let error { Section { StockTradeMessage(text: error) } }
                    if let active = store.activeWorkflow {
                        Section { StockTradeWorkflowRow(task: active); Text("已有任务执行中，请等待完成后再提交。").font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button(submitting ? "正在提交…" : "确认启动") { Task { await submit() } }
                            .buttonStyle(HakoActionButtonStyle()).disabled(submitting || store.activeWorkflow != nil || openedScope != store.scope)
                    } footer: { Text("任务由后台持久保存。结果不完整或失败时，不替换已发布快照。网络结果不确定时可重试同一请求，不会重复创建任务。") }
                }.disabled(submitting)
            }
        }
        .onAppear { if openedScope == nil { openedScope = store.scope } }
        .onChange(of: useDate) { _, _ in requestID = UUID().uuidString.lowercased() }
        .onChange(of: date) { _, _ in requestID = UUID().uuidString.lowercased() }
    }
    private func submit() async {
        guard openedScope == store.scope else { error = StockTradeFailure.changedContext.localizedDescription; return }
        submitting = true; error = nil
        defer { submitting = false }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        do { submitted = try await store.submitWorkflow(kind: kind, dataDate: useDate ? f.string(from: date) : nil, requestID: requestID) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription; await store.refreshWorkflows() }
    }
}

private struct StockTradeWorkflowDetail: View {
    @ObservedObject var store: StockTradeStore
    let initial: StockTradeWorkflowTask
    let showResults: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: StockTradeWorkflowTask?
    @State private var error: String?
    @State private var retry = false
    @State private var openedScope: UUID?
    private var task: StockTradeWorkflowTask { detail ?? store.workflowTasks.first { $0.id == initial.id } ?? initial }
    var body: some View {
        List {
            if let error { Section { StockTradeMessage(text: error) } }
            if openedScope == nil || openedScope == store.scope {
                Section {
                    StockTradeWorkflowRow(task: task)
                    ForEach(Array(task.kind.phases.enumerated()), id: \.element) { index, phase in
                        HStack {
                            Image(systemName: phaseIcon(index)).foregroundStyle(.secondary)
                            Text(StockTradeWorkflowKind.phaseTitle(phase)); Spacer()
                            if phase == task.phase { Text(task.state.title).font(.caption).foregroundStyle(.secondary) }
                        }.stockTradeSeparator()
                    }
                    if task.phase == "pending" { Text("等待后台执行或等待其他数据工作流结束。").font(.footnote).foregroundStyle(.secondary) }
                    if task.state == .failed {
                        StockTradeMessage(text: task.failureCode == "worker_interrupted" ? "执行进程已结束，结果未确认。请先查看发布记录，再决定是否重新运行。" : "当前步骤失败，本次未完成发布。上一次完整快照继续可用。")
                        Button("重新运行") { retry = true }.buttonStyle(HakoActionButtonStyle()).disabled(store.activeWorkflow != nil)
                    }
                    if let result = task.result, task.state == .succeeded {
                        LabeledContent("数据日期", value: result.dataAsOf).stockTradeSeparator()
                        Button("查看选股结果") {
                            Task {
                                do { try await store.openPublishedRun(result.runId); showResults(); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(HakoActionButtonStyle())
                    }
                }
                Section("执行日志") {
                    ForEach(task.events) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.message).font(.subheadline)
                            Text(StockTradeTime.display(event.at)).font(.caption).foregroundStyle(.secondary)
                        }.stockTradeSeparator()
                    }
                }
            } else { Text("账号或连接已切换，请关闭后重新打开。") }
        }
        .sheet(isPresented: $retry) { StockTradeWorkflowForm(store: store, kind: task.kind, showResults: showResults) }
        .task(id: "\(store.scope)|\(scenePhase == .active)") {
            if openedScope == nil { openedScope = store.scope }
            guard openedScope == store.scope, scenePhase == .active else { return }
            repeat {
                do { detail = try await store.workflowTask(initial.id); error = nil }
                catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
                if !task.state.active { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func phaseIcon(_ index: Int) -> String {
        let current = task.kind.phases.firstIndex(of: task.phase) ?? -1
        if task.state == .succeeded || index < current { return "checkmark.circle.fill" }
        if index == current { return task.state == .failed ? "exclamationmark.circle" : "circle.inset.filled" }
        return "circle"
    }
}

private struct StockTradePublications: View {
    @ObservedObject var store: StockTradeStore
    let showResults: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [StockTradePublishedRun] = []
    @State private var cursor: String?
    @State private var error: String?
    @State private var loading = false
    @State private var openedScope: UUID?
    var body: some View {
        List {
            if let error { StockTradeMessage(text: error) }
            if openedScope == store.scope {
                ForEach(items) { run in
                    Button {
                        Task {
                            do { try await store.openPublishedRun(run.runId); showResults(); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(run.dataAsOf).font(.headline)
                            Text("发布 " + StockTradeTime.display(run.publishedAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.stockTradeSeparator()
                }
                if cursor != nil { Button("加载更早发布") { Task { await load(append: true) } }.disabled(loading) }
            }
            if loading { ProgressView("读取发布记录…") }
        }
        .task(id: store.scope) { items = []; cursor = nil; openedScope = store.scope; await load(append: false) }
        .refreshable { await load(append: false) }
    }
    private func load(append: Bool) async {
        guard !loading else { return }
        let scope = store.scope
        loading = true; error = nil
        defer { loading = false }
        do {
            var query = [URLQueryItem(name: "limit", value: "30")]
            if append, let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let value = try await store.read(["runs"], query: query, as: StockTradePage<StockTradePublishedRun>.self)
            guard scope == store.scope else { return }
            guard value.items.allSatisfy({ $0.status == "complete" }), !append || Set(items.map(\.id)).isDisjoint(with: value.items.map(\.id)) else { throw StockTradeFailure.invalidResponse }
            items = append ? items + value.items : value.items; cursor = value.nextCursor
        } catch is CancellationError { }
        catch { if scope == store.scope { self.error = error.localizedDescription } }
    }
}
