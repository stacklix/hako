import Foundation

struct CryptoBinanceAsset: Codable, Identifiable, Equatable {
    var symbol: String
    var name: String
    var free: Double
    var locked: Double
    var frozen: Double
    var withdrawing: Double
    var unitPrice: Double? = nil
    var equityUSDPrice: Double? = nil
    var equitySymbol: String? {
        let code=symbol.uppercased()
        return code.hasPrefix("EQ_") && code.count > 3 ? String(code.dropFirst(3)) : nil
    }
    var id: String { symbol }
    var quantity: Double { free + locked + frozen + withdrawing }
    var price: Double? {
        if ["USDT","USD"].contains(symbol) { return 1 }
        return equitySymbol == nil ? unitPrice : equityUSDPrice
    }
    var usdtValue: Double? {
        guard let price, price.isFinite, price > 0 else { return nil }
        let value=quantity * price
        return value.isFinite ? value : nil
    }
    var isVisible: Bool { quantity != 0 && (usdtValue.map { abs($0) >= 1 } ?? true) }
}

struct CryptoBinanceAccount: Codable, Identifiable, Equatable {
    var name: String
    var balance: Double
    var assets: [CryptoBinanceAsset]?
    var id: String { name }
    var currentBalance: Double {
        guard let assets,!assets.isEmpty else { return balance }
        let values=assets.compactMap(\.usdtValue)
        guard values.count == assets.count else { return balance }
        let total=values.reduce(0,+)
        return total.isFinite ? total : balance
    }
    var visibleAssets: [CryptoBinanceAsset]? { assets.map { $0.filter(\.isVisible) } }
    var isVisible: Bool { visibleAssets.map { !$0.isEmpty } ?? (balance != 0) }
}

struct CryptoBinanceSnapshot: Codable, Equatable {
    var scope: String
    var sampledAt: Date
    var accounts: [CryptoBinanceAccount]
    var quoteError: String? = nil
    var total: Double { accounts.reduce(0) { $0 + $1.currentBalance } }
    var visibleAccounts: [CryptoBinanceAccount] { accounts.filter(\.isVisible) }
}

struct CryptoWalletAsset: Codable, Identifiable, Equatable {
    static func isIncluded(_ symbol:String) -> Bool {
        ["BTC","ETH","ATOM","TRX","USDT","USDC"].contains(symbol.trimmingCharacters(in:.whitespacesAndNewlines).uppercased())
    }
    var id: String
    var symbol: String
    var name: String
    var quantity: Double
    var value: Double?
}

struct CryptoWalletSnapshot: Codable, Equatable {
    var total: Double
    var assets: [CryptoWalletAsset]
    var sampledAt: Date = .now
    var includedOnly: Self {
        let selected=assets.filter { CryptoWalletAsset.isIncluded($0.symbol) }.map { asset in
            var asset = asset
            // Shorten the native asset names already saved in existing snapshots.
            switch (asset.symbol, asset.name) {
            case ("TRX", "TRON（含质押及解质押资产）"): asset.name = "TRON"
            case ("ATOM", "Cosmos Hub（含质押、解押及奖励）"): asset.name = CryptoWallet.cosmosHub
            default: break
            }
            return asset
        }
        return Self(total:selected.compactMap(\.value).reduce(0,+),assets:selected,sampledAt:sampledAt)
    }
}

