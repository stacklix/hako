import Foundation

struct CryptoWallet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var network = "TRON"
    var address = ""
    func validate() throws {
        let pattern = network == "TRON" ? "^T[1-9A-HJ-NP-Za-km-z]{33}$" : "^0x[0-9a-fA-F]{40}$"
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              address.range(of: pattern, options: .regularExpression) != nil else {
            throw HakoError(message: "请填写名称和所选网络的完整公开地址。")
        }
    }
    var identity: String { network + ":" + (network == "TRON" ? address : address.lowercased()) }
    static func load() throws -> [Self] {
        guard let data = UserDefaults.standard.data(forKey: "crypto.wallets") else { return [] }
        return try JSONDecoder().decode([Self].self, from: data)
    }
    static func save(_ values: [Self]) throws {
        for value in values { try value.validate() }
        guard Set(values.map(\.identity)).count == values.count else { throw HakoError(message: "该网络下已添加此地址。") }
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: "crypto.wallets")
    }
}

enum CryptoDay {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    static func key(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
}

enum CryptoSyncPolicy {
    static func dates(now: Date) -> (today: String, yesterday: String) {
        (CryptoDay.key(now), CryptoDay.key(CryptoDay.calendar.date(byAdding:.day,value:-1,to:now)!))
    }
    static func confirmed(_ records: [CryptoRecord], pending: [CryptoRecord], kind: String, day: String, scope: String) -> Bool {
        records.contains { r in r.kind==kind && r.day==day && r.scope==scope &&
            (kind != "htx-trx" || (r.values["funding_trx"] != nil && r.values["funding_rate"] != nil)) &&
            !pending.contains(where:{$0.id==r.id}) }
    }
}

struct CryptoRecord: Codable, Identifiable, Equatable {
    var kind: String // portfolio or htx-trx
    var day: String
    var sampledAt: Double
    var scope: String
    var values: [String: Double]
    var id: String { kind + "|" + day + "|" + scope }
    var date: Date { Date(timeIntervalSince1970: sampledAt) }
    var path: String { "data/crypto/\(kind)/\(day.prefix(4)).csv" }
    static let columns = ["htx", "binance", "chain", "total", "trx", "price", "liquidation", "liquidation_sampled_at", "funding_trx", "funding_rate", "legacy_contract_equity", "backfill"]
    static let header = ["date", "sampled_at", "scope"] + columns
    static func encode(_ rows: [Self]) -> String {
        CSV.encode([header] + rows.sorted { $0.id < $1.id }.map { r in
            [r.day, String(r.sampledAt), r.scope] + columns.map { r.values[$0].map(String.init(describing:)) ?? "" }
        })
    }
    static func decode(_ text: String, kind: String, year: String) throws -> [Self] {
        let rows = try CSV.parse(text)
        guard rows.first == header else { throw HakoError(message: "资产 CSV 表头不匹配，已停止覆盖。") }
        var ids = Set<String>()
        return try rows.dropFirst().map { row in
            guard row.count == header.count, let time = Double(row[1]), time.isFinite,
                  row[0] == CryptoDay.key(Date(timeIntervalSince1970: time)), row[0].hasPrefix(year + "-"),
                  row[2].count == 64, row[2].allSatisfy({ $0.isHexDigit }) else { throw HakoError(message: "资产 CSV 日期或范围无效。") }
            var values: [String: Double] = [:]
            for (index, name) in columns.enumerated() where !row[index+3].isEmpty {
                guard let value = Double(row[index+3]), value.isFinite else { throw HakoError(message: "资产 CSV 数值无效。") }
                values[name] = value
            }
            let required = kind == "portfolio" ? ["total"] : ["trx", "price"]
            guard required.allSatisfy({ values[$0] != nil }) else { throw HakoError(message: "资产 CSV 缺少必要字段。") }
            let record = Self(kind: kind, day: row[0], sampledAt: time, scope: row[2], values: values)
            guard ids.insert(record.id).inserted else { throw HakoError(message: "资产 CSV 存在重复日期。") }
            return record
        }
    }
    static func merge(_ remote: [Self], _ local: [Self]) -> [Self] {
        var result = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for r in local where r.sampledAt >= (result[r.id]?.sampledAt ?? -.infinity) { result[r.id] = r }
        return result.values.sorted { $0.id < $1.id }
    }
}
