import Foundation

struct WorkshopConversationVisibility {
    private var owners: [UUID: UUID] = [:]
    private var previews: Set<UUID> = []
    var foreground: Set<UUID> {
        previews.isEmpty ? Set(owners.values) : Set(previews.compactMap { owners[$0] })
    }
    func contains(_ conversation: UUID) -> Bool { owners.values.contains(conversation) }
    mutating func enter(_ owner: UUID, conversation: UUID, preview: Bool) {
        owners[owner] = conversation
        if preview { previews.insert(owner) } else { previews.remove(owner) }
    }
    mutating func leave(_ owner: UUID) { owners[owner] = nil; previews.remove(owner) }
}

enum WorkshopConnectionState: Equatable {
    case disconnected, connecting, connected

    var beginningRequest: Self { self == .connected ? .connected : .connecting }
    var accessibilityDescription: String {
        switch self {
        case .disconnected: "电脑未连接"
        case .connecting: "正在连接电脑"
        case .connected: "电脑已连接"
        }
    }

    func afterFailure(_ error: Error) -> Self {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            return self == .connected ? .connected : .disconnected
        }
        if let failure = error as? WorkshopFailure {
            switch failure.code {
            case "computer_offline", "workshop_disconnected", "workshop_timeout", "stream_overflow":
                return .disconnected
            case "workshop_busy", "invalid_request", "unsupported_method":
                return self == .connected ? .connected : .disconnected
            default:
                // An Agent error still proves that the computer replied.
                return .connected
            }
        }
        return .disconnected
    }
}

enum WorkshopSystemPrompt {
    static let maximumLength = 4000
    static let defaultText = """
    你通过 Hako 代码工坊与用户协作，遵循用户指示和当前仓库规范。

    原型交付规则：
    每次新建或修改原型，都必须在本次最终回复中发送一张新的原型卡片。
    每次交付都使用全新、唯一的 HTML 文件名和绝对路径；修改已有原型时也要另存为新文件，不得覆盖或复用此前已交付的原型路径。
    最终回复必须包含本次新文件的原型卡片引用：visualize{"path":"本次新文件的绝对路径","title":"原型标题"}。
    卡片须展示本次修改后的完整原型，不能只说明“已修改”，也不能让用户返回旧卡片查看。
    """

    static func valid(_ text: String) -> Bool {
        text.utf16.count <= maximumLength && !text.contains("\0")
    }
}

enum WorkshopCacheIdentity {
    // Stable across route changes, login restoration and token/session rotation.
    static func account(serverURL: String, username: String) -> String {
        String(data: try! JSONEncoder().encode([serverURL, username]), encoding: .utf8)!
    }
}

struct WorkshopAgent: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let online: Bool
    let protocolVersion: Int
    var supported: Bool { protocolVersion == 1 }
    var supportsArchiving: Bool { protocolVersion == 1 }

}

struct WorkshopApplication: Codable, Identifiable, Equatable, Sendable {
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

struct WorkshopSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let applicationId: String
    let cwd: String
    let preview: String
    let updatedAt: Int64
    let state: String
    let operationId: String?
    var completionId: String? = nil
    var lastSentAt: Int64 = 0

    var inProgress: Bool { ["starting", "running", "waiting", "stopping", "finishing", "queued", "steering"].contains(state) }
}

struct WorkshopCatalog: Codable, Sendable {
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
            if $0.lastSentAt != $1.lastSentAt { return $0.lastSentAt > $1.lastSentAt }
            return $0.id < $1.id
        }
    }

    static func prioritizingDrafts(_ sessions: [WorkshopSession], ids: Set<String>) -> [WorkshopSession] {
        sessions.filter { ids.contains($0.id) } + sessions.filter { !ids.contains($0.id) }
    }
}

// Detail reads fence older catalog responses. A verified terminal state also
// survives later stale polls until the catalog proves a newer operation/activity.
struct WorkshopSessionUpdates {
    private struct Update { let revision: Int; let session: WorkshopSession }
    private var updates: [String: Update] = [:]
    private(set) var revision = 0

    mutating func record(_ session: WorkshopSession, agentId: String) {
        revision += 1
        updates[agentId + ":" + session.id] = Update(revision: revision, session: session)
    }

    mutating func remove(threadId: String, agentId: String) {
        updates[agentId + ":" + threadId] = nil
    }

    func merging(_ sessions: [WorkshopSession], agentId: String, since checkpoint: Int) -> [WorkshopSession] {
        sessions.map { session in
            guard let update = updates[agentId + ":" + session.id],
                  update.session.operationId == session.operationId,
                  session.updatedAt <= update.session.updatedAt,
                  session.completionId == nil || session.completionId == update.session.completionId else { return session }
            let known = update.session
            let staleRunning = session.inProgress && ["completed", "failed", "interrupted", "cancelled"].contains(known.state)
            guard update.revision > checkpoint || staleRunning else { return session }
            return WorkshopSession(id: session.id, title: session.title, applicationId: session.applicationId,
                cwd: session.cwd, preview: session.preview, updatedAt: session.updatedAt,
                state: known.state, operationId: known.operationId, completionId: known.completionId, lastSentAt: session.lastSentAt)
        }
    }
}

