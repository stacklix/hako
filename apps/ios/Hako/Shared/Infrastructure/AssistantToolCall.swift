import Foundation

enum AssistantToolState: String, Codable, Sendable {
    case running, succeeded, needsClarification, failed, cancelled, interrupted
    var title: String {
        switch self {
        case .running: "执行中"
        case .succeeded: "已完成"
        case .needsClarification: "参数待完善"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .interrupted: "已中断"
        }
    }
}

struct AssistantToolField: Codable, Equatable, Sendable {
    let label: String
    let value: String
}

/// Features supply business labels and result interpretation; the record owns its lifecycle.
protocol AssistantToolPresentation: Sendable {
    static func title(_ name: String) -> String
    static func icon(_ name: String) -> String
    static func summary(_ record: AssistantToolCall<Self>) -> String
    static func outputs(_ record: AssistantToolCall<Self>) -> [AssistantToolField]
    static func resultState(_ payload: [String: Any]) -> AssistantToolState
    static func clarificationTitle(_ payload: [String: Any]) -> String
    static func resolves(_ earlier: AssistantToolCall<Self>, with later: AssistantToolCall<Self>) -> Bool
}

extension AssistantToolPresentation {
    static func resultState(_ payload: [String: Any]) -> AssistantToolState {
        if payload["error"] != nil { return .failed }
        return payload["status"] as? String == "needs_clarification" ? .needsClarification : .succeeded
    }
    static func clarificationTitle(_ payload: [String: Any]) -> String { "参数待完善" }
    static func resolves(_ earlier: AssistantToolCall<Self>, with later: AssistantToolCall<Self>) -> Bool { false }
}

struct AssistantToolCall<Presentation: AssistantToolPresentation>: Codable, Identifiable, Equatable, Sendable {
    typealias State = AssistantToolState
    typealias Field = AssistantToolField

    // Keep the on-disk fields independent of the presentation policy.
    let id: UUID
    let callID: String
    let name: String
    let arguments: String
    let inputs: [Field]
    let startedAt: Date
    private(set) var state: State = .running
    private(set) var finishedAt: Date?
    private(set) var elapsed: TimeInterval?
    private(set) var result: String?

    init(call: LanguageModelCall, inputs: [Field], at date: Date = .now) {
        id = UUID(); callID = call.id; name = call.name
        arguments = call.rawArguments ?? call.arguments.flatMap(AssistantToolJSON.encode) ?? "模型未提供可解析的参数。"
        self.inputs = inputs; startedAt = date
    }
    var payload: [String: Any] { result.flatMap { AssistantToolJSON.decode($0) as? [String: Any] } ?? [:] }
    var title: String { Presentation.title(name) }
    var icon: String { Presentation.icon(name) }
    var summary: String { Presentation.summary(self) }
    var statusTitle: String { state == .needsClarification ? Presentation.clarificationTitle(payload) : state.title }
    var durationText: String {
        guard let elapsed else { return state == .running ? "" : "耗时未记录" }
        if elapsed < 0.1 { return "<0.1 秒" }
        if elapsed < 60 { return String(format: "%.1f 秒", elapsed) }
        return "\(Int(elapsed) / 60) 分 \(Int(elapsed) % 60) 秒"
    }
    var outputs: [Field] {
        if let error = payload["error"] as? String { return [.init(label: "错误原因", value: error)] }
        if state == .running { return [.init(label: "当前进度", value: "等待工具返回结果。")] }
        if state == .cancelled { return [.init(label: "执行结果", value: "调用已取消，没有取得完整返回结果。")] }
        if state == .interrupted { return [.init(label: "执行结果", value: "上次会话未保存到这次调用的结果，无法确认是否完成。")] }
        return Presentation.outputs(self)
    }
    mutating func finish(result: String, at date: Date = .now, elapsed: TimeInterval) {
        guard state == .running else { return }
        self.result = result; finishedAt = date; self.elapsed = max(0, elapsed)
        state = Presentation.resultState(payload)
    }
    mutating func cancel(at date: Date = .now, elapsed: TimeInterval) {
        guard state == .running else { return }
        state = .cancelled; finishedAt = date; self.elapsed = max(0, elapsed)
    }
    func restored() -> Self {
        var record = self
        if record.state == .running { record.state = .interrupted }
        return record
    }
    static func pretty(_ text: String) -> String { AssistantToolJSON.pretty(text) }

    @MainActor
    static func perform(_ initial: Self, update: (Self) -> Void,
                        transformResult: (String) throws -> String = { $0 },
                        errorResult: (Error) throws -> String = { AssistantToolJSON.encode(["error": $0.localizedDescription])! },
                        operation: () async throws -> String) async throws -> String {
        var record = initial
        let started = ProcessInfo.processInfo.systemUptime
        update(record)
        do {
            try Task.checkCancellation()
            let result = try transformResult(try await operation())
            record.finish(result: result, elapsed: ProcessInfo.processInfo.systemUptime - started)
            update(record)
            return result
        } catch {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if error is CancellationError || Task.isCancelled {
                record.cancel(elapsed: elapsed); update(record); throw CancellationError()
            }
            let result = try transformResult(errorResult(error))
            record.finish(result: result, elapsed: elapsed); update(record)
            return result
        }
    }
}

enum AssistantToolJSON {
    static func contains(_ supplied: [String: Any], in completed: [String: Any]) -> Bool {
        supplied.allSatisfy { key, value in
            if value is NSNull || (value as? String)?.isEmpty == true { return true }
            if let fields = value as? [String: Any] {
                return contains(fields, in: completed[key] as? [String: Any] ?? [:])
            }
            guard let other = completed[key] else { return false }
            return encode(value) == encode(other)
        }
    }
    static func decode(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
    static func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func pretty(_ text: String) -> String {
        guard let value = decode(text), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

enum AssistantToolFollowUp {
    struct Entry {
        let id: UUID
        var isUser = false
    }

    // Keep the original results. Resolve only matched operations within one user turn.
    static func resolved<Presentation>(timeline: [Entry], records: [UUID: AssistantToolCall<Presentation>]) -> [UUID: UUID] {
        var pending: [AssistantToolCall<Presentation>] = []
        var result: [UUID: UUID] = [:]
        for entry in timeline {
            if entry.isUser { pending.removeAll() }
            guard let record = records[entry.id] else { continue }
            if record.state == .needsClarification { pending.append(record) }
            if record.state == .succeeded {
                pending.removeAll { earlier in
                    guard Presentation.resolves(earlier, with: record) else { return false }
                    result[earlier.id] = record.id
                    return true
                }
            }
        }
        return result
    }
}
