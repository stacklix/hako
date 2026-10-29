import Foundation

struct ArcaneHostStats: Decodable {
    let cpuUsage: Double?
    let cpuCount: Int?
    let memoryUsage: Int64?
    let memoryTotal: Int64?
    let diskUsage: Int64?
    let diskTotal: Int64?
    let architecture: String?
    let platform: String?
    let hostname: String?
    let gpus: [GPU]?

    struct GPU: Decodable {
        let name: String
        let index: Int
        let memoryUsed: Double?
        let memoryTotal: Double?
    }
    var cpuPercent: Double? { Self.percent(cpuUsage) }
    var memoryPercent: Double? { Self.usagePercent(memoryUsage, memoryTotal) }
    var diskPercent: Double? { Self.usagePercent(diskUsage, diskTotal) }

    static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 100)
    }
    static func usagePercent(_ used: Int64?, _ total: Int64?) -> Double? {
        guard let used, let total, used >= 0, total > 0 else { return nil }
        return percent(Double(used) / Double(total) * 100)
    }
    static func parse(_ data: Data) throws -> Self {
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.cpuUsage != nil || value.memoryUsage != nil || value.diskUsage != nil else {
                throw ArcaneFailure(message: "主机资源响应缺少指标，请核对 Arcane 版本。")
            }
            return value
        } catch let error as ArcaneFailure { throw error }
        catch { throw ArcaneFailure(message: "无法解析主机资源数据，请核对 Arcane 版本。") }
    }
}

struct ArcaneHostInfo: Decodable {
    let success: Bool?
    let name: String?
    let operatingSystem: String?
    let kernelVersion: String?
    let architecture: String?
    let osType: String?
    let cpuCount: Int?
    let memoryTotal: Int64?
    let serverVersion: String?
    let apiVersion: String?
    let driver: String?
    let loggingDriver: String?
    let dockerRootDir: String?
    let containers: Int?
    let running: Int?
    let stopped: Int?
    let paused: Int?
    let images: Int?

    enum CodingKeys: String, CodingKey {
        case success, apiVersion
        case name = "Name", operatingSystem = "OperatingSystem", kernelVersion = "KernelVersion"
        case architecture = "Architecture", osType = "OSType", cpuCount = "NCPU", memoryTotal = "MemTotal"
        case serverVersion = "ServerVersion", driver = "Driver", loggingDriver = "LoggingDriver", dockerRootDir = "DockerRootDir"
        case containers = "Containers", running = "ContainersRunning", stopped = "ContainersStopped", paused = "ContainersPaused", images = "Images"
    }
    static func parse(_ data: Data) throws -> Self {
        do {
            // Unlike resource APIs, /system/docker/info returns a flat Docker Info.
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.success != false else { throw ArcaneFailure(message: "Arcane 未能读取 Docker 主机信息。") }
            guard value.name?.isEmpty == false || value.serverVersion?.isEmpty == false || (value.cpuCount ?? 0) > 0 else {
                throw ArcaneFailure(message: "主机信息响应缺少内容，请核对 Arcane 版本。")
            }
            return value
        } catch let error as ArcaneFailure { throw error }
        catch { throw ArcaneFailure(message: "无法解析主机信息，请核对 Arcane 版本。") }
    }
}

enum ArcaneHostFormat {
    static func percent(_ value: Double?) -> String {
        guard let value = ArcaneHostStats.percent(value) else { return "—" }
        return String(format: "%.1f%%", value)
    }
    static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
    static func byteCount(_ value: Double?) -> Int64? {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
    static func usage(_ used: Int64?, _ total: Int64?) -> String {
        "\(bytes(used)) / \(bytes(total.flatMap { $0 > 0 ? $0 : nil }))"
    }
}

struct ArcanePortMapping: Decodable, Identifiable {
    let id: String
    let containerId: String
    let containerName: String
    let hostIp: String?
    let hostPort: Int?
    let containerPort: Int
    let transport: String
    let isPublished: Bool
    enum CodingKeys: String, CodingKey {
        case id, containerId, containerName, hostIp, hostPort, containerPort, isPublished
        case transport = "protocol"
    }
}

struct ArcaneNetworkPort: Identifiable {
    struct Key: Hashable {
        let containerID: String
        let hostPort: Int?
        let containerPort: Int
        let transport: String
    }
    let id: Key
    let addresses: [String]
    var title: String {
        let target = "\(id.containerPort)/\(id.transport)"
        return id.hostPort.map { "\($0) → " + target } ?? target
    }
    var bindingText: String {
        guard id.hostPort != nil else { return "未映射到宿主机" }
        return "绑定：" + addresses.map { $0.isEmpty ? "未指定地址" : $0 }.joined(separator: "、")
    }
}

struct ArcaneContainerPorts: Identifiable {
    let id: String
    let name: String
    let ports: [ArcaneNetworkPort]

    static func summarize(_ mappings: [ArcanePortMapping]) -> [Self] {
        var rows: [ArcaneNetworkPort.Key: Set<String>] = [:]
        var names: [String: Set<String>] = [:]
        for mapping in mappings {
            guard (1...65535).contains(mapping.containerPort) else { continue }
            let host: Int?
            if mapping.isPublished, let port = mapping.hostPort, port != 0 {
                guard (1...65535).contains(port) else { continue }
                host = port
            } else { host = nil }
            let transport = mapping.transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !transport.isEmpty else { continue }
            let key = ArcaneNetworkPort.Key(containerID: mapping.containerId, hostPort: host, containerPort: mapping.containerPort, transport: transport)
            let name = mapping.containerName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !name.isEmpty { names[mapping.containerId, default: []].insert(name) }
            rows[key, default: []].insert(host == nil ? "" : mapping.hostIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let ports = rows.map { ArcaneNetworkPort(id: $0.key, addresses: $0.value.sorted()) }
        return Dictionary(grouping: ports, by: { $0.id.containerID }).map { containerID, ports in
            Self(id: containerID, name: names[containerID]?.sorted().first ?? String(containerID.prefix(12)), ports: ports.sorted {
                if $0.id.containerPort != $1.id.containerPort { return $0.id.containerPort < $1.id.containerPort }
                if $0.id.transport != $1.id.transport { return $0.id.transport < $1.id.transport }
                return ($0.id.hostPort ?? 0) < ($1.id.hostPort ?? 0)
            })
        }.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }
}
