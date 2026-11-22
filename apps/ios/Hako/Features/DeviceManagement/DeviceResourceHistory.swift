import Foundation

enum DeviceResourceHistoryCommand {
    static let name = "query.system.metrics.history"
}

enum DeviceResourceHistoryRange: Int, CaseIterable, Identifiable {
    case hour = 3600, sixHours = 21600, day = 86400, week = 604800
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .hour: "1 小时"
        case .sixHours: "6 小时"
        case .day: "24 小时"
        case .week: "7 天"
        }
    }
}

struct DeviceResourceHistory: Decodable {
    let collectedAt: Int64
    let from: Int64
    let to: Int64
    let sampleIntervalSeconds: Int
    let retentionDays: Int
    let bucketSeconds: Int
    let lastSampleAt: Int64?
    let samplingError: String?
    let points: [DeviceResourceHistoryPoint]

    var isValid: Bool {
        from >= 0 && to >= from && to <= collectedAt && retentionDays == 7 && sampleIntervalSeconds == 10
            && bucketSeconds >= sampleIntervalSeconds && bucketSeconds <= 2520
            && bucketSeconds % sampleIntervalSeconds == 0 && to - from <= 604_800_000
            && points.count <= 240 && lastSampleAt.map { $0 >= collectedAt - 604_800_000 && $0 <= collectedAt } != false
            && points.allSatisfy { $0.isValid && $0.timestamp >= from && $0.timestamp <= to }
            && zip(points, points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp }
    }
    var sampleCount: Int { points.reduce(0) { $0 + $1.sampleCount } }
    var cpuAverage: Double {
        guard sampleCount > 0 else { return 0 }
        return points.reduce(0) { $0 + $1.cpuUsagePercent * Double($1.sampleCount) } / Double(sampleCount)
    }
    var memoryAverage: Double {
        guard sampleCount > 0 else { return 0 }
        return points.reduce(0) { $0 + $1.memoryUsagePercent * Double($1.sampleCount) } / Double(sampleCount)
    }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}

struct DeviceResourceHistoryPoint: Decodable, Identifiable {
    let timestamp: Int64
    let cpuUsagePercent: Double
    let cpuMaxPercent: Double
    let memoryUsagePercent: Double
    let memoryMaxPercent: Double
    let sampleCount: Int
    var id: Int64 { timestamp }
    var date: Date { DeviceResourceHistory.date(timestamp) }
    var isValid: Bool {
        sampleCount > 0 && sampleCount <= 60_481 && [cpuUsagePercent, cpuMaxPercent, memoryUsagePercent, memoryMaxPercent]
            .allSatisfy { $0.isFinite && (0...100).contains($0) }
            && cpuMaxPercent + 0.000001 >= cpuUsagePercent && memoryMaxPercent + 0.000001 >= memoryUsagePercent
    }
}
