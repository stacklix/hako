import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// One-release migration. Remove this file and its single call site next release.
// Freeze the legacy source so its daily workflow cannot keep extending migration.
enum CryptoLegacyBackfill {
    static func combine(api: [String:[String:Double]], times:[String:Double], legacy:[CryptoRecord], existing:[CryptoRecord], scope:String, before:String) -> [CryptoRecord] {
        let old=Dictionary(uniqueKeysWithValues:existing.filter{$0.kind=="htx-trx" && $0.scope==scope}.map{($0.day,$0)})
        let csv=Dictionary(uniqueKeysWithValues:legacy.map{($0.day,$0)})
        let days=Set(api.keys).union(csv.keys)
        let f=DateFormatter();f.calendar=CryptoDay.calendar;f.timeZone=CryptoDay.calendar.timeZone;f.dateFormat="yyyy-MM-dd"
        return days.sorted().compactMap { day in
            guard day >= "2026-09-01",day<before else { return nil }
            if let existing=old[day],existing.values["backfill"] != 1 { return nil }
            let fields=api[day] ?? [:]
            var values=old[day]?.values ?? [:]
            for (key,value) in fields { values[key]=value }
            for (key,value) in csv[day]?.values ?? [:] where values[key]==nil { values[key]=value }
            // Old total_equity is only a fallback when API equity/price cannot
            // produce a valuation; it never overrides API-derived values.
            let previouslyAPIValued=old[day]?.values["backfill"]==1 && old[day]?.values["legacy_contract_equity"]==nil
            if previouslyAPIValued || (fields["trx"] != nil && fields["price"] != nil) { values["legacy_contract_equity"]=nil }
            guard values["trx"] != nil,values["price"] != nil else { return nil }
            values["backfill"]=1
            let timestamp=times[day].map{$0/1000} ?? old[day]?.sampledAt ?? csv[day]?.sampledAt ?? f.date(from:day)!.timeIntervalSince1970
            return CryptoRecord(kind:"htx-trx",day:day,sampledAt:timestamp,scope:scope,values:values)
        }
    }
    static let source = "https://raw.githubusercontent.com/stacklix/storage/5c27ffd882aa98219212cc6ec0a545dc3721b39d/data/htx_equity.csv"
    static func fetch(scope: String, before day: String) async throws -> [CryptoRecord] {
        let (data,response)=try await HTTPTransport.shared.data(from:URL(string:source)!)
        guard (response as? HTTPURLResponse)?.statusCode==200,let text=String(data:data,encoding:.utf8) else {
            throw HakoError(message:"历史资产文件读取失败，下次触发时重试。")
        }
        return try decode(text,scope:scope,before:day)
    }
    static func decode(_ text:String,scope:String,before day:String) throws -> [CryptoRecord] {
        let rows=try CSV.parse(text)
        guard rows.first==["date","total_equity","trx_balance","trx_liquidation_price","trx_price"] else {
            throw HakoError(message:"历史资产 CSV 表头不匹配。")
        }
        var seen=Set<String>(),result:[CryptoRecord]=[]
        let f=DateFormatter();f.calendar=CryptoDay.calendar;f.timeZone=CryptoDay.calendar.timeZone;f.dateFormat="yyyyMMdd";f.isLenient=false
        for row in rows.dropFirst() {
            guard row.count==5,let date=f.date(from:row[0]),f.string(from:date)==row[0] else { throw HakoError(message:"历史资产 CSV 日期无效。") }
            let key=CryptoDay.key(date)
            guard seen.insert(key).inserted else { throw HakoError(message:"历史资产 CSV 存在重复日期。") }
            guard key >= "2026-09-01",key<day else { continue }
            func number(_ index:Int) throws -> Double {
                guard let value=Double(row[index]),value.isFinite,value>=0 else { throw HakoError(message:"历史资产 CSV 数值无效。") };return value
            }
            var values=["trx":try number(2),"price":try number(4),"legacy_contract_equity":try number(1)]
            guard values["price"]!>0 else { throw HakoError(message:"历史价格无效。") }
            if !row[3].isEmpty { values["liquidation"]=try number(3) }
            // Time was not recorded by the legacy daily file. Midnight represents
            // its date only; the original rounded values remain unchanged.
            result.append(CryptoRecord(kind:"htx-trx",day:key,sampledAt:date.timeIntervalSince1970,scope:scope,values:values))
        }
        return result
    }
}
