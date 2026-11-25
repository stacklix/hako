import SwiftUI

struct StockTradeWorkbench: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    var showResults: () -> Void
    var showSettings: () -> Void
    @State private var notifications = false
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "工作台", subtitle: "从数据更新到结果发布，都在这里")
            if let error = store.workflowError { StockTradeMessage(text: error) }
            if let task = store.activeWorkflow { StockTradeTaskBanner(task: task) { navigation.push(.task(task)) } }
            StockTradeCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("完整选股并发布").font(.headline)
                    Text("抓取行情 → 初选 → 复评 → 发布").font(.subheadline).foregroundStyle(.secondary)
                    Text("任务在后台执行，离开应用后仍会继续。").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                    Button {
                        if let task = store.activeWorkflow { navigation.push(.task(task)) }
                        else { navigation.push(.create(.full)) }
                    } label: { Label(store.activeWorkflow == nil ? "启动完整选股" : "查看进行中的任务", systemImage: store.activeWorkflow == nil ? "play" : "waveform.path.ecg") }
                        .buttonStyle(StockTradeAppearance.action)
                }
            }
            StockTradeSectionLabel(title: "任务与数据")
            StockTradeCard(padding: 18) {
                Button { navigation.push(.history) } label: { StockTradeEntryRow(title: "任务记录", subtitle: taskSummary) }.buttonStyle(.plain)
                Button { navigation.push(.publications) } label: { StockTradeEntryRow(title: "发布记录", subtitle: "完整快照与数据日期") }.buttonStyle(.plain)
                Button { navigation.push(.operations) } label: { StockTradeEntryRow(title: "分步操作", subtitle: "行情 · 初选 · 复评 · 发布", separator: false) }.buttonStyle(.plain)
            }
            StockTradeSectionLabel(title: "运行管理")
            StockTradeCard(padding: 18) {
                Button { navigation.push(.health) }
                label: { StockTradeEntryRow(title: "调度与后台状态", subtitle: store.workflowOnline ? "执行服务在线" : "尚未确认在线") }.buttonStyle(.plain)
                Button { notifications = true } label: { StockTradeEntryRow(title: "通知配置", subtitle: "邮件与手机提醒") }.buttonStyle(.plain)
                Button(action: showSettings) { StockTradeEntryRow(title: "连接与授权", subtitle: "Cerno · Hako 原生授权", separator: false) }.buttonStyle(.plain)
            }
        }
        .refreshable { await store.refreshWorkflows() }
        .sheet(isPresented: $notifications) { StockTradeNotificationSettings(store: store) }
    }
    private var taskSummary: String {
        let count = store.workflowTasks.filter { $0.state == .failed }.count
        return count == 0 ? "运行进度与日志" : "有 \(count) 项失败"
    }
}

struct StockTradeWorkflowHistory: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let showResults: () -> Void
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "任务记录", subtitle: "查看历史执行结果与失败原因")
            if let error = store.workflowError { StockTradeMessage(text: error) }
            StockTradeCard(padding: 18) {
                ForEach(Array(store.workflowTasks.enumerated()), id: \.element.id) { index, task in
                    Button { navigation.push(.task(task)) }
                    label: { StockTradeWorkflowRow(task: task).padding(.vertical, 12) }.buttonStyle(.plain)
                    if index < store.workflowTasks.count - 1 { Divider() }
                }
                if store.workflowTasks.isEmpty { Text("暂无任务记录。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                if store.workflowCursor != nil { Button("加载更早任务") { Task { await store.refreshWorkflows(append: true) } }.padding(.vertical, 12) }
            }
            Button("启动新任务") { navigation.push(.create(.full)) }.buttonStyle(StockTradeAppearance.action)
        }.refreshable { await store.refreshWorkflows() }
    }
}

