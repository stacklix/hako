import SwiftUI

struct WorkshopInlineAgentsView: View {
    let group: WorkshopAgentGroup
    @ObservedObject var model: WorkshopSidechats
    @Binding var expanded: Bool
    @Binding var expandedRows: Set<String>
    let floating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").foregroundStyle(HakoStyle.muted)
                    Text("子代理").fontWeight(.medium)
                    Text("\(group.completedCount)/\(group.rows.count)").foregroundStyle(HakoStyle.muted).monospacedDigit()
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(HakoStyle.muted)
                }
                .font(.caption).padding(.horizontal, floating ? 20 : 14).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("子代理任务，\(group.completedCount)/\(group.rows.count) 已完成")
            .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                if floating {
                    ScrollView { rows }.frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
                } else { rows }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(floating ? HakoStyle.background : HakoStyle.card)
        .clipShape(RoundedRectangle(cornerRadius: floating ? 0 : 12))
        .overlay(alignment: .bottom) { if floating { Divider() } }
        .shadow(color: .black.opacity(floating ? 0.08 : 0), radius: 8, y: 4)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(group.rows) { row in
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        if expandedRows.contains(row.id) { expandedRows.remove(row.id) }
                        else { expandedRows.insert(row.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.activity.state == "completed" ? "checkmark" : row.active ? "circle.dotted" : "person.crop.circle")
                                .foregroundStyle(row.activity.state == "completed" ? Color.green : HakoStyle.muted).frame(width: 16)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.title).font(.caption).foregroundStyle(.primary).lineLimit(2)
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if row.active {
                                        TimelineView(.periodic(from: .now, by: 1)) { context in timing(row, at: context.date) }
                                    } else { timing(row, at: .now) }
                                }.font(.caption2).foregroundStyle(HakoStyle.muted)
                            }
                            Image(systemName: expandedRows.contains(row.id) ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(HakoStyle.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                    if expandedRows.contains(row.id) {
                        WorkshopInlineAgentDetails(row: row, model: model).padding(.leading, 26).padding(.bottom, 14)
                    }
                    if row.id != group.rows.last?.id { Divider() }
                }
            }
        }.padding(.horizontal, floating ? 20 : 14).padding(.bottom, 4)
    }

    private func timing(_ row: WorkshopAgentGroup.Row, at date: Date) -> some View {
        Text(row.elapsed(at: date).map { "\(row.status) · \($0)" } ?? row.status).monospacedDigit()
    }
}

private struct WorkshopInlineAgentDetails: View {
    let row: WorkshopAgentGroup.Row
    @ObservedObject var model: WorkshopSidechats
    @State private var instructions: [WorkshopSubagentInstruction] = []
    @State private var records: [WorkshopEntry] = []
    @State private var taskCursor: String?
    @State private var recordCursor: String?
    @State private var loading = false
    @State private var error: String?

    private var observationID: String { row.id + ":" + (row.activity.turn?.id ?? "") + ":" + row.activity.state + ":" + row.activity.summary + row.sources.joined(separator: ",") }
    private var messages: [WorkshopSubagentTaskPage.Message] {
        WorkshopSubagentTaskPage.messages(instructions).filter { row.sources.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if messages.isEmpty {
                section("分派摘要", text: row.activity.task.isEmpty ? "尚未读取到任务说明" : row.activity.task)
            } else {
                ForEach(messages) { message in
                    section(message.kind == "task" ? "任务说明" : "补充指令", text: message.text)
                    if !message.complete { Text("内容尚未读取完整").font(.caption2).foregroundStyle(HakoStyle.muted) }
                }
            }
            if !row.activity.summary.isEmpty {
                section(row.activity.state == "completed" ? "结果" : "最新进展", text: row.activity.summary)
            }
            ForEach(records.filter { $0.role != "user" && $0.kind != "turn" }) { entry in
                section(entry.role == "assistant" ? "子代理回复" : entry.recordTitle, text: entry.text)
            }
            if loading { ProgressView("正在读取任务记录…").font(.caption) }
            if taskCursor != nil || recordCursor != nil {
                Button("加载更多任务记录") { Task { await read(more: true) } }.font(.caption).disabled(loading)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重新读取") { Task { await read() } }.font(.caption).disabled(loading)
            }
        }
        .task(id: observationID) { await read() }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(HakoStyle.muted)
            Text(text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func read(more: Bool = false) async {
        let parent = model.parent
        guard !loading, parent.scope == parent.store.scope, parent.store.authenticated, let thread = parent.threadId else { return }
        loading = true
        defer { loading = false }
        let parameters: [String: Any] = ["threadId": thread, "applicationId": parent.application.id, "agentId": row.activity.agentId]
        do {
            if !more || taskCursor != nil {
                var query = parameters
                query["messageIds"] = Array(row.sources.suffix(32))
                if more { query["cursor"] = taskCursor }
                let page: WorkshopSubagentTaskPage = try await parent.store.call(parent.agent, "subagent.task.read", query)
                guard !Task.isCancelled, parent.scope == parent.store.scope else { return }
                var chunks = more ? instructions : []
                for entry in page.entries {
                    if let index = chunks.firstIndex(where: { $0.id == entry.id }) { chunks[index] = entry }
                    else { chunks.append(entry) }
                }
                instructions = chunks; taskCursor = page.nextCursor
                parent.updateInlineAgentInstructions(WorkshopSubagentTaskPage.messages(chunks))
            }
            if let turn = row.activity.turn?.id, !turn.isEmpty, !more || recordCursor != nil {
                var query = parameters
                if more { query["cursor"] = recordCursor }
                let page: WorkshopHistory = try await parent.store.call(parent.agent, "subagent.read", query)
                guard !Task.isCancelled, parent.scope == parent.store.scope else { return }
                let matching = page.entries.filter { $0.turnId == turn }
                if more { records = matching.filter { entry in !records.contains(where: { $0.id == entry.id }) } + records }
                else { records = matching }
                recordCursor = page.nextCursor
            }
            error = nil
        } catch is CancellationError { }
        catch { if parent.scope == parent.store.scope { self.error = error.localizedDescription } }
    }
}
