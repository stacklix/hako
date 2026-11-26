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

enum WorkshopCollaborationTab: String, CaseIterable { case sidechats = "侧聊", agents = "子代理" }
