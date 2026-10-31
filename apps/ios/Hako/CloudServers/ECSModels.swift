import Foundation

struct ECSFailure: LocalizedError, Sendable {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
}

struct ECSConnection: Codable, Equatable, Sendable {
    var name = ""
    var region = "cn-hangzhou"
    var instanceID = ""
    var username = "root"
    var accessKeyID = ""
    var accessKeySecret = ""
    var securityToken = ""

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        value.instanceID = instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.accessKeySecret = accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        value.securityToken = securityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.region.range(of: #"^[a-z][a-z0-9-]{1,62}[a-z0-9]$"#, options: .regularExpression) != nil,
              value.instanceID.range(of: #"^i-[A-Za-z0-9]{1,80}$"#, options: .regularExpression) != nil,
              value.username.range(of: #"^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}\$?$"#, options: .regularExpression) != nil else {
            throw ECSFailure(message: "请检查地域 ID、实例 ID 和 Linux 用户名。")
        }
        guard !value.accessKeyID.isEmpty, !value.accessKeySecret.isEmpty,
              value.accessKeyID.count <= 256, value.accessKeySecret.count <= 256, value.securityToken.count <= 16_384,
              ![value.accessKeyID, value.accessKeySecret, value.securityToken].contains(where: { $0.contains(where: { $0.isNewline }) }) else {
            throw ECSFailure(message: "请填写有效的 RAM AccessKey ID 和 Secret，临时凭据还需填写 STS Token。")
        }
        if value.name.isEmpty { value.name = value.instanceID }
        guard value.name.count <= 100 else { throw ECSFailure(message: "连接名称不能超过 100 个字符。") }
        return value
    }
}

struct ECSInstance: Sendable {
    let name: String
    let status: String
    let os: String
    let address: String
    let cpu: Int?
    let memoryMiB: Int?
}

struct ECSMonitorPoint: Identifiable, Sendable {
    var id: Date { time }
    let time: Date
    let cpu: Double?
    let receiveBytesPerSecond: Double?
    let sendBytesPerSecond: Double?
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
}

struct ECSSnapshot: Decodable, Sendable {
    let version: Int
    let time: Double
    let hostname: String?
    let kernel: String?
    let architecture: String?
    let uptime: Double?
    let memoryTotal: Double?
    let memoryAvailable: Double?
    let load: [Double]?
    let disks: [ECSDisk]?
    let interfaces: [ECSInterface]?
    let primaryInterface: String?
    let sockets: [ECSSocket]?
    let socketSummary: ECSConnectionCounts?
    let totalListeningPorts: Int?
    var processes: [ECSProcess]?
    var totalProcesses: Int?
    var nextProcessPID: Int?
    let totalSockets: Int?
    let truncated: Bool?
    let socketError: String?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 24_576 else { throw ECSFailure(message: "系统快照超过返回大小限制，请缩小查询范围。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.time.isFinite, value.time > 0 else { throw ECSFailure(message: "系统快照格式不受支持。") }
        return value
    }

    static func processList(readPage: (Int) async throws -> Self) async throws -> Self {
        try Task.checkCancellation()
        var result = try await readPage(0)
        var page = result
        var rows: [ECSProcess] = []
        var cursor = 0
        while true {
            try Task.checkCancellation()
            guard page.truncated != true, let processes = page.processes else {
                throw ECSFailure(message: "进程列表返回不完整，请刷新重试。")
            }
            var last = cursor
            for process in processes {
                guard process.pid > last else { throw ECSFailure(message: "进程列表分页顺序无效，请刷新重试。") }
                last = process.pid
            }
            rows.append(contentsOf: processes)
            guard let next = page.nextProcessPID else { break }
            guard next > cursor, next == last else { throw ECSFailure(message: "进程列表分页游标无效，请刷新重试。") }
            cursor = next
            page = try await readPage(cursor)
        }
        result.processes = rows
        result.totalProcesses = rows.count
        result.nextProcessPID = nil
        return result
    }
}

struct ECSDisk: Decodable, Identifiable, Sendable {
    var id: String { mount }
    let mount: String
    let filesystem: String
    let total: Double
    let used: Double
    let available: Double
}

struct ECSInterface: Decodable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let receive: Double
    let send: Double
    let receiveRate: Double?
    let sendRate: Double?
    let receiveDrops: Double
    let sendDrops: Double
}

struct ECSSocket: Decodable, Identifiable, Sendable {
    var id: String { "\(protocolName)|\(local)|\(peer)|\(state)|\(pid ?? 0)" }
    let protocolName: String
    let state: String
    let local: String
    let peer: String
    let pid: Int?
    let process: String?
    let direction: String?
    var listening: Bool { state == "LISTEN" || (protocolName == "udp" && state == "UNCONN") }
    var established: Bool { protocolName == "tcp" && ["ESTAB", "ESTABLISHED"].contains(state) }
}

struct ECSConnectionCounts: Decodable, Sendable {
    let outgoing: Int
    let incoming: Int
    let unknown: Int
}

enum ECSProcessGroup: String, CaseIterable, Identifiable {
    case all = "全部", system = "系统", user = "用户", unknown = "未分类"
    var id: String { rawValue }
}

struct ECSProcess: Decodable, Identifiable, Sendable {
    var id: Int { pid }
    let pid: Int
    let parent: Int?
    let name: String
    let user: String
    let uid: Int?
    let category: String
    let source: String?
    let cpu: Double?
    let memory: Double
    let threads: Int?
    let elapsed: Double?
    let executable: String?
    let read: Double?
    let write: Double?
    var group: ECSProcessGroup {
        switch category { case "system": return .system; case "user": return .user; default: return .unknown }
    }
}
