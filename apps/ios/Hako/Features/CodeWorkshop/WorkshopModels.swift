import Foundation

struct WorkshopAgent: Codable, Identifiable {
    let id: String
    let name: String
    let online: Bool
    let protocolVersion: Int
    var supported: Bool { protocolVersion == 1 }
    var supportsArchiving: Bool { protocolVersion == 1 }

}

struct WorkshopApplication: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
}

struct WorkshopSession: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let applicationId: String
    let cwd: String
    let preview: String
    let updatedAt: Int64
    let state: String
    let operationId: String?
    var completionId: String? = nil

    var inProgress: Bool { ["starting", "running", "waiting", "stopping", "finishing", "queued", "steering"].contains(state) }
}

struct WorkshopCatalog: Codable {
    let applications: [WorkshopApplication]
    let sessions: [WorkshopSession]
    let nextCursor: String?

    static func merge(_ page: [WorkshopSession], existing: [WorkshopSession], more: Bool) -> [WorkshopSession] {
        ordered((page + (more ? existing : [])).reduce(into: [WorkshopSession]()) { values, item in
            if !values.contains(where: { $0.id == item.id }) { values.append(item) }
        })
    }

    static func ordered(_ sessions: [WorkshopSession]) -> [WorkshopSession] {
        sessions.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}

struct WorkshopArchiveReply: Decodable {
    let threadId: String
    let archived: Bool
}

struct WorkshopCachedCatalog: Codable {
    let catalog: WorkshopCatalog
    let savedAt: Date
}

struct WorkshopListSnapshot: Codable {
    let agents: [WorkshopAgent]
    let catalogs: [String: WorkshopCachedCatalog]
}

struct WorkshopEntry: Codable, Identifiable, Equatable, Sendable {
    let kind: String
    let id: String
    var text: String
    let role: String
    let state: String
    let truncated: Bool
    var replacesId: String? = nil

    var recordTitle: String {
        switch kind {
        case "commandExecution": "命令执行"
        case "fileChange": "文件改动"
        case "plan": "计划更新"
        default: "工具记录"
        }
    }

    var recordIcon: String {
        switch kind {
        case "commandExecution": "terminal"
        case "fileChange": "doc.text"
        case "plan": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    var recordSummary: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "查看详情"
        if kind == "fileChange" { return first.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? first }
        if kind == "commandExecution", first.hasPrefix("\""), let end = first.dropFirst().firstIndex(of: "\"") {
            let executable = first[first.index(after: first.startIndex)..<end].replacingOccurrences(of: "\\", with: "/")
            return (executable.components(separatedBy: "/").last ?? executable) + first[first.index(after: end)...]
        }
        return first
    }
}

struct WorkshopArtifact: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let threadId: String
}

struct WorkshopHistory: Decodable {
    let threadId: String
    let cwd: String
    let entries: [WorkshopEntry]
    let artifacts: [WorkshopArtifact]
    let nextCursor: String?
    let operationId: String?
    let completionId: String?
}

struct WorkshopReadState: Codable {
    struct Receipt: Codable { let completionId: String; let readAt: Date }
    private(set) var receipts: [String: Receipt] = [:]
    static let unreadLifetime: TimeInterval = 12 * 60 * 60

    func isUnread(_ session: WorkshopSession, agentId: String, now: Date = .now) -> Bool {
        guard session.state == "completed", let completion = session.completionId,
              now.timeIntervalSince1970 - Double(session.updatedAt) <= Self.unreadLifetime else { return false }
        return receipts[agentId + ":" + session.id]?.completionId != completion
    }

    @discardableResult mutating func markRead(threadId: String, completionId: String, agentId: String) -> Bool {
        let key = agentId + ":" + threadId
        guard receipts[key]?.completionId != completionId else { return false }
        receipts[key] = Receipt(completionId: completionId, readAt: .now)
        if receipts.count > 1000 {
            receipts = Dictionary(uniqueKeysWithValues: receipts.sorted { $0.value.readAt > $1.value.readAt }.prefix(1000).map { ($0.key, $0.value) })
        }
        return true
    }
}

struct WorkshopOperation: Codable {
    let id: String
    let applicationId: String
    let threadId: String?
    let turnId: String?
    let state: String
    let message: String?
    let startedAt: Int64
    var active: Bool { ["starting", "running", "waiting", "stopping", "finishing"].contains(state) }
}

struct WorkshopQuestion: Decodable, Identifiable {
    let id: String
    let question: String
    let options: [String]
}

struct WorkshopApproval: Decodable, Identifiable {
    let id: String
    let kind: String
    let detail: String
    let questions: [WorkshopQuestion]
}

struct WorkshopOperationPage: Decodable {
    let operation: WorkshopOperation
    let events: [WorkshopEntry]
    let cursor: Int64
    let hasMore: Bool
    let approvals: [WorkshopApproval]
    let artifacts: [WorkshopArtifact]
    let followups: [WorkshopFollowupState]
}

struct WorkshopFollowupState: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let state: String
    let revision: Int
    let imageIds: [String]
    var editable: Bool { state == "queued" || state == "paused" }
}

struct WorkshopFollowupReply: Decodable {
    let id: String
    let message: String
    let imageIds: [String]
    let state: String
    let revision: Int
    let detail: String?
    var status: WorkshopFollowupState { WorkshopFollowupState(id: id, state: state, revision: revision, imageIds: imageIds) }
    var entry: WorkshopEntry { WorkshopEntry(kind: "followup", id: id,
        text: message + (imageIds.isEmpty ? "" : "\n[图片 × \(imageIds.count)]"), role: "user", state: state, truncated: false) }
}

