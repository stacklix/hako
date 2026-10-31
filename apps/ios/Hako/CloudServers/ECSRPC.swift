import Foundation
import CryptoKit

// ECS RPC v1 signing. Credentials stay in the HTTPS POST body, never in URLs.
enum ECSRPC {
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))!
    }
    static func canonical(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { encode($0) + "=" + encode(parameters[$0]!) }.joined(separator: "&")
    }
    static func signature(_ parameters: [String: String], secret: String, method: String = "POST") -> String {
        let text = method + "&%2F&" + encode(canonical(parameters))
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data((secret + "&").utf8)))).base64EncodedString()
    }
    static func snapshotCommand(source: String, mode: String, pid: Int? = nil, after: Int = 0) throws -> String {
        guard ["overview", "network", "processes", "process"].contains(mode),
              after >= 0, after == 0 || mode == "processes",
              mode != "process" || pid.map({ $0 > 0 }) == true else {
            throw ECSFailure(message: "系统查询参数无效。")
        }
        // Foundation's zlib compression emits raw DEFLATE (Python wbits=-15).
        let compressed = try (Data(source.utf8) as NSData).compressed(using: .zlib) as Data
        let command = """
        command -v python3 >/dev/null 2>&1 || { printf 'HAKO_PYTHON_MISSING'; exit 127; }
        python3 - \(mode) \(pid ?? 0) \(after) <<'HAKO_ECS_SNAPSHOT'
        import base64,zlib
        exec(compile(zlib.decompress(base64.b64decode('\(compressed.base64EncodedString())'),-15),'hako-ecs-snapshot','exec'))
        HAKO_ECS_SNAPSHOT

        """
        guard Data(command.utf8).base64EncodedString().utf8.count < 24_000 else {
            throw ECSFailure(message: "系统查询脚本超过云助手长度限制。")
        }
        return command
    }

    static func request(connection: ECSConnection, action: String, parameters: [String: String], now: Date = .now, nonce: String = UUID().uuidString) -> URLRequest {
        var values = parameters
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        values.merge(["Action": action, "RegionId": connection.region, "Version": "2014-05-26", "Format": "JSON",
            "AccessKeyId": connection.accessKeyID, "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
            "SignatureNonce": nonce, "Timestamp": formatter.string(from: now)]) { _, new in new }
        if !connection.securityToken.isEmpty { values["SecurityToken"] = connection.securityToken }
        values["Signature"] = signature(values, secret: connection.accessKeySecret)
        var request = URLRequest(url: URL(string: "https://ecs.aliyuncs.com/")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(canonical(values).utf8)
        return request
    }
}

private final class ECSNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class ECSClient: @unchecked Sendable {
    let connection: ECSConnection
    let session: URLSession

