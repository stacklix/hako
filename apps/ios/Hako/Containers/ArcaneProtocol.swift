import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ArcaneFailure: LocalizedError {
    let message: String
    var status: Int? = nil
    var outcomeUnknown = false
    var errorDescription: String? { message }
}

struct ArcaneConnection: Codable, Equatable {
    var id = UUID().uuidString
    var name = "我的 Arcane"
    var address = ""
    var apiKey = ""
    var allowHTTP = false

    func normalized() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.apiKey.isEmpty,
              !value.apiKey.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else {
            throw ArcaneFailure(message: "请填写连接名称和有效的 API Key。")
        }
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ArcaneFailure(message: "请输入 Arcane 服务地址，不包含账号、密码、查询参数或页面路径。")
        }
        guard scheme != "http" || allowHTTP else {
            throw ArcaneFailure(message: "建议使用 HTTPS；使用 HTTP 时请先明确开启不加密连接。")
        }
        url.scheme = scheme
        while url.path.hasSuffix("/") { url.path.removeLast() }
        if url.path.hasSuffix("/api") { url.path.removeLast(4) }
        guard let result = url.url else { throw ArcaneFailure(message: "Arcane 地址无效。") }
        value.address = result.absoluteString
        return value
    }

    func request(_ components: [String], query: [URLQueryItem] = [], method: String = "GET", websocket: Bool = false) throws -> URLRequest {
        let value = try normalized()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw ArcaneFailure(message: "服务端返回了无效的资源 ID。")
        }
        var url = URL(string: value.address)!.appendingPathComponent("api")
        for component in components { url.appendPathComponent(component) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        if websocket { parts.scheme = parts.scheme == "https" ? "wss" : "ws" }
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(value.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

struct ArcaneEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let data: T
    let pagination: ArcanePagination?
}

struct ArcanePagination: Decodable {
    let totalItems: Int
}

struct ArcaneEnvironment: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let status: String?
    let enabled: Bool?
    var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? (id == "0" ? "本地 Docker" : id) }
    var statusText: String {
        if enabled == false { return "已停用" }
        switch status?.lowercased() {
        case "online", "connected": return "在线"
        case "standby": return "待命"
        case "offline", "disconnected": return "离线"
        case "error": return "连接异常"
        default: return status ?? "状态未知"
        }
    }
}

struct ArcaneUpdateInfo: Decodable {
    let hasUpdate: Bool?
    let currentVersion: String?
    let latestVersion: String?
    let currentDigest: String?
    let latestDigest: String?
    let checkTime: String?
    let error: String?
    let containerUpdates: [String: ArcaneContainerUpdate]?

    func forContainer(_ id: String) -> ArcaneContainerUpdate {
        containerUpdates?[id] ?? ArcaneContainerUpdate(hasUpdate: hasUpdate, currentVersion: currentVersion,
            latestVersion: latestVersion, currentDigest: currentDigest, latestDigest: latestDigest, checkTime: checkTime, error: error)
    }
}

struct ArcaneContainerUpdate: Decodable {
    let hasUpdate: Bool?
    let currentVersion: String?
    let latestVersion: String?
    let currentDigest: String?
    let latestDigest: String?
    let checkTime: String?
    let error: String?
    var text: String {
        if let error, !error.isEmpty { return "检查失败" }
        if hasUpdate == true { return "有更新" }
        return hasUpdate == false ? "未发现更新" : "尚未检查"
    }
}

