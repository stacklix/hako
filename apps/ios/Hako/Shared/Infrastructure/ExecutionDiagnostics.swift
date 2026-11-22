import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct HakoExecutionEvent: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case started = "开始", succeeded = "完成", failed = "失败", cancelled = "已取消", info = "信息" }
    var id = UUID()
    var time = Date.now
    let stage: String
    let state: State
    let detail: String
}

final class HakoExecutionCancellation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var value: String?
    private var executionRunID: UUID?
    private var executionStep: String?
    private var executionAttemptID: UUID?

    func bind(to runID: UUID) {
        lock.lock(); defer { lock.unlock() }
        executionRunID = runID
    }

    var runID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return executionRunID
    }

    func bind(step: String, attemptID: UUID) {
        lock.lock(); defer { lock.unlock() }
        executionStep = step
        executionAttemptID = attemptID
    }

    var attempt: (step: String, id: UUID)? {
        lock.lock(); defer { lock.unlock() }
        guard let executionStep, let executionAttemptID else { return nil }
        return (executionStep, executionAttemptID)
    }

    func record(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        value = reason
    }

    var reason: String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

struct HakoExecutionLogRow: Identifiable {
    let id: UUID
    let stage: String
    var state: HakoExecutionEvent.State
    let startedAt: Date?
    var finishedAt: Date?
    var detail: String

    var isDiagnostic: Bool {
        ["开始执行子任务", "执行子任务", "重试子任务", "子任务结束", "子任务跳过",
         "执行环境", "取消时执行环境", "失败时执行环境", "快捷指令取消原因",
         "读取设备身份记录", "读取 Secure Enclave 公钥", "保存服务端登录会话",
         "恢复服务端登录会话", "读取服务端登录会话", "刷新服务端登录会话",
         "生成设备请求签名（Secure Enclave）", "服务端响应"].contains(stage)
        || stage.hasPrefix("发送请求 ")
    }

    func elapsed(at now: Date) -> String {
        guard let startedAt else { return "—" }
        let milliseconds = max(0, Int(((finishedAt ?? now).timeIntervalSince(startedAt) * 1_000).rounded()))
        return milliseconds < 1_000 ? "\(milliseconds) 毫秒" : String(format: "%.2f 秒", Double(milliseconds) / 1_000)
    }

    static func merging(_ events: [HakoExecutionEvent]) -> [Self] {
        var rows: [Self] = []
        var positions: [UUID: Int] = [:]
        // Older versions assigned separate IDs to a stage's start and finish.
        // Reserve shared IDs first, so name matching cannot steal a correlated event.
        let counts = Dictionary(grouping: events, by: \.id).mapValues(\.count)
        var legacyStarts: [String: [Int]] = [:]
        for event in events {
            if (event.state == .started && ["开始执行子任务", "执行子任务", "重试子任务"].contains(event.stage))
                || ["子任务结束", "子任务跳过"].contains(event.stage) {
                // A retry must never finish a stage left open by an earlier attempt.
                legacyStarts.removeAll()
            }
            var matchedIndex: Int?
            if let index = positions[event.id], rows[index].state == .started, event.state != .started {
                matchedIndex = index
            } else if counts[event.id] == 1, [.succeeded, .failed, .cancelled].contains(event.state),
                      let candidates = legacyStarts[event.stage], candidates.count == 1,
                      let index = candidates.first, let start = rows[index].startedAt, event.time >= start {
                matchedIndex = index
            }
            if let index = matchedIndex {
                rows[index].state = event.state
                rows[index].finishedAt = event.time
                // Timing is already presented in the row's metadata.
                rows[index].detail = event.detail.replacingOccurrences(
                    of: #"\A耗时：\s*\d+ 毫秒(?:\r?\n|$)"#, with: "", options: .regularExpression)
                legacyStarts[event.stage]?.removeAll { $0 == index }
            } else {
                positions[event.id] = rows.count
                if event.state == .started, counts[event.id] == 1 {
                    legacyStarts[event.stage, default: []].append(rows.count)
                }
                rows.append(Self(id: event.id, stage: event.stage, state: event.state,
                                 startedAt: event.state == .started || event.state == .info ? event.time : nil,
                                 finishedAt: event.state == .started ? nil : event.time, detail: event.detail))
            }
        }
        return rows
    }
}

// The caller owns the sink. Child services can report progress without depending on
// shortcut history, and unrelated tasks do not share a global active-run identifier.
enum HakoExecutionDiagnostics {
    typealias Sink = @MainActor @Sendable (HakoExecutionEvent) -> Void
    static let context = TaskLocal<Sink?>(wrappedValue: nil)
    static let cancellation = TaskLocal<HakoExecutionCancellation?>(wrappedValue: nil)
    static var sink: Sink? { context.get() }

