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
