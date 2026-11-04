import Foundation

extension CryptoClient {
    func currentContract(_ c: CryptoCredential, scope: String, now: Date = .now) async throws -> CryptoCurrentContract {
        let response=try await htx("api.hbdm.com", "/swap-api/v1/swap_account_info", credential:c, body:["contract_code":"TRX-USD"])
        guard let account=(response["data"] as? [[String:Any]])?.first(where: { $0["contract_code"] as? String == "TRX-USD" }) else {
            throw HakoError(message:"当前 TRX 合约账户数据缺失。")
        }
        let trx=try Self.number(account["margin_balance"])
        let price=try await price("TRX")
        guard (trx * price).isFinite else { throw HakoError(message:"当前 TRX 合约估值无效。") }
        let liquidation=try? Self.number(account["liquidation_price"])
        let start=CryptoDay.calendar.startOfDay(for:now)
        let fee=try? await fundingFee(c,from:start,to:now)
        let rates=try? await fundingRates(from:start,to:now)
        return CryptoCurrentContract(sampledAt:now,scope:scope,trx:trx,price:price,
            available:try? Self.number(account["margin_available"]),
            unrealizedProfit:try? Self.number(account["profit_unreal"]),
            liquidation:liquidation.flatMap { $0 > 0 ? $0 : nil },
            fundingTRX:fee,fundingRate:rates?[CryptoDay.key(start)])
    }

    // Actual funding cash flow in a half-open date range, shared by today and completed days.
    func fundingFee(_ c: CryptoCredential, from startDate: Date, to endDate: Date) async throws -> Double {
        guard startDate < endDate else { throw HakoError(message:"资金费查询日期范围无效。") }
        let start=startDate.timeIntervalSince1970*1000, end=endDate.timeIntervalSince1970*1000
        var fee=0.0,cursor:Int64?,seen=Set<String>()
        for page in 1...100 {
            var body:[String:Any]=["contract":"TRX-USD","type":"30,31","start_time":Int64(start),"end_time":Int64(end-1),"direct":"next"]
            if let cursor { body["from_id"]=cursor }
            let response=try await htx("api.hbdm.com","/swap-api/v3/swap_financial_record",credential:c,body:body)
            guard response["code"] as? Int == 200, let list=response["data"] as? [[String:Any]] else { throw HakoError(message:"该日资金费流水无效。") }
            if list.isEmpty { break }
            for row in list {
                let time=try Self.number(row["ts"]),type=row["type"] as? Int ?? 0
                guard time>=start,time<end,row["contract_code"] as? String == "TRX-USD",[30,31].contains(type) else { continue }
                let id=String(describing:row["id"] ?? "")
                if seen.insert(id).inserted { fee += (type==30 ? 1 : -1)*abs(try Self.number(row["amount"])) }
            }
            guard let next=list.compactMap({ ($0["query_id"] as? NSNumber)?.int64Value }).max(),next != cursor else { throw HakoError(message:"资金费分页游标未前进。") }
            cursor=next
            if page==100 { throw HakoError(message:"该日资金费流水未读取完整。") }
        }
        guard fee.isFinite else { throw HakoError(message:"资金费汇总无效。") }
        return fee
    }


    // HTX may return null realized_rate even for settled historical entries.
    // Prefer a supplied realized rate (including zero); otherwise use the published funding rate.
    static func historicalFundingRate(_ row: [String: Any]) throws -> Double {
        let realized = row["realized_rate"]
        let missing = realized == nil || realized is NSNull || (realized as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) == ""
        let field = missing ? "funding_rate" : "realized_rate"
        guard let rate = try? number(row[field]) else {
            throw HakoError(message: "资金费率记录缺少有效的 \(field)，未将缺失费率记为零。")
        }
        return rate
    }

    // Aggregate settlement rates in a half-open Shanghai date range.
    func fundingRates(from start: Date, to end: Date) async throws -> [String: Double] {
        guard start < end else { throw HakoError(message: "资金费率查询日期范围无效。") }
        let startMS = start.timeIntervalSince1970 * 1000, endMS = end.timeIntervalSince1970 * 1000
        var rates: [Double: Double] = [:], previousOldest = Double.infinity
        for page in 1...100 {
            let response: [String: Any]
            do {
                response = try await htx("api.hbdm.com", "/swap-api/v1/swap_historical_funding_rate",
                                         params:["contract_code":"TRX-USD", "page_index":String(page), "page_size":"50"])
            } catch is CancellationError { throw CancellationError() }
            catch { throw HakoError(message: "历史资金费率第 \(page) 页读取失败：" + error.localizedDescription) }
            guard let data = response["data"] as? [String: Any],
                  let rows = data["data"] as? [[String: Any]],
                  let pages = data["total_page"] as? Int, pages >= 0 else {
                throw HakoError(message: "历史资金费率第 \(page) 页响应格式无效。")
            }
            if let current = data["current_page"] as? Int, current != page {
                throw HakoError(message: "历史资金费率分页未前进。")
            }
            if rows.isEmpty {
                guard page >= pages else { throw HakoError(message: "历史资金费率分页缺失，未写入不完整费率。") }
                break
            }
            var oldest = Double.infinity
            for row in rows {
                guard row["contract_code"] as? String == "TRX-USD",
                      let time = try? Self.number(row["funding_time"]), time > 0 else {
                    throw HakoError(message: "历史资金费率记录的合约或结算时间无效。")
                }
                oldest = min(oldest,time)
                guard time >= startMS, time < endMS else { continue }
                let rate = try Self.historicalFundingRate(row)
                if let previous = rates[time], previous != rate {
                    throw HakoError(message: "同一结算时间的历史资金费率不一致。")
                }
                rates[time] = rate
            }
            guard oldest < previousOldest else { throw HakoError(message: "历史资金费率分页未前进。") }
            previousOldest = oldest
            if oldest < startMS || page >= pages { break }
            guard page < 100 else { throw HakoError(message: "历史资金费率分页超过上限，尚未读取完整。") }
        }
        var sums: [String: Double] = [:]
        for time in rates.keys.sorted() {
            let day = CryptoDay.key(Date(timeIntervalSince1970:time / 1000))
            sums[day,default:0] += rates[time]!
        }
        var date = start
        while date < end {
            let day = CryptoDay.key(date)
            guard let sum = sums[day], sum.isFinite else {
                throw HakoError(message: "\(day) 的资金费率记录缺失，未将缺失费率记为零。")
            }
            date = CryptoDay.calendar.date(byAdding:.day,value:1,to:date)!
        }
        return sums
    }
}
