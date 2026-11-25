import SwiftUI
import AppIntents
import UIKit

struct HakoShortcutRunControl: View {
    @ObservedObject private var history = HakoShortcutHistory.shared
    private var active: HakoShortcutRun? { history.runs.first { $0.status == .running } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(intent: ManualSyncHakoDataIntent()) {
                Label(active == nil ? "立即同步 Hako 数据" : "正在同步…", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(HakoActionButtonStyle())
            .disabled(active != nil)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

struct HakoShortcutsView: View {
    @ObservedObject private var history = HakoShortcutHistory.shared
    private var displayedRun: HakoShortcutRun? {
        history.runs.first { $0.status == .running } ?? history.runs.first
    }

    var body: some View {
        List {
            Section("子任务") {
                ForEach(HakoShortcutRegistry.availableTaskNames, id: \.self) { name in
                    let step = displayedRun?.steps.first { $0.name == name }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(name, value: step?.status.rawValue ?? (displayedRun == nil ? "待执行" : "本次未执行"))
                        if step?.status == .running, let event = step?.events?.last {
                            Text(event.stageTitle + " · " + event.state.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
            Section {
                HakoShortcutRunControl()
            } header: { Text("同步 Hako 数据") } footer: {
                Text("按各子任务的执行计划同步，结果保存在执行历史中。需要立即备份时，请在投资备份设置中单独执行。")
            }
            if let issue = history.storageIssue {
                Section { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            }
            if let run = displayedRun {
                Section(run.status == .running ? "处理进度" : "最近一次执行") {
                    HakoShortcutProgressView(run: run)
                    NavigationLink {
                        HakoShortcutRunView(history: history, runID: run.id)
                    } label: {
                        Label("查看执行详情", systemImage: "list.bullet.rectangle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HakoShortcutProgressView: View {
    let run: HakoShortcutRun

    var body: some View {
        let completed = run.steps.filter { $0.status != .running && $0.status != .pending }.count
        let active = run.steps.filter { $0.status == .running }
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(run.name, value: run.status.rawValue)
            if !run.steps.isEmpty {
                ProgressView(value: Double(completed), total: Double(run.steps.count)) {
                    Text("已处理 \(completed)/\(run.steps.count) 个子任务")
                        .font(.subheadline)
                }
            }
            if run.status == .running {
                if active.isEmpty { Text("正在准备子任务…").font(.subheadline.weight(.medium)) }
                ForEach(active) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.name).font(.subheadline.weight(.medium))
                        if let event = step.events?.last {
                            Text(event.stageTitle + " · " + event.state.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

struct HakoShortcutHistoryView: View {
    @ObservedObject private var history = HakoShortcutHistory.shared

    var body: some View {
        List {
            if let issue = history.storageIssue {
                Section { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                if history.runs.isEmpty {
                    ContentUnavailableView("暂无执行记录", systemImage: "clock.arrow.circlepath",
                                           description: Text("在快捷指令中运行「同步 Hako 数据」后，记录会显示在这里。"))
                }
                ForEach(history.runs) { run in
                    NavigationLink {
                        HakoShortcutRunView(history: history, runID: run.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(run.name).font(.headline)
                                Text(run.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("触发来源：" + (run.triggerSource?.title ?? "未记录"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if run.lastRetrySource != nil {
                                    Text("最近重试来源：App 内触发").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(run.status.rawValue).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            } footer: {
                Text("本机最多保留最近 \(HakoShortcutHistory.capacity) 次执行。可在“iCloud 与换机恢复”中选择是否纳入系统备份。")
            }
        }
        .navigationTitle("快捷指令执行历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HakoShortcutRunView: View {
    @ObservedObject var history: HakoShortcutHistory
    let runID: UUID
    @State private var copiedLogs = false

    var body: some View {
        List {
            if let run = history.runs.first(where: { $0.id == runID }) {
                Section("执行概况") {
                    LabeledContent("快捷指令", value: run.name)
                    LabeledContent("状态", value: run.status.rawValue)
                    LabeledContent("触发来源", value: run.triggerSource?.title ?? "未记录")
                    if let source = run.lastRetrySource {
                        LabeledContent("最近重试来源", value: source.title)
                    }
                    LabeledContent("开始时间", value: run.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let finished = run.finishedAt {
                        LabeledContent("结束时间", value: finished.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("耗时", value: "\(max(0, Int(finished.timeIntervalSince(run.startedAt)))) 秒")
                    }
                    Button {
                        let app = Bundle.main.infoDictionary ?? [:]
                        let version = app["CFBundleShortVersionString"] as? String ?? "未记录"
                        let build = app["CFBundleVersion"] as? String ?? "未记录"
                        let header = ["执行 ID：" + run.id.uuidString, "状态：" + run.status.rawValue,
                                      "应用版本：" + version + " (" + build + ")",
                                      "触发来源：" + (run.triggerSource?.title ?? "未记录")]
                        UIPasteboard.general.string = ([run.name] + header + run.steps.map { step in
                            HakoExecutionLogExport.text(title: step.name, metadata: ["状态：" + step.status.rawValue, step.message ?? ""],
                                events: step.events ?? [], startedAt: step.startedAt, finishedAt: step.finishedAt, capacity: HakoShortcutHistory.eventCapacity)
                        }).joined(separator: "\n\n")
                        copiedLogs = true
                    } label: {
                        Label(copiedLogs ? "已复制全部子任务日志" : "复制全部子任务日志", systemImage: copiedLogs ? "checkmark" : "doc.on.doc")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                if run.status.canRetry {
                    Section {
                        HakoShortcutRetryButton(history: history, runID: runID)
                    } footer: {
                        Text("仅重新执行失败、取消或中断的子任务；成功和按计划跳过的子任务不重试。重试仍遵守各子任务的执行计划。")
                    }
                }
                if !run.steps.isEmpty {
                    Section("子任务") {
                        ForEach(run.steps) { step in
                            NavigationLink {
                                HakoShortcutStepView(history: history, runID: runID, name: step.name)
                            } label: {
                                LabeledContent(step.name, value: step.status.rawValue)
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }
                    }
                }
            } else {
                ContentUnavailableView("记录已移出历史", systemImage: "clock")
            }
        }
        .navigationTitle("执行详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HakoShortcutStepView: View {
    @ObservedObject var history: HakoShortcutHistory
    let runID: UUID
    let name: String
    @State private var diagnosticsExpanded = false
    @State private var copiedLog = false

    private var step: HakoShortcutRun.Step? {
        history.runs.first(where: { $0.id == runID })?.steps.first(where: { $0.name == name })
    }

    var body: some View {
        List {
            if let step {
                let rows = HakoExecutionLogRow.merging(step.events ?? [])
                let keySteps = HakoExecutionLogItem.grouping(rows)
                let diagnostics = rows.filter(\.isDiagnostic)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(step.status.rawValue, systemImage: statusSymbol(step.status))
                            .font(.headline)
                            .foregroundStyle(step.status == .failed ? Color.red : Color.primary)
                        if let message = step.message, !message.isEmpty {
                            Text(message).font(.subheadline).textSelection(.enabled)
                        }
                        if let start = step.startedAt {
                            Text(start, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            if step.status == .running {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(totalDuration(step, at: context.date))
                                }
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            } else {
                                Text(totalDuration(step, at: .now))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        UIPasteboard.general.string = logText(step)
                        copiedLog = true
                    } label: {
                        Label(copiedLog ? "已复制全量日志" : "复制全量日志", systemImage: copiedLog ? "checkmark" : "doc.on.doc")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                Section("关键步骤") {
                    if !keySteps.isEmpty {
                        ForEach(keySteps) { item in
                            HakoShortcutEventRow(row: item.row, running: step.status == .running, children: item.children)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }
                    } else {
                        Text("此记录未记录业务步骤。已有诊断信息可在下方展开；下次执行会记录实际步骤和结果。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("诊断信息 · \(diagnostics.count) 项", isExpanded: $diagnosticsExpanded) {
                        ForEach(diagnostics) { row in
                            HakoShortcutEventRow(row: row, running: step.status == .running)
                                .textSelection(.enabled)
                        }
                    }
                    DisclosureGroup("执行信息") {
                        if let count = step.attempts { LabeledContent("执行次数", value: "\(count)") }
                        if let start = step.startedAt {
                            LabeledContent("本次开始", value: start.formatted(date: .abbreviated, time: .standard))
                            if let end = step.finishedAt {
                                LabeledContent("本次结束", value: end.formatted(date: .abbreviated, time: .standard))
                                LabeledContent("本次耗时", value: String(format: "%.2f 秒", max(0, end.timeIntervalSince(start))))
                            }
                        }
                    }
                } footer: {
                    Text("保留最近 \(HakoShortcutHistory.eventCapacity) 条原始事件，包含重试前的记录。展开步骤可查看起止时间和详情。")
                }
            } else {
                ContentUnavailableView("记录已移出历史", systemImage: "clock")
            }
        }
        .privacySensitive()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let step {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: logText(step)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("分享子任务执行日志")
                }
            }
        }
    }

    // Use the whole child's wall time; its nested operations may overlap.
    // startedAt/finishedAt belong to the current attempt, excluding time waiting for a retry.
    private func totalDuration(_ step: HakoShortcutRun.Step, at now: Date) -> String {
        guard let start = step.startedAt,
              let end = step.finishedAt ?? (step.status == .running ? now : nil) else { return "总耗时：未记录" }
        return (step.status == .running ? "已耗时：" : "总耗时：")
            + String(format: "%.2f 秒", max(0, end.timeIntervalSince(start)))
    }

    private func statusSymbol(_ status: HakoShortcutRun.Status) -> String {
        switch status {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled, .interrupted: "pause.circle"
        case .skipped: "arrow.right.circle"
        case .pending, .running: "clock"
        }
    }

    private func logText(_ step: HakoShortcutRun.Step) -> String {
        let app = Bundle.main.infoDictionary ?? [:]
        let version = app["CFBundleShortVersionString"] as? String ?? "未记录"
        let build = app["CFBundleVersion"] as? String ?? "未记录"
        return HakoExecutionLogExport.text(title: name, metadata: [
            "应用版本：" + version + " (" + build + ")", "执行 ID：" + runID.uuidString,
            "触发来源：" + (history.runs.first(where: { $0.id == runID })?.triggerSource?.title ?? "未记录"),
            "状态：" + step.status.rawValue, "执行次数：\(step.attempts ?? 1)", step.message ?? "",
            totalDuration(step, at: .now)
        ], events: step.events ?? [], startedAt: step.startedAt, finishedAt: step.finishedAt, capacity: HakoShortcutHistory.eventCapacity)
    }

}

private struct HakoShortcutEventRow: View {
    let row: HakoExecutionLogRow
    let running: Bool
    var children: [HakoExecutionLogItem] = []
    var showsParallelBadge = true
    var expansion: Binding<Bool>?
    @State private var expanded = false
    @State private var expandedChildID: UUID?

    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text("开始：" + (row.startedAt?.formatted(date: .abbreviated, time: .standard) ?? "未记录"))
                Text("结束：" + (row.finishedAt?.formatted(date: .abbreviated, time: .standard) ?? "未记录"))
                if row.plannedBranches == nil {
                    if let branch = row.parallelBranch { Text("并行分支：" + branch) }
                    if !row.detail.isEmpty { Text(row.detail).textSelection(.enabled) }
                } else if [.failed, .cancelled].contains(row.state), !row.detail.isEmpty {
                    Text(row.detail).textSelection(.enabled)
                }
                if row.plannedBranches != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                            if index > 0 { Divider() }
                            AnyView(HakoShortcutEventRow(row: child.row, running: running, children: child.children,
                                                        showsParallelBadge: false, expansion: childExpansion(child.id)))
                        }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
                    .padding(.vertical, 8)
                    Text("计划耗时按整体起止时间计算，各分支耗时不相加。")
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).font(.subheadline)
                    .frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.stageTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        if showsParallelBadge && (row.parallelBranch != nil || (row.plannedBranches ?? 0) > 1) {
                            Text("并行").font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }
                    }
                    if let planned = row.plannedBranches {
                        let completed = HakoExecutionLogItem(row: row, children: children).completedBranches
                        Text("\(completed) / \(planned) 个分支已完成" + (row.detail.components(separatedBy: "\n").first.map { " · " + $0 } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !row.detail.isEmpty && row.detail != "执行成功。" {
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if row.state != .info {
                        if row.state == .started && running {
                            TimelineView(.periodic(from: .now, by: 1)) { context in timing(at: context.date) }
                        } else {
                            timing(at: row.finishedAt ?? .now)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .disclosureGroupStyle(HakoShortcutLogDisclosureStyle())
    }

    private func childExpansion(_ id: UUID) -> Binding<Bool> {
        Binding {
            expandedChildID == id
        } set: { isExpanded in
            if isExpanded {
                expandedChildID = id
            } else if expandedChildID == id {
                expandedChildID = nil
            }
        }
    }

    private var tint: Color { row.state == .failed ? .red : row.state == .succeeded ? .green : .secondary }

    private var symbol: String {
        switch row.state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "pause.circle"
        case .started: "clock"
        case .info: "info.circle"
        }
    }

    private func timing(at now: Date) -> some View {
        let result = row.state == .started ? (running ? "执行中" : "未记录结束") : row.state.rawValue
        let duration = row.finishedAt == nil && !running ? "—" : row.elapsed(at: now)
        return Text(result + (duration == "—" ? "" : " · " + duration))
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
    }
}

// Keep nested log details in a top-aligned layout instead of List's native
// disclosure transition, which can reposition the containing plan row.
private struct HakoShortcutLogDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

private struct HakoShortcutRetryButton: View {
    @ObservedObject var history: HakoShortcutHistory
    let runID: UUID
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                error = nil
                Task {
                    do { _ = try await HakoShortcutRegistry.retry(runID) }
                    catch { self.error = error.localizedDescription }
                }
            } label: {
                Label("重试未完成任务", systemImage: "arrow.clockwise")
            }
            .buttonStyle(HakoActionButtonStyle())
            .disabled(history.runs.contains { $0.status == .running })
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