struct StockTradeOperations: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let showResults: () -> Void
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "分步操作", subtitle: "用于补数据、排查和发布已有完整结果")
            StockTradeCard(padding: 18) {
                ForEach(StockTradeWorkflowKind.allCases.filter { $0 != .full }) { kind in
                    Button { navigation.push(.create(kind)) }
                    label: { StockTradeEntryRow(title: kind.title, subtitle: operationSubtitle(kind), separator: kind != .publish) }.buttonStyle(.plain)
                }
            }
            StockTradeFootnote(text: "分步操作同样受任务互斥约束。初选、复评完成后，需通过发布校验才会更新选股页。")
        }
    }
    private func operationSubtitle(_ kind: StockTradeWorkflowKind) -> String {
        switch kind {
        case .full: "完整流程"
        case .fetch: "更新数据源"
        case .preselect: "生成候选名单"
        case .review: "评估候选股票"
        case .publish: "校验完整性后发布"
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

struct StockTradeWorkflowFormContent: View {
    @ObservedObject var store: StockTradeStore
    let kind: StockTradeWorkflowKind
    let showResults: () -> Void
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
                StockTradeScreen {
                    StockTradeHeading(title: kind == .full ? "启动完整选股" : kind.title, subtitle: kind == .full ? "完成全部步骤后，自动发布新结果" : "分步任务 · 启动前确认")
                    StockTradeCard {
                        VStack(alignment: .leading, spacing: 16) {
                            if kind == .full || kind == .preselect {
                                DatePicker("选股日期", selection: $date, in: ...Date(), displayedComponents: .date)
                                    .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
                                Divider()
                            }
                            LabeledContent("股票范围", value: "沿用后台配置").font(.subheadline)
                            Divider()
                            LabeledContent("策略参数", value: "沿用后台当前规则").font(.subheadline)
                        }
                    }
                    StockTradeCard {
                        Text("执行流程").font(.headline).padding(.bottom, 18)
                        StockTradeTimeline(phases: kind.phases)
                        Text(kind.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error { StockTradeMessage(text: error) }
                    if let active = store.activeWorkflow {
                        StockTradeTaskBanner(task: active) { submitted = active }
                    }
                    Button(submitting ? "正在提交…" : "确认启动") { Task { await submit() } }
                        .buttonStyle(StockTradeAppearance.action).disabled(submitting || store.activeWorkflow != nil || openedScope != store.scope)
                    StockTradeFootnote(text: "预计需要数分钟或更长，取决于数据量和复评耗时。后台保存任务状态，网络结果不确定时重试同一请求，不会重复创建。")
                }.disabled(submitting)

            }
        }
        .onAppear { if openedScope == nil { openedScope = store.scope } }
        .onChange(of: date) { _, _ in requestID = UUID().uuidString.lowercased() }
    }
    private func submit() async {
        guard openedScope == store.scope else { error = StockTradeFailure.changedContext.localizedDescription; return }
        submitting = true; error = nil
        defer { submitting = false }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        do { submitted = try await store.submitWorkflow(kind: kind, dataDate: kind == .full || kind == .preselect ? f.string(from: date) : nil, requestID: requestID) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription; await store.refreshWorkflows() }
    }
}

struct StockTradeWorkflowDetail: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let initial: StockTradeWorkflowTask
    let showResults: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: StockTradeWorkflowTask?
    @State private var error: String?
    @State private var openedScope: UUID?
    private var task: StockTradeWorkflowTask { detail ?? store.workflowTasks.first { $0.id == initial.id } ?? initial }
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: detailTitle, subtitle: "任务 #" + String(task.id.prefix(8)) + " · " + (task.dataDate ?? StockTradeTime.display(task.createdAt)))
            if let error { StockTradeMessage(text: error) }
            if openedScope == nil || openedScope == store.scope {
                StockTradeCard {
                    HStack {
                        Text(StockTradeWorkflowKind.phaseTitle(task.phase)).font(.headline)
                        Spacer()
                        Text(task.state.active ? "\(completedPhases) / \(task.kind.phases.count)" : task.state.title).font(.caption).foregroundStyle(StockTradeAppearance.tint)
                    }
                    ProgressView(value: Double(completedPhases), total: Double(task.kind.phases.count))
                        .tint(StockTradeAppearance.tint).padding(.vertical, 16).accessibilityLabel("已完成流程阶段")
                    StockTradeTimeline(phases: task.kind.phases, task: task)
                    if let event = task.events.last {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(event.message).font(.subheadline)
                            Text("最近更新 · " + StockTradeTime.display(event.at))
                                .font(.caption).foregroundStyle(.secondary)
                            if task.state.active, let started = task.startedAt.flatMap(StockTradeTime.date) {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("已运行 " + Self.elapsed(context.date.timeIntervalSince(started)))
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(StockTradeAppearance.soft, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 12)
                    }
                    if task.phase == "pending" { Text("等待后台执行或等待其他数据工作流结束。").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 12) }
                    if task.state == .failed {
                        StockTradeMessage(text: task.failureCode == "worker_interrupted" ? "执行进程已结束，结果未确认。请先查看发布记录，再决定是否重新运行。" : "当前步骤失败，本次未完成发布。上一次完整快照继续可用。")
                        Button("重新运行") { navigation.push(.create(task.kind)) }.buttonStyle(StockTradeAppearance.action).disabled(store.activeWorkflow != nil)
                    } else if task.state.active { Text("可以离开页面。阶段内进展由后台持续更新，百分比仅代表当前处理步骤。").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 12) }
                    if let result = task.result, task.state == .succeeded {
                        Text("数据日期 · " + result.dataAsOf).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 12)
                        Button("查看选股结果") {
                            Task {
                                do { try await store.openPublishedRun(result.runId); showResults() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(StockTradeAppearance.action)
                    }
                    DisclosureGroup("执行日志") {
                        ForEach(task.events) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.message).font(.subheadline)
                                Text(StockTradeTime.display(event.at)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                        }
                    }.font(.subheadline).padding(.top, 12)
                }
                StockTradeFootnote(text: "任务状态由后台保存。重新进入后可恢复查看，不会重复提交。")
            } else { Text("账号或连接已切换，请关闭后重新打开。") }
        }
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
    private var completedPhases: Int {
        task.state == .succeeded ? task.kind.phases.count : task.kind.phases.firstIndex(of: task.phase) ?? 0
    }
    private static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 3600 { return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分 \(seconds % 60) 秒" }
        if seconds >= 60 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds) 秒"
    }
    private var detailTitle: String {
        if task.state == .succeeded { return task.result == nil ? "任务已完成" : "结果已发布" }
        if task.state == .failed { return "选股未完成" }
        return task.kind == .full ? "完整选股进行中" : task.kind.title
    }

}

struct StockTradePublications: View {
    @ObservedObject var store: StockTradeStore
    let showResults: () -> Void
    @State private var items: [StockTradePublishedRun] = []
    @State private var cursor: String?
    @State private var error: String?
    @State private var loading = false
    @State private var openedScope: UUID?
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "发布记录", subtitle: "仅展示校验通过的完整快照")
            if let error { StockTradeMessage(text: error) }
            StockTradeCard(padding: 18) {
                if openedScope == store.scope {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, run in
                        Button {
                            Task {
                                do { try await store.openPublishedRun(run.runId); showResults() }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: { StockTradeEntryRow(title: run.dataAsOf + " · 完整选股", subtitle: "已发布 · " + StockTradeTime.display(run.publishedAt), separator: index < items.count - 1) }.buttonStyle(.plain)
                    }
                    if cursor != nil { Button("加载更早发布") { Task { await load(append: true) } }.disabled(loading).padding(.vertical, 12) }
                }
                if loading { ProgressView("读取发布记录…").padding(.vertical, 18) }
                if !loading && items.isEmpty && error == nil { Text("暂无已发布快照。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 18) }
            }
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
