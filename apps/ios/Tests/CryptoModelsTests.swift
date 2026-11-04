import Foundation

@main struct CryptoModelsTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition,message) }
        let formatter=ISO8601DateFormatter()
        let now=formatter.date(from:"2026-12-31T16:01:00Z")!
        let dates=CryptoSyncPolicy.dates(now:now)
        check(dates.today=="2027-01-01" && dates.yesterday=="2026-12-31","Shanghai midnight and year rollover")
        let scope=String(repeating:"a",count:64)
        let prior=CryptoRecord(kind:"htx-trx",day:"2026-12-31",sampledAt:formatter.date(from:"2026-12-31T08:00:00Z")!.timeIntervalSince1970,scope:scope,values:["trx":100,"price":0.3,"funding_trx": -1,"funding_rate":0.0001])
        let csv=CryptoRecord.encode([prior])
        check(try CryptoRecord.decode(csv,kind:"htx-trx",year:"2026")==[prior],"roundtrip preserves signed funding and decimals")
        check(prior.path=="data/crypto/htx-trx/2026.csv","historical target year")
        check(!CryptoSyncPolicy.confirmed([prior],pending:[prior],kind:"htx-trx",day:dates.yesterday,scope:scope),"pending upload must retry")
        check(CryptoSyncPolicy.confirmed([prior],pending:[],kind:"htx-trx",day:dates.yesterday,scope:scope),"confirmed yesterday skips on repeated trigger")
        check(!CryptoSyncPolicy.confirmed([prior],pending:[],kind:"portfolio",day:dates.today,scope:scope),"contract success never suppresses portfolio task")
        check(!CryptoSyncPolicy.confirmed([prior],pending:[],kind:"htx-trx",day:dates.yesterday,scope:"other"),"changed source cannot inherit completion")
        var newer=prior;newer.sampledAt+=10;newer.values["funding_trx"]=2
        check(CryptoRecord.merge([newer],[prior])==[newer],"older pending row cannot replace newer remote row")
        do { _ = try CryptoRecord.decode(csv.replacingOccurrences(of:"0.3",with:"nan"),kind:"htx-trx",year:"2026");fatalError("nonfinite CSV accepted") } catch {}
        do { _ = try CryptoRecord.decode(csv,kind:"htx-trx",year:"2027");fatalError("wrong year accepted") } catch {}
        let wallet=CryptoWallet(name:"wallet",network:"Ethereum",address:"0x"+String(repeating:"1",count:40))
        try wallet.validate()
        do { var invalid=wallet;invalid.address="0x123";try invalid.validate();fatalError("invalid address accepted") } catch {}
        let legacy="date,total_equity,trx_balance,trx_liquidation_price,trx_price\n20260901,100,300,0.5,0.3\n20260903,101,310,,0.3\n20261104,110,320,0.5,0.3\n"
        let migrated=try CryptoLegacyBackfill.decode(legacy,scope:scope,before:"2026-11-04")
        check(migrated.count==2 && migrated[0].day=="2026-09-01" && migrated[1].day=="2026-09-03","migration preserves date gaps and excludes today")
        check(migrated[0].values["legacy_contract_equity"]==100 && migrated[0].values["trx"]==300,"migration preserves original rounded values")
        check(migrated.allSatisfy{$0.values["funding_trx"]==nil && $0.values["funding_rate"]==nil},"missing legacy funding is not fabricated as zero")
        check(try CryptoRecord.decode(CryptoRecord.encode(migrated),kind:"htx-trx",year:"2026")==migrated,"migrated records survive annual CSV roundtrip")
        let preferred=CryptoLegacyBackfill.combine(api:["2026-09-01":["trx":999,"price":0.4,"funding_trx":2]],times:[:],legacy:migrated,existing:[],scope:scope,before:"2026-11-04")
        check(preferred[0].values["trx"]==999 && preferred[0].values["price"]==0.4 && preferred[0].values["liquidation"]==0.5,"API wins field by field; unavailable historical liquidation falls back to CSV")
        check(preferred[0].values["legacy_contract_equity"]==nil,"legacy valuation cannot override API equity and price")
        check(preferred[1].values["trx"]==310,"CSV supplies days missing API equity")
        check(CryptoLegacyBackfill.combine(api:[prior.day:["trx":999]],times:[:],legacy:[],existing:[prior],scope:scope,before:"2027-01-01").isEmpty,"normal daily records are not overwritten by migration")
        print("Crypto models: 19 checks passed")
    }
}
