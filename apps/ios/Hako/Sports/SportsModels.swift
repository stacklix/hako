import Foundation

struct SportsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SportsRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var date: String
    var type: String
    var distance: Double
    var duration: Int

    static let types = ["Swimming", "Biking", "Hiking", "Walking"]
    var year: String { String(date.prefix(4)) }
    var month: Int { Int(date.dropFirst(4).prefix(2)) ?? 0 }
    var csvRow: [String] { [id.uuidString.lowercased(), date, type, String(distance), String(duration)] }

    static func formatter() -> DateFormatter {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyyMMdd"
        value.isLenient = false
        return value
    }

    func validate(year: String? = nil) throws {
        let format = Self.formatter()
        guard date.range(of: #"^[0-9]{8}$"#, options: .regularExpression) != nil,
              let parsed = format.date(from: date), format.string(from: parsed) == date,
              self.year != "0000", year == nil || year == self.year,
              !type.isEmpty, type == type.trimmingCharacters(in: .whitespacesAndNewlines),
              type.count <= 80, type.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }),
              distance.isFinite, distance >= 0, distance < Double(Int.max), duration > 0 else {
            throw SportsError(message: "运动记录无效，请检查日期、英文类型、距离及正整数分钟时长。")
        }
    }
}

enum SportsCSV {
    static let header = ["id", "date", "type", "distance_km", "duration_minutes"]

    static func decode(_ text: String, year: String) throws -> [SportsRecord] {
        let rows = try CSV.parse(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text)
        guard rows.first == header else { throw SportsError(message: "运动 CSV 表头不兼容，已停止同步，未覆盖本地数据。") }
        var ids = Set<UUID>()
        return try rows.dropFirst().map { row in
            guard row.count == 5, let id = UUID(uuidString: row[0]),
                  let distance = Double(row[3]), let duration = Int(row[4]), ids.insert(id).inserted else {
                throw SportsError(message: "运动 CSV 含无效数据或重复 ID，已停止同步。")
            }
            let record = SportsRecord(id: id, date: row[1], type: row[2], distance: distance, duration: duration)
            try record.validate(year: year)
            return record
        }
    }

    static func encode(_ records: [SportsRecord]) -> String {
        CSV.encode([header] + records.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }.map(\.csvRow))
    }
}

// Operation timestamps and tombstones stay on this device, outside the five-column CSV.
struct SportsOperation: Codable, Equatable, Identifiable {
    var id: UUID { recordID }
    let recordID: UUID
    var record: SportsRecord?
    var operatedAt: Date
    var years: Set<String>
}

struct SportsState: Codable, Equatable {
    var records: [SportsRecord] = []
    var operations: [SportsOperation] = []
    var syncedAt: Date?

    mutating func save(_ record: SportsRecord, at time: Date = .now) throws {
        try record.validate()
        var years = Set([record.year])
        if let old = records.first(where: { $0.id == record.id }) { years.insert(old.year) }
        if let old = operations.first(where: { $0.recordID == record.id }) { years.formUnion(old.years) }
        records.removeAll { $0.id == record.id }
        records.append(record)
        operations.removeAll { $0.recordID == record.id }
        operations.append(SportsOperation(recordID: record.id, record: record, operatedAt: time, years: years))
    }

    mutating func delete(_ id: UUID, at time: Date = .now) {
        guard let old = records.first(where: { $0.id == id }) else { return }
        var years = Set([old.year])
        if let operation = operations.first(where: { $0.recordID == id }) { years.formUnion(operation.years) }
        records.removeAll { $0.id == id }
        operations.removeAll { $0.recordID == id }
        operations.append(SportsOperation(recordID: id, record: nil, operatedAt: time, years: years))
    }

    func validate() throws {
        guard Set(records.map(\.id)).count == records.count,
              Set(operations.map(\.recordID)).count == operations.count else {
            throw SportsError(message: "本地运动数据含重复 ID，已停止处理。")
        }
        try records.forEach { try $0.validate() }
        for op in operations {
            guard !op.years.isEmpty, op.years.allSatisfy({ $0.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil }),
                  op.operatedAt.timeIntervalSince1970.isFinite,
                  op.record == nil || (op.record?.id == op.recordID && op.years.contains(op.record!.year)),
                  op.record == records.first(where: { $0.id == op.recordID }) else {
                throw SportsError(message: "本地运动操作日志无效，已停止同步。")
            }
        }
    }
}

