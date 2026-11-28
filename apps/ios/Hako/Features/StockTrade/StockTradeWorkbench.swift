import SwiftUI

struct StockTradeWorkbench: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    var showResults: () -> Void
    @State private var strategySettings = false
    @State private var refreshID = UUID()
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "工作台", subtitle: "运行选股，管理后台任务")
            if let error = store.workflowError { StockTradeMessage(text: error) }
            StockTradeWorkbenchTaskCard(store: store, showResults: showResults, refreshID: refreshID)
            VStack(alignment: .leading, spacing: 8) {
                StockTradeSectionLabel(title: "选股管理")
                StockTradeCard {
                    Button { strategySettings = true }
                    label: { StockTradeWorkbenchEntry(title: "策略配置", subtitle: "股票范围、初选参数与推荐门槛", symbol: "line.3.horizontal.decrease") }
                        .buttonStyle(.plain).accessibilityIdentifier("cerno.work.strategy")
                    Button { navigation.push(.history) }
                    label: { StockTradeWorkbenchEntry(title: "执行记录", subtitle: "运行进度、日志与失败原因", symbol: "clock") }
                        .buttonStyle(.plain).accessibilityIdentifier("cerno.work.history")
                    Button { navigation.push(.publications) }
                    label: { StockTradeWorkbenchEntry(title: "发布历史", subtitle: "已完成的选股结果与数据日期", symbol: "square.3.layers.3d", separator: false) }
                        .buttonStyle(.plain).accessibilityIdentifier("cerno.work.publications")
                }
            }
            StockTradeWorkbenchMonitorEntry(store: store, refreshID: refreshID)
            StockTradeCard {
                Button { navigation.push(.operations) }
                label: { StockTradeWorkbenchEntry(title: "维护与诊断", subtitle: "分步操作、调度与后台状态", symbol: "wrench.and.screwdriver", separator: false) }
                    .buttonStyle(.plain).accessibilityIdentifier("cerno.work.maintenance")
            }
        }
        .refreshable { await store.refreshWorkflows(); refreshID = UUID() }
        .sheet(isPresented: $strategySettings) { StockTradeStrategySheet(store: store) }
    }
}

