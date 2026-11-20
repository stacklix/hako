import SwiftUI

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

    var body: some View {
        List {
            if let run = history.runs.first(where: { $0.id == runID }) {
                Section("执行概况") {
                    LabeledContent("快捷指令", value: run.name)
                    LabeledContent("状态", value: run.status.rawValue)
                    LabeledContent("开始时间", value: run.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let finished = run.finishedAt {
                        LabeledContent("结束时间", value: finished.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("耗时", value: "\(max(0, Int(finished.timeIntervalSince(run.startedAt)))) 秒")
                    }
                }
                if run.status == .failed {
                    Section {
                        HakoShortcutRetryButton(history: history, runID: runID)
                    } footer: {
                        Text("仅重新执行未成功的子任务，成功后更新本条记录。")
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

    private var step: HakoShortcutRun.Step? {
        history.runs.first(where: { $0.id == runID })?.steps.first(where: { $0.name == name })
    }

    var body: some View {
        List {
            if let step {
                Section("子任务概况") {
                    LabeledContent("状态", value: step.status.rawValue)
                    if let count = step.attempts { LabeledContent("执行次数", value: "\(count)") }
                    if let start = step.startedAt {
                        LabeledContent("本次开始", value: start.formatted(date: .abbreviated, time: .standard))
                        if let end = step.finishedAt {
                            LabeledContent("本次耗时", value: "\(max(0, Int(end.timeIntervalSince(start)))) 秒")
                        }
                    }
                }
                if let message = step.message, !message.isEmpty {
                    Section("执行结果") { Text(message).textSelection(.enabled) }
                }
                Section {
                    if let events = step.events, !events.isEmpty {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(event.time, format: .dateTime.hour().minute().second())
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    Spacer()
                                    Text(event.state.rawValue).font(.caption)
                                        .foregroundStyle(event.state == .failed ? Color.red : Color.secondary)
                                }
                                Text(event.stage).font(.subheadline.weight(.medium))
                                if !event.detail.isEmpty { Text(event.detail).font(.footnote).foregroundStyle(.secondary) }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }
                    } else {
                        Text("此记录没有详细日志。更新后重新执行可生成日志。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("详细日志") } footer: {
                    Text("最多保留最近 \(HakoShortcutHistory.eventCapacity) 条日志，包含重试前的记录。时间为本机时间。")
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

    private func logText(_ step: HakoShortcutRun.Step) -> String {
        (["\(name)：\(step.status.rawValue)", step.message ?? ""] + (step.events ?? []).map {
            "[\($0.time.formatted(date: .numeric, time: .standard))] [\($0.state.rawValue)] \($0.stage)\n\($0.detail)"
        }).joined(separator: "\n")
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
                Label("重试失败任务", systemImage: "arrow.clockwise")
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