    init(connection: ECSConnection, session: URLSession? = nil) throws {
        self.connection = try connection.validated()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: ECSNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func call(_ action: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        let started = Date.now
        var outcome = "网络或响应格式异常"
        var level = HakoLogLevel.error
        defer {
            HakoLog.record(.cloudServers, level, "阿里云 API · \(action)",
                detail: "\(outcome)\n地域：\(connection.region)\n耗时：\(Int(Date.now.timeIntervalSince(started) * 1000)) ms",
                secrets: [connection.accessKeyID, connection.accessKeySecret, connection.securityToken])
        }
        do {
            let (data, response) = try await session.data(for: ECSRPC.request(connection: connection, action: action, parameters: parameters))
            guard let http = response as? HTTPURLResponse, data.count <= 2_097_152,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ECSFailure(message: "阿里云返回的数据格式无效。")
            }
            if !(200...299).contains(http.statusCode) || object["Code"] != nil {
                // Do not display provider error text: it may echo signed parameters.
                let code = object["Code"] as? String ?? ""
                outcome = "HTTP \(http.statusCode) · \(code)"
                let message: String
                switch code {
                case "InvalidAccessKeyId.NotFound", "InvalidAccessKeyId": message = "RAM AccessKey ID 无效。"
                case "SignatureDoesNotMatch": message = "请求签名校验失败，请检查 AccessKey Secret。"
                case "InvalidSecurityToken.Expired", "InvalidSecurityToken", "InvalidSecurityToken.MismatchWithAccessKey": message = "STS 临时凭据无效或已过期，请更新整组凭据。"
                case "InvalidTimeStamp.Expired": message = "手机时间与阿里云不一致，请检查系统时间。"
                case "Throttling", "Throttling.User", "Throttling.Api": message = "阿里云请求过于频繁，请稍后刷新。"
                case "InvalidSessionId.NotFound": message = "终端会话已经结束。"
                default:
                    if code.lowercased().contains("session") && code.lowercased().contains("disabled") { message = "请先在阿里云控制台启用会话管理。" }
                    else if http.statusCode == 403 { message = "没有执行此操作的 RAM 权限，或云助手 / 会话管理尚未就绪。" }
                    else { message = "阿里云操作失败（HTTP \(http.statusCode)），请检查实例状态、地域及云助手。" }
                }
                throw ECSFailure(message: message, code: code)
            }
            outcome = "HTTP \(http.statusCode) · 成功"; level = .info
            return object
        } catch is CancellationError { outcome = "请求已取消"; level = .info; throw CancellationError() }
        catch let failure as ECSFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw ECSFailure(message: "无法连接阿里云，请检查网络后重试。") }
    }

    func instance() async throws -> ECSInstance {
        let object = try await call("DescribeInstances", ["InstanceIds": "[\"\(connection.instanceID)\"]"])
        guard let values = (object["Instances"] as? [String: Any])?["Instance"] as? [[String: Any]], let item = values.first else {
            throw ECSFailure(message: "找不到此实例，请检查地域和实例 ID。")
        }
        let vpc = item["VpcAttributes"] as? [String: Any]
        let privateIP = ((vpc?["PrivateIpAddress"] as? [String: Any])?["IpAddress"] as? [String])?.first ?? ""
        return ECSInstance(name: item["InstanceName"] as? String ?? connection.name, status: item["Status"] as? String ?? "",
            os: item["OSName"] as? String ?? "", address: privateIP,
            cpu: (item["Cpu"] as? NSNumber)?.intValue, memoryMiB: (item["Memory"] as? NSNumber)?.intValue)
    }

    func monitor() async throws -> [ECSMonitorPoint] {
        let formatter = ISO8601DateFormatter()
        let end = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 / 60) * 60)
        let object = try await call("DescribeInstanceMonitorData", ["InstanceId": connection.instanceID,
            "StartTime": formatter.string(from: end.addingTimeInterval(-3600)), "EndTime": formatter.string(from: end), "Period": "60"])
        let items = (object["MonitorData"] as? [String: Any])?["InstanceMonitorData"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let text = item["TimeStamp"] as? String, let date = formatter.date(from: text) else { return nil }
            func number(_ key: String) -> Double? { (item[key] as? NSNumber)?.doubleValue }
            // RX/TX are kbits per period, not bytes/s. Preserve absent values.
            return ECSMonitorPoint(time: date, cpu: number("CPU"), receiveBytesPerSecond: number("IntranetRX").map { $0 * 1000 / 8 / 60 },
                sendBytesPerSecond: number("IntranetTX").map { $0 * 1000 / 8 / 60 }, readBytesPerSecond: number("BPSRead"), writeBytesPerSecond: number("BPSWrite"))
        }.sorted { $0.time < $1.time }
    }

    func snapshot(mode: String, pid: Int? = nil) async throws -> ECSSnapshot {
        guard ["overview", "network", "processes", "process"].contains(mode), (mode != "process" || pid.map({ $0 > 0 }) == true),
              let url = Bundle.main.url(forResource: "ecs-snapshot.py", withExtension: "txt") else {
            throw ECSFailure(message: "无法读取系统查询资源。")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        if mode == "processes" {
            return try await ECSSnapshot.processList { cursor in
                try await self.snapshotPage(mode: mode, pid: pid, after: cursor, source: source)
            }
        }
        return try await snapshotPage(mode: mode, pid: pid, after: 0, source: source)
    }

    private func snapshotPage(mode: String, pid: Int?, after: Int, source: String) async throws -> ECSSnapshot {
        try Task.checkCancellation()
        let command = try ECSRPC.snapshotCommand(source: source, mode: mode, pid: pid, after: after)
        let reply = try await call("RunCommand", ["InstanceId.1": connection.instanceID, "Type": "RunShellScript", "CommandContent": Data(command.utf8).base64EncodedString(),
            "ContentEncoding": "Base64", "KeepCommand": "false", "Timeout": "45", "TerminationMode": "ProcessTree",
            "Username": connection.username, "ClientToken": UUID().uuidString])
        guard let invocation = reply["InvokeId"] as? String else { throw ECSFailure(message: "阿里云未返回查询任务 ID。") }
        return try await withTaskCancellationHandler {
            for _ in 0..<35 {
                try await Task.sleep(for: .seconds(2))
                let object = try await call("DescribeInvocationResults", ["InvokeId": invocation, "InstanceId": connection.instanceID, "ContentEncoding": "PlainText"])
                let rows = ((object["Invocation"] as? [String: Any])?["InvocationResults"] as? [String: Any])?["InvocationResult"] as? [[String: Any]] ?? []
                guard let result = rows.first else { continue }
                let status = result["InvocationStatus"] as? String ?? ""
                if ["Pending", "Scheduled", "Running", "Starting"].contains(status) { continue }
                let output = result["Output"] as? String ?? ""
                guard status == "Success", (result["ExitCode"] as? NSNumber)?.intValue == 0 else {
                    if output.contains("HAKO_PYTHON_MISSING") { throw ECSFailure(message: "系统查询需要实例已有 Python 3；Hako 不会自动安装软件。") }
                    throw ECSFailure(message: "系统查询未完成，请检查云助手状态、Linux 用户和读取权限。")
                }
                guard ((result["Dropped"] as? NSNumber)?.intValue ?? 0) == 0 else { throw ECSFailure(message: "查询结果被阿里云截断，请缩小查询范围后重试。") }
                return try ECSSnapshot.decode(Data(output.utf8))
            }
            await stop(invocation)
            throw ECSFailure(message: "等待系统查询超时，请稍后刷新。")
        } onCancel: {
            Task { await self.stop(invocation) }
        }
    }
    private func stop(_ invocation: String) async { _ = try? await call("StopInvocation", ["InvokeId": invocation, "InstanceId.1": connection.instanceID]) }

    func startTerminal() async throws -> (id: String, url: URL) {
        let result = try await call("StartTerminalSession", ["InstanceId.1": connection.instanceID, "Username": connection.username,
            "ConnectionType": "Internet", "ClientToken": UUID().uuidString])
        // Log before validation so rejected provider addresses remain inspectable.
        // Never persist the raw signed URL, SessionId or SecurityToken.
        let address = (result["WebSocketUrl"] as? String).map(HakoLog.safeURL) ?? "[未返回 WebSocketUrl]"
        HakoLog.record(.cloudServers, "阿里云返回终端连接地址", detail: "地址：\(address)\n使用接口返回的原始连接地址；允许协议：wss",
            secrets: [connection.accessKeyID, connection.accessKeySecret, connection.securityToken,
                      result["SecurityToken"] as? String ?? "", result["SessionId"] as? String ?? ""])
        guard let id = result["SessionId"] as? String, !id.isEmpty else { throw ECSFailure(message: "阿里云未返回终端会话 ID。") }
        // StartTerminalSession is the authority for the endpoint. Do not derive a
        // hostname from RegionId or rewrite the signed URL returned over HTTPS.
        guard let text = result["WebSocketUrl"] as? String, let url = URL(string: text), url.scheme?.lowercased() == "wss",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port.map({ (1...65_535).contains($0) }) ?? true else {
            HakoLog.record(.cloudServers, .error, "终端连接地址格式无效", detail: "接口需返回包含主机、有效端口且无用户密码的 wss 地址。")
            try? await endTerminal(id)
            throw ECSFailure(message: "阿里云返回的终端连接地址格式无效。")
        }
        return (id, url)
    }
    func endTerminal(_ id: String) async throws {
        do { _ = try await call("EndTerminalSession", ["SessionId": id]) }
        catch let failure as ECSFailure where failure.code == "InvalidSessionId.NotFound" { }
    }
}