    @MainActor static func record(_ stage: String, state: HakoExecutionEvent.State = .info, detail: String = "") {
        sink?(HakoExecutionEvent(stage: stage, state: state, detail: detail))
    }

    @MainActor static func environment(_ stage: String = "执行环境") {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        var detail = "应用版本：\(version)（\(build)）"
        #if canImport(UIKit)
        let app = UIApplication.shared
        let state: String
        switch app.applicationState {
        case .active: state = "前台"
        case .inactive: state = "非活跃"
        case .background: state = "后台"
        @unknown default: state = "未知"
        }
        detail += "\n应用状态：\(state)；受保护数据：\(app.isProtectedDataAvailable ? "可访问" : "不可访问")"
        let remaining = app.backgroundTimeRemaining
        detail += remaining.isFinite && remaining < 86_400 ? "\n后台剩余时间：\(max(0, Int(remaining))) 秒" : "\n后台剩余时间：当前未受限"
        #endif
        if let reason = cancellation.get()?.reason { detail += "\n取消原因：\(reason)" }
        record(stage, detail: detail)
    }

    static func failure(_ error: Error) -> String {
        let value = error as NSError
        let symbol = value.domain == NSOSStatusErrorDomain && value.code == -25308 ? "（errSecInteractionNotAllowed）" : ""
        var detail = "错误域：\(value.domain)；错误码：\(value.code)\(symbol)\n\(error.localizedDescription)"
        if error is CancellationError || Task.isCancelled {
            detail += "\n取消原因：" + (cancellation.get()?.reason ?? "任务收到取消信号，系统未提供具体原因。")
        } else if (error as? URLError)?.code == .cancelled {
            detail += "\n网络传输被取消，当前任务未收到取消信号。"
        }
        return HakoLog.sanitize(detail)
    }

    @MainActor static func measure<T>(_ stage: String, success: (T) -> String = { _ in "执行成功。" }, operation: () throws -> T) rethrows -> T {
        guard sink != nil else { return try operation() }
        let event = HakoExecutionEvent(stage: stage, state: .started, detail: "")
        sink?(event)
        do {
            let result = try operation()
            sink?(HakoExecutionEvent(id: event.id, stage: stage, state: .succeeded, detail: HakoLog.sanitize(success(result))))
            return result
        } catch {
            sink?(HakoExecutionEvent(id: event.id, stage: stage, state: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                                     detail: failure(error)))
            throw error
        }
    }

    @MainActor static func measure<T>(_ stage: String, success: (T) -> String = { _ in "执行成功。" }, operation: () async throws -> T) async rethrows -> T {
        guard sink != nil else { return try await operation() }
        let event = HakoExecutionEvent(stage: stage, state: .started, detail: "")
        sink?(event)
        do {
            let result = try await operation()
            sink?(HakoExecutionEvent(id: event.id, stage: stage, state: .succeeded, detail: HakoLog.sanitize(success(result))))
            return result
        } catch {
            sink?(HakoExecutionEvent(id: event.id, stage: stage, state: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                                     detail: failure(error)))
            throw error
        }
    }

}
