import SwiftUI

struct WorkshopSubagentRow: View {
    let agent: WorkshopSubagent
    var unread = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkshopSessionStatusIcon(item: .init(session: agent.session, hasDraft: false, isUnread: unread),
                symbol: "person.crop.square")
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name).foregroundStyle(HakoStyle.text).fontWeight(.medium)
                if !agent.role.isEmpty { Text(agent.role).font(.caption).foregroundStyle(.secondary) }
                Text(agent.taskDescription).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityValue(agent.status + (unread ? "，未读" : "，已读"))
    }
}

struct WorkshopSubagentDetail: View {
    @ObservedObject var model: WorkshopSidechats
    @Environment(\.scenePhase) private var scenePhase
    let initial: WorkshopSubagent
    @State private var entries: [WorkshopEntry] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var instructions: [WorkshopSubagentInstruction] = []
    @State private var taskCursor: String?
    @State private var taskLoading = false
    @State private var taskState = "loading"
    @State private var taskError: String?
    @State private var taskRevision: String?
    private var agent: WorkshopSubagent { model.agents.first { $0.id == initial.id } ?? initial }

    var body: some View {
        List {
            Section {
                LabeledContent("状态", value: agent.status)
                if !agent.role.isEmpty { LabeledContent("角色", value: agent.role) }
                if !agent.model.isEmpty { LabeledContent("模型", value: agent.model) }
                if !agent.reasoningEffort.isEmpty { LabeledContent("推理强度", value: agent.reasoningEffort) }
                LabeledContent("来源", value: "主会话分派")
            }
            let messages = WorkshopSubagentTaskPage.messages(instructions)
            Section("初始任务") {
                if let initial = messages.first(where: { $0.kind == "task" }) {
                    Text(initial.text).textSelection(.enabled)
                    if !initial.complete { Text("任务内容尚未读取完整").font(.caption).foregroundStyle(.secondary) }
                } else if taskState == "loading" {
                    ProgressView("正在读取任务说明…")
                } else if taskState != "error" {
                    Text("未记录初始任务说明").foregroundStyle(.secondary)
                }
            }
            let followups = messages.filter { $0.kind == "followup" }
            if !followups.isEmpty {
                Section("后续追加指令") {
                    ForEach(followups) { message in
                        Text(message.text).font(.subheadline).textSelection(.enabled)
                        if !message.complete { Text("指令内容尚未读取完整").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if taskCursor != nil || taskError != nil {
                Section {
                    if taskCursor != nil {
                        Button("加载更多任务指令") { Task { await readTasks(more: true) } }.disabled(taskLoading)
                    }
                    if let taskError {
                        Text(taskError).font(.footnote).foregroundStyle(.secondary)
                        Button("重新读取任务说明") { Task { await readTasks() } }.disabled(taskLoading)
                    }
                }
            }
            Section("最近进展与回复") {
                if cursor != nil {
                    Button("加载更早的记录") { Task { await read(more: true) } }.disabled(loading)
                }
                if entries.isEmpty && loading { ProgressView("正在读取…") }
                if entries.isEmpty && !loading && error == nil { Text("暂无进展记录").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.role == "assistant" ? "子代理回复" : entry.role == "user" ? "任务指令" : "执行记录")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.text).font(.subheadline).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取") { Task { await read() } }.disabled(loading)
                }
            }
            Section { DisclosureGroup("代理标识") { Text(agent.id).font(.caption.monospaced()).textSelection(.enabled) } }
        }
        .scrollContentBackground(.hidden).background(HakoStyle.background)
        .navigationTitle(agent.name).navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshAgents(); await read(); await readTasks() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshAgents()
                await read()
                await readTasks()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func readTasks(more: Bool = false) async {
        let parent = model.parent
        guard !taskLoading, parent.scope == parent.store.scope, parent.store.authenticated,
              let id = parent.threadId else { return }
        if !more, taskError == nil, taskState != "loading", agent.taskState != "loading", taskRevision == agent.taskVersion { return }
        let requestedRevision = agent.taskVersion
        taskLoading = true
        defer { taskLoading = false }
        do {
            var params: [String: Any] = ["threadId": id, "applicationId": parent.application.id, "agentId": initial.id]
            if more { guard let taskCursor else { return }; params["cursor"] = taskCursor }
            let reply: WorkshopSubagentTaskPage = try await parent.store.call(parent.agent, "subagent.task.read", params)
            guard !Task.isCancelled, parent.scope == parent.store.scope else { return }
            var byID = Dictionary(instructions.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            for chunk in reply.entries { byID[chunk.id] = chunk }
            instructions = Array(byID.values)
            if more || taskCursor == nil { taskCursor = reply.nextCursor }
            taskState = reply.state
            if reply.state == "ready" || reply.state == "missing" { taskRevision = requestedRevision }
            taskError = reply.state == "error" ? "任务说明暂时无法读取，请重新刷新。" : nil
        } catch is CancellationError { }
        catch {
            if parent.scope == parent.store.scope { taskState = "error"; taskError = error.localizedDescription }
        }
    }

    private func read(more: Bool = false) async {
        let parent = model.parent
        guard !loading, parent.scope == parent.store.scope, parent.store.authenticated, let id = parent.threadId else { return }
        loading = true
        defer { loading = false }
        let snapshot = agent
        do {
            var params: [String: Any] = ["threadId": id, "applicationId": parent.application.id, "agentId": initial.id]
            if more { guard let cursor else { return }; params["cursor"] = cursor }
            let reply: WorkshopHistory = try await parent.store.call(parent.agent, "subagent.read", params)
            guard !Task.isCancelled, parent.scope == parent.store.scope else { return }
            if more { entries = reply.entries.filter { entry in !entries.contains { $0.id == entry.id } } + entries }
            else {
                // Keep already loaded older pages while replacing the refreshed tail.
                let refreshed = Set(reply.entries.map(\.id))
                if let first = entries.firstIndex(where: { refreshed.contains($0.id) }) {
                    entries = Array(entries[..<first]) + reply.entries
                } else { entries = reply.entries; cursor = reply.nextCursor }
            }
            if more || cursor == nil { cursor = reply.nextCursor }
            if !more, snapshot.state == "completed" {
                parent.store.markRead(threadId: snapshot.id, completionId: snapshot.readToken, agentId: parent.agent.id)
            }
            error = nil
        } catch is CancellationError { }
        catch { if parent.scope == parent.store.scope { self.error = error.localizedDescription } }
    }
}