struct CryptoWallet: Codable, Identifiable, Equatable {
    static let cosmosHub = "Cosmos Hub"
    static let networks = ["TRON", "Ethereum", "BNB Smart Chain", cosmosHub]
    var id = UUID()
    var name = ""
    var network = "TRON"
    var address = ""
    func validate() throws {
        guard Self.networks.contains(network) else {
            throw HakoError(message: "不支持此观察地址网络。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HakoError(message: "请填写名称和所选网络的完整公开地址。")
        }
        if network == Self.cosmosHub {
            guard Self.validCosmosAddress(address) else {
                throw HakoError(message: "Cosmos Hub 地址校验失败，请检查完整 cosmos1 地址。")
            }
        } else {
            let pattern = network == "TRON" ? "^T[1-9A-HJ-NP-Za-km-z]{33}$" : "^0x[0-9a-fA-F]{40}$"
            guard address.range(of: pattern, options: .regularExpression) != nil else {
                throw HakoError(message: "请填写名称和所选网络的完整公开地址。")
            }
        }
    }
    // Cosmos Hub account addresses contain 20 payload bytes and a Bech32 checksum.
    private static func validCosmosAddress(_ address:String) -> Bool {
        guard address.hasPrefix("cosmos1"), address.count == 45 else { return false }
        let alphabet=Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        let hrp=Array("cosmos".utf8)
        var values=hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 }
        for byte in address.dropFirst(7).utf8 {
            guard let index=alphabet.firstIndex(of:byte) else { return false }
            values.append(UInt8(index))
        }
        var checksum:UInt32=1
        let generators:[UInt32]=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]
        for value in values {
            let top=checksum >> 25
            checksum=(checksum & 0x1ffffff) << 5 ^ UInt32(value)
            for index in 0..<5 where ((top >> index) & 1) != 0 { checksum ^= generators[index] }
        }
        return checksum == 1
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
    static func canReuseAssets(updatedAt: Date?, now: Date) -> Bool {
        canReuse(updatedAt:updatedAt,now:now,lifetime:6*60*60)
    }
    static func canReusePrices(updatedAt: Date?, now: Date) -> Bool {
        canReuse(updatedAt:updatedAt,now:now,lifetime:60*60)
    }
    private static func canReuse(updatedAt: Date?, now: Date, lifetime:TimeInterval) -> Bool {
        guard let updatedAt else { return false }
        let age=now.timeIntervalSince(updatedAt)
        return age >= 0 && age < lifetime && CryptoDay.calendar.isDate(updatedAt,inSameDayAs:now)
    }
    static func recentContractDays(now: Date) -> [Date] {
        let today=CryptoDay.calendar.startOfDay(for:now)
        return (1...7).map { CryptoDay.calendar.date(byAdding:.day,value:-$0,to:today)! }
    }
    static func fundingSettlement(now: Date) -> Date {
        let calendar=CryptoDay.calendar
        let hour=calendar.component(.hour,from:now) / 8 * 8
        return calendar.date(byAdding:.hour,value:hour,to:calendar.startOfDay(for:now))!
    }
    static func fundingRefreshWindow(now: Date) -> Date {
        let settlement=fundingSettlement(now:now)
        // A query during settlement can precede posting. Recheck once after a short grace period.
        let posted=settlement.addingTimeInterval(120)
        return now < posted ? settlement : posted
    }
    static func canReuseFunding(updatedAt: Date?, now: Date) -> Bool {
        guard let updatedAt else { return false }
        return updatedAt <= now && updatedAt >= fundingRefreshWindow(now:now)
    }
}

// A current account snapshot is local-only and never a historical settlement row.
struct CryptoCurrentContract: Codable, Equatable {
    var sampledAt: Date
    var scope: String
    var trx: Double
    var price: Double
    var available: Double?
    var unrealizedProfit: Double?
    var liquidation: Double?
    var fundingTRX: Double?
    var fundingRate: Double? // Percent: 0.030 means 0.030%.
    var fundingTRXUpdatedAt: Date? = nil
    var fundingRateUpdatedAt: Date? = nil
    var totalEquity: Double? = nil
    var equity: Double { totalEquity ?? trx * price }
}

struct CryptoRecord: Codable, Identifiable, Equatable {
    var kind: String // portfolio or htx-trx
    var day: String
    var sampledAt: Double
    var scope: String
    var values: [String: Double]
    static let contractFields:Set<String> = ["trx","price","equity","liquidation","funding_trx","funding_rate"]
    var missingContractFields: Set<String> { Self.contractFields.subtracting(values.keys) }
    func fillingMissingContractFields(from other: Self) -> Self {
        guard kind == "htx-trx", other.id == id else { return self }
        var result=self
        for (key,value) in other.values where result.values[key] == nil { result.values[key]=value }
        return result
    }
    var id: String { kind + "|" + day }
    // Exact collection time is local-only; zero means an archive supplied only a date.
    var date: Date { Self.dayFormatter.date(from:day.replacingOccurrences(of:"-",with:""))! }
    var equity: Double? { values["equity"] }
    private static var dayFormatter: DateFormatter {
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.calendar=CryptoDay.calendar
        f.timeZone=CryptoDay.calendar.timeZone;f.dateFormat="yyyyMMdd";f.isLenient=false;return f
    }
    var path: String { "data/crypto/\(kind)/\(day.prefix(4)).csv" }

