import Foundation

@main struct ConsoleAgentProtocolTests {
    static func main() throws {
        let decoder = JSONDecoder()
        func agent(_ capabilities: String) throws -> ConsoleAgent {
            try decoder.decode(ConsoleAgent.self, from: Data("{\"id\":\"A1234\",\"name\":\"设备\",\"online\":false,\"lastSeen\":\"\",\"capabilities\":\(capabilities)}".utf8))
        }
        let unknown = try agent("null")
        let empty = try agent("[]")
        precondition(unknown.capabilities == nil)
        precondition(empty.capabilities?.isEmpty == true)
        let manifest = try agent("[{\"name\":\"query.system.metrics\",\"version\":1},{\"name\":\"action.network.http.check\",\"version\":1}]")
        precondition(manifest.capabilities?.count == 2)
        let payload = Data(#"{"capabilities":[{"name":"query.system.metrics","version":1}],"result":{"data":{"query.system.metrics":{"version":1,"error":{"code":"sample_failed","message":"采样失败"}},"query.future.data":{"version":7,"result":{"bytes":9007199254740993}},"query.future.null":{"version":1,"result":null},"query.future.invalid":{"version":1,"error":{},"result":0}}}}"#.utf8)
        let envelope = try decoder.decode(ConsoleQueryEnvelope.self, from: payload)
        precondition(envelope.capabilities.first?.name == "query.system.metrics")
        let reply = try decoder.decode(ConsoleAgentReply<ConsoleQueryResult>.self, from: payload)
        guard case .result(let queries) = reply else { fatalError("Expected aggregate") }
        precondition(queries.data["query.system.metrics"]?.error?.code == "sample_failed")
        precondition(queries.data["query.future.data"]?.result?.formatted.contains("9007199254740993") == true)
        precondition(queries.data["query.future.null"]?.result?.formatted == "null")
        precondition(queries.data["query.future.invalid"]?.error?.code == "invalid_data")
        precondition(queries.data["query.missing"] == nil)
        for status in [200, 301, 401, 404, 500] {
            let result = try decoder.decode(ConsoleHTTPCheck.self, from: Data("{\"url\":\"https://example.com\",\"reachable\":true,\"httpSuccess\":\(status == 200),\"statusCode\":\(status),\"elapsedMs\":12,\"checkedAt\":\"2026-10-28T08:00:00Z\",\"failure\":null}".utf8))
            precondition(result.reachable && result.statusCode == status)
        }
        for malformed in [#"{}"#, #"{"result":{},"error":{"code":"bad","message":"bad"}}"#] {
            do { _ = try decoder.decode(ConsoleAgentReply<ConsoleQueryResult>.self, from: Data(malformed.utf8)); fatalError("Invalid reply accepted") }
            catch is DecodingError { }
        }
        print("PASS: unknown/empty manifests, aggregate partial errors/null/missing data, integer preservation, HTTP results and reply validation")
    }
}
