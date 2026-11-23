import Foundation

@main struct DeviceResourceHistoryTests {
    static func main() throws {
        let now: Int64 = 1_795_348_800_000
        func sample(_ timestamp: Int64, cpu: Double, peak: Double, count: Int = 1, smoothed: Double = 30) -> [String: Any] {
            ["timestamp": timestamp, "cpuUsagePercent": cpu, "cpuMaxPercent": peak,
             "memoryUsagePercent": 50, "memoryMaxPercent": 60, "sampleCount": count,
             "cpuSmoothedMaxPercent": smoothed, "memorySmoothedMaxPercent": 55]
        }
        let rows = [sample(now - 15_000, cpu: 10, peak: 20), sample(now, cpu: 90, peak: 100, count: 3)]
        func decode(_ points: [[String: Any]], interval: Int = 1, bucket: Int = 15, last: Int64? = nil, range: Int64 = 3600) throws -> DeviceResourceHistory {
            try JSONDecoder().decode(DeviceResourceHistory.self, from: JSONSerialization.data(withJSONObject: [
                "collectedAt": now, "from": now - range * 1000, "to": now, "sampleIntervalSeconds": interval,
                "retentionDays": 7, "bucketSeconds": bucket, "lastSampleAt": last.map { $0 as Any } ?? NSNull(),
                "samplingError": NSNull(), "points": points
            ]))
        }
        let valid = try decode(rows, last: now)
        precondition(valid.isValid && valid.sampleCount == 4 && valid.cpuAverage == 70 && valid.memoryAverage == 50)
        precondition(valid.points[0].cpuSmoothedMaxPercent == 30 && valid.points[0].memorySmoothedMaxPercent == 55,
            "Five-second windows may include samples before the bucket; their means can exceed this bucket's raw peak")
        let empty = try decode([])
        precondition(empty.isValid)
        let quarterHour = try decode(rows, bucket: 4, range: 900)
        let halfHour = try decode(rows, bucket: 8, range: 1800)
        precondition(quarterHour.isValid && halfHour.isValid && quarterHour.to - quarterHour.from == 900_000
                     && halfHour.to - halfHour.from == 1_800_000)
        precondition(quarterHour.bucketDurationText == "4 秒" && halfHour.bucketDurationText == "8 秒")
        let fullBucket = quarterHour.interval(for: quarterHour.points[0])
        precondition(fullBucket.start == quarterHour.points[0].date && fullBucket.duration == 4)
        let partial = try decode([sample(now - 2_000, cpu: 10, peak: 20)], bucket: 4, range: 900)
        precondition(partial.interval(for: partial.points[0]).duration == 2,
                     "The last point's interval must stop at the query end, not extend into the future")
        precondition(quarterHour.interval(for: quarterHour.points[1]).duration == 0)
        let durationLabels = try [decode([], bucket: 90).bucketDurationText,
                                  decode([], bucket: 360).bucketDurationText,
                                  decode([], bucket: 2520).bucketDurationText]
        precondition(durationLabels == ["1 分 30 秒", "6 分钟", "42 分钟"])
        for invalid in try [decode(rows, interval: 0), decode(rows, bucket: 0), decode(rows, last: now + 1),
                            decode(Array(rows.reversed())), decode([rows[0], rows[0]]),
                            decode([sample(now, cpu: 101, peak: 100)]), decode([sample(now, cpu: 20, peak: 10)]),
                            decode([sample(now, cpu: 0, peak: 0, count: 0)]), decode([sample(now + 1, cpu: 0, peak: 0)]),
                            decode([sample(now, cpu: 10, peak: 20, smoothed: -1)]),
                            decode([sample(now, cpu: 10, peak: 20, smoothed: 101)])] {
            precondition(!invalid.isValid)
        }
        precondition(DeviceResourceHistoryRange.allCases.map(\.rawValue) == [900, 1800, 3600, 21600, 86400, 604800])
        precondition(DeviceResourceHistoryRange.fifteenMinutes.title == "15 分钟" && DeviceResourceHistoryRange.thirtyMinutes.title == "30 分钟")
        print("PASS: history decoding, empty history, weighted averages, peaks, ranges and invalid data")
    }
}
