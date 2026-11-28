import Foundation

struct WorkshopSubagent: Decodable, Identifiable {
    let id: String
    let name: String
    let role: String
    let task: String
    let state: String
    let model: String
    let reasoningEffort: String
    let updatedAt: Int64
    var taskState: String? = nil
    var taskVersion: String? = nil
    var turn: WorkshopTurn? = nil
    var summary: String? = nil

    var taskDescription: String {
        if !task.isEmpty { return task }
        switch taskState {
        case "loading": return "正在读取任务说明…"
        case "missing": return "未记录任务说明"
        case "error": return "任务说明读取失败，请重新刷新"
        default: return "任务说明尚未加载"
        }
    }

    // The native list exposes the latest update time, rather than a completion ID.
    var readToken: String { "subagent:\(updatedAt)" }

    var session: WorkshopSession {
        // Child agents have no user-send timestamp; use native latest activity within each priority group.
        WorkshopSession(id: id, title: name, applicationId: "", cwd: "", preview: task,
            updatedAt: updatedAt, state: state, operationId: nil, completionId: readToken, lastSentAt: updatedAt)
    }

    static func ordered(_ agents: [Self], isUnread: (Self) -> Bool) -> [Self] {
        let byID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return agents.map { WorkshopSessionListItem(session: $0.session, hasDraft: false, isUnread: isUnread($0)) }
            .sorted(by: WorkshopSessionListItem.precedes).compactMap { byID[$0.id] }
    }

    var active: Bool { ["running", "waiting", "starting"].contains(state) }
    var status: String {
        switch state {
        case "running", "starting": "执行中"
        case "waiting": "等待中"
        case "completed": "已完成"
        case "failed": "失败"
        case "interrupted": "已中断"
        default: "空闲"
        }
    }
}
struct WorkshopSubagentList: Decodable {
    let agents: [WorkshopSubagent]
    let nextCursor: String?
}

struct WorkshopSubagentInstruction: Decodable, Identifiable {
    let id: String
    let messageId: String
    let kind: String
    let text: String
    let offset: Int
    let complete: Bool
    let position: Int
}

struct WorkshopSubagentTaskPage: Decodable {
    let state: String
    let entries: [WorkshopSubagentInstruction]
    let nextCursor: String?

    struct Message: Identifiable {
        let id: String
        let kind: String
        let text: String
        let complete: Bool
        let position: Int
    }

    static func messages(_ entries: [WorkshopSubagentInstruction]) -> [Message] {
        let unique = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        return Dictionary(grouping: unique.values, by: \.messageId).compactMap { id, chunks -> Message? in
            let sorted = chunks.sorted { $0.offset < $1.offset }
            guard let first = sorted.first, first.offset == 0 else { return nil }
            var text = "", complete = false
            for chunk in sorted {
                guard chunk.offset == text.utf16.count else { break }
                text += chunk.text
                complete = chunk.complete
            }
            return Message(id: id, kind: first.kind, text: text, complete: complete, position: first.position)
        }.sorted { $0.position < $1.position }
    }
}
