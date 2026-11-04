import Foundation

extension CryptoClient {
    func contract(_ c: CryptoCredential, now: Date, scope: String) async throws -> CryptoRecord {
        let endDate = CryptoDay.calendar.startOfDay(for:now)
        let startDate = CryptoDay.calendar.date(byAdding:.day,value:-1,to:endDate)!
        let start = startDate.timeIntervalSince1970*1000, end = endDate.timeIntervalSince1970*1000
        var settlements:[[String:Any]]=[],page=1
        while true {
            let response=try await htx("api.hbdm.com","/swap-api/v1/swap_user_settlement_records",credential:c,body:["contract_code":"TRX-USD","start_time":Int64(start),"end_time":Int64(end-1),"page_index":page,"page_size":50])
            guard let d=response["data"] as? [String:Any],let list=d["settlement_records"] as? [[String:Any]],let pages=d["total_page"] as? Int else { throw HakoError(message:"昨日结算记录格式无效。") }
            settlements += list
            if page >= pages { break };page += 1
            guard page <= 100 else { throw HakoError(message:"昨日结算记录未读取完整。") }
        }
        let dated = try settlements.map { row in (row,try Self.number(row["settlement_time"])) }.filter { $0.1 >= start && $0.1 < end }
        guard let latest=dated.max(by: { $0.1 < $1.1 }) else { throw HakoError(message:"昨日无可用结算权益，未使用当前权益替代。稍后可重新触发。") }
        var fee=0.0,cursor:Int64?,seen=Set<String>()
        for page in 1...100 {
            var body:[String:Any]=["contract":"TRX-USD","type":"30,31","start_time":Int64(start),"end_time":Int64(end-1),"direct":"next"]
            if let cursor { body["from_id"]=cursor }
            let response=try await htx("api.hbdm.com","/swap-api/v3/swap_financial_record",credential:c,body:body)
            guard response["code"] as? Int == 200, let list=response["data"] as? [[String:Any]] else { throw HakoError(message:"昨日资金费流水无效。") }
            if list.isEmpty { break }
            for row in list {
                let time=try Self.number(row["ts"]),type=row["type"] as? Int ?? 0
                guard time>=start,time<end,row["contract_code"] as? String == "TRX-USD",[30,31].contains(type) else { continue }
                let id=String(describing:row["id"] ?? "")
                if seen.insert(id).inserted { fee += (type==30 ? 1 : -1)*abs(try Self.number(row["amount"])) }
            }
            guard let next=list.compactMap({ ($0["query_id"] as? NSNumber)?.int64Value }).max(),next != cursor else { throw HakoError(message:"资金费分页游标未前进。") }
            cursor=next
            if page==100 { throw HakoError(message:"昨日资金费流水未读取完整。") }
        }
        var rate=0.0;page=1
        while true {
            let response=try await htx("api.hbdm.com","/swap-api/v1/swap_historical_funding_rate",params:["contract_code":"TRX-USD","page_index":String(page),"page_size":"50"])
            guard let d=response["data"] as? [String:Any],let list=d["data"] as? [[String:Any]],let pages=d["total_page"] as? Int else { throw HakoError(message:"昨日结算费率数据无效。") }
            for row in list { let time=try Self.number(row["funding_time"]);if time>=start && time<end { rate += try Self.number(row["realized_rate"]) } }
            let oldest=try list.last.map { try Self.number($0["funding_time"]) } ?? 0
            if list.isEmpty || oldest<start || page>=pages { break };page+=1
            guard page<=100 else { throw HakoError(message:"费率数据未读取完整。") }
        }
        // Coin-margined settlement_price is USD, not USDT. Use the most recent
        // completed TRX/USDT minute candle before that settlement; never look ahead.
        let response=try await htx("api.huobi.pro","/market/history/kline",params:["symbol":"trxusdt","period":"1min","size":"2000"])
        let candles=response["data"] as? [[String:Any]] ?? []
        let eligible=try candles.map { ($0,try Self.number($0["id"])) }.filter { ($0.1+60)*1000<=latest.1 }
        guard let candle=eligible.max(by:{$0.1<$1.1}),latest.1/1000-candle.1<=120 else { throw HakoError(message:"昨日结算时点的 TRX/USDT 分钟价格缺失。") }
        let price=try Self.number(candle.0["close"])
        guard price>0 else { throw HakoError(message:"历史价格无效。") }
        var values=["trx":try Self.number(latest.0["margin_balance"]),"price":price,"funding_trx":fee,"funding_rate":rate]
        let current=try await htx("api.hbdm.com","/swap-api/v1/swap_account_info",credential:c,body:["contract_code":"TRX-USD"])
        guard let account=(current["data"] as? [[String:Any]])?.first(where:{$0["contract_code"] as? String == "TRX-USD"}) else { throw HakoError(message:"当前 TRX 合约强平价数据缺失。") }
        // Explicit user-selected convention: store collection-time liquidation price
        // alongside yesterday's settlement data, retaining its distinct timestamp.
        if let liquidation=try? Self.number(account["liquidation_price"]),liquidation>0 { values["liquidation"]=liquidation }
        values["liquidation_sampled_at"]=Date.now.timeIntervalSince1970
        return CryptoRecord(kind:"htx-trx",day:CryptoDay.key(startDate),sampledAt:latest.1/1000,scope:scope,values:values)
    }
}
