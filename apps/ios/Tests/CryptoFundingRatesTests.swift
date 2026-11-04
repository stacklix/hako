import Foundation

private final class FundingMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock=NSLock()
    static var handler:((URLRequest) throws -> (Int,Any))?
    static func respond(_ block:@escaping (URLRequest) throws -> (Int,Any)) {
        lock.lock();defer { lock.unlock() };handler=block
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock();let block=Self.handler!;Self.lock.unlock()
            let (status,object)=try block(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

@main struct CryptoFundingRatesTests {
    static func main() async throws {
        func check(_ value:Bool,_ message:String) { precondition(value,message) }
        for missing:Any in [NSNull(),"", "  "] {
            check(try CryptoClient.historicalFundingRate(["realized_rate":missing,"funding_rate":"0.0001"]) == 0.0001,"null/empty realized rates use published rates")
        }
        check(try CryptoClient.historicalFundingRate(["funding_rate":"-0.0002"]) == -0.0002,"missing realized rate preserves a negative published rate")
        check(try CryptoClient.historicalFundingRate(["realized_rate":"0","funding_rate":"0.0001"]) == 0,"real zero must not fall back")
        check(try CryptoClient.historicalFundingRate(["realized_rate":"0.00009","funding_rate":"0.0001"]) == 0.00009,"actual rate takes precedence")
        for invalid:[String:Any] in [[:],["realized_rate":NSNull(),"funding_rate":NSNull()],["realized_rate":"nan","funding_rate":"0.0001"],["funding_rate":"bad"]] {
            do { _ = try CryptoClient.historicalFundingRate(invalid);fatalError("Invalid rate accepted") } catch {}
        }
        let fixtureURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Crypto/htx-funding-rates.json")
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL))
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FundingMockProtocol.self]
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let client=CryptoClient(session:session)
        let calendar=CryptoDay.calendar
        let start=calendar.date(from:DateComponents(year:2026,month:11,day:3))!
        let end=calendar.date(byAdding:.day,value:1,to:start)!
        let startMS=start.timeIntervalSince1970*1000
        FundingMockProtocol.respond { request in
            precondition(request.httpMethod == "GET" && request.url!.path == "/swap-api/v1/swap_historical_funding_rate")
            return (200,fixture)
        }
        let rates=try await client.fundingRates(from:start,to:end)
        check(rates.count == 1 && abs(rates["2026-11-03"]! - 0.0003) < 1e-12,"real API fixture with null realized_rate yields three daily settlements")

        func row(_ offsetHours:Double,_ rate:String)->[String:Any] {
            ["contract_code":"TRX-USD","funding_time":String(Int64(startMS+offsetHours*3_600_000)),"realized_rate":NSNull(),"funding_rate":rate]
        }
        let midnight=row(0,"0.0001"), morning=row(8,"-0.0002"), afternoon=row(16,"0.0003")
        FundingMockProtocol.respond { request in
            let page=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="page_index"}!.value!
            if page == "1" { return (200,["data":["total_page":2,"current_page":1,"data":[row(24,"100"),afternoon,morning]]]) }
            precondition(page == "2")
            return (200,["data":["total_page":2,"current_page":2,"data":[morning,midnight,row(-8,"100")]]])
        }
        let paged=try await client.fundingRates(from:start,to:end)
        check(abs(paged["2026-11-03"]! - 0.0002) < 1e-12,"deduplicate page overlap and use half-open Shanghai day boundaries")
        for (status,response,expected):(Int,[String:Any],String) in [
            (429,[:],"HTTP 429"),
            (200,["status":"error","err_code":1016],"1016"),
            (200,["data":["total_page":0,"data":[]]],"2026-11-03"),
            (200,["data":["total_page":2,"data":[]]],"分页缺失"),
            (200,["data":["total_page":2,"current_page":1,"data":[afternoon]]],"分页未前进")
        ] {
            FundingMockProtocol.respond { _ in (status,response) }
            do { _ = try await client.fundingRates(from:start,to:end);fatalError("Incomplete response accepted") }
            catch { precondition(error.localizedDescription.contains(expected),error.localizedDescription) }
        }

        // Exercise the daily contract collector, with no historical backfill entry point.
        let settlement=startMS+16*3_600_000
        FundingMockProtocol.respond { request in
            let path=request.url!.path
            switch path {
            case "/swap-api/v1/swap_user_settlement_records":
                return (200,["data":["total_page":1,"settlement_records":[["settlement_time":settlement,"margin_balance":100]]]])
            case "/swap-api/v3/swap_financial_record": return (200,["code":200,"data":[]])
            case "/swap-api/v1/swap_historical_funding_rate": return (200,fixture)
            case "/market/history/kline": return (200,["data":[["id":settlement/1000-60,"close":0.3]]])
            case "/swap-api/v1/swap_account_info": return (200,["data":[["contract_code":"TRX-USD","liquidation_price":0.4]]])
            default: fatalError("Unexpected endpoint: \(path)")
            }
        }
        let contract=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:end,scope:String(repeating:"a",count:64))
        check(contract.day == "2026-11-03" && contract.values["trx"] == 100,"daily collection still records yesterday's equity")
        check(abs(contract.values["funding_rate"]! - 0.0003) < 1e-12 && contract.values["funding_trx"] == 0,"daily collection handles missing realized rate without changing actual funding cash flow")
        FundingMockProtocol.respond { request in
            precondition(request.url!.path == "/swap-api/v1/swap_historical_funding_rate","a missing rate must not query unrelated contract endpoints")
            return (200,fixture)
        }
        let rateOnly=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:end,scope:"",day:start,fields:["funding_rate"])
        check(rateOnly.values.count == 1 && abs(rateOnly.values["funding_rate"]! - 0.0003) < 1e-12,"rate-only collection succeeds independently of other contract APIs")
        let weekEnd=calendar.date(byAdding:.day,value:7,to:start)!
        var historicalRequests=0
        FundingMockProtocol.respond { request in
            switch request.url!.path {
            case "/swap-api/v1/swap_user_settlement_records":
                return (200,["data":["total_page":1,"settlement_records":[["settlement_time":settlement,"margin_balance":100]]]])
            case "/swap-api/v3/swap_financial_record": return (200,["code":200,"data":[]])
            case "/swap-api/v1/swap_historical_funding_rate": return (200,fixture)
            case "/api/v3/klines":
                historicalRequests+=1
                let q=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
                check(q.first{$0.name=="endTime"}!.value == String(Int64(settlement-1)),"bounded historical minute request")
                check(request.value(forHTTPHeaderField:"X-MBX-APIKEY") == nil,"no account credentials sent for public history")
                return (200,[[settlement-60_000,"0","0","0","0.31","0",settlement-1],
                             [settlement,"0","0","0","999","0",settlement+59_999]])
            case "/swap-api/v1/swap_account_info": return (200,["data":[["contract_code":"TRX-USD","liquidation_price":0.4]]])
            default: fatalError("Old day must request time-bounded public history: \(request.url!)")
            }
        }
        let week=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:weekEnd,scope:"",day:start)
        check(week.day == "2026-11-03" && week.values["price"] == 0.31 && historicalRequests == 1,"oldest allowed day uses completed historical minute, never future candle")
        FundingMockProtocol.respond { _ in fatalError("Out-of-window date must not call an API") }
        for invalid in [calendar.date(byAdding:.day,value:-1,to:start)!,weekEnd] {
            do { _ = try await client.contract(CryptoCredential(key:"test",secret:"test"),now:weekEnd,scope:"",day:invalid);fatalError("out-of-window collection accepted") } catch {}
        }
        // Today's funding uses only midnight-to-sample cash flow and settled rates.
        let sample=start.addingTimeInterval(12*3600)
        let credential=CryptoCredential(key:"test",secret:"test")
        func body(_ request: URLRequest) throws -> [String:Any] {
            var bytes=request.httpBody ?? Data()
            if bytes.isEmpty,let stream=request.httpBodyStream {
                stream.open();defer { stream.close() }
                var buffer=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count=stream.read(&buffer,maxLength:buffer.count)
                    if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count))
                }
            }
            return try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        }
        func cash(_ id:Int,_ hour:Double,_ type:Int,_ amount:Double)->[String:Any] {
            ["id":String(id),"query_id":id,"contract_code":"TRX-USD","ts":startMS+hour*3_600_000,"type":type,"amount":amount]
        }
        let income=cash(1,0,30,5),expense=cash(2,8,31,-2)
        for mode in ["normal","empty","failed"] {
            FundingMockProtocol.respond { request in
                switch request.url!.path {
                case "/swap-api/v1/swap_account_info":
                    return (200,["data":[["contract_code":"TRX-USD","margin_balance":100,"liquidation_price":0.1]]])
                case "/market/detail/merged": return (200,["tick":["close":0.3]])
                case "/swap-api/v1/swap_historical_funding_rate":
                    if mode == "failed" { return (503,[:]) }
                    return (200,["data":["total_page":1,"data":mode == "empty" ? [] : [row(-8,"100"),midnight,morning,afternoon]]])
                case "/swap-api/v3/swap_financial_record":
                    let params=try body(request)
                    check((params["start_time"] as! NSNumber).doubleValue == startMS,"today begins at Shanghai midnight")
                    check((params["end_time"] as! NSNumber).doubleValue == sample.timeIntervalSince1970*1000-1,"future cash flow is excluded")
                    if mode == "failed" { return (503,[:]) }
                    if mode == "empty" { return (200,["code":200,"data":[]]) }
                    switch (params["from_id"] as? NSNumber)?.intValue {
                    case nil: return (200,["code":200,"data":[income,expense]])
                    case 2: return (200,["code":200,"data":[expense,cash(3,-1,30,100),cash(4,12,30,100)]])
                    case 4: return (200,["code":200,"data":[]])
                    default: fatalError("Unexpected funding pagination")
                    }
                default: fatalError("Current snapshot must not query historical equity")
                }
            }
            let snapshot=try await client.currentContract(credential,scope:"test",now:sample)
            check(snapshot.trx == 100 && snapshot.equity == 30,"funding failures must not hide the current account")
            if mode == "normal" {
                check(snapshot.fundingTRX == 3 && abs(snapshot.fundingRate! + 0.0001) < 1e-12,"sum signed cash flow and settled rates, excluding future entries and duplicate cash flow")
                let restored=try JSONDecoder().decode(CryptoCurrentContract.self,from:JSONEncoder().encode(snapshot))
                check(restored == snapshot,"new funding fields survive the cache round trip")
                var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as! [String:Any]
                legacy.removeValue(forKey:"fundingTRX");legacy.removeValue(forKey:"fundingRate")
                let old=try JSONDecoder().decode(CryptoCurrentContract.self,from:JSONSerialization.data(withJSONObject:legacy))
                check(old.fundingTRX == nil && old.fundingRate == nil && old.trx == 100,"old caches load without funding fields")
            } else if mode == "empty" {
                check(snapshot.fundingTRX == 0 && snapshot.fundingRate == nil,"successful empty cash flow is zero; missing rate remains unavailable")
            } else {
                check(snapshot.fundingTRX == nil && snapshot.fundingRate == nil,"failed funding requests never become zero")
            }
        }
        print("Crypto funding: real API fixture, fallback, zero/negative rates, pagination, missing data, diagnostics, seven-day bounds and historical minute pricing passed")
    }
}
