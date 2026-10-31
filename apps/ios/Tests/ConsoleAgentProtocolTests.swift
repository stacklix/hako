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
        let listenerJSON = #"{"collectedAt":"2026-10-31T12:00:00Z","ports":[{"protocol":"TCP","port":8080,"processes":[{"processId":10,"processName":"hako","startedAt":"2026-10-30T10:58:59Z","uptimeSeconds":90061,"addresses":["0.0.0.0","::"]},{"processId":11,"addresses":["127.0.0.2"]}]}],"warnings":[]}"#
        let listeners = try decoder.decode(ConsoleListenerSnapshot.self, from: Data(listenerJSON.utf8))
        precondition(listeners.isValid && listeners.ports.count == 1 && listeners.ports[0].processes.count == 2)
        precondition(listeners.ports[0].processes[0].formattedUptime == "1 天 1 小时 1 分 1 秒")
        precondition(listeners.ports[0].processes[1].formattedUptime == "暂不可用")
        precondition(listeners.hasUnclassifiedProcesses && listeners.ports(in: .system).isEmpty
            && listeners.ports(in: .user).count == 1)
        let groupedJSON = listenerJSON.replacingOccurrences(of: #""processId":10"#, with: #""category":"system","processId":10"#)
            .replacingOccurrences(of: #""processId":11"#, with: #""category":"user","processId":11"#)
        let grouped = try decoder.decode(ConsoleListenerSnapshot.self, from: Data(groupedJSON.utf8))
        precondition(grouped.isValid && !grouped.hasUnclassifiedProcesses)
        precondition(grouped.ports(in: .system).first?.processes.map(\.processId) == [10])
        precondition(grouped.ports(in: .user).first?.processes.map(\.processId) == [11])
        precondition(grouped.ports[0].processes.count == 2)
        let invalidListeners = try decoder.decode(ConsoleListenerSnapshot.self, from: Data(listenerJSON.replacingOccurrences(of: "90061", with: "-1").utf8))
        precondition(!invalidListeners.isValid)
        let badPort = try decoder.decode(ConsoleListenerSnapshot.self, from: Data(listenerJSON.replacingOccurrences(of: "8080", with: "65536").utf8))
        precondition(!badPort.isValid)
        var days: [[String: Any]] = (22...28).map { day in
            ["date": "2026-10-\(day)", "requestCount": 2, "inputTokens": 100, "cachedInputTokens": 40,
             "outputTokens": 10, "reasoningOutputTokens": 3, "totalTokens": 110, "breakdownAvailable": true]
        }
        func codex(_ days: [[String: Any]], running: Int? = nil, details: [[String: Any]]? = nil) throws -> ConsoleCodexUsage {
            var payload: [String: Any] = ["available": true, "collectedAt": "2026-10-28T08:00:00Z", "timeZone": "Asia/Shanghai",
                                          "days": days, "requestCountKind": "user_messages", "runningSessions": NSNull(), "warnings": ["运行状态暂不可用"]]
            if let running { payload["runningSessions"] = running }
            if let details { payload["runningSessionDetails"] = details }
            return try decoder.decode(ConsoleCodexUsage.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let usage = try codex(days)
        precondition(usage.isValid && usage.countsUserMessages && usage.totalCalls == 14 && usage.totalTokens == 770
                     && usage.runningSessions == nil && usage.days.last?.requestCount == 2)
        let active = try codex(days, running: 1, details: [["title": "调整图表", "projectName": "hako"]])
        precondition(active.isValid && active.runningSessionDetails?.first?.title == "调整图表")
        let oldAgent = try codex(days, running: 1)
        precondition(oldAgent.isValid && oldAgent.runningSessionDetails == nil)
        let idle = try codex(days, running: 0, details: [])
        precondition(idle.isValid && idle.runningSessionDetails?.isEmpty == true)
        let inconsistent = try codex(days, running: 2, details: [["title": "调整图表", "projectName": "hako"]])
        precondition(!inconsistent.isValid)
        let invalidDetails = try codex(days, running: 1, details: [["title": " ", "projectName": "hako"]])
        precondition(!invalidDetails.isValid)
        let chartMaxima: [Int64] = [0, 1, 7, 163, 100_000_000, Int64.max]
        for maximum in chartMaxima {
            let scale = ConsoleCodexChartScale.maximum(for: maximum)
            precondition(scale.isFinite && scale > 0 && scale >= Double(maximum))
            precondition((scale / 4).rounded() == scale / 4)
        }
        let incompleteUsage = try codex(Array(days.dropLast()))
        precondition(!incompleteUsage.isValid)
        days[0]["totalTokens"] = 111
        let invalidUsage = try codex(days)
        precondition(!invalidUsage.isValid)
        func metrics(_ network: Any? = nil) throws -> ConsoleMetrics {
            var payload: [String: Any] = ["cpuUsagePercent": 25, "memoryUsagePercent": 50,
                "memoryUsedBytes": 4_294_967_296, "memoryTotalBytes": 8_589_934_592,
                "sampledAt": "2026-10-29T08:00:00Z", "sampleWindowMs": 1000]
            if let network { payload["network"] = network }
            return try decoder.decode(ConsoleMetrics.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let legacyMetrics = try metrics()
        precondition(legacyMetrics.isValid && !legacyMetrics.networkReported && legacyMetrics.network == nil)
        let networkMetrics = try metrics(["available": true, "downloadBytesPerSecond": 3072,
            "uploadBytesPerSecond": 1536, "interfaceCount": 2])
        precondition(networkMetrics.isValid && networkMetrics.networkReported && networkMetrics.network?.isValid == true
            && networkMetrics.network?.downloadBytesPerSecond == 3072 && networkMetrics.network?.uploadBytesPerSecond == 1536)
        let unavailableMetrics = try metrics(["available": false, "interfaceCount": 0, "message": "暂不可用"])
        precondition(unavailableMetrics.isValid && unavailableMetrics.network?.isValid == true && unavailableMetrics.network?.available == false)
        let malformedNetwork = try metrics(["available": "bad"])
        precondition(malformedNetwork.isValid && malformedNetwork.networkReported && malformedNetwork.network == nil)
        let negativeRate = try metrics(["available": true, "downloadBytesPerSecond": -1,
            "uploadBytesPerSecond": 1, "interfaceCount": 1])
        precondition(negativeRate.isValid && negativeRate.network?.isValid == false)
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
