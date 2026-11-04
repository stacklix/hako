import Foundation

// Temporary, batched API-first migration for the existing September history.
enum CryptoHistoricalAPI {
    struct Result { var fields:[String:[String:Double]]=[:];var times:[String:Double]=[:];var failures:[String]=[] }
    static func fetch(_ credential:CryptoCredential, until end:Date) async -> Result {
        let client=CryptoClient(),calendar=CryptoDay.calendar
        let first=calendar.date(from:DateComponents(year:2026,month:9,day:1))!
        let retention=calendar.date(byAdding:.day,value:-89,to:end)!
        let start=max(first,retention)
        var result=Result()
        guard start<end else { return result }
        let startMS=Int64(start.timeIntervalSince1970*1000),endMS=Int64(end.timeIntervalSince1970*1000)-1
        func day(_ milliseconds:Double)->String { CryptoDay.key(Date(timeIntervalSince1970:milliseconds/1000)) }
        // One paged settlement query covers the whole retained history.
        do {
            var page=1,fields:[String:[String:Double]]=[:],times:[String:Double]=[:]
            while true {
                let response=try await client.htx("api.hbdm.com","/swap-api/v1/swap_user_settlement_records",credential:credential,body:["contract_code":"TRX-USD","start_time":startMS,"end_time":endMS,"page_index":page,"page_size":50])
                guard let data=response["data"] as? [String:Any],let records=data["settlement_records"] as? [[String:Any]],let pages=data["total_page"] as? Int else { throw HakoError(message:"历史权益响应无效。") }
                for row in records {
                    let time=try CryptoClient.number(row["settlement_time"])
                    guard time>=Double(startMS),time<=Double(endMS) else { continue }
                    let key=day(time)
                    if time>(times[key] ?? 0) { fields[key]=["trx":try CryptoClient.number(row["margin_balance"])];times[key]=time }
                }
                if page>=pages { break };page+=1
                guard page<=100 else { throw HakoError(message:"历史权益分页未完成。") }
            }
            result.fields=fields;result.times=times
        } catch { result.failures.append("历史权益接口暂不可用") }
        // Up to 2000 hourly candles cover 83 days. Choose the final completed
        // hour in each Shanghai calendar day, not the current market quote.
        do {
            let response=try await client.htx("api.huobi.pro","/market/history/kline",params:["symbol":"trxusdt","period":"60min","size":"2000"])
            guard let candles=response["data"] as? [[String:Any]] else { throw HakoError(message:"历史行情响应无效。") }
            var times:[String:Double]=[:]
            for row in candles {
                let timestamp=try CryptoClient.number(row["id"]),time=timestamp*1000
                guard time>=Double(startMS),time+3600000<=Double(endMS)+1 else { continue }
                let key=day(time)
                if time>(times[key] ?? 0) { result.fields[key,default:[:]]["price"]=try CryptoClient.number(row["close"]);times[key]=time }
            }
        } catch { result.failures.append("历史价格接口暂不可用") }
        // V3 financial history permits 48-hour windows. Only publish a day's
        // aggregate after every cursor in that window has been read.
        var window=startMS
        while window<=endMS {
            let upper=min(window+48*60*60*1000-1,endMS)
            do {
                var sums:[String:Double]=[:],cursor:Int64?,seen=Set<String>()
                for page in 1...100 {
                    var body:[String:Any]=["contract":"TRX-USD","type":"30,31","start_time":window,"end_time":upper,"direct":"next"]
                    if let cursor { body["from_id"]=cursor }
                    let response=try await client.htx("api.hbdm.com","/swap-api/v3/swap_financial_record",credential:credential,body:body)
                    guard response["code"] as? Int==200,let rows=response["data"] as? [[String:Any]] else { throw HakoError(message:"历史资金费响应无效。") }
                    if rows.isEmpty { break }
                    for row in rows {
                        let time=try CryptoClient.number(row["ts"]),type=row["type"] as? Int ?? 0
                        guard time>=Double(window),time<=Double(upper),[30,31].contains(type),row["contract_code"] as? String=="TRX-USD" else { continue }
                        if seen.insert(String(describing:row["id"] ?? "")).inserted {
                            sums[day(time),default:0] += (type==30 ? 1 : -1)*abs(try CryptoClient.number(row["amount"]))
                        }
                    }
                    guard let next=rows.compactMap({($0["query_id"] as? NSNumber)?.int64Value}).max(),next != cursor else { throw HakoError(message:"资金费游标未前进。") }
                    cursor=next
                    if page==100 { throw HakoError(message:"资金费分页未完成。") }
                }
                var date=Date(timeIntervalSince1970:Double(window)/1000)
                while date.timeIntervalSince1970*1000<=Double(upper) {
                    let key=CryptoDay.key(date);result.fields[key,default:[:]]["funding_trx"]=sums[key] ?? 0
                    date=calendar.date(byAdding:.day,value:1,to:date)!
                }
            } catch { result.failures.append("部分历史资金费尚未读取完整") }
            window=upper+1
        }
        do {
            var sums:[String:Double]=[:],page=1
            while true {
                let response=try await client.htx("api.hbdm.com","/swap-api/v1/swap_historical_funding_rate",params:["contract_code":"TRX-USD","page_index":String(page),"page_size":"50"])
                guard let data=response["data"] as? [String:Any],let rows=data["data"] as? [[String:Any]],let pages=data["total_page"] as? Int else { throw HakoError(message:"历史费率响应无效。") }
                for row in rows {
                    let time=try CryptoClient.number(row["funding_time"])
                    if time>=Double(startMS) && time<=Double(endMS) { sums[day(time),default:0] += try CryptoClient.number(row["realized_rate"]) }
                }
                let oldest=try rows.last.map{try CryptoClient.number($0["funding_time"])} ?? 0
                if rows.isEmpty || oldest<Double(startMS) || page>=pages { break };page+=1
                guard page<=100 else { throw HakoError(message:"历史费率分页未完成。") }
            }
            var date=start
            while date<end { let key=CryptoDay.key(date);result.fields[key,default:[:]]["funding_rate"]=sums[key] ?? 0;date=calendar.date(byAdding:.day,value:1,to:date)! }
        } catch { result.failures.append("历史费率接口暂不可用") }
        result.failures=Array(Set(result.failures)).sorted()
        return result
    }
}