struct WorkshopQueuedSend: Codable, Identifiable {
    let id: String
    let operationId: String
    let message: String
    let imageIds: [String]
    var parameters: [String: Any] { ["operationId": operationId, "requestId": id, "message": message, "imageIds": imageIds] }
    var entry: WorkshopEntry { WorkshopEntry(kind: "followup", id: id,
        text: message + (imageIds.isEmpty ? "" : "\n[图片 × \(imageIds.count)]"), role: "user", state: "pending", truncated: false) }
}

struct WorkshopArtifactChunk: Decodable {
    let id: String
    let name: String
    let revision: String
    let offset: Int
    let total: Int
    let content: String
    let nextOffset: Int
}

struct WorkshopFailure: Error, Decodable, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct WorkshopReply<Value: Decodable>: Decodable {
    let result: Value?
    let error: WorkshopFailure?
}

struct WorkshopReceipt: Codable, Identifiable {
    let id: String
    let agentId: String
    let applicationId: String
    let originalThreadId: String?
    var threadId: String?
    let title: String
    let message: String
    let createdAt: Date
    var state: String
    var model: String? = nil
    var permission: String? = nil
    var imageIds: [String]? = nil
    var serviceTier: String? = nil

    var parameters: [String: Any] {
        var result: [String: Any] = ["requestId": id, "applicationId": applicationId, "name": title, "message": message]
        result["threadId"] = originalThreadId
        result["model"] = model
        result["permission"] = permission
        result["imageIds"] = imageIds
        result["serviceTier"] = serviceTier
        return result
    }
}

struct WorkshopPreferences: Codable {
    var agentId = ""
    var applicationId = ""
    var order: [String] = []
    var seenSessions: [String] = []
    var receipts: [WorkshopReceipt] = []
    var choices: [String: WorkshopChoice]? = nil
}

// Keep a newly sent conversation visible until the live catalog acknowledges it.
struct WorkshopLocalSessions {
    private var receipts: [String: WorkshopReceipt] = [:]

    mutating func record(_ receipt: WorkshopReceipt, isNew: Bool) {
        guard receipt.originalThreadId == nil else { return }
        if receipt.state == "rejected" { receipts[receipt.id] = nil }
        else if isNew || receipts[receipt.id] != nil { receipts[receipt.id] = receipt }
    }

    mutating func confirm(_ sessions: [WorkshopSession], agentId: String) {
        receipts = receipts.filter { _, receipt in
            receipt.agentId != agentId || !sessions.contains { $0.id == receipt.threadId || $0.operationId == receipt.id }
        }
    }

    mutating func remove(threadId: String, agentId: String) {
        receipts = receipts.filter { $0.value.agentId != agentId || $0.value.threadId != threadId }
    }

    func merging(_ sessions: [WorkshopSession], agentId: String, applications: [WorkshopApplication], archived: Bool) -> [WorkshopSession] {
        guard !archived else { return sessions }
        let local = receipts.values.compactMap { receipt -> WorkshopSession? in
            guard receipt.agentId == agentId,
                  let application = applications.first(where: { $0.id == receipt.applicationId }),
                  !sessions.contains(where: { $0.id == receipt.threadId || $0.operationId == receipt.id }) else { return nil }
            return WorkshopSession(id: receipt.threadId ?? "pending-" + receipt.id, title: receipt.title,
                applicationId: receipt.applicationId, cwd: application.path,
                preview: receipt.threadId == nil ? "发送结果等待确认" : receipt.message,
                updatedAt: Int64(receipt.createdAt.timeIntervalSince1970),
                state: receipt.state == "pending" ? (receipt.threadId == nil ? "unknown" : "starting") : receipt.state,
                operationId: receipt.id)
        }
        return WorkshopCatalog.ordered(sessions + local)
    }
}

struct WorkshopModel: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let isDefault: Bool
    let supportsImages: Bool
    let serviceTiers: [WorkshopSpeed]
}

struct WorkshopSpeed: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    static let standard = WorkshopSpeed(id: "default", name: "Standard", description: "标准速度")
}

struct WorkshopModelList: Decodable { let models: [WorkshopModel] }
struct WorkshopUpload: Decodable { let id: String; let nextOffset: Int; let complete: Bool }
struct WorkshopPhoto: Identifiable { let id: String; let data: Data }

struct WorkshopImageCaption {
    let text: String
    let count: Int

    init(_ message: String) {
        if let range = message.range(of: #"\n+\[图片 × [1-3]\]$"#, options: .regularExpression),
           let number = message[range].first(where: { $0.isNumber })?.wholeNumberValue {
            text = String(message[..<range.lowerBound]); count = number
        } else { text = message; count = 0 }
    }
}

enum WorkshopPermission: String, Codable, CaseIterable, Identifiable {
    case ask, auto, full, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "请求确认"
        case .auto: "自动审批"
        case .full: "完全访问"
        case .custom: "跟随 config.toml"
        }
    }
    var detail: String {
        switch self {
        case .ask: "使用工作区沙箱，额外权限请求由你确认。"
        case .auto: "使用工作区沙箱，由 Codex 自动审查额外权限请求。"
        case .full: "允许访问整台电脑和网络，执行前不再请求确认。"
        case .custom: "使用执行电脑 config.toml 中配置的沙箱和审批规则。"
        }
    }
}

struct WorkshopChoice: Codable, Equatable {
    var model: String? = nil
    var permission: WorkshopPermission = .auto
    var serviceTier: String? = nil
}
