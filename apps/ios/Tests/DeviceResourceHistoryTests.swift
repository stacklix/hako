import Foundation

@main struct DeviceResourceHistoryTests {
    static func main() throws {
        let now: Int64 = 1_795_348_800_000
        func sample(_ timestamp: Int64, cpu: Double, peak: Double, count: Int = 1) -> [String: Any] {
            ["timestamp": timestamp, "cpuUsagePercent": cpu, "cpuMaxPercent": peak,
             "memoryUsagePercent": 50, "memoryMaxPercent": 60, "sampleCount": count]
        }
        let rows = [sample(now - 20_000, cpu: 10, peak: 20), sample(now - 10_000, cpu: 90, peak: 100, count: 3)]
        func decode(_ points: [[String: Any]], interval: Int = 10, bucket: Int = 20, last: Int64? = nil) throws -> DeviceResourceHistory {
            try JSONDecoder().decode(DeviceResourceHistory.self, from: JSONSerialization.data(withJSONObject: [
                "collectedAt": now, "from": now - 3_600_000, "to": now, "sampleIntervalSeconds": interval,
                "retentionDays": 7, "bucketSeconds": bucket, "lastSampleAt": last.map { $0 as Any } ?? NSNull(),
                "samplingError": NSNull(), "points": points
            ]))
        }
        let valid = try decode(rows, last: now - 10_000)
        precondition(valid.isValid && valid.sampleCount == 4 && valid.cpuAverage == 70 && valid.memoryAverage == 50)
        let empty = try decode([])
        precondition(empty.isValid)
        for invalid in try [decode(rows, interval: 5), decode(rows, bucket: 5), decode(rows, last: now + 1),
                            decode(Array(rows.reversed())), decode([rows[0], rows[0]]),
                            decode([sample(now, cpu: 101, peak: 100)]), decode([sample(now, cpu: 20, peak: 10)]),
                            decode([sample(now, cpu: 0, peak: 0, count: 0)]), decode([sample(now + 1, cpu: 0, peak: 0)])] {
            precondition(!invalid.isValid)
        }
        precondition(DeviceResourceHistoryRange.allCases.map(\.rawValue) == [3600, 21600, 86400, 604800])
        print("PASS: history decoding, empty history, weighted averages, peaks, ranges and invalid data")
    }
}
