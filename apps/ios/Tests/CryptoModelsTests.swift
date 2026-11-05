import Foundation

@main struct CryptoModelsTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition,message) }
        let dust=CryptoBinanceAsset(symbol:"BTC",name:"Bitcoin",free:0.000009,locked:0,frozen:0,withdrawing:0,unitPrice:100000)
        let boundary=CryptoBinanceAsset(symbol:"BTC",name:"Bitcoin",free:0,locked:0.00001,frozen:0,withdrawing:0,unitPrice:100000)
        let usdt=CryptoBinanceAsset(symbol:"USDT",name:"Tether",free:2,locked:3,frozen:4,withdrawing:1)
        check(!dust.isVisible && boundary.isVisible,"hide values below 1 USDT, retain exactly 1 USDT including locked holdings")
        check(usdt.quantity == 10 && usdt.price == 1 && usdt.usdtValue == 10,"holdings include all balance components without displaying their breakdown")
        let legacy=try JSONDecoder().decode(CryptoBinanceAsset.self,from:Data(#"{"symbol":"BTC","name":"Bitcoin","free":1,"locked":0,"frozen":0,"withdrawing":0}"#.utf8))
        check(legacy.price == nil && legacy.usdtValue == nil && legacy.isVisible,"old cached unpriced assets remain readable and are not mistaken for dust")
        let accounts=[CryptoBinanceAccount(name:"Empty",balance:0,assets:[]),CryptoBinanceAccount(name:"Dust",balance:0.9,assets:[dust]),CryptoBinanceAccount(name:"Spot",balance:11,assets:[boundary,usdt]),CryptoBinanceAccount(name:"Unavailable",balance:2,assets:nil)]
        let snapshot=CryptoBinanceSnapshot(scope:"test",sampledAt:.now,accounts:accounts)
        check(snapshot.visibleAccounts.map(\.name) == ["Spot","Unavailable"],"hide empty asset types and types containing only dust, preserve unavailable details")
        check(snapshot.total == 13.9 && snapshot.accounts.count == 4,"display filtering does not change reported total assets or cached accounts")
        let formatter=ISO8601DateFormatter()
        let now=formatter.date(from:"2026-12-31T16:01:00Z")!
        let recent=CryptoSyncPolicy.recentContractDays(now:now).map(CryptoDay.key)
        check(recent == ["2026-12-31","2026-12-30","2026-12-29","2026-12-28","2026-12-27","2026-12-26","2026-12-25"],"seven completed Shanghai days across the year boundary")
        let beforeMidnight=CryptoSyncPolicy.recentContractDays(now:formatter.date(from:"2026-11-04T15:59:59Z")!).map(CryptoDay.key)
        let afterMidnight=CryptoSyncPolicy.recentContractDays(now:formatter.date(from:"2026-11-04T16:00:00Z")!).map(CryptoDay.key)
        check(beforeMidnight.first == "2026-11-03" && !beforeMidnight.contains("2026-11-04"),"the current Shanghai day stays out of history")
        check(afterMidnight == ["2026-11-04","2026-11-03","2026-11-02","2026-11-01","2026-10-31","2026-10-30","2026-10-29"],"November 5 midnight immediately includes November 4 in the missing-data window")
        let settled=formatter.date(from:"2026-11-05T00:03:00Z")!
        check(CryptoSyncPolicy.canReuseFunding(updatedAt:settled,now:formatter.date(from:"2026-11-05T07:59:59Z")!),"cache survives repeated entry before the next Shanghai 16:00 settlement")
        check(!CryptoSyncPolicy.canReuseFunding(updatedAt:settled,now:formatter.date(from:"2026-11-05T08:00:00Z")!),"new settlement invalidates old funding totals")
        let provisional=formatter.date(from:"2026-11-05T08:00:30Z")!
        check(CryptoSyncPolicy.canReuseFunding(updatedAt:provisional,now:formatter.date(from:"2026-11-05T08:01:00Z")!),"avoid repeated requests within the initial settlement window")
        check(!CryptoSyncPolicy.canReuseFunding(updatedAt:provisional,now:formatter.date(from:"2026-11-05T08:02:00Z")!),"recheck provisional results after posting grace")
        check(!CryptoSyncPolicy.canReuseFunding(updatedAt:settled,now:formatter.date(from:"2026-11-05T16:00:00Z")!),"midnight invalidates yesterday funding")
        check(!CryptoSyncPolicy.canReuseFunding(updatedAt:nil,now:settled),"legacy or missing success timestamp requires a query")
        check(!CryptoSyncPolicy.canReuseFunding(updatedAt:provisional,now:settled),"clock rollback cannot reuse a future observation")
        let scope=String(repeating:"a",count:64)
        let prior=CryptoRecord(kind:"htx-trx",day:"2026-12-31",sampledAt:formatter.date(from:"2026-12-31T08:00:00Z")!.timeIntervalSince1970,scope:scope,
                               values:["equity":8723.12345*0.32439,"trx":8723.12345,"price":0.32439,"liquidation":0.4438,"funding_trx": -1.235,"funding_rate":0.0001234567])
        let csv=try CryptoRecord.encode([prior],kind:"htx-trx")
        let cells=try CSV.parse(csv)
        check(cells[0] == ["date","total_equity","trx_balance","trx_liquidation_price","trx_price","funding_trx","funding_rate"],"new contract schema")
        check(cells[1][0] == "20261231" && cells[1][2] == "8723.12" && cells[1][3] == "0.444" && cells[1][4] == "0.324" && cells[1][5] == "-1.24","amounts two decimals, prices three, signed half-up rounding")
        check(cells[1][6] == "0.0001234567","rate precision unchanged")
        check(!csv.contains("sampled_at") && !csv.contains(scope),"timestamps and scopes stay local")
        let decoded=try CryptoRecord.decode(csv,kind:"htx-trx",year:"2026",scope:scope)[0]
        check(decoded.sampledAt == 0 && CryptoDay.key(decoded.date) == prior.day,"archive date never becomes a fabricated collection time")
        check(decoded.equity != decoded.values["trx"]! * decoded.values["price"]!,"equity retains independently rounded original valuation")
        check(try CryptoRecord.encode([decoded],kind:"htx-trx") == csv,"repeated saves do not recalculate equity from rounded price")
        check(try prior.normalized().sampledAt == prior.sampledAt,"local collection timestamp survives normalization")
        var missing=decoded
        missing.values.removeValue(forKey:"funding_rate");missing.values.removeValue(forKey:"equity")
        let partial=try CryptoRecord.decode(CryptoRecord.encode([missing],kind:"htx-trx"),kind:"htx-trx",year:"2026")[0]
        check(partial.missingContractFields == ["funding_rate","equity"] && partial.equity == nil,"blank fields remain missing until corresponding APIs fill them")
        var update=decoded;update.values["trx"]=1;update.values["funding_rate"]=0
        let filled=missing.fillingMissingContractFields(from:update)
        check(filled.values["trx"] == decoded.values["trx"] && filled.values["funding_rate"] == 0,"fill only nil fields, including a real zero")
        check(!filled.missingContractFields.contains("funding_rate"),"zero rates are complete")
        let portfolio=CryptoRecord(kind:"portfolio",day:prior.day,sampledAt:prior.sampledAt,scope:scope,values:["htx":20.125,"binance":30,"chain":0,"total":50.125])
        let portfolioCSV=try CryptoRecord.encode([portfolio],kind:"portfolio")
        check(try CSV.parse(portfolioCSV) == [["date","htx","binance","chain","total"],["20261231","20.13","30.00","0.00","50.13"]],"all portfolio amounts use two fixed decimals")
        var newer=portfolio;newer.scope="changed";newer.sampledAt+=10
        check(CryptoRecord.merge([portfolio],[newer]) == [newer],"latest local daily snapshot wins")
        check(try CryptoRecord.formatted(2.675,column:"funding_trx") == "2.68","decimal ties do not depend on binary floating point")
        check(try CryptoRecord.formatted(-0.004,column:"funding_trx") == "0.00","no negative zero")
        var optional=prior;optional.values.removeValue(forKey:"liquidation");optional.values.removeValue(forKey:"funding_trx")
        let optionalCells=try CSV.parse(CryptoRecord.encode([optional],kind:"htx-trx"))
        check(optionalCells[1][3].isEmpty && optionalCells[1][5].isEmpty,"missing values stay blank")
        for invalid in ["20260230","2026121","20261301","2026-12-31"] {
            do { _ = try CryptoRecord.decode(csv.replacingOccurrences(of:"20261231",with:invalid),kind:"htx-trx",year:"2026");fatalError("invalid date accepted") } catch {}
        }
        do { _ = try CryptoRecord.decode(csv,kind:"htx-trx",year:"2027");fatalError("wrong year accepted") } catch {}
        do { _ = try CryptoRecord.decode(csv.replacingOccurrences(of:"0.324",with:"nan"),kind:"htx-trx",year:"2026");fatalError("nonfinite value accepted") } catch {}
        do { _ = try CryptoRecord.encode([prior,portfolio],kind:"htx-trx");fatalError("mixed kinds accepted") } catch {}
        do { _ = try CryptoRecord.decode(CSV.encode([cells[0],cells[1],cells[1]]),kind:"htx-trx",year:"2026");fatalError("duplicate date accepted") } catch {}
        check(try CryptoRecord.decode(CryptoRecord.encode([],kind:"htx-trx"),kind:"htx-trx",year:"2026").isEmpty,"empty annual file")
        try CryptoWallet(name:"wallet",network:"Ethereum",address:"0x"+String(repeating:"1",count:40)).validate()
        print("Crypto models: precision, dates, equity stability, strict CSV validation and sync policy passed")
    }
}
