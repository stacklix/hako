import Foundation

extension CryptoClient {
    func contract(_ c: CryptoCredential, now: Date, scope: String, day: Date? = nil, fields: Set<String>? = nil) async throws -> CryptoRecord {
        let today=CryptoDay.calendar.startOfDay(for:now)
        let startDate=CryptoDay.calendar.startOfDay(for:day ?? CryptoDay.calendar.date(byAdding:.day,value:-1,to:today)!)
        guard startDate >= CryptoDay.calendar.date(byAdding:.day,value:-7,to:today)!, startDate < today else {
            throw HakoError(message:"合约采集范围仅限最近 7 个完整自然日。")
        }
        let endDate=CryptoDay.calendar.date(byAdding:.day,value:1,to:startDate)!
        let start = startDate.timeIntervalSince1970*1000, end = endDate.timeIntervalSince1970*1000
        let wanted=fields ?? CryptoRecord.contractFields
        var values:[String:Double]=[:]
        var sampledAt=0.0
        if !wanted.isDisjoint(with:["trx","price","equity"]) {
            var settlements:[[String:Any]]=[],page=1
            while true {
                let response=try await htx("api.hbdm.com","/swap-api/v1/swap_user_settlement_records",credential:c,body:["contract_code":"TRX-USD","start_time":Int64(start),"end_time":Int64(end-1),"page_index":page,"page_size":50])
                guard let d=response["data"] as? [String:Any],let list=d["settlement_records"] as? [[String:Any]],let pages=d["total_page"] as? Int else { throw HakoError(message:"该日结算记录格式无效。") }
                settlements += list
                if page >= pages { break };page += 1
                guard page <= 100 else { throw HakoError(message:"该日结算记录未读取完整。") }
            }
            let dated = try settlements.map { row in (row,try Self.number(row["settlement_time"])) }.filter { $0.1 >= start && $0.1 < end }
            guard let latest=dated.max(by: { $0.1 < $1.1 }) else { throw HakoError(message:"该日无可用结算权益，未使用当前权益替代。稍后可重新触发。") }
            sampledAt=latest.1/1000
            let trx=try Self.number(latest.0["margin_balance"])
            if wanted.contains("trx") { values["trx"]=trx }
            if !wanted.isDisjoint(with:["price","equity"]) {
                let price=try await contractPrice(at:sampledAt,now:now)
                if wanted.contains("price") { values["price"]=price }
                if wanted.contains("equity") { values["equity"]=trx*price }
            }
        }
        if wanted.contains("funding_trx") {
            let fee=try await fundingFee(c,from:startDate,to:endDate)
            values["funding_trx"]=fee
        }
        if wanted.contains("funding_rate") {
            let rates=try await fundingRates(from:startDate,to:endDate)
            guard let rate=rates[CryptoDay.key(startDate)] else { throw HakoError(message:"该日资金费率缺失。") }
            values["funding_rate"]=rate
        }
        if wanted.contains("liquidation") {
            let current=try await htx("api.hbdm.com","/swap-api/v1/swap_account_info",credential:c,body:["contract_code":"TRX-USD"])
            guard let account=(current["data"] as? [[String:Any]])?.first(where:{$0["contract_code"] as? String == "TRX-USD"}) else { throw HakoError(message:"当前 TRX 合约强平价数据缺失。") }
            // Keep the collection-time liquidation price in USD/TRX; it is not a historical price.
            if let liquidation=try? Self.number(account["liquidation_price"]),liquidation>0 { values["liquidation"]=liquidation }
        }
        return CryptoRecord(kind:"htx-trx",day:CryptoDay.key(startDate),sampledAt:sampledAt,scope:scope,values:values)
    }
    private func contractPrice(at settlement: Double, now: Date) async throws -> Double {
        // HTX only provides the latest 2000 minute candles on this endpoint.
        if now.timeIntervalSince1970 - settlement < 1999 * 60 {
            let response=try await htx("api.huobi.pro","/market/history/kline",params:["symbol":"trxusdt","period":"1min","size":"2000"])
            let candles=response["data"] as? [[String:Any]] ?? []
            let eligible=try candles.map { ($0,try Self.number($0["id"])) }.filter { $0.1+60 <= settlement && settlement-$0.1 <= 120 }
            if let candle=eligible.max(by:{$0.1<$1.1}) {
                let price=try Self.number(candle.0["close"])
                if price > 0 { return price }
            }
        }
        // Public historical TRX/USDT candles cover older days without account credentials.
        let params=["symbol":"TRXUSDT","interval":"1m","startTime":String(Int64((settlement-120)*1000)),"endTime":String(Int64(settlement*1000-1)),"limit":"2"]
        let request=URLRequest(url:URL(string:"https://data-api.binance.vision/api/v3/klines?"+Self.query(params))!)
        guard let candles=try await json(request) as? [[Any]] else { throw HakoError(message:"结算时点的 TRX/USDT 分钟价格无效。") }
        var eligible:[(Double,Double)]=[]
        for row in candles {
            guard row.count >= 7 else { throw HakoError(message:"TRX/USDT 分钟行情格式无效。") }
            let open=try Self.number(row[0])/1000,close=try Self.number(row[6])/1000,price=try Self.number(row[4])
            if open+60 <= settlement,close < settlement,settlement-open <= 120,price > 0 { eligible.append((open,price)) }
        }
        guard let latest=eligible.max(by:{$0.0<$1.0}) else { throw HakoError(message:"结算时点的 TRX/USDT 分钟价格缺失。") }
        return latest.1
    }

}
