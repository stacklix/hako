import Foundation

enum DeviceResourceHistoryCommand {
    static let name = "query.system.metrics.history"
}

enum DeviceResourceHistoryRange: Int, CaseIterable, Identifiable {
    case recent = 0, fifteenMinutes = 900, thirtyMinutes = 1800, hour = 3600, sixHours = 21600, day = 86400, week = 604800
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .recent: "近期趋势"
        case .fifteenMinutes: "15 分钟"
        case .thirtyMinutes: "30 分钟"
        case .hour: "1 小时"
        case .sixHours: "6 小时"
        case .day: "24 小时"
        case .week: "7 天"
        }
    }

    var parameters: [String: Any] {
        self == .recent ? ["latestPoints": 240] : ["rangeSeconds": rawValue]
    }

    func accepts(_ history: DeviceResourceHistory) -> Bool {
        guard history.isValid else { return false }
        if self == .recent {
            return history.bucketSeconds == 1 && history.points.allSatisfy { $0.sampleCount == 1 }
        }
        return history.to - history.from == Int64(rawValue) * 1000
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
        from >= 0 && to >= from && to <= collectedAt && retentionDays == 7 && sampleIntervalSeconds == 1
            && bucketSeconds >= sampleIntervalSeconds && bucketSeconds <= 2520
            && bucketSeconds % sampleIntervalSeconds == 0 && to - from <= 604_800_000
            && points.count <= 240 && lastSampleAt.map { $0 >= collectedAt - 604_800_000 && $0 <= collectedAt } != false
            && points.allSatisfy { $0.isValid && $0.timestamp >= from && $0.timestamp <= to }
            && zip(points, points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp }
    }
    var sampleCount: Int { points.reduce(0) { $0 + $1.sampleCount } }
    var bucketDurationText: String {
        let minutes = bucketSeconds / 60, seconds = bucketSeconds % 60
        if minutes == 0 { return "\(seconds) 秒" }
        return seconds == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(seconds) 秒"
    }
    func interval(for point: DeviceResourceHistoryPoint) -> DateInterval {
        DateInterval(start: point.date, end: Self.date(min(to, point.timestamp + Int64(bucketSeconds) * 1000)))
    }
    var cpuAverage: Double {
        guard sampleCount > 0 else { return 0 }
        return points.reduce(0) { $0 + $1.cpuUsagePercent * Double($1.sampleCount) } / Double(sampleCount)
    }
    var memoryAverage: Double {
        guard sampleCount > 0 else { return 0 }
        return points.reduce(0) { $0 + $1.memoryUsagePercent * Double($1.sampleCount) } / Double(sampleCount)
    }
    private func displayGap(for range: DeviceResourceHistoryRange) -> Int64 {
        Int64(bucketSeconds) * (range == .recent ? 1500 : 1000)
    }
    func displayPoints(for range: DeviceResourceHistoryRange) -> [DeviceResourceHistoryDisplayPoint] {
        var displayed: [DeviceResourceHistoryDisplayPoint] = []
        var previous: DeviceResourceHistoryPoint?
        for point in points {
            if let previous, point.timestamp - previous.timestamp > displayGap(for: range) {
                // One extra endpoint holds the previous value across a gap;
                // the actual next point then supplies the new value at that time.
                displayed.append(.init(timestamp: point.timestamp, source: previous, carried: true))
            }
            displayed.append(.init(timestamp: point.timestamp, source: point, carried: false))
            previous = point
        }
        if let previous, to - previous.timestamp > displayGap(for: range) {
            displayed.append(.init(timestamp: to, source: previous, carried: true))
        }
        return displayed
    }
    func displayPoint(at date: Date, for range: DeviceResourceHistoryRange) -> DeviceResourceHistoryDisplayPoint? {
        let time = date.timeIntervalSince1970 * 1000
        let duration = Double(bucketSeconds) * 1000
        for (previous, next) in zip(points, points.dropFirst()) {
            if next.timestamp - previous.timestamp > displayGap(for: range),
               time >= Double(previous.timestamp) + duration, time < Double(next.timestamp) {
                return .init(timestamp: Int64(time), source: previous, carried: true)
            }
        }
        if let last = points.last, to - last.timestamp > displayGap(for: range),
           time >= Double(last.timestamp) + duration, time <= Double(to) {
            return .init(timestamp: Int64(time), source: last, carried: true)
        }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            .map { .init(timestamp: $0.timestamp, source: $0, carried: false) }
    }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}

struct DeviceResourceHistoryDisplayPoint: Identifiable {
    let timestamp: Int64
    let source: DeviceResourceHistoryPoint
    let carried: Bool
    var id: String { "\(timestamp)-\(carried)" }
    var date: Date { DeviceResourceHistory.date(timestamp) }
}