struct SportsRemote {
    var records: [SportsRecord]
    var modifiedAt: [String: Date]
    var existingYears: Set<String>
    var head: String
}

enum SportsMerge {
    static func apply(local: SportsState, remote: SportsRemote) throws -> SportsState {
        try local.validate()
        guard Set(remote.records.map(\.id)).count == remote.records.count else {
            throw SportsError(message: "GitHub 运动记录跨年度存在重复 ID，已停止同步。")
        }
        try remote.records.forEach { try $0.validate() }
        var records = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.id, $0) })
        var retained: [SportsOperation] = []
        for operation in local.operations {
            // A date edit may move a record across files. Treat that as one atomic operation.
            let cutoff = operation.years.compactMap { remote.modifiedAt[$0] }.max() ?? .distantPast
            guard operation.operatedAt > cutoff else { continue }
            records[operation.recordID] = operation.record
            retained.append(operation)
        }
        return SportsState(records: Array(records.values), operations: retained, syncedAt: local.syncedAt)
    }

    static func files(local: SportsState, remote: SportsRemote) -> [String: String] {
        let years = Set(local.records.map(\.year)).union(remote.existingYears)
            .union(local.operations.flatMap(\.years))
        var result: [String: String] = [:]
        for year in years {
            let records = local.records.filter { $0.year == year }
            let old = remote.records.filter { $0.year == year }
            if SportsCSV.encode(records) != SportsCSV.encode(old) {
                result["data/sports/\(year).csv"] = SportsCSV.encode(records)
            }
        }
        return result
    }
}

enum SportsMetric: String, CaseIterable, Identifiable {
    case count, duration, distance
    var id: Self { self }
    var title: String { switch self { case .count: "运动次数"; case .duration: "运动时长"; case .distance: "运动距离" } }
    var unit: String { switch self { case .count: "次"; case .duration: "小时"; case .distance: "km" } }
    func value(_ record: SportsRecord) -> Double {
        switch self { case .count: 1; case .duration: Double(record.duration) / 60; case .distance: record.distance }
    }
}

struct SportsPoint: Identifiable {
    var id: String { "\(type)-\(month)" }
    let type: String
    let month: Int
    let value: Double
}

struct SportsPeriodPoint: Identifiable {
    var id: String { "\(type)|\(period)" }
    let type: String
    // Categorical coordinates keep a real band width for both months and years.
    let period: String
    let value: Double
}

struct SportsChartData {
    let periods: [String]
    let points: [SportsPeriodPoint]

    func values(in period: String) -> [SportsPeriodPoint] { points.filter { $0.period == period } }
}

enum SportsStatistics {
    static func chart(_ records: [SportsRecord], metric: SportsMetric, cumulative: Bool,
                      year: Int?, months: Int = 12) -> SportsChartData {
        let selected = records.filter { year == nil || $0.year == String(year!) }
        let periods = year == nil
            ? Set(selected.map(\.year)).sorted()
            : (1...min(12, max(1, months))).map { "\($0)月" }
        let grouped = Dictionary(grouping: selected) { record in
            year == nil ? record.year : "\(record.month)月"
        }
        let points = Set(selected.map(\.type)).sorted().flatMap { type -> [SportsPeriodPoint] in
            var total = 0.0
            return periods.map { period in
                let value = (grouped[period] ?? []).filter { $0.type == type }.reduce(0) { $0 + metric.value($1) }
                total = cumulative ? total + value : value
                return SportsPeriodPoint(type: type, period: period, value: total)
            }
        }
        return SportsChartData(periods: periods, points: points)
    }

    static func points(_ records: [SportsRecord], metric: SportsMetric, cumulative: Bool, months: Int = 12) -> [SportsPoint] {
        let types = Set(records.map(\.type)).sorted()
        return types.flatMap { type -> [SportsPoint] in
            var total = 0.0
            return (1...max(1, months)).map { month in
                let value = records.filter { $0.type == type && $0.month == month }.reduce(0) { $0 + metric.value($1) }
                total = cumulative ? total + value : value
                return SportsPoint(type: type, month: month, value: total)
            }
        }
    }
}
