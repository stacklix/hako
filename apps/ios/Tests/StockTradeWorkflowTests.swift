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
        print("Cerno workflow contracts passed")
    }
}
