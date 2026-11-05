import Foundation

struct CryptoContractCollection {
    var record: CryptoRecord
    var errors: [String]
}

struct CryptoContractHistory {
    var current:Result<CryptoCurrentContract,Error>?
    var fees:[String:Result<Double,Error>]=[:]
}

extension CryptoClient {
    func contractHistory(_ c:CryptoCredential,now:Date,requests:[(day:Date,fields:Set<String>)],current:Result<CryptoCurrentContract,Error>? = nil) async throws -> CryptoContractHistory {
        var history=CryptoContractHistory()
        guard !requests.isEmpty else { return history }
        let end=CryptoDay.calendar.startOfDay(for:now)
        let start=CryptoDay.calendar.date(byAdding:.day,value:-7,to:end)!
        if requests.contains(where: { !$0.fields.isDisjoint(with:["trx","price","equity","liquidation"]) }) {
            if let current { history.current=current }
            else {
                do { history.current = .success(try await contractEquity(c,now:now,scope:CryptoDay.hash(c.key))) }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation();history.current = .failure(error) }
            }
        }
        if requests.contains(where: { $0.fields.contains("funding_trx") }) {
            // The financial-record endpoint limits each query to 48 hours.
            var cursor=start
            while cursor < end {
                let limit=min(cursor.addingTimeInterval(48*3600),end)
                let result:Result<[String:Double],Error>
                do { result = .success(try await fundingFees(c,from:cursor,to:limit)) }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation();result = .failure(error) }
                var day=cursor
                while day < limit {
                    let key=CryptoDay.key(day)
                    history.fees[key]=result.map { $0[key] ?? 0 }
                    day=CryptoDay.calendar.date(byAdding:.day,value:1,to:day)!
                }
                cursor=limit
            }
        }
        return history
    }

    // Fetch a fresh snapshot without querying funding sources unrelated to the missing fields.
    private func contractEquity(_ c:CryptoCredential,now:Date,scope:String) async throws -> CryptoCurrentContract {
        let response=try await htx("api.hbdm.com","/swap-api/v1/swap_account_info",credential:c,body:["contract_code":"TRX-USD"])
        guard let account=(response["data"] as? [[String:Any]])?.first(where: { $0["contract_code"] as? String == "TRX-USD" }) else {
            throw HakoError(message:"当前 TRX 合约账户数据缺失。")
        }
        let trx=try Self.number(account["margin_balance"]),price=try await price("TRX")
        let totalEquity=try await contractTotalEquity(c)
        guard (trx*price).isFinite else { throw HakoError(message:"当前 TRX 合约估值无效。") }
        let liquidation=try? Self.number(account["liquidation_price"])
        return CryptoCurrentContract(sampledAt:now,scope:scope,trx:trx,price:price,available:nil,unrealizedProfit:nil,
            liquidation:liquidation.flatMap { $0 > 0 ? $0 : nil },fundingTRX:nil,fundingRate:nil,totalEquity:totalEquity)
    }

    func contract(_ c: CryptoCredential, now: Date, scope: String, day: Date? = nil, fields: Set<String>? = nil, history:CryptoContractHistory? = nil) async throws -> CryptoContractCollection {
        let today=CryptoDay.calendar.startOfDay(for:now)
        let startDate=CryptoDay.calendar.startOfDay(for:day ?? CryptoDay.calendar.date(byAdding:.day,value:-1,to:today)!)
        guard startDate >= CryptoDay.calendar.date(byAdding:.day,value:-7,to:today)!, startDate < today else {
            throw HakoError(message:"合约采集范围仅限最近 7 个完整自然日。")
        }
        let endDate=CryptoDay.calendar.date(byAdding:.day,value:1,to:startDate)!
        let wanted=fields ?? CryptoRecord.contractFields
        var values:[String:Double]=[:]
        var sampledAt=0.0
        var errors:[String]=[]
        // Each source can fail independently. Keep acquired fields and retry only missing ones.
        func collect(_ step:String, operation:() async throws -> Void) async throws {
            try Task.checkCancellation()
            do { try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch {
                errors.append(step+"："+error.localizedDescription)
                logStore.append(source:.crypto,level:.error,message:CryptoDay.key(startDate)+" TRX 合约 · "+step+"失败",detail:error.localizedDescription,fullDetail:true)
            }
        }
        if !wanted.isDisjoint(with:["trx","price","equity","liquidation"]) {
            try await collect("当前权益补录") {
                let current:CryptoCurrentContract
                if let cached=history?.current { current=try cached.get() }
                else { current=try await contractEquity(c,now:now,scope:scope) }
                // User-selected backfill policy: copy the current snapshot, never infer historical equity.
                sampledAt=current.sampledAt.timeIntervalSince1970
                if wanted.contains("trx") { values["trx"]=current.trx }
                if wanted.contains("price") { values["price"]=current.price }
                if wanted.contains("equity") { values["equity"]=current.equity }
                if wanted.contains("liquidation"),let liquidation=current.liquidation { values["liquidation"]=liquidation }
            }
        }
        if wanted.contains("funding_trx") {
            try await collect("资金费流水") {
                let fee:Double
                if let cached=history?.fees[CryptoDay.key(startDate)] { fee=try cached.get() }
                else { fee=try await fundingFee(c,from:startDate,to:endDate) }
                values["funding_trx"]=fee
            }
        }
        if wanted.contains("funding_rate") {
            try await collect("历史资金费率") {
                let rates=try await fundingRates(from:startDate,to:endDate)
                guard let rate=rates[CryptoDay.key(startDate)] else { throw HakoError(message:"该日资金费率缺失。") }
                values["funding_rate"]=rate * 100
            }
        }
        return CryptoContractCollection(record:CryptoRecord(kind:"htx-trx",day:CryptoDay.key(startDate),sampledAt:sampledAt,scope:scope,values:values),errors:errors)
    }
}
