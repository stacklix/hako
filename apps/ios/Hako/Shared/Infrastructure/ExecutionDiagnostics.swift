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

    var stageTitle: String {
        HakoExecutionLogRow(id: id, stage: stage, state: state, startedAt: nil, finishedAt: nil, detail: detail).stageTitle
    }
}

final class HakoExecutionCancellation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var value: String?
    private var executionRunID: UUID?
    private var executionAttempts: [String: UUID] = [:]

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
        executionAttempts[step] = attemptID
    }

    func finish(step: String, attemptID: UUID, keepForCancellation: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !keepForCancellation, executionAttempts[step] == attemptID { executionAttempts[step] = nil }
    }

    var attempts: [String: UUID] {
        lock.lock(); defer { lock.unlock() }
        return executionAttempts
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

    private var annotations: (title: String, values: [String: String]) {
        var title = stage, values: [String: String] = [:]
        while title.hasPrefix("["), let end = title.range(of: "] ") {
            let marker = title[title.index(after: title.startIndex)..<end.lowerBound].components(separatedBy: " · ")
            guard marker.count == 2, ["并行", "组", "分组"].contains(marker[0]) else { break }
            values[marker[0]] = marker[1]
            title = String(title[end.upperBound...])
        }
        return (title, values)
    }

    var parallelBranch: String? { annotations.values["并行"] }
    var parentGroupID: UUID? { annotations.values["组"].flatMap(UUID.init(uuidString:)) }
    var plannedBranches: Int? { annotations.values["分组"].flatMap(Int.init) }
    var stageTitle: String { annotations.title }

    var isAssetRequest: Bool { stageTitle.hasPrefix("资产接口 ") }

    var isDiagnostic: Bool {
        let stage = stageTitle
        return isAssetRequest ||
        ["开始执行子任务", "执行子任务", "重试子任务", "子任务结束", "子任务跳过",
         "执行环境", "取消时执行环境", "失败时执行环境", "快捷指令取消原因",
         "读取设备身份记录", "读取 Secure Enclave 公钥", "保存服务端登录会话",
         "恢复服务端登录会话", "读取服务端登录会话", "刷新服务端登录会话",
         "生成设备请求签名（Secure Enclave）", "服务端响应"].contains(stage)
        || stage.hasPrefix("发送请求 ") || stage.hasPrefix("行情请求 ") || stage.hasPrefix("行情缓存缺口 · ") || stage.hasPrefix("行情缓存结果 · ")
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

struct HakoExecutionLogItem: Identifiable {
    let row: HakoExecutionLogRow
    var children: [Self] = []
    var id: UUID { row.id }

    var completedBranches: Int {
        Set(children.filter { $0.row.startedAt != nil && $0.row.finishedAt != nil && $0.row.state != .info }
            .map { $0.row.parallelBranch ?? $0.id.uuidString }).count
    }

    static func grouping(_ rows: [HakoExecutionLogRow]) -> [Self] {
        let business = rows.filter { !$0.isDiagnostic }
        let groups = Set(business.filter { $0.plannedBranches != nil }.map(\.id))
        func items(parent: UUID?) -> [Self] {
            business.filter { row in
                let owner = row.parentGroupID.flatMap { groups.contains($0) ? $0 : nil }
                return owner == parent
            }.map { row in
                Self(row: row, children: row.plannedBranches == nil ? [] : items(parent: row.id))
            }
        }
        return items(parent: nil)
    }
}

enum HakoExecutionLogExport {
    static func text(title: String, metadata: [String], events: [HakoExecutionEvent],
                     startedAt: Date? = nil, finishedAt: Date? = nil, now: Date = .now, capacity: Int) -> String {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date.timeZone = TimeZone(secondsFromGMT: 0)
        var lines = [title, "导出时间：" + date.string(from: now)] + metadata
        if let startedAt { lines.append("本次开始：" + date.string(from: startedAt)) }
        if let finishedAt { lines.append("本次结束：" + date.string(from: finishedAt)) }
        if let startedAt, events.contains(where: { $0.time < startedAt }) {
            lines.append("包含此前尝试的事件；相对开始时间以本次开始为基准，重试前的事件可以为负数。")
        }
        lines.append("原始事件：\(events.count) 条；保留上限：\(capacity) 条。时间采用 UTC，包含毫秒。")
        if events.count >= capacity { lines.append("已达到保留上限，较早事件可能已被移除；本次导出包含当前保留的全部事件。") }
        lines.append("\n阶段耗时汇总（并行分支耗时不相加）")
        for row in HakoExecutionLogRow.merging(events) {
            let kind = row.isDiagnostic ? "诊断" : "关键步骤"
            let branch = row.parallelBranch.map { "；分支：" + $0 } ?? ""
            let finish = row.finishedAt.map { date.string(from: $0) } ?? "未结束或未记录"
            lines.append("[\(kind)] \(row.stageTitle)\(branch)；\(row.state.rawValue)；耗时：\(row.elapsed(at: now))；开始：\(row.startedAt.map { date.string(from: $0) } ?? "未记录")；结束：\(finish)；ID：\(row.id.uuidString)")
        }
        lines.append("\n全量原始事件（保存顺序，包含开始、完成、失败、取消和诊断详情）")
        for (index, event) in events.enumerated() {
            let offset = startedAt.map { String(format: "；相对开始：%.3f 秒", event.time.timeIntervalSince($0)) } ?? ""
            lines.append("\n#\(index + 1) \(date.string(from: event.time))\(offset)\n状态：\(event.state.rawValue)\n事件 ID：\(event.id.uuidString)\n阶段：\(event.stage)\n\(event.detail)")
        }
        return HakoLog.sanitize(lines.joined(separator: "\n"), limit: Int.max)
    }
}

// The caller owns the sink. Child services can report progress without depending on
// shortcut history, and unrelated tasks do not share a global active-run identifier.
enum HakoExecutionDiagnostics {
    typealias Sink = @MainActor @Sendable (HakoExecutionEvent) -> Void
    static let context = TaskLocal<Sink?>(wrappedValue: nil)
    static let cancellation = TaskLocal<HakoExecutionCancellation?>(wrappedValue: nil)
    // Runtime-only branch marker; the stored event format remains unchanged.
    static let parallel = TaskLocal<String?>(wrappedValue: nil)
    static let group = TaskLocal<UUID?>(wrappedValue: nil)
    static var sink: Sink? { context.get() }

    static func stageName(_ stage: String) -> String {
        let branch = parallel.get().map { "[并行 · \($0)] " + stage } ?? stage
        return group.get().map { "[组 · \($0.uuidString)] " + branch } ?? branch
    }

    @MainActor static func record(_ stage: String, state: HakoExecutionEvent.State = .info, detail: String = "") {
        sink?(HakoExecutionEvent(stage: stageName(stage), state: state, detail: detail))
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
        let stage = stageName(stage)
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
        let stage = stageName(stage)
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

    @MainActor static func measureGroup<T>(_ stage: String, branches: Int, detail: String,
                                           resultState: (T) -> HakoExecutionEvent.State = { _ in .succeeded },
                                           operation: () async throws -> T) async rethrows -> T {
        guard let sink else { return try await operation() }
        let event = HakoExecutionEvent(stage: stageName("[分组 · \(branches)] " + stage), state: .started, detail: detail)
        sink(event)
        do {
            let result = try await group.withValue(event.id) { try await operation() }
            sink(HakoExecutionEvent(id: event.id, stage: event.stage, state: resultState(result), detail: HakoLog.sanitize(detail)))
            return result
        } catch {
            sink(HakoExecutionEvent(id: event.id, stage: event.stage,
                                    state: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                                    detail: HakoLog.sanitize(detail + "\n" + failure(error))))
            throw error
        }
    }

}
