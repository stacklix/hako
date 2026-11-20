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

// The caller owns the sink. Child services can report progress without depending on
// shortcut history, and unrelated tasks do not share a global active-run identifier.
enum HakoExecutionDiagnostics {
    typealias Sink = @MainActor @Sendable (HakoExecutionEvent) -> Void
    static let context = TaskLocal<Sink?>(wrappedValue: nil)
    static var sink: Sink? { context.get() }

    @MainActor static func record(_ stage: String, state: HakoExecutionEvent.State = .info, detail: String = "") {
        sink?(HakoExecutionEvent(stage: stage, state: state, detail: detail))
    }

    @MainActor static func environment() {
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
        #endif
        record("执行环境", detail: detail)
    }

    static func failure(_ error: Error) -> String {
        let value = error as NSError
        let symbol = value.domain == NSOSStatusErrorDomain && value.code == -25308 ? "（errSecInteractionNotAllowed）" : ""
        return HakoLog.sanitize("错误域：\(value.domain)；错误码：\(value.code)\(symbol)\n\(error.localizedDescription)")
    }

    @MainActor static func measure<T>(_ stage: String, operation: () throws -> T) rethrows -> T {
        guard sink != nil else { return try operation() }
        record(stage, state: .started)
        let start = Date.now
        do {
            let result = try operation()
            record(stage, state: .succeeded, detail: elapsed(since: start))
            return result
        } catch {
            record(stage, state: error is CancellationError ? .cancelled : .failed,
                   detail: elapsed(since: start) + "\n" + failure(error))
            throw error
        }
    }

    @MainActor static func measure<T>(_ stage: String, operation: () async throws -> T) async rethrows -> T {
        guard sink != nil else { return try await operation() }
        record(stage, state: .started)
        let start = Date.now
        do {
            let result = try await operation()
            record(stage, state: .succeeded, detail: elapsed(since: start))
            return result
        } catch {
            record(stage, state: error is CancellationError ? .cancelled : .failed,
                   detail: elapsed(since: start) + "\n" + failure(error))
            throw error
        }
    }

    private static func elapsed(since start: Date) -> String {
        "耗时：\(max(0, Int(Date.now.timeIntervalSince(start) * 1_000))) 毫秒"
    }
}
