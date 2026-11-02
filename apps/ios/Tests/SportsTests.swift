import Foundation

@main struct SportsTests {
    static func main() throws {
        func expect(_ condition: @autoclosure () throws -> Bool) throws { let value = try condition(); precondition(value) }
        let cutoff = Date(timeIntervalSince1970: 100)
        let older = Date(timeIntervalSince1970: 99)
        let newer = Date(timeIntervalSince1970: 101)
        let id = UUID()
        let original = SportsRecord(id: id, date: "20260101", type: "Swimming", distance: 1.05, duration: 69)
        let another = SportsRecord(id: UUID(), date: "20260101", type: "Biking", distance: 4.56, duration: 32)
        var changed = original; changed.distance = 2
        let remote = SportsRemote(records: [original, another], modifiedAt: ["2026": cutoff], existingYears: ["2026"], head: "head")

        let decoded = try SportsCSV.decode(SportsCSV.encode([original, another]), year: "2026")
        precondition(Set(decoded.map(\.id)) == Set([id, another.id]))
        precondition(decoded.first(where: { $0.id == id }) == original)
        precondition(SportsCSV.header == ["id", "date", "type", "distance_km", "duration_minutes"])
        for time in [older, cutoff, newer] {
            var state = SportsState(records: [original])
            try state.save(changed, at: time)
            let merged = try SportsMerge.apply(local: state, remote: remote)
            precondition(merged.records.first(where: { $0.id == id }) == (time > cutoff ? changed : original))
            precondition(merged.operations.count == (time > cutoff ? 1 : 0))
            precondition(merged.records.contains(another))
            state.delete(id, at: time)
            let deleted = try SportsMerge.apply(local: state, remote: remote)
            precondition(deleted.records.contains(where: { $0.id == id }) == (time <= cutoff))
        }

        var staleCache = SportsState(records: [changed])
        let authoritative = try SportsMerge.apply(local: staleCache, remote: remote)
        precondition(authoritative.records.contains(original))
        let empty = SportsRemote(records: [], modifiedAt: ["2026": cutoff], existingYears: [], head: "deleted")
        try expect(try SportsMerge.apply(local: staleCache, remote: empty).records.isEmpty)
        try staleCache.save(changed, at: newer)
        try expect(try SportsMerge.apply(local: staleCache, remote: empty).records == [changed])

        // Adds are timestamped too; stale unsynced additions must not reappear.
        for time in [older, cutoff, newer] {
            var local = SportsState()
            try local.save(changed, at: time)
            let merged = try SportsMerge.apply(local: local, remote: empty)
            precondition(merged.records.isEmpty == (time <= cutoff))
        }
        // No path history means a genuinely new annual file, independent of other repo commits.
        let missing = SportsRemote(records: [], modifiedAt: [:], existingYears: [], head: "head")
        var added = SportsState()
        try added.save(original, at: older)
        let created = try SportsMerge.apply(local: added, remote: missing)
        precondition(created.records == [original])
        precondition(SportsMerge.files(local: created, remote: missing).keys.sorted() == ["data/sports/2026.csv"])

        // Move dates across years atomically, retaining the same ID and both touched paths.
        var moved = original; moved.date = "20250101"
        var moving = SportsState(records: [original])
        try moving.save(moved, at: newer)
        precondition(moving.operations[0].years == ["2025", "2026"])
        let movedState = try SportsMerge.apply(local: moving, remote: remote)
        let files = SportsMerge.files(local: movedState, remote: remote)
        precondition(Set(files.keys) == ["data/sports/2025.csv", "data/sports/2026.csv"])
        try expect(try SportsCSV.decode(files["data/sports/2025.csv"]!, year: "2025") == [moved])
        try expect(try SportsCSV.decode(files["data/sports/2026.csv"]!, year: "2026") == [another])
        var newerDestination = remote; newerDestination.modifiedAt["2025"] = newer
        let rejectedMove = try SportsMerge.apply(local: moving, remote: newerDestination)
        precondition(rejectedMove.operations.isEmpty && rejectedMove.records.contains(original))

        moving.delete(id, at: newer)
        precondition(moving.operations[0].years == ["2025", "2026"] && moving.operations[0].record == nil)
        let persisted = try JSONDecoder().decode(SportsState.self, from: JSONEncoder().encode(moving))
        precondition(persisted == moving)
        try persisted.validate()
        // A successful local pull can be retained on upload failure without clearing its journal.
        let pending = try SportsMerge.apply(local: persisted, remote: remote)
        precondition(pending.operations.count == 1 && !pending.records.contains(where: { $0.id == id }))
        precondition(SportsMerge.files(local: SportsState(records: remote.records), remote: remote).isEmpty)

        let invalidRows = [
            ["invalid-id", "20260101", "Swimming", "1", "20"],
            [id.uuidString, "20260230", "Swimming", "1", "20"],
            [id.uuidString, "20250101", "Swimming", "1", "20"],
            [id.uuidString, "20260101", "Swimming", "nan", "20"],
            [id.uuidString, "20260101", "Swimming", "-1", "20"],
            [id.uuidString, "20260101", "Swimming", "1", "0"],
            [id.uuidString, "20260101", "Swimming", "1", "1.5"],
            [id.uuidString, "20260101", "游泳", "1", "20"],
            [id.uuidString, "20260101", "Swimming", "1"]
        ]
        for row in invalidRows {
            do { _ = try SportsCSV.decode(CSV.encode([SportsCSV.header, row]), year: "2026"); fatalError("Accepted invalid record") }
            catch is SportsError { }
        }
        do { _ = try SportsCSV.decode(SportsCSV.encode([original, original]), year: "2026"); fatalError("Duplicate ID") }
        catch is SportsError { }
        var duplicated = remote; duplicated.records.append(original)
        do { _ = try SportsMerge.apply(local: SportsState(), remote: duplicated); fatalError("Duplicate remote ID") }
        catch is SportsError { }

        // Chart values use minutes -> hours and preserve type-specific running totals.
        let count = SportsStatistics.points([original, another], metric: .count, cumulative: false)
        precondition(count.filter { $0.month == 1 }.reduce(0) { $0 + $1.value } == 2)
        let hours = SportsStatistics.points([original], metric: .duration, cumulative: true)
        precondition(abs(hours.last!.value - 1.15) < 0.00001)
        precondition(SportsStatistics.points([original], metric: .distance, cumulative: false).last!.value == 0)
        print("Sports tests passed: CSV, IDs, timestamps, tombstones, cross-year moves, persistence and charts")
    }
}
