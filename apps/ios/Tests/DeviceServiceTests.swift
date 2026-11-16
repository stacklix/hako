import Foundation

@main struct DeviceServiceTests {
    static func main() throws {
        precondition(DeviceServiceCommand.status == "admin.services.status" && DeviceServiceCommand.start == "admin.services.start")
        var device = ConsoleDeviceData()
        device.entries[DeviceServiceCommand.status] = ConsoleCapabilityData(version: 1, result: .string("guardian"))
        device.entries["query.system.metrics"] = ConsoleCapabilityData(version: 1, result: .string("new live sample"))
        device.liveUpdates["query.system.metrics"] = UUID()
        device.mergeQueries(["query.system.metrics": ConsoleCapabilityData(version: 1, result: .string("old query"))], since: [:])
        precondition(device.entries[DeviceServiceCommand.status]?.result?.decode(String.self) == "guardian")
        precondition(device.entries["query.system.metrics"]?.result?.decode(String.self) == "new live sample")
        device.mergeQueries([:], since: device.liveUpdates)
        precondition(device.entries.count == 1 && device.entries[DeviceServiceCommand.status] != nil && device.loaded)
        let decoder = JSONDecoder()
        func snapshot(_ services: String) throws -> DeviceServiceSnapshot {
            try decoder.decode(DeviceServiceSnapshot.self, from: Data("{\"collectedAt\":\"2026-11-15T10:00:00Z\",\"services\":\(services),\"warnings\":[]}".utf8))
        }
        let responding = #"{"name":"chore","port":8000,"description":"截图服务","status":"responding","processes":[{"processId":1,"processName":"python","addresses":["0.0.0.0"]}],"http":{"url":"http://127.0.0.1:8000/","statusCode":404,"elapsedMs":5},"canStart":false}"#
        let stopped = #"{"name":"workbench","port":8003,"status":"stopped","processes":[],"canStart":true}"#
        let valid = try snapshot("[\(responding),\(stopped)]")
        precondition(valid.isValid && valid.services[0].status.title == "已响应")
        precondition(valid.services[0].http?.statusCode == 404 && valid.services[1].canStart)
        let empty = try snapshot("[]")
        precondition(empty.isValid)
        for invalid in [
            responding.replacingOccurrences(of: "8000", with: "65536"),
            responding.replacingOccurrences(of: "404", with: "503"),
            responding.replacingOccurrences(of: #""elapsedMs":5"#, with: #""elapsedMs":-1"#),
            responding.replacingOccurrences(of: #""canStart":false"#, with: #""canStart":true"#),
            stopped.replacingOccurrences(of: #""canStart":true"#, with: #""canStart":true,"startup":{"state":"starting","message":"正在启动","requestedAt":"now"}"#)
        ] {
            let value = try snapshot("[\(invalid)]")
            precondition(!value.isValid)
        }
        let duplicate = try snapshot("[\(responding),\(responding)]")
        precondition(!duplicate.isValid)
        let serverError = responding.replacingOccurrences(of: "responding", with: "http_error").replacingOccurrences(of: "404", with: "503")
        let serverErrorSnapshot = try snapshot("[\(serverError)]")
        precondition(serverErrorSnapshot.isValid)
        let failed = responding.replacingOccurrences(of: "responding", with: "unreachable")
            .replacingOccurrences(of: #""statusCode":404"#, with: #""failure":"HTTP 探测超时。""#)
        let failedSnapshot = try snapshot("[\(failed)]")
        precondition(failedSnapshot.isValid)
        let reply = try decoder.decode(DeviceServiceStartReply.self,
            from: Data(#"{"name":"chore","requestId":"test-id","state":"starting","message":"已提交启动命令"}"#.utf8))
        precondition(reply.state == "starting", "A submitted command must not be presented as a running service")
        print("Service monitoring HTTP status, validation, duplicate IDs, startup availability and start receipt tests passed")
    }
}