struct DeviceResourceHistoryPoint: Decodable, Identifiable {
    let timestamp: Int64
    let cpuUsagePercent: Double
    let cpuMaxPercent: Double
    let memoryUsagePercent: Double
    let memoryMaxPercent: Double
    let sampleCount: Int
    let cpuSmoothedMaxPercent: Double
    let memorySmoothedMaxPercent: Double
    var id: Int64 { timestamp }
    var date: Date { DeviceResourceHistory.date(timestamp) }
    var isValid: Bool {
        sampleCount > 0 && sampleCount <= 604_801
            && [cpuUsagePercent, cpuMaxPercent, memoryUsagePercent, memoryMaxPercent, cpuSmoothedMaxPercent, memorySmoothedMaxPercent]
            .allSatisfy { $0.isFinite && (0...100).contains($0) }
            && cpuMaxPercent + 0.000001 >= cpuUsagePercent && memoryMaxPercent + 0.000001 >= memoryUsagePercent
    }
}

struct DeviceResourceHistorySample: Equatable {
    let timestamp: Int64
    let cpu: Double
    let memory: Double

    init(timestamp: Int64, cpu: Double, memory: Double) {
        self.timestamp = timestamp; self.cpu = cpu; self.memory = memory
    }

    init?(sampledAt: String, cpu: Double, memory: Double) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: sampledAt) ?? ISO8601DateFormatter().date(from: sampledAt) else { return nil }
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, (0...253_402_300_799_999).contains(milliseconds) else { return nil }
        self.init(timestamp: Int64(milliseconds), cpu: cpu, memory: memory)
        guard isValid else { return nil }
    }

    var isValid: Bool {
        (0...253_402_300_799_999).contains(timestamp)
            && [cpu, memory].allSatisfy { $0.isFinite && (0...100).contains($0) }
    }
}

struct DeviceResourceHistoryLiveSeries {
    let range: DeviceResourceHistoryRange
    private(set) var history: DeviceResourceHistory?
    private var bucketOrigin: Int64 = 0
    private var lastTimestamp: Int64?
    private var liveSamples: [DeviceResourceHistorySample] = []

    init(range: DeviceResourceHistoryRange = .recent) { self.range = range }

    mutating func seed(_ snapshot: DeviceResourceHistory) {
        // A response may arrive after newer live samples. Replay only samples
        // beyond its query boundary, so neither samples nor counts are doubled.
        let pending = liveSamples
        history = snapshot; bucketOrigin = snapshot.from; lastTimestamp = snapshot.to
        liveSamples = []
        for sample in pending { append(sample) }
    }

    mutating func append(_ sample: DeviceResourceHistorySample) {
        guard sample.isValid, lastTimestamp.map({ sample.timestamp > $0 }) != false else { return }
        lastTimestamp = sample.timestamp
        liveSamples.append(sample)
        if liveSamples.count > 240 { liveSamples.removeFirst(liveSamples.count - 240) }
        let bucketSeconds = range == .recent ? 1 : Int(ceil(Double(range.rawValue) / 240))
        if history == nil {
            bucketOrigin = range == .recent ? sample.timestamp : max(0, sample.timestamp - Int64(range.rawValue) * 1000)
            history = DeviceResourceHistory(collectedAt: sample.timestamp, from: bucketOrigin, to: sample.timestamp,
                sampleIntervalSeconds: 1, retentionDays: 7, bucketSeconds: bucketSeconds,
                lastSampleAt: nil, samplingError: nil, points: [])
        }
        guard let current = history else { return }
        let duration = Int64(current.bucketSeconds) * 1000
        let timestamp = range == .recent ? sample.timestamp
            : bucketOrigin + (sample.timestamp - bucketOrigin) / duration * duration
        var points = current.points
        if range != .recent, let last = points.last, last.timestamp == timestamp {
            let count = last.sampleCount + 1
            points[points.count - 1] = DeviceResourceHistoryPoint(timestamp: timestamp,
                cpuUsagePercent: (last.cpuUsagePercent * Double(last.sampleCount) + sample.cpu) / Double(count),
                cpuMaxPercent: max(last.cpuMaxPercent, sample.cpu),
                memoryUsagePercent: (last.memoryUsagePercent * Double(last.sampleCount) + sample.memory) / Double(count),
                memoryMaxPercent: max(last.memoryMaxPercent, sample.memory), sampleCount: count,
                cpuSmoothedMaxPercent: last.cpuSmoothedMaxPercent, memorySmoothedMaxPercent: last.memorySmoothedMaxPercent)
        } else {
            points.append(DeviceResourceHistoryPoint(timestamp: timestamp,
                cpuUsagePercent: sample.cpu, cpuMaxPercent: sample.cpu,
                memoryUsagePercent: sample.memory, memoryMaxPercent: sample.memory, sampleCount: 1,
                cpuSmoothedMaxPercent: sample.cpu, memorySmoothedMaxPercent: sample.memory))
        }
        let from = range == .recent ? 0 : max(0, sample.timestamp - Int64(range.rawValue) * 1000)
        // Already aggregated historical buckets cannot be split accurately.
        // Drop a bucket once its start leaves the window, without inventing a
        // partial average or filling any unreceived live samples.
        points.removeAll { $0.timestamp < from }
        points = Array(points.suffix(240))
        history = DeviceResourceHistory(collectedAt: sample.timestamp,
            from: range == .recent ? (points.first?.timestamp ?? sample.timestamp) : from, to: sample.timestamp,
            sampleIntervalSeconds: 1, retentionDays: 7, bucketSeconds: current.bucketSeconds,
            lastSampleAt: sample.timestamp, samplingError: current.samplingError, points: points)
    }
}
