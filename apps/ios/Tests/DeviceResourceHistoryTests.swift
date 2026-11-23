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
        precondition(DeviceResourceHistoryRange.allCases.map(\.rawValue) == [0, 900, 1800, 3600, 21600, 86400, 604800])
        precondition(DeviceResourceHistoryRange.recent.title == "近期趋势")
        precondition(DeviceResourceHistoryRange.recent.parameters["latestPoints"] as? Int == 240)
        precondition(DeviceResourceHistoryRange.recent.parameters["rangeSeconds"] == nil)
        let recent = try decode([sample(now - 1000, cpu: 10, peak: 10), sample(now, cpu: 90, peak: 90)], bucket: 1)
        precondition(DeviceResourceHistoryRange.recent.accepts(recent))
        precondition(!DeviceResourceHistoryRange.recent.accepts(valid))
        precondition(DeviceResourceHistoryRange.fifteenMinutes.title == "15 分钟" && DeviceResourceHistoryRange.thirtyMinutes.title == "30 分钟")
        var live = DeviceResourceHistoryLiveSeries()
        let initialPoints = (0..<240).map { sample(now - Int64(239 - $0) * 1000, cpu: 10, peak: 10) }
        live.seed(try decode(initialPoints, bucket: 1, last: now))
        live.append(.init(timestamp: now, cpu: 80, memory: 60))
        live.append(.init(timestamp: now - 1, cpu: 80, memory: 60))
        precondition(live.history?.sampleCount == 240 && live.history?.points.last?.cpuUsagePercent == 10,
            "Replayed and out-of-order live events must not duplicate or rewrite historical samples")
        live.append(.init(timestamp: now + 1000, cpu: 80, memory: 60))
        precondition(live.history?.isValid == true && live.history?.points.count == 240)
        precondition(live.history?.from == now - 238_000 && live.history?.to == now + 1000)
        precondition(live.history?.points.last?.cpuUsagePercent == 80 && live.history?.points.last?.memoryUsagePercent == 60)
        live.append(.init(timestamp: now + 10_000, cpu: 30, memory: 40))
        precondition(live.history?.points.suffix(2).map(\.timestamp) == [now + 1000, now + 10_000],
            "Disconnected intervals must remain gaps without fabricated samples")
        for bad in [DeviceResourceHistorySample(timestamp: now + 11_000, cpu: .nan, memory: 50),
                    .init(timestamp: now + 11_000, cpu: 10, memory: 101), .init(timestamp: -1, cpu: 10, memory: 50)] {
            live.append(bad)
        }
        precondition(live.history?.to == now + 10_000)
        var pending = DeviceResourceHistoryLiveSeries()
        pending.append(.init(timestamp: now + 1000, cpu: 80, memory: 60))
        precondition(pending.history?.points.count == 1 && pending.history?.isValid == true,
            "A valid live sample can draw the chart even before the initial history response")
        pending.seed(try decode([sample(now, cpu: 20, peak: 20)], bucket: 1, last: now))
        precondition(pending.history?.points.count == 2 && pending.history?.to == now + 1000,
            "A delayed initial history response must preserve newer received live samples")
        pending.seed(try decode([sample(now, cpu: 20, peak: 20)], bucket: 1, last: now))
        precondition(pending.history?.points.count == 2 && pending.history?.sampleCount == 2,
            "Reseeding must not count a buffered live sample twice")
        var grouped = DeviceResourceHistoryLiveSeries(range: .fifteenMinutes)
        grouped.seed(try decode([sample(now, cpu: 20, peak: 30, count: 2)], bucket: 4, last: now, range: 900))
        grouped.append(.init(timestamp: now + 1000, cpu: 80, memory: 80))
        precondition(grouped.history?.points.last?.cpuUsagePercent == 40
            && grouped.history?.points.last?.memoryUsagePercent == 60 && grouped.history?.sampleCount == 3,
            "Live samples must update a time bucket with sample-count weighted CPU and memory averages")
        grouped.append(.init(timestamp: now + 4000, cpu: 60, memory: 70))
        precondition(grouped.history?.points.count == 2 && grouped.history?.points.last?.timestamp == now + 4000)
        precondition(grouped.history?.isValid == true && grouped.history?.to == now + 4000
            && grouped.history?.from == now + 4000 - 900_000)
        grouped.append(.init(timestamp: now + 910_000, cpu: 60, memory: 70))
        precondition(grouped.history?.points.count == 1 && grouped.history?.sampleCount == 1,
            "Expired historical buckets must leave the rolling time window")
        for range in DeviceResourceHistoryRange.allCases {
            var bounded = DeviceResourceHistoryLiveSeries(range: range)
            for index in 0..<1000 {
                bounded.append(.init(timestamp: now + Int64(index) * 5000, cpu: 20, memory: 60))
            }
            precondition(bounded.history?.isValid == true && (bounded.history?.points.count ?? 0) <= 240)
        }
        precondition(DeviceResourceHistorySample(sampledAt: "2026-11-23T15:00:00.123Z", cpu: 20, memory: 60) != nil)
        precondition(DeviceResourceHistorySample(sampledAt: "2026-11-23T15:00:00Z", cpu: 20, memory: 60) != nil)
        precondition(DeviceResourceHistorySample(sampledAt: "invalid", cpu: 20, memory: 60) == nil)
        let gapHistory = try decode([sample(now - 10_000, cpu: 20, peak: 20), sample(now, cpu: 90, peak: 90)], bucket: 1)
        let filled = gapHistory.displayPoints(for: .recent)
        precondition(filled.count == 3 && filled[1].carried && filled[1].timestamp == now
            && filled[1].source.timestamp == now - 10_000 && filled[1].source.cpuUsagePercent == 20,
            "A missing interval must hold the previous observed value until the next real sample")
        precondition(Set(filled.map(\.id)).count == filled.count && !filled[2].carried
            && filled[2].source.cpuUsagePercent == 90)
        let insideGap = gapHistory.displayPoint(at: DeviceResourceHistory.date(now - 2000), for: .recent)
        precondition(insideGap?.carried == true && insideGap?.source.cpuUsagePercent == 20,
            "Selecting a filled interval must show its previous value, not a future sample")
        precondition(gapHistory.displayPoint(at: DeviceResourceHistory.date(now), for: .recent)?.carried == false)
        precondition(gapHistory.sampleCount == 2 && gapHistory.cpuAverage == 55 && gapHistory.points.count == 2,
            "Display-only carry-forward must not alter real counts, averages or historical data")
        let trailing = try decode([sample(now - 10_000, cpu: 20, peak: 20)], bucket: 1)
        precondition(trailing.displayPoints(for: .recent).last?.timestamp == now
            && trailing.displayPoints(for: .recent).last?.carried == true)
        precondition(trailing.displayPoint(at: DeviceResourceHistory.date(now - 1000), for: .recent)?.carried == true)
        let emptyDisplay = try decode([], bucket: 1)
        precondition(emptyDisplay.displayPoints(for: .recent).isEmpty)
        precondition(recent.displayPoints(for: .recent).allSatisfy { !$0.carried },
            "Normal consecutive samples must keep their existing line display")
        print("PASS: history validation, live append, bounded windows, deduplication, gaps, weighted buckets and delayed history merge")
    }
}
