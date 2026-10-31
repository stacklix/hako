import Foundation

struct ConsoleAgent: Decodable, Identifiable {
    let id: String
    let name: String
    let online: Bool
    let lastSeen: String
    let capabilities: [ConsoleAgentCapability]?
}
struct ConsoleAgentCapability: Decodable, Identifiable {
    let name: String
    let version: Int
    var id: String { name }
}
struct ConsoleListenerSnapshot: Decodable {
    let collectedAt: String
    let ports: [ConsoleListenerPort]
    let warnings: [String]
    var isValid: Bool {
        Set(ports.map(\.id)).count == ports.count && ports.allSatisfy(\.isValid)
    }
}
struct ConsoleListenerPort: Decodable, Identifiable {
    let `protocol`: String
    let port: Int
    let processes: [ConsoleListenerProcess]
    var id: String { "\(`protocol`):\(port)" }
    var isValid: Bool {
        ["TCP", "UDP"].contains(`protocol`) && (0...65535).contains(port) && !processes.isEmpty
            && Set(processes.map(\.processId)).count == processes.count && processes.allSatisfy(\.isValid)
    }
}
struct ConsoleListenerProcess: Decodable, Identifiable {
    let processId: Int
    let processName: String?
    let startedAt: String?
    let uptimeSeconds: Int64?
    let addresses: [String]
    var id: Int { processId }
    var displayName: String { processName ?? "进程名称暂不可用" }
    var isValid: Bool {
        processId >= 0 && (uptimeSeconds == nil || uptimeSeconds! >= 0)
            && !addresses.isEmpty && addresses.allSatisfy { !$0.isEmpty }
            && Set(addresses).count == addresses.count
    }
    var formattedUptime: String {
        guard let seconds = uptimeSeconds else { return "暂不可用" }
        let days = seconds / 86400
        let hours = seconds % 86400 / 3600
        let minutes = seconds % 3600 / 60
        let rest = seconds % 60
        return days > 0 ? "\(days) 天 \(hours) 小时 \(minutes) 分 \(rest) 秒" :
            hours > 0 ? "\(hours) 小时 \(minutes) 分 \(rest) 秒" : "\(minutes) 分 \(rest) 秒"
    }
}
struct ConsoleCodexUsage: Decodable {
    let available: Bool
    let collectedAt: String
    let timeZone: String
    let days: [ConsoleCodexUsageDay]
    let runningSessions: Int?
    let runningSessionDetails: [ConsoleCodexRunningSession]?
    let warnings: [String]
    let requestCountKind: String?
    var countsUserMessages: Bool { requestCountKind == "user_messages" }
    var totalCalls: Int64? { Self.sum(days.map(\.requestCount)) }
    var totalTokens: Int64? { Self.sum(days.map(\.totalTokens)) }
    private static func sum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
    var isValid: Bool {
        days.count == 7 && Set(days.map(\.date)).count == 7 && days.allSatisfy(\.isValid)
            && days.map(\.date) == days.map(\.date).sorted()
            && (runningSessions == nil || runningSessions! >= 0)
            && (runningSessionDetails == nil || (runningSessionDetails?.count == runningSessions
                && runningSessionDetails!.allSatisfy(\.isValid)))
            && totalCalls != nil && totalTokens != nil
    }
}
struct ConsoleCodexRunningSession: Decodable {
    let title: String
    let projectName: String
    var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
enum ConsoleCodexChartScale {
    static func maximum(for value: Int64) -> Double {
        guard value > 0 else { return 4 }
        let rawStep = Double(value) / 4
        let magnitude = pow(10, floor(log10(rawStep)))
        let fraction = rawStep / magnitude
        let factor = [1.0, 2.0, 2.5, 5.0, 10.0].first { $0 >= fraction } ?? 10
        return 4 * max(1, ceil(factor * magnitude))
    }
}
struct ConsoleCodexUsageDay: Decodable, Identifiable {
    let date: String
    let requestCount: Int64
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let breakdownAvailable: Bool
    var id: String { date }
    var isValid: Bool {
        date.range(of: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z", options: .regularExpression) != nil
            && requestCount >= 0 && inputTokens >= 0 && outputTokens >= 0 && cachedInputTokens >= 0
            && reasoningOutputTokens >= 0 && totalTokens >= 0
            && (!breakdownAvailable || (cachedInputTokens <= inputTokens && reasoningOutputTokens <= outputTokens
                && inputTokens <= Int64.max - outputTokens && totalTokens == inputTokens + outputTokens))
    }
}
struct ConsoleAgentError: Decodable, Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message.isEmpty ? "设备执行失败（\(code)）。" : message }
}
enum ConsoleAgentReply<Result: Decodable>: Decodable {
    case result(Result)
    case failure(ConsoleAgentError)
    private enum CodingKeys: String, CodingKey { case result, error }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.result) != container.contains(.error) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected result or error"))
        }
        if container.contains(.error) { self = .failure(try container.decode(ConsoleAgentError.self, forKey: .error)) }
        else { self = .result(try container.decode(Result.self, forKey: .result)) }
    }
}
struct ConsoleMetrics: Decodable {
    let cpuUsagePercent: Double
    let memoryUsagePercent: Double
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let sampledAt: String
    let sampleWindowMs: Int
    let network: ConsoleNetworkMetrics?
    let networkReported: Bool
    private enum CodingKeys: String, CodingKey {
        case cpuUsagePercent, memoryUsagePercent, memoryUsedBytes, memoryTotalBytes, sampledAt, sampleWindowMs, network
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cpuUsagePercent = try values.decode(Double.self, forKey: .cpuUsagePercent)
        memoryUsagePercent = try values.decode(Double.self, forKey: .memoryUsagePercent)
        memoryUsedBytes = try values.decode(UInt64.self, forKey: .memoryUsedBytes)
        memoryTotalBytes = try values.decode(UInt64.self, forKey: .memoryTotalBytes)
        sampledAt = try values.decode(String.self, forKey: .sampledAt)
        sampleWindowMs = try values.decode(Int.self, forKey: .sampleWindowMs)
        if values.contains(.network) { networkReported = !(try values.decodeNil(forKey: .network)) }
        else { networkReported = false }
        // A malformed optional network result must not discard valid CPU/memory data.
        network = try? values.decode(ConsoleNetworkMetrics.self, forKey: .network)
    }
    var isValid: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: sampledAt) ?? ISO8601DateFormatter().date(from: sampledAt)
        return date != nil && cpuUsagePercent.isFinite && (0...100).contains(cpuUsagePercent)
            && memoryUsagePercent.isFinite && (0...100).contains(memoryUsagePercent)
            && memoryTotalBytes > 0 && memoryUsedBytes <= memoryTotalBytes && (500...5000).contains(sampleWindowMs)
            && abs(memoryUsagePercent - Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100) < 0.1
    }
}
struct ConsoleNetworkMetrics: Decodable {
    let available: Bool
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let interfaceCount: Int
    let message: String?
    var isValid: Bool {
        interfaceCount >= 0 && (!available || (interfaceCount > 0
            && downloadBytesPerSecond.map { $0.isFinite && $0 >= 0 } == true
            && uploadBytesPerSecond.map { $0.isFinite && $0 >= 0 } == true))
    }
}
// Preserve integer values when presenting unknown query payloads.
enum ConsoleJSON: Codable {
    case object([String: ConsoleJSON]), array([ConsoleJSON]), string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: ConsoleJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([ConsoleJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    func decode<T: Decodable>(_ type: T.Type) -> T? { (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(type, from: $0) } }
    var formatted: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "数据格式无效"
    }
}
struct ConsoleCapabilityData: Decodable {
    let version: Int
    let result: ConsoleJSON?
    let error: ConsoleAgentError?
    private enum CodingKeys: String, CodingKey { case version, result, error }
    init(from decoder: Decoder) throws {
        let parsed: (Int, ConsoleJSON?, ConsoleAgentError?)
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let v = try c.decode(Int.self, forKey: .version)
            guard v > 0, c.contains(.result) != c.contains(.error) else { throw CocoaError(.coderReadCorrupt) }
            if c.contains(.result) {
                parsed = (v, try c.decode(ConsoleJSON.self, forKey: .result), nil)
            } else {
                parsed = (v, nil, try c.decode(ConsoleAgentError.self, forKey: .error))
            }
        } catch {
            parsed = (0, nil, ConsoleAgentError(code: "invalid_data", message: "设备返回的数据格式无效。"))
        }
        version = parsed.0; result = parsed.1; error = parsed.2
    }
}
struct ConsoleQueryResult: Decodable { let data: [String: ConsoleCapabilityData] }
struct ConsoleQueryEnvelope: Decodable {
    let capabilities: [ConsoleAgentCapability]
}
struct ConsoleDeviceData {
    var loading = false
    var loaded = false
    var error: String?
    var entries: [String: ConsoleCapabilityData] = [:]
}
struct ConsoleHTTPCheck: Decodable {
    let url: String
    let reachable: Bool
    let httpSuccess: Bool
    let statusCode: Int?
    let elapsedMs: Int
    let checkedAt: String
    let failure: ConsoleAgentError?
}
struct ConsoleHTTPCheckState {
    var loading = false
    var result: ConsoleHTTPCheck?
    var error: String?
}
