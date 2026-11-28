import SwiftUI

struct StockTradeWorkbenchEntry: View {
    let title: String
    let subtitle: String
    let symbol: String
    var status: String? = nil
    var separator = true
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { if separator { Divider() } }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        .accessibilityElement(children: .combine)
    }
}

struct StockTradeWorkbenchTaskCard: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: StockTradeStore
    let showResults: () -> Void
    let refreshID: UUID
    @State private var latestRun: StockTradeRun?
    @State private var resultScope: UUID?
    @State private var noPublishedResult = false
    @State private var resultError: String?
    @State private var openingResult = false
    private var task: StockTradeWorkflowTask? {
        store.activeWorkflow ?? store.workflowTasks.first.flatMap { $0.state == .failed ? $0 : nil }
    }
    private var latest: StockTradeRun? { resultScope == store.scope ? latestRun : nil }
    private var refreshKey: String {
        let publication = store.workflowTasks.first { $0.state == .succeeded && $0.result != nil }?.id ?? ""
        return "\(store.scope)|\(publication)|\(scenePhase == .active)|\(refreshID)"
    }
    var body: some View {
        StockTradeCard {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) { title; Spacer(minLength: 0); status }
                    VStack(alignment: .leading, spacing: 8) { title; status }
                }
                taskSubtitle
                StockTradeWorkbenchPhases(task: task).padding(.vertical, 6)
                if let task, let event = task.events.max(by: { $0.sequence < $1.sequence }) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.message).font(.footnote).lineLimit(3)
                        Text("最近日志 · " + StockTradeTime.display(event.at)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(StockTradeAppearance.line).frame(width: 2) }
                }
                Button {
                    if let task { navigation.push(.task(task)) }
                    else { navigation.push(.create(.full)) }
                } label: {
                    Label(task == nil ? "启动完整选股" : task?.state == .failed ? "查看原因并重试" : "查看进度与日志",
                          systemImage: task == nil ? "play" : task?.state == .failed ? "exclamationmark.bubble" : "waveform.path.ecg")
                }.buttonStyle(StockTradeAppearance.action).accessibilityIdentifier("cerno.work.primary")
                Text(task?.state == .failed ? "本次未完成发布，上一次完整结果仍可查看。" : "在后台执行，离开 App 后仍会继续。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().padding(.top, 2)
                if let latest {
                    Button { Task { await openResult(latest) } } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { publicationDate(latest); Spacer(minLength: 0); publicationCounts(latest) }
                            VStack(alignment: .leading, spacing: 6) { publicationDate(latest); publicationCounts(latest) }
                        }
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(openingResult).accessibilityIdentifier("cerno.work.latest-result")
                } else {
                    Button { navigation.push(.publications) } label: {
                        HStack {
                            Text(resultScope == store.scope && noPublishedResult ? "暂无已发布结果" : "查看发布结果")
                            Spacer()
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if resultScope == store.scope, let resultError { StockTradeMessage(text: resultError) }
            }
        }
        .task(id: refreshKey) { if scenePhase == .active { await refreshLatest() } }
    }
    private var title: some View { Text(task?.kind.title ?? "完整选股并发布").font(.headline) }
    private var status: some View {
        Text(task?.state.title ?? "准备就绪")
            .font(.caption).foregroundStyle(task?.state == .failed ? .orange : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(StockTradeAppearance.soft, in: RoundedRectangle(cornerRadius: 7))
    }
    @ViewBuilder private var taskSubtitle: some View {
        if let task {
            VStack(alignment: .leading, spacing: 4) {
                Text(StockTradeWorkflowKind.phaseTitle(task.phase)).font(.footnote).foregroundStyle(.secondary)
                if task.state.active, let started = task.startedAt.flatMap(StockTradeTime.date) {
                    HStack(spacing: 4) { Text("已运行"); Text(started, style: .timer).monospacedDigit() }
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text(StockTradeTime.display(task.finishedAt ?? task.createdAt)).font(.caption).foregroundStyle(.secondary) }
            }
        } else { Text("选择日期，完成后自动发布新结果").font(.footnote).foregroundStyle(.secondary) }
    }
    private func publicationDate(_ run: StockTradeRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resultError == nil ? "最近发布" : "最近读取的发布").foregroundStyle(.secondary)
            Text(StockTradeTime.display(run.publishedAt))
        }
    }
    private func publicationCounts(_ run: StockTradeRun) -> some View {
        HStack(spacing: 6) {
            Text("\(run.candidateCount) 候选 · \(run.recommendationCount) 推荐").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }
    private func refreshLatest() async {
        let scope = store.scope
        do {
            let value = try await store.read(["runs", "latest"], as: StockTradeRun.self)
            try Task.checkCancellation()
            guard scope == store.scope else { return }
            guard value.status == "complete", value.candidateCount >= 0, value.recommendationCount >= 0 else { throw StockTradeFailure.invalidResponse }
            latestRun = value; noPublishedResult = false; resultScope = scope; resultError = nil
        } catch is CancellationError { }
        catch {
            guard scope == store.scope else { return }
            if resultScope != scope { latestRun = nil }
            resultScope = scope
            if let failure = error as? StockTradeFailure, case .api(404, "snapshot_unavailable", _, _) = failure {
                latestRun = nil; noPublishedResult = true; resultError = nil
            } else { noPublishedResult = false; resultError = "最新发布结果读取失败：" + error.localizedDescription }
        }
    }
    private func openResult(_ run: StockTradeRun) async {
        let scope = store.scope
        openingResult = true
        defer { openingResult = false }
        do {
            try await store.openPublishedRun(run.runId)
            guard scope == store.scope else { return }
            showResults()
        } catch is CancellationError { }
        catch { if scope == store.scope { resultError = error.localizedDescription } }
    }
}

