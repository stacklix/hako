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
