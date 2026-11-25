import Foundation

@main struct StockTradeWorkflowTests {
    static func main() throws {
        let fixture = #"{"id":"aabbccddeeff00112233445566778899","kind":"full","dataDate":null,"state":"queued","phase":"pending","createdAt":"2026-11-25T01:00:00+00:00","startedAt":null,"finishedAt":null,"result":null,"failureCode":null,"events":[{"sequence":1,"at":"2026-11-25T01:00:00+00:00","message":"任务已接收。"}]}"#
        let decoder = JSONDecoder()
        func decode(_ text: String) throws -> StockTradeWorkflowTask {
            try decoder.decode(StockTradeWorkflowTask.self, from: Data(text.utf8)).validated()
        }
        let queued = try decode(fixture)
        precondition(queued.state.active && queued.kind.phases.count == 4 && queued.result == nil)
        let running = try decode(fixture.replacingOccurrences(of: "queued", with: "running").replacingOccurrences(of: "pending", with: "review"))
        precondition(running.state.active && running.phase == "review")
        func reject(_ text: String) {
            do { _ = try decode(text); preconditionFailure("Invalid workflow contract accepted") } catch { }
        }
        reject(fixture.replacingOccurrences(of: "queued", with: "succeeded"))
        reject(fixture.replacingOccurrences(of: "pending", with: "shell"))
        reject(fixture.replacingOccurrences(of: "aabbccddeeff00112233445566778899", with: "../other"))
        reject(fixture.replacingOccurrences(of: "queued", with: "unknown"))
        let partial = try decode(fixture.replacingOccurrences(of: "full", with: "fetch").replacingOccurrences(of: "queued", with: "succeeded").replacingOccurrences(of: "pending", with: "fetch"))
        precondition(!partial.state.active && partial.result == nil)
        let failed = try decode(fixture.replacingOccurrences(of: "queued", with: "failed").replacingOccurrences(of: "pending", with: "publish"))
        precondition(!failed.state.active)
        let monitoring = fixture.replacingOccurrences(of: "full", with: "monitor")
        let monitorQueued = try decode(monitoring)
        precondition(monitorQueued.kind == .monitor)
        reject(monitoring.replacingOccurrences(of: "queued", with: "succeeded"))
        let result = #"{"enabled":true,"snapshotId":"aabbccddeeff00112233445566778899","sourceSnapshotId":"aabbccddeeff00112233445566778899","initializedCount":0,"watchCount":0,"openCount":0,"publishedAt":"2026-11-25T01:00:00+00:00"}"#
        let ready = monitoring.replacingOccurrences(of: "queued", with: "succeeded")
            .replacingOccurrences(of: "pending", with: "monitor")
            .replacingOccurrences(of: #""result":null"#, with: #""result":null,"monitorResult":"# + result)
        let activated = try decode(ready)
        precondition(activated.monitorResult?.watchCount == 0 && activated.result == nil)
        reject(ready.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#))
        reject(ready.replacingOccurrences(of: #""watchCount":0"#, with: #""watchCount":-1"#))
        print("Cerno workflow contracts passed")
    }
}