struct WorkshopArchiveReply: Decodable {
    let threadId: String
    let archived: Bool
}

struct WorkshopCachedCatalog: Codable, Sendable {
    let catalog: WorkshopCatalog
    let savedAt: Date
}

struct WorkshopListSnapshot: Codable, Sendable {
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

struct WorkshopQuestionReply: Equatable, Sendable {
    let question: String
    let answer: String
}

struct WorkshopAsyncQuestion: Codable, Equatable, Sendable {
    let title: String
    let options: [String]
    private static let replyPrefix = "针对提问的回答：\n"

    static func replyMessage(_ questions: [Self], answers: [Int: String]) -> String? {
        guard !questions.isEmpty, questions.indices.allSatisfy({ !(answers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let message = replyPrefix + questions.enumerated().map { index, question in
            question.title + "\n" + answers[index]!.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
        return message.utf16.count <= 4000 ? message : nil
    }

    static func replySections(in message: String, questions: [Self]) -> [WorkshopQuestionReply]? {
        guard !questions.isEmpty, message.hasPrefix(replyPrefix) else { return nil }
        var remaining = String(message.dropFirst(replyPrefix.count))
        var result: [WorkshopQuestionReply] = []
        for (index, question) in questions.enumerated() {
            let heading = question.title + "\n"
            guard !question.title.isEmpty, remaining.hasPrefix(heading) else { return nil }
            remaining.removeFirst(heading.count)
            let answer: String
            if index + 1 < questions.count {
                let separator = "\n\n" + questions[index + 1].title + "\n"
                guard let boundary = remaining.range(of: separator),
                      remaining.range(of: separator, range: boundary.upperBound..<remaining.endIndex) == nil else { return nil }
                answer = String(remaining[..<boundary.lowerBound])
                remaining = String(remaining[boundary.lowerBound...].dropFirst(2))
            } else { answer = remaining }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            result.append(WorkshopQuestionReply(question: question.title, answer: answer))
        }
        return result
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
    var model: String? = nil
    var reasoningEffort: String? = nil
    var generation: WorkshopGenerationSettings { .init(model: model, reasoningEffort: reasoningEffort) }
}

struct WorkshopGenerationSettings: Equatable {
    let model: String?
    let reasoningEffort: String?
    init(model: String? = nil, reasoningEffort: String? = nil) {
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }
        self.reasoningEffort = reasoningEffort.flatMap { $0.isEmpty ? nil : $0 }
    }
    static func displayed(history: Self, operation: WorkshopOperation?) -> Self {
        if let operation, operation.active { return operation.generation }
        return history
    }
    var effortLabel: String {
        reasoningEffort.map { WorkshopReasoningEffort(id: $0, description: "").title } ?? "推理强度待确认"
    }
}

struct WorkshopReadState: Codable, Sendable {
    struct Receipt: Codable, Sendable { let completionId: String; let readAt: Date }
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

struct WorkshopOperation: Codable, Equatable {
    let id: String
    let applicationId: String
    let threadId: String?
    let turnId: String?
    let state: String
    let message: String?
    let startedAt: Int64
    var finishedAt: Int64? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil
    var generation: WorkshopGenerationSettings { .init(model: model, reasoningEffort: reasoningEffort) }
    var active: Bool { ["starting", "running", "waiting", "stopping", "finishing"].contains(state) }

    func elapsedText(at now: Date) -> String? {
        guard startedAt > 0 else { return nil }
        let end: TimeInterval
        if active { end = now.timeIntervalSince1970 }
        else if ["completed", "failed", "interrupted", "cancelled"].contains(state), let finishedAt, finishedAt > 0 {
            // Operation starts use Unix seconds; durable terminal records use milliseconds.
            end = Double(finishedAt) / 1000
        } else { return nil }
        let elapsed = max(0, end - Double(startedAt))
        guard elapsed.isFinite, elapsed < Double(Int.max) else { return nil }
        let seconds = Int(elapsed)
        if seconds >= 3600 { return "\(seconds / 3600) 小时 \(seconds / 60 % 60) 分 \(seconds % 60) 秒" }
        if seconds >= 60 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds) 秒"
    }

    var statusLabel: String {
        switch state {
        case "starting": "正在连接 Codex…"
        case "running": "任务在电脑上执行中"
        case "waiting": "等待你确认"
        case "stopping": "正在停止任务"
        case "finishing": "正在保存结果并释放会话"
        case "completed": "本轮已完成"
        case "interrupted", "cancelled": "任务已停止"
        case "failed": "本轮未完成"
        default: "请核对本轮执行结果"
        }
    }

    var statusIcon: String {
        switch state {
        case "completed": "checkmark.circle"
        case "failed": "exclamationmark.circle"
        case "interrupted", "cancelled": "stop.circle"
        default: active ? "circle.dotted" : "questionmark.circle"
        }
    }
}

struct WorkshopQuestion: Decodable, Identifiable, Equatable {
    let id: String
    let question: String
    let options: [String]
}

struct WorkshopApproval: Decodable, Identifiable, Equatable {
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

struct WorkshopQueuedSend: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let operationId: String
    let message: String
    let imageIds: [String]
    var questionId: String? = nil
    var reasoningEffort: String? = nil
    var parameters: [String: Any] {
        var result: [String: Any] = ["operationId": operationId, "requestId": id, "message": message, "imageIds": imageIds]
        result["questionId"] = questionId
        result["reasoningEffort"] = reasoningEffort
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

struct WorkshopReceipt: Codable, Identifiable, Equatable, Sendable {
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
    var systemPrompt: String? = nil
    var reasoningEffort: String? = nil

    var parameters: [String: Any] {
        var result: [String: Any] = ["requestId": id, "applicationId": applicationId, "name": title, "message": message]
        result["threadId"] = originalThreadId
        result["model"] = model
        result["permission"] = permission
        result["imageIds"] = imageIds
        result["serviceTier"] = serviceTier
        result["reasoningEffort"] = reasoningEffort
        result["questionId"] = questionId
        if originalThreadId == nil { result["systemPrompt"] = systemPrompt }
        return result
    }

    var fitsRequestBudget: Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["method": "turn.start", "params": parameters]) else { return false }
        return data.count <= 16 * 1024
    }
}

struct WorkshopPreferences: Codable, Sendable {
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
    struct Verification: Equatable {
        let operationId: String
        let agentId: String
        let revision: Int
    }
    private struct Activity {
        var receipt: WorkshopReceipt
        let date: Date
        let preview: String
        let queued: Bool
        let queuedMessageId: String?
        let revision: Int
    }
    private var receipts: [String: Activity] = [:]
    private var revision = 0

    mutating func record(_ receipt: WorkshopReceipt, isNew: Bool, queued: Bool = false, queuedMessageId: String? = nil) {
        if receipt.state == "rejected" { receipts[receipt.id] = nil }
        else if isNew || receipts[receipt.id] != nil {
            if isNew, let threadId = receipt.threadId {
                receipts = receipts.filter { $0.key == receipt.id || $0.value.receipt.agentId != receipt.agentId || $0.value.receipt.threadId != threadId }
            }
            let previous = receipts[receipt.id]
            let keepActivity = previous.map { $0.date > receipt.createdAt } == true
            revision += 1
            receipts[receipt.id] = Activity(receipt: receipt,
                date: keepActivity ? previous!.date : receipt.createdAt,
                preview: keepActivity ? previous!.preview : receipt.message,
                queued: queued || (!isNew && previous?.queued == true),
                queuedMessageId: queuedMessageId ?? (!isNew ? previous?.queuedMessageId : nil), revision: revision)
        }
    }

    func verifications(for sessions: [WorkshopSession], agentId: String) -> [Verification] {
        receipts.values.filter { activity in
            activity.receipt.agentId == agentId && sessions.contains { session in
                !session.inProgress && (session.id == activity.receipt.threadId || session.operationId == activity.receipt.id)
            }
        }.sorted { $0.receipt.id < $1.receipt.id }.map {
            Verification(operationId: $0.receipt.id, agentId: agentId, revision: $0.revision)
        }
    }

    @discardableResult mutating func verify(_ ticket: Verification, operation: WorkshopOperation,
        followups: [WorkshopFollowupState], pendingMessages: [String] = []) -> Bool {
        guard let activity = receipts[ticket.operationId], activity.revision == ticket.revision,
              activity.receipt.agentId == ticket.agentId, operation.id == ticket.operationId,
              operation.applicationId == activity.receipt.applicationId,
              activity.receipt.threadId == nil || operation.threadId == activity.receipt.threadId,
              ["completed", "failed", "interrupted", "cancelled"].contains(operation.state) else { return false }
        // A parent's completion cannot acknowledge a follow-up that the computer
        // has not seen yet. Match each outstanding message by its own identity.
        if activity.queued && activity.queuedMessageId == nil { return false }
        let required = pendingMessages + [activity.queuedMessageId].compactMap { $0 }
        guard required.allSatisfy({ id in followups.contains { $0.id == id &&
            ["completed", "sent", "steered", "failed", "interrupted", "cancelled", "paused"].contains($0.state) } }) else { return false }
        receipts[ticket.operationId] = nil
        return true
    }

    // A missing task is not proof of completion. Only retire its activity when
    // a later send in our own receipt order is confirmed by the current catalog.
    @discardableResult mutating func verifyMissing(_ ticket: Verification, sessions: [WorkshopSession],
        history: [WorkshopReceipt], pendingMessages: [String] = []) -> Bool {
        guard let activity = receipts[ticket.operationId], activity.revision == ticket.revision,
              activity.receipt.agentId == ticket.agentId, !activity.queued, pendingMessages.isEmpty,
              let threadId = activity.receipt.threadId,
              let index = history.firstIndex(where: { $0.id == ticket.operationId && $0.agentId == ticket.agentId }),
              let current = sessions.first(where: { $0.id == threadId && $0.applicationId == activity.receipt.applicationId }),
              ["completed", "failed", "interrupted", "cancelled"].contains(current.state),
              let currentId = current.operationId, currentId != ticket.operationId,
              history.dropFirst(index + 1).contains(where: {
                  $0.id == currentId && $0.agentId == ticket.agentId && $0.threadId == threadId &&
                  $0.applicationId == current.applicationId && $0.state == current.state
              }) else { return false }
        receipts[ticket.operationId] = nil
        return true
    }

    mutating func confirm(_ sessions: [WorkshopSession], agentId: String) {
        receipts = receipts.filter { _, activity in
            activity.receipt.agentId != agentId || !sessions.contains { acknowledges($0, activity: activity) }
        }
    }

    mutating func remove(threadId: String, agentId: String) {
        receipts = receipts.filter { $0.value.receipt.agentId != agentId || $0.value.receipt.threadId != threadId }
    }

    mutating func settle(threadId: String, operationId: String?, agentId: String) {
        receipts = receipts.filter { _, value in
            value.receipt.agentId != agentId || value.receipt.threadId != threadId || value.receipt.id != operationId
        }
    }

    private func acknowledges(_ session: WorkshopSession, activity: Activity) -> Bool {
        guard session.operationId == activity.receipt.id else { return false }
        // An operation ID identifies the original send across both clocks.
        // A queued follow-up shares its parent's ID, so it still needs evidence
        // of newer activity before that parent's completion can acknowledge it.
        if !activity.queued && ["completed", "failed", "interrupted", "cancelled"].contains(session.state) { return true }
        return session.updatedAt >= Int64(activity.date.timeIntervalSince1970)
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
                preview: receipt.threadId == nil ? "发送结果等待确认" :
                    (!activity.queued && remote?.operationId == receipt.id ? remote!.preview : activity.preview),
                updatedAt: max(Int64(activity.date.timeIntervalSince1970), remote?.updatedAt ?? 0),
                state: receipt.state == "pending" ? (receipt.threadId == nil ? "unknown" : "starting") : receipt.state,
                operationId: receipt.id, lastSentAt: max(Int64(activity.date.timeIntervalSince1970), remote?.lastSentAt ?? 0))
            if let index { result[index] = local } else { result.append(local) }
            localDates[local.id] = activity.date
        }
        return result.sorted {
            if $0.lastSentAt != $1.lastSentAt { return $0.lastSentAt > $1.lastSentAt }
            let left = localDates[$0.id] ?? Date(timeIntervalSince1970: Double($0.lastSentAt))
            let right = localDates[$1.id] ?? Date(timeIntervalSince1970: Double($1.lastSentAt))
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
    let reasoningEfforts: [WorkshopReasoningEffort]
    let defaultReasoningEffort: String
}

struct WorkshopReasoningEffort: Decodable, Identifiable {
    let id: String
    let description: String
    var title: String {
        switch id {
        case "none": "无"
        case "minimal": "最低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "超高"
        case "max": "最高"
        case "ultra": "极高"
        default: id
        }
    }

    var detail: String {
        switch id {
        case "none": "不使用额外推理。"
        case "minimal": "使用最低推理强度，优先快速响应。"
        case "low": "使用较低推理强度，适合简单任务。"
        case "medium": "兼顾推理深度与响应速度。"
        case "high": "投入更多推理，适合复杂任务。"
        case "xhigh": "使用超高推理强度，可能需要更长时间。"
        case "max": "使用最高推理强度，可能需要更长时间。"
        case "ultra": "使用极高推理强度，可能需要更长时间。"
        default: description
        }
    }
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

enum WorkshopPermission: String, Codable, CaseIterable, Identifiable, Sendable {
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

struct WorkshopChoice: Codable, Equatable, Sendable {
    var model: String? = nil
    var permission: WorkshopPermission = .auto
    var serviceTier: String? = nil
    var reasoningEffort: String? = nil
}
