import Foundation

@MainActor enum AndroidVideoShutdown {
    // A lost stop reply does not prove that the workstation failed to sleep
    // the phone. Reconcile with a read-only query; never repeat the action.
    static func finish(stop: () async throws -> Void, screen: () async throws -> String) async throws -> String? {
        do {
            try await stop()
            return nil
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
        }
        do {
            let state = try await screen()
            try Task.checkCancellation()
            switch state {
            case "off", "doze": return nil
            case "on": return "投屏已关闭，手机仍亮屏，请检查自动熄屏是否受系统限制。"
            default: break
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
        }
        return "投屏已关闭，暂时无法确认手机是否熄屏，请查看手机状态。"
    }
}
