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
                Text("保存在本机，最多保留最近 \(HakoShortcutHistory.capacity) 次执行。")
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
                if !run.steps.isEmpty {
                    Section("子任务") {
                        ForEach(run.steps) { step in
                            LabeledContent(step.name, value: step.status.rawValue)
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
