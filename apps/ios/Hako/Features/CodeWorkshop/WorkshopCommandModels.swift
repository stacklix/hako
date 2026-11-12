import Foundation

struct WorkshopSavedCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var command = ""
    var note = ""
    var timeoutSeconds = 3600
    var allowBackgroundProcesses = false

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf8.count <= 8000
            && (1...86400).contains(timeoutSeconds)
    }
}

struct WorkshopCommandTask: Codable, Identifiable {
    let id: String
    let applicationId: String
    let name: String
    let command: String
    let directory: String
    let state: String
    let startedAt: Int64
    let finishedAt: Int64?
    let exitCode: Int?
    let error: String?
    let canStop: Bool
    let allowBackgroundProcesses: Bool
    var active: Bool { ["starting", "running", "stopping"].contains(state) }
    var status: String { Self.status(state) }
    static func status(_ state: String) -> String {
        switch state {
        case "starting": "正在启动"
        case "running": "执行中"
        case "stopping": "正在停止"
        case "succeeded": "已完成"
        case "cancelled": "已取消"
        case "timed_out": "已超时"
        case "interrupted": "已中断"
        default: "失败"
        }
    }
}

struct WorkshopCommandSummary: Decodable, Identifiable {
    let id: String
    let applicationId: String
    let name: String
    let state: String
    let startedAt: Int64
    var status: String { WorkshopCommandTask.status(state) }
}