struct ArcaneContainer: Decodable, Identifiable {
    let id: String
    let names: [String]?
    let image: String?
    let state: String?
    let status: String?
    let labels: [String: String]?
    let updateInfo: ArcaneUpdateInfo?
    let resourceSample: ArcaneResourceSample?
    let redeployDisabled: Bool?
    var name: String { (names?.first ?? String(id.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var project: String? { labels?["com.docker.compose.project"] }
    var abnormal: Bool { status?.lowercased().contains("unhealthy") == true || ["dead", "restarting"].contains(state ?? "") }
    var stopped: Bool { ["exited", "created", "dead"].contains(state ?? "") }
    var update: ArcaneContainerUpdate? { updateInfo?.forContainer(id) }
    var stateText: String { ArcaneContainerState.text(state ?? "") }
}

struct ArcaneContainerState: Decodable {
    let status: String?
    let running: Bool?
    let exitCode: Int?
    let startedAt: String?
    let finishedAt: String?
    let health: Health?
    struct Health: Decodable { let status: String?; let failingStreak: Int? }
    static func text(_ state: String) -> String {
        switch state {
        case "running": return "运行中"
        case "exited": return "已停止"
        case "created": return "尚未启动"
        case "paused": return "已暂停"
        case "restarting": return "正在重启"
        case "removing": return "正在删除"
        case "dead": return "异常退出"
        default: return state.isEmpty ? "状态未知" : state
        }
    }
}

struct ArcaneContainerDetails: Decodable, Identifiable {
    let id: String
    let name: String?
    let image: String?
    let state: ArcaneContainerState?
    let config: Config?
    let hostConfig: HostConfig?
    let ports: [Port]?
    let mounts: [Mount]?
    let networkSettings: Networks?
    let labels: [String: String]?
    let redeployDisabled: Bool?
    let updateInfo: ArcaneUpdateInfo?
    let activityId: String?
    let composeInfo: ArcaneComposeReference?
    struct Config: Decodable { let env: [String]?; let cmd: [String]?; let workingDir: String? }
    struct HostConfig: Decodable { let restartPolicy: String?; let memory: Int64?; let autoRemove: Bool? }
    struct Port: Decodable {
        let privatePort: Int; let publicPort: Int?; let type: String?
        let ip: String?
        var protocolName: String {
            let value = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return value.isEmpty ? "tcp" : value
        }
        var mappedPort: Int? { publicPort.flatMap { $0 > 0 ? $0 : nil } }
        var bindingAddress: String? {
            let value = ip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ["", "0.0.0.0", "::"].contains(value) ? nil : value
        }
        var text: String {
            let containerPort = "\(privatePort)/\(protocolName)"
            guard let mappedPort else { return containerPort }
            if let address = bindingAddress {
                let host = address.contains(":") ? "[\(address)]" : address
                return "\(host):\(mappedPort) → \(containerPort)"
            }
            return "\(mappedPort) → \(containerPort)"
        }
    }
    struct Mount: Decodable { let type: String?; let name: String?; let source: String?; let destination: String?; let rw: Bool? }
    struct Networks: Decodable {
        let networks: [String: Endpoint]?
        struct Endpoint: Decodable { let ipAddress: String?; let globalIPv6Address: String? }
    }
    var displayName: String { (name ?? String(id.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var project: String? { composeInfo?.projectName ?? labels?["com.docker.compose.project"] }
    var portsText: String? {
        guard let ports, !ports.isEmpty else { return nil }
        // Arcane enumerates Docker's port map without sorting. Dual-stack
        // wildcard bindings represent the same mapping in this compact display.
        let sorted = ports.sorted {
            if $0.privatePort != $1.privatePort { return $0.privatePort < $1.privatePort }
            if $0.protocolName != $1.protocolName { return $0.protocolName < $1.protocolName }
            if $0.mappedPort != $1.mappedPort { return ($0.mappedPort ?? 0) < ($1.mappedPort ?? 0) }
            return ($0.bindingAddress ?? "") < ($1.bindingAddress ?? "")
        }
        var seen = Set<String>()
        return sorted.map(\.text).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}

struct ArcaneResourceSample: Decodable {
    let cpuPercent: Double?
    let memoryUsageBytes: Int64?
    let memoryLimitBytes: Int64?
    let sampleTime: String?
    let networkRxBytes: Int64?
    let networkTxBytes: Int64?

    init(cpuPercent: Double?, memoryUsageBytes: Int64?, memoryLimitBytes: Int64?, sampleTime: String?,
         networkRxBytes: Int64? = nil, networkTxBytes: Int64? = nil) {
        self.cpuPercent = cpuPercent; self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes; self.sampleTime = sampleTime
        self.networkRxBytes = networkRxBytes; self.networkTxBytes = networkTxBytes
    }

    var memoryPercent: Double? {
        guard let used = memoryUsageBytes, let limit = memoryLimitBytes, used >= 0, limit > 0 else { return nil }
        return Double(used) / Double(limit) * 100
    }

    var sourceDate: Date? {
        guard let sampleTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: sampleTime) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: sampleTime)
    }

    // The per-container socket uses Docker's stats response. The batch socket uses ResourceSample.
    static func parse(_ data: Data) throws -> Self {
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["cpu_stats"] != nil {
            let cpu = object["cpu_stats"] as? [String: Any] ?? [:]
            let previous = object["precpu_stats"] as? [String: Any] ?? [:]
            let usage = cpu["cpu_usage"] as? [String: Any] ?? [:]
            let oldUsage = previous["cpu_usage"] as? [String: Any] ?? [:]
            let delta = (usage["total_usage"] as? NSNumber)?.doubleValue ?? 0
            let oldDelta = (oldUsage["total_usage"] as? NSNumber)?.doubleValue ?? 0
            let system = (cpu["system_cpu_usage"] as? NSNumber)?.doubleValue ?? 0
            let oldSystem = (previous["system_cpu_usage"] as? NSNumber)?.doubleValue ?? 0
            let count = (cpu["online_cpus"] as? NSNumber)?.doubleValue ?? Double((usage["percpu_usage"] as? [Any])?.count ?? 0)
            let percent: Double? = system > oldSystem && delta >= oldDelta && oldSystem > 0 && count > 0 ? (delta - oldDelta) / (system - oldSystem) * count * 100 : nil
            let memory = object["memory_stats"] as? [String: Any] ?? [:]
            let stats = memory["stats"] as? [String: Any] ?? [:]
            let used = (memory["usage"] as? NSNumber)?.int64Value
            let cache = (stats["total_inactive_file"] as? NSNumber)?.int64Value ?? (stats["inactive_file"] as? NSNumber)?.int64Value ?? 0
            let networks = object["networks"] as? [String: [String: Any]]
            func counter(_ key: String) -> Int64? {
                guard let networks, !networks.isEmpty else { return nil }
                var total: Int64 = 0
                for interface in networks.values {
                    guard let bytes = (interface[key] as? NSNumber)?.int64Value, bytes >= 0 else { return nil }
                    let sum = total.addingReportingOverflow(bytes)
                    guard !sum.overflow else { return nil }
                    total = sum.partialValue
                }
                return total
            }
            return Self(cpuPercent: percent, memoryUsageBytes: used.map { max(0, $0 - cache) },
                        memoryLimitBytes: (memory["limit"] as? NSNumber)?.int64Value, sampleTime: object["read"] as? String,
                        networkRxBytes: counter("rx_bytes"), networkTxBytes: counter("tx_bytes"))
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct ArcaneNetworkTraffic {
    let uploadBytesPerSecond: Double?
    let downloadBytesPerSecond: Double?
    let receivedBytes: Int64?
    let transmittedBytes: Int64?

    init(previous: ArcaneResourceSample?, current: ArcaneResourceSample, elapsed: TimeInterval) {
        func rate(_ old: Int64?, _ new: Int64?) -> Double? {
            guard let old, let new, old >= 0, new >= old, elapsed > 0, elapsed <= 30 else { return nil }
            return Double(new - old) / elapsed
        }
        uploadBytesPerSecond = rate(previous?.networkTxBytes, current.networkTxBytes)
        downloadBytesPerSecond = rate(previous?.networkRxBytes, current.networkRxBytes)
        receivedBytes = current.networkRxBytes
        transmittedBytes = current.networkTxBytes
    }

    static func speed(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "等待采样" }
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB/s", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }
}

enum ArcaneAction: String, Codable, Identifiable {
    case start, stop, restart, redeploy, delete
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .redeploy: return "拉取镜像并重新部署"
        case .delete: return "删除容器"
        }
    }
    var confirmationTitle: String {
        switch self {
        case .start: return "启动容器？"
        case .stop: return "停止容器？"
        case .restart: return "重启容器？"
        case .redeploy: return "拉取镜像并重新部署？"
        case .delete: return "删除容器？"
        }
    }
    var progressTitle: String {
        switch self {
        case .start: return "启动中"
        case .stop: return "停止中"
        case .restart: return "重启中"
        case .redeploy: return "更新中"
        case .delete: return "删除中"
        }
    }
}

struct ArcaneOperationStatus {
    let action: ArcaneAction
    let running: Bool
    var text: String {
        guard running else { return action == .redeploy ? "更新结果待确认" : "\(action.title)结果待确认" }
        return action.progressTitle + "…"
    }
}

struct ArcanePendingOperation: Codable, Identifiable {
    var id = UUID().uuidString
    let connectionID: String
    let environmentID: String
    let environmentName: String
    let containerID: String
    let containerName: String
    let action: ArcaneAction
    var startedAt = Date()
}

struct ArcaneActivity: Decodable, Identifiable {
    let id: String
    let type: String?
    let status: String?
    let resourceId: String?
    let progress: Int?
    let step: String?
    let latestMessage: String?
    let startedAt: String?
}

struct ArcaneActivityDetail: Decodable {
    let activity: ArcaneActivity
    let messages: [Message]?
    struct Message: Decodable { let message: String; let level: String? }
}

enum ArcaneLogDecoder {
    static func lines(_ data: Data) throws -> [String] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String, !error.isEmpty { throw ArcaneFailure(message: "日志流中断：" + String(error.prefix(300))) }
            if let messages = object["messages"] as? [[String: Any]] { return messages.compactMap(line) }
            if let message = line(object) { return [message] }
        }
        if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return objects.compactMap(line) }
        guard let text = String(data: data, encoding: .utf8) else { throw ArcaneFailure(message: "无法读取日志编码。") }
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
    private static func line(_ item: [String: Any]) -> String? {
        guard let message = item["message"] as? String else { return nil }
        return [item["timestamp"] as? String, item["level"] as? String, message].compactMap { $0 }.joined(separator: " ")
    }
}