struct StockTradeWorkflowHistory: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let showResults: () -> Void
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "执行记录", subtitle: "查看历史执行结果与失败原因")
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
            StockTradeHeading(title: "维护与诊断", subtitle: "分步执行，检查调度与数据状态")
            StockTradeSectionLabel(title: "分步操作")
            StockTradeCard(padding: 18) {
                ForEach(StockTradeWorkflowKind.allCases.filter { $0 != .full && $0 != .monitor }) { kind in
                    Button { navigation.push(.create(kind)) }
                    label: { StockTradeEntryRow(title: kind.title, subtitle: operationSubtitle(kind), separator: kind != .publish) }.buttonStyle(.plain)
                }
            }
            StockTradeFootnote(text: "分步操作同样受任务互斥约束。初选、复评完成后，需通过发布校验才会更新选股页。")
            StockTradeSectionLabel(title: "后台诊断")
            StockTradeCard {
                Button { navigation.push(.health) }
                label: { StockTradeWorkbenchEntry(title: "调度与后台状态", subtitle: "服务、任务执行与监控采样", symbol: "waveform.path.ecg", separator: false) }
                    .buttonStyle(.plain).accessibilityIdentifier("cerno.work.health")
            }
        }
    }
    private func operationSubtitle(_ kind: StockTradeWorkflowKind) -> String {
        switch kind {
        case .full: "完整流程"
        case .fetch: "更新数据源"
        case .preselect: "生成候选名单"
        case .review: "评估候选股票"
        case .publish: "校验完整性后发布"
        case .monitor: "启用盘中规则监控"
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
    @State private var configuration: StockTradeStrategyConfiguration?
    @State private var showsStrategy = false
    private var usesStrategy: Bool { [.full, .fetch, .preselect, .review].contains(kind) }
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
                            LabeledContent(kind == .monitor ? "观察名单来源" : "股票范围", value: kind == .monitor ? "最新已发布的正式推荐" : configuration?.settings.boardSummary ?? (usesStrategy ? "等待读取" : "已有结果的股票范围")).font(.subheadline)
                            Divider()
                            if usesStrategy {
                                if let configuration {
                                    LabeledContent("配置版本", value: String(configuration.revision.prefix(12))).font(.caption.monospaced())
                                    Text("流动性池 \(configuration.settings.liquidityCount) 只 · 最多推荐 \(configuration.settings.recommendationCount) 只").font(.footnote).foregroundStyle(.secondary)
                                }
                                Button("查看与修改策略配置") { showsStrategy = true }.font(.subheadline)
                                Button("重新读取配置") { Task { await loadStrategy() } }.font(.subheadline)
                            } else { LabeledContent("策略参数", value: "沿用已发布结果的规则").font(.subheadline) }
                        }
                    }
                    if kind == .monitor { StockTradeMonitorControlStatus(store: store) }
                    StockTradeCard {
                        Text("执行流程").font(.headline).padding(.bottom, 18)
                        if kind == .monitor {
                            StockTradeMonitorSteps()
                        } else { StockTradeTimeline(phases: kind.phases) }
                        Text(kind.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error { StockTradeMessage(text: error) }
                    if let active = store.activeWorkflow {
                        StockTradeTaskBanner(task: active) { submitted = active }
                    }
                    Button(submitting ? "正在提交…" : "确认启动") { Task { await submit() } }
                        .buttonStyle(StockTradeAppearance.action).disabled(submitting || store.activeWorkflow != nil || openedScope != store.scope || usesStrategy && configuration == nil)
                    StockTradeFootnote(text: kind == .monitor ? "仅生成规则提醒和纸面模拟记录，不会下单。正式推荐为空时仍会启用调度并发布空快照；重复启用不会启动第二套调度。" : "预计需要数分钟或更长，取决于数据量和复评耗时。后台保存任务状态，网络结果不确定时重试同一请求，不会重复创建。")
                }.disabled(submitting)

            }
        }
        .onAppear { if openedScope == nil { openedScope = store.scope } }
        .task(id: store.scope) {
            if openedScope == nil { openedScope = store.scope }
            if usesStrategy { await loadStrategy() }
        }
        .onChange(of: store.scope) { _, _ in configuration = nil }
        .sheet(isPresented: $showsStrategy, onDismiss: { Task { await loadStrategy() } }) { StockTradeStrategySheet(store: store) }
        .onChange(of: date) { _, _ in requestID = UUID().uuidString.lowercased() }
    }
    private func submit() async {
        guard openedScope == store.scope else { error = StockTradeFailure.changedContext.localizedDescription; return }
        submitting = true; error = nil
        defer { submitting = false }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        do { submitted = try await store.submitWorkflow(kind: kind, dataDate: kind == .full || kind == .preselect ? f.string(from: date) : nil, requestID: requestID, strategyRevision: usesStrategy ? configuration?.revision : nil) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription; await store.refreshWorkflows() }
    }
    private func loadStrategy() async {
        guard openedScope == store.scope, usesStrategy else { return }
        do {
            let value = try await store.strategyConfiguration()
            guard openedScope == store.scope else { return }
            if configuration?.revision != value.revision { requestID = UUID().uuidString.lowercased() }
            configuration = value; error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
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
                        StockTradeMessage(text: task.failureCode == "worker_interrupted" ? "执行进程已结束，结果未确认。请先查看后台状态，再决定是否重新运行。" : task.kind == .monitor ? "监控启用未完成，请检查调度与后台状态后重试。" : "当前步骤失败，本次未完成发布。上一次完整快照继续可用。")
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
                    if let result = task.monitorResult, task.state == .succeeded {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("观察中", value: "\(result.watchCount) 只").font(.subheadline)
                            LabeledContent("纸面持仓", value: "\(result.openCount) 只").font(.subheadline)
                            Text("首份监控快照 · " + StockTradeTime.display(result.publishedAt)).font(.caption).foregroundStyle(.secondary)
                            if result.watchCount == 0 && result.openCount == 0 {
                                Text("当前没有可监控记录，后续正式推荐发布后会自动同步。首份快照已发布。").font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("调度按后台交易日与时段规则采样，启用成功不代表已有实时行情或规则触发。").font(.footnote).foregroundStyle(.secondary)
                            Button("查看调度与后台状态") { navigation.push(.health) }.buttonStyle(HakoActionButtonStyle(primary: false))
                        }.padding(.vertical, 12)
                    }
                    DisclosureGroup("执行日志") {
                        ForEach(task.events) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.message).font(.subheadline)
                                Text(StockTradeTime.display(event.at)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                        }
                    }.font(.subheadline).padding(.top, 12)
                    if let configuration = task.configuration {
                        DisclosureGroup("本次使用的策略配置") {
                            Text(configuration.settings.boardSummary).font(.subheadline)
                            LabeledContent("配置版本", value: String(configuration.revision.prefix(12))).font(.caption.monospaced())
                            LabeledContent("流动性池", value: "\(configuration.settings.liquidityCount) 只 / \(configuration.settings.turnoverDays) 日")
                            LabeledContent("最低总分", value: configuration.settings.minScore.formatted())
                            LabeledContent("最低排序分", value: configuration.settings.minRankScore.formatted())
                            LabeledContent("最多推荐", value: "\(configuration.settings.recommendationCount) 只")
                        }.font(.subheadline).padding(.top, 12)
                    }
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
        if task.state == .succeeded { return task.kind == .monitor ? "规则监控已启用" : task.result == nil ? "任务已完成" : "结果已发布" }
        if task.state == .failed { return task.kind == .monitor ? "监控启用未完成" : "选股未完成" }
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
