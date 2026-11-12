import Foundation

enum WorkshopCacheIdentity {
    // Stable across route changes, login restoration and token/session rotation.
    static func account(serverURL: String, username: String) -> String {
        String(data: try! JSONEncoder().encode([serverURL, username]), encoding: .utf8)!
    }
}

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

    static func containing(_ cwd: String, in applications: [Self]) -> Self? {
        func normalized(_ path: String) -> String {
            var value = path.replacingOccurrences(of: "\\", with: "/").lowercased()
            while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
            return value
        }
        let directory = normalized(cwd)
        return applications.filter {
            let root = normalized($0.path)
            return !root.isEmpty && (directory == root || directory.hasPrefix(root == "/" ? root : root + "/"))
        }.max { normalized($0.path).count < normalized($1.path).count }
    }
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
    var questions: [WorkshopAsyncQuestion]? = nil
    var questionId: String? = nil

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

struct WorkshopAsyncQuestion: Codable, Equatable, Sendable {
    let title: String
    let options: [String]

    static func replyMessage(_ questions: [Self], answers: [Int: String]) -> String? {
        guard !questions.isEmpty, questions.indices.allSatisfy({ !(answers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let message = "针对提问的回答：\n" + questions.enumerated().map { index, question in
            question.title + "\n" + answers[index]!.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
        return message.utf16.count <= 4000 ? message : nil
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

    static func merging(_ updates: [Self], into current: [Self]) -> [Self] {
        var result = current
        for update in updates {
            guard let index = result.firstIndex(where: { $0.id == update.id }) else {
                result.append(update)
                continue
            }
            let previous = result[index]
            guard update.revision >= previous.revision else { continue }
            if update.revision == previous.revision {
                // Steer acknowledgement changes state within one revision.
                // Older pages or RPC replies can arrive after that acknowledgement.
                if previous.state == "steered", update.state != "steered" { continue }
                if ["starting", "running", "waiting", "finishing", "sent", "completed"].contains(previous.state),
                   ["pending", "queued", "paused", "steering"].contains(update.state) { continue }
            }
            result[index] = update
        }
        return result
    }
}

struct WorkshopFollowupReply: Decodable {
    let id: String
    let message: String
    let imageIds: [String]
    let state: String
    let revision: Int
    let detail: String?
    var questionId: String? = nil
    var status: WorkshopFollowupState { WorkshopFollowupState(id: id, state: state, revision: revision, imageIds: imageIds) }
    var entry: WorkshopEntry { WorkshopEntry(kind: "followup", id: id,
        text: message + (imageIds.isEmpty ? "" : "\n[图片 × \(imageIds.count)]"), role: "user", state: state, truncated: false, questionId: questionId) }
}

struct WorkshopQueuedSend: Codable, Identifiable {
    let id: String
    let operationId: String
    let message: String
    let imageIds: [String]
    var questionId: String? = nil
    var parameters: [String: Any] {
        var result: [String: Any] = ["operationId": operationId, "requestId": id, "message": message, "imageIds": imageIds]
        result["questionId"] = questionId
        return result
    }
    var entry: WorkshopEntry { WorkshopEntry(kind: "followup", id: id,
        text: message + (imageIds.isEmpty ? "" : "\n[图片 × \(imageIds.count)]"), role: "user", state: "pending", truncated: false, questionId: questionId) }
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
    var questionId: String? = nil

    var parameters: [String: Any] {
        var result: [String: Any] = ["requestId": id, "applicationId": applicationId, "name": title, "message": message]
        result["threadId"] = originalThreadId
        result["model"] = model
        result["permission"] = permission
        result["imageIds"] = imageIds
        result["serviceTier"] = serviceTier
        result["questionId"] = questionId
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

// Reflect sends immediately, until the catalog acknowledges their operation
// and activity time. An older catalog response must not undo the local state.
struct WorkshopLocalSessions {
    private struct Activity {
        var receipt: WorkshopReceipt
        let date: Date
        let preview: String
    }
    private var receipts: [String: Activity] = [:]

    mutating func record(_ receipt: WorkshopReceipt, isNew: Bool) {
        if receipt.state == "rejected" { receipts[receipt.id] = nil }
        else if isNew || receipts[receipt.id] != nil {
            if isNew, let threadId = receipt.threadId {
                receipts = receipts.filter { $0.key == receipt.id || $0.value.receipt.agentId != receipt.agentId || $0.value.receipt.threadId != threadId }
            }
            let previous = receipts[receipt.id]
            let keepActivity = previous.map { $0.date > receipt.createdAt } == true
            receipts[receipt.id] = Activity(receipt: receipt,
                date: keepActivity ? previous!.date : receipt.createdAt,
                preview: keepActivity ? previous!.preview : receipt.message)
        }
    }

    mutating func confirm(_ sessions: [WorkshopSession], agentId: String) {
        receipts = receipts.filter { _, activity in
            activity.receipt.agentId != agentId || !sessions.contains { acknowledges($0, activity: activity) }
        }
    }

    mutating func remove(threadId: String, agentId: String) {
        receipts = receipts.filter { $0.value.receipt.agentId != agentId || $0.value.receipt.threadId != threadId }
    }

    private func acknowledges(_ session: WorkshopSession, activity: Activity) -> Bool {
        session.operationId == activity.receipt.id && session.updatedAt >= Int64(activity.date.timeIntervalSince1970)
            && (activity.receipt.state == "pending" || !session.inProgress)
    }

    mutating func reject(operationId: String, agentId: String) {
        if receipts[operationId]?.receipt.agentId == agentId { receipts[operationId] = nil }
    }

    func merging(_ sessions: [WorkshopSession], agentId: String, applications: [WorkshopApplication], archived: Bool) -> [WorkshopSession] {
        guard !archived else { return sessions }
        var result = sessions
        var localDates: [String: Date] = [:]
        for activity in receipts.values {
            let receipt = activity.receipt
            guard receipt.agentId == agentId,
                  let application = applications.first(where: { $0.id == receipt.applicationId }) else { continue }
            let index = result.firstIndex { $0.id == receipt.threadId || $0.operationId == receipt.id }
            let remote = index.map { result[$0] }
            if let remote, acknowledges(remote, activity: activity) { continue }
            let local = WorkshopSession(id: receipt.threadId ?? remote?.id ?? "pending-" + receipt.id, title: remote?.title ?? receipt.title,
                applicationId: receipt.applicationId, cwd: application.path,
                preview: receipt.threadId == nil ? "发送结果等待确认" : activity.preview,
                updatedAt: max(Int64(activity.date.timeIntervalSince1970), remote?.updatedAt ?? 0),
                state: receipt.state == "pending" ? (receipt.threadId == nil ? "unknown" : "starting") : receipt.state,
                operationId: receipt.id)
            if let index { result[index] = local } else { result.append(local) }
            localDates[local.id] = activity.date
        }
        return result.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            let left = localDates[$0.id] ?? Date(timeIntervalSince1970: Double($0.updatedAt))
            let right = localDates[$1.id] ?? Date(timeIntervalSince1970: Double($1.updatedAt))
            return left != right ? left > right : $0.id < $1.id
        }
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