private struct StockTradeWorkbenchPhases: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: StockTradeWorkflowTask?
    private var phases: [String] { task?.kind.phases ?? StockTradeWorkflowKind.full.phases }
    private var current: Int? { task.flatMap { phases.firstIndex(of: $0.phase) } }
    var body: some View {
        let vertical = typeSize.isAccessibilitySize
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            ForEach(Array(phases.enumerated()), id: \.element) { index, phase in
                let completed = task?.state == .succeeded || current.map { index < $0 } == true
                let selected = index == current
                let cell = vertical ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 7))
                cell {
                    HStack(spacing: 0) {
                        if !vertical { line(visible: index > 0) }
                        ZStack {
                            Circle().fill(selected ? StockTradeAppearance.tint : StockTradeAppearance.panel)
                            Circle().strokeBorder(StockTradeAppearance.line, lineWidth: selected ? 0 : 1)
                            Group {
                                if completed { Image(systemName: "checkmark") }
                                else { Text("\(index + 1)") }
                            }.font(.caption2).foregroundStyle(selected ? StockTradeAppearance.selectedText : StockTradeAppearance.tint)
                        }.frame(width: 23, height: 23)
                        if !vertical { line(visible: index < phases.count - 1) }
                    }.accessibilityHidden(true)
                    Text(StockTradeWorkflowKind.phaseTitle(phase)).font(.caption2)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .multilineTextAlignment(vertical ? .leading : .center)
                        .frame(maxWidth: .infinity, alignment: vertical ? .leading : .center)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StockTradeWorkflowKind.phaseTitle(phase) + (completed ? "，已完成" : selected ? "，" + (task?.state.title ?? "") : "，等待执行"))
            }
        }
    }
    private func line(visible: Bool) -> some View { Rectangle().fill(visible ? StockTradeAppearance.line : .clear).frame(height: 1) }
}

struct StockTradeWorkbenchMonitorEntry: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: StockTradeStore
    let refreshID: UUID
    @State private var status: StockTradeMonitorStatus?
    @State private var displayedScope: UUID?
    @State private var error: String?
    private var refreshKey: String {
        let task = store.workflowTasks.first { $0.kind == .monitor }
        return "\(store.scope)|\(task?.id ?? "")|\(task?.state.rawValue ?? "")|\(scenePhase == .active)|\(refreshID)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StockTradeSectionLabel(title: "持续监控")
            StockTradeCard {
                Button { navigation.push(.monitorControl) } label: {
                    StockTradeWorkbenchEntry(title: "规则监控", subtitle: "跟踪正式推荐，记录规则触发", symbol: "waveform.path.ecg",
                        status: displayedScope == store.scope ? status?.title ?? "状态未确认" : "状态未确认", separator: false)
                }.buttonStyle(.plain).accessibilityIdentifier("cerno.work.monitor")
            }
            StockTradeFootnote(text: "单独启用后持续运行；纸面模拟，不会下单。")
            if displayedScope == store.scope, let error { StockTradeMessage(text: error) }
        }
        .task(id: refreshKey) {
            guard scenePhase == .active else { return }
            let scope = store.scope
            do {
                let value = try await store.read(["monitor", "status"], as: StockTradeMonitorStatus.self)
                try Task.checkCancellation()
                guard scope == store.scope else { return }
                status = value; displayedScope = scope; error = nil
            } catch is CancellationError { }
            catch {
                guard scope == store.scope else { return }
                status = nil; displayedScope = scope; self.error = "监控状态读取失败，可进入规则监控重试。"
            }
        }
    }
}

struct StockTradeMonitorManagement: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let showMonitor: () -> Void
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "规则监控", subtitle: "独立启用，持续跟踪正式推荐")
            StockTradeMonitorControlStatus(store: store)
            StockTradeCard {
                Button(action: showMonitor) {
                    StockTradeWorkbenchEntry(title: "监控与提醒记录", subtitle: "观察中、纸面持仓与已结束", symbol: "waveform.path.ecg")
                }.buttonStyle(.plain)
                Button { navigation.push(.health) } label: {
                    StockTradeWorkbenchEntry(title: "调度与采样状态", subtitle: "查看心跳、最近行情和异常", symbol: "heart.text.square", separator: false)
                }.buttonStyle(.plain)
            }
            StockTradeCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("从正式推荐同步观察名单").font(.headline)
                    Text("启用后在后台按交易时段采样；后续正式推荐发布时自动同步，保留已有纸面持仓。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("配置与同步观察名单") { navigation.push(.create(.monitor)) }.buttonStyle(StockTradeAppearance.action)
                }
            }
            StockTradeFootnote(text: "名单为空也可启用。此处为规则观察与纸面模拟，不会向券商下单。")
        }
    }
}