    static func header(for kind: String) throws -> [String] {
        switch kind {
        case "htx-trx": return ["date", "total_equity", "trx_balance", "trx_liquidation_price", "trx_price", "funding_trx", "funding_rate"]
        case "portfolio": return ["date", "htx", "binance", "chain", "total"]
        default: throw HakoError(message: "资产记录类型无效。")
        }
    }
    private static func valueKey(_ column: String) -> String {
        switch column {
        case "total_equity": return "equity"
        case "trx_balance": return "trx"
        case "trx_liquidation_price": return "liquidation"
        case "trx_price": return "price"
        default: return column
        }
    }
    static func formatted(_ value: Double, column: String) throws -> String {
        guard value.isFinite else { throw HakoError(message:"资产 CSV 数值无效。") }
        let digits = ["trx_price","trx_liquidation_price","funding_rate"].contains(column) ? 3 : 2
        guard var decimal=Decimal(string:String(value),locale:Locale(identifier:"en_US_POSIX")) else {
            throw HakoError(message:"资产 CSV 数值超出范围。")
        }
        var rounded=Decimal();NSDecimalRound(&rounded,&decimal,digits,.plain)
        guard !rounded.isNaN else { throw HakoError(message:"资产 CSV 数值超出范围。") }
        let number = rounded == 0 ? 0 : NSDecimalNumber(decimal:rounded).doubleValue
        return String(format:"%.*f",locale:Locale(identifier:"en_US_POSIX"),digits,number)
    }
    static func encode(_ rows: [Self], kind: String) throws -> String {
        let columns = try header(for:kind)
        guard rows.allSatisfy({ $0.kind == kind }) else { throw HakoError(message: "不能将不同类型的资产记录写入同一文件。") }
        let encoded = try rows.sorted { $0.id < $1.id }.map { r in
            try columns.map { column in
                if column == "date" { return r.day.replacingOccurrences(of:"-",with:"") }
                let value = column == "total_equity" ? r.equity : r.values[valueKey(column)]
                return try value.map { try formatted($0,column:column) } ?? ""
            }
        }
        let text=CSV.encode([columns]+encoded)
        if let first = rows.first { _ = try decode(text,kind:kind,year:String(first.day.prefix(4))) }
        return text
    }
    func normalized() throws -> Self {
        var row=try Self.decode(Self.encode([self],kind:kind),kind:kind,year:String(day.prefix(4)),scope:scope)[0]
        row.sampledAt=sampledAt
        return row
    }
    static func decode(_ text: String, kind: String, year: String, scope: String = "") throws -> [Self] {
        let rows = try CSV.parse(text), columns = try header(for:kind)
        guard rows.first == columns else { throw HakoError(message: "资产 CSV 表头不匹配，已停止覆盖。") }
        var ids = Set<String>()
        return try rows.dropFirst().map { row in
            guard row.count == columns.count else { throw HakoError(message: "资产 CSV 列数无效。") }
            let fields = Dictionary(uniqueKeysWithValues:zip(columns,row))
            let rawDay=fields["date"]!
            guard rawDay.count == 8, rawDay.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let date=dayFormatter.date(from:rawDay), dayFormatter.string(from:date) == rawDay,
                  rawDay.hasPrefix(year) else {
                throw HakoError(message: "资产 CSV 日期无效。")
            }
            let day=CryptoDay.key(date)
            var values: [String: Double] = [:]
            for column in columns where column != "date" && !fields[column]!.isEmpty {
                guard let value = Double(fields[column]!), value.isFinite else { throw HakoError(message: "资产 CSV 数值无效。") }
                values[valueKey(column)] = value
            }
            let required = kind == "portfolio" ? ["total"] : []
            guard required.allSatisfy({ values[$0] != nil }) else {
                throw HakoError(message: "资产 CSV 缺少必要字段。")
            }
            let record = Self(kind:kind,day:day,sampledAt:0,scope:scope,values:values)
            guard ids.insert(record.id).inserted else { throw HakoError(message: "资产 CSV 存在重复日期。") }
            return record
        }
    }
    static func merge(_ remote: [Self], _ local: [Self]) -> [Self] {
        var result: [String: Self] = [:]
        for r in remote + local where r.sampledAt >= (result[r.id]?.sampledAt ?? -.infinity) { result[r.id] = r }
        return result.values.sorted { $0.id < $1.id }
    }
}
