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
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["X-Request-ID":"visible-response-trace","Set-Cookie":"session=private-response-cookie; Path=/"])!,cacheStoragePolicy:.notAllowed)
            let data:Data
            if let body=object as? Data { data=body }
            else { data=try JSONSerialization.data(withJSONObject:object) }
            client?.urlProtocol(self,didLoad:data)
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
        let logDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("hako-crypto-logs-"+UUID().uuidString)
        let logFile=logDirectory.appendingPathComponent("events.json")
        let logs=HakoLogStore(fileURL:logFile)
        defer { logs.flush();try? FileManager.default.removeItem(at:logDirectory) }
        let client=CryptoClient(session:session,logStore:logs)
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

        // A missing fee rate must remain independent of all equity sources.
        FundingMockProtocol.respond { request in
            precondition(request.url!.path == "/swap-api/v1/swap_historical_funding_rate")
            return (200,fixture)
        }
        let rateOnly=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:end,scope:"",day:start,fields:["funding_rate"])
        check(rateOnly.record.values.count == 1 && abs(rateOnly.record.values["funding_rate"]! - 0.03) < 1e-12 && rateOnly.errors.isEmpty,"rate-only retry never queries current equity")

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
                case "/swap-api/v1/swap_balance_valuation": return (200,["data":[["valuation_asset":"USDT","balance":30]]])
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
                check(snapshot.fundingTRX == 3 && abs(snapshot.fundingRate! + 0.01) < 1e-12,"sum signed cash flow and settled rates, excluding future entries and duplicate cash flow")
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
        // Reentering refreshes realtime balances, but funding is cached independently per settlement.
        var moment=sample,feeCalls=0,rateCalls=0,accountCalls=0
        var delayLatest=false,failFee=false
        FundingMockProtocol.respond { request in
            let dayStart=calendar.startOfDay(for:moment)
            switch request.url!.path {
            case "/swap-api/v1/swap_account_info":
                accountCalls+=1
                return (200,["data":[["contract_code":"TRX-USD","margin_balance":100+accountCalls]]])
            case "/market/detail/merged": return (200,["tick":["close":0.3]])
                case "/swap-api/v1/swap_balance_valuation": return (200,["data":[["valuation_asset":"USDT","balance":30]]])
            case "/swap-api/v3/swap_financial_record":
                feeCalls+=1
                return failFee ? (503,[:]) : (200,["code":200,"data":[]])
            case "/swap-api/v1/swap_historical_funding_rate":
                rateCalls+=1
                let latest=CryptoSyncPolicy.fundingSettlement(now:moment)
                let rows=[0,8,16].compactMap { hour -> [String:Any]? in
                    let time=dayStart.addingTimeInterval(Double(hour)*3600)
                    guard time < moment, !delayLatest || time != latest else { return nil }
                    return ["contract_code":"TRX-USD","funding_time":time.timeIntervalSince1970*1000,"funding_rate":"0.0001"]
                }
                return (200,["data":["total_page":1,"data":rows]])
            default: fatalError("Unexpected funding cache endpoint")
            }
        }
        var cached=try await client.currentContract(credential,scope:"test",now:moment)
        check(feeCalls == 1 && rateCalls == 1 && cached.fundingTRX == 0,"initial funding observation, including a real zero")
        moment=sample.addingTimeInterval(60)
        cached=try await client.currentContract(credential,scope:"test",now:moment,cached:cached)
        check(feeCalls == 1 && rateCalls == 1 && accountCalls == 2 && cached.trx == 102,"reentry reuses funding while refreshing account equity")
        moment=start.addingTimeInterval(16*3600+30);delayLatest=true
        cached=try await client.currentContract(credential,scope:"test",now:moment,cached:cached)
        check(feeCalls == 2 && rateCalls == 2 && cached.fundingRate == nil && cached.fundingRateUpdatedAt == nil,"an unpublished latest settlement must not cache an incomplete daily rate")
        moment=moment.addingTimeInterval(30);delayLatest=false
        cached=try await client.currentContract(credential,scope:"test",now:moment,cached:cached)
        check(feeCalls == 2 && rateCalls == 3 && cached.fundingRate != nil,"retry only the unavailable rate, keep successful fee cache")
        moment=start.addingTimeInterval(16*3600+120)
        cached=try await client.currentContract(credential,scope:"test",now:moment,cached:cached)
        check(feeCalls == 3 && rateCalls == 4,"refresh provisional settlement data once after posting grace")
        cached=try JSONDecoder().decode(CryptoCurrentContract.self,from:JSONEncoder().encode(cached))
        moment=moment.addingTimeInterval(60)
        cached=try await client.currentContract(credential,scope:"test",now:moment,cached:cached)
        check(feeCalls == 3 && rateCalls == 4,"success timestamps survive disk serialization and avoid another query")
        moment=end.addingTimeInterval(180)
        cached=try await client.currentContract(credential,scope:"test",now:moment,cached:cached)
        check(feeCalls == 4 && rateCalls == 5 && cached.fundingRate == 0.01,"midnight requests fresh daily totals instead of reusing yesterday")
        failFee=true
        cached=try await client.currentContract(credential,scope:"changed-account",now:moment,cached:cached)
        check(feeCalls == 5 && rateCalls == 6 && cached.fundingTRX == nil && cached.fundingTRXUpdatedAt == nil,"account changes invalidate caches; failed fees have no success timestamp")
        failFee=false
        cached=try await client.currentContract(credential,scope:"changed-account",now:moment,cached:cached)
        check(feeCalls == 6 && rateCalls == 6 && cached.fundingTRX == 0,"retry failed fees without requerying valid rates")
        var legacyCache=try JSONSerialization.jsonObject(with:JSONEncoder().encode(cached)) as! [String:Any]
        legacyCache.removeValue(forKey:"fundingTRXUpdatedAt");legacyCache.removeValue(forKey:"fundingRateUpdatedAt")
        cached=try JSONDecoder().decode(CryptoCurrentContract.self,from:JSONSerialization.data(withJSONObject:legacyCache))
        check(cached.fundingTRXUpdatedAt == nil && cached.fundingRateUpdatedAt == nil,"old caches with funding values but no success timestamps remain readable")
        _ = try await client.currentContract(credential,scope:"changed-account",now:moment,cached:cached)
        check(feeCalls == 7 && rateCalls == 7,"legacy funding values receive one fresh observation before being reused")
        let privateKey="private-log-api-key",privateSecret="private-log-api-secret"
        let privateHeader="private-log-header",privateBody="private-log-body",privateResponse="private-log-balance"
        let bodyToken="private-body-token",responseToken="private-response-token",bearer="private-bearer-token"
        var requestSignatures=[String]()
        logs.clear()
        FundingMockProtocol.respond { request in
            if let signature=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "Signature"})?.value { requestSignatures.append(signature) }
            return (200,["status":"ok","balance":privateResponse,"access_token":responseToken,
                         "nested":[["refresh_token":bodyToken,"echo":privateKey]],
                         "authorization":"Bearer "+bearer,"debug":bearer+" private-response-cookie",
                         "tokens":[["symbol":"TRX","balance":"123.45"]]])
        }
        _ = try await client.htx("api.hbdm.com","/swap-api/v1/swap_account_info",credential:CryptoCredential(key:privateKey,secret:privateSecret),body:["test":privateBody,"contract_code":"TRX-USD","start_time":startMS,"nested":["api_secret":privateSecret,"refresh_token":bodyToken]])
        let address="0x"+String(repeating:"1",count:40)
        var privateRequest=URLRequest(url:URL(string:"https://deep-index.moralis.io/api/v2.2/wallets/"+address+"/tokens?apiKey="+privateKey)!)
        privateRequest.setValue(privateHeader,forHTTPHeaderField:"X-API-Key")
        privateRequest.setValue("Bearer "+bearer,forHTTPHeaderField:"Authorization")
        privateRequest.httpBody=Data(privateBody.utf8)
        _ = try await client.json(privateRequest)
        let networkLogs=logs.snapshot().entries
        check(networkLogs.count == 4 && networkLogs.allSatisfy{$0.source == .crypto},"record request starts and completions under the Crypto source")
        check(networkLogs.contains{$0.message.contains("swap_account_info") && $0.detail.contains("HTTP 状态：200") && $0.detail.contains("耗时：")},"request logs identify endpoint, HTTP result and elapsed time")
        let safeText=networkLogs.map(\.text).joined(separator:"\n")
        for secret in [privateKey,privateSecret,privateHeader,bodyToken,responseToken,bearer,"private-response-cookie"]+requestSignatures {
            check(!safeText.contains(secret),"redact credential fields and their echoes before writing complete HTTP logs")
        }
        check(!networkLogs[0].detail.contains(bearer),"redact bearer token echoes in response bodies")
        check(safeText.contains(privateBody) && safeText.contains(privateResponse) && safeText.contains(address),"retain permitted request/response business data instead of dropping entire bodies")
        check(safeText.contains("start_time") && safeText.contains("TRX-USD") && safeText.contains("123.45") && safeText.contains("visible-response-trace"),"retain query fields, timestamps, token holdings and non-secret response headers")
        FundingMockProtocol.respond { _ in (503,["error":privateResponse]) }
        do { _ = try await client.json(privateRequest);fatalError("Expected HTTP failure") } catch {}
        check(logs.snapshot().entries.first?.level == .error && logs.snapshot().entries.first?.detail.contains("HTTP 状态：503") == true && logs.snapshot().entries.first?.detail.contains(privateResponse) == true,"HTTP failures retain their complete redacted response body")
        FundingMockProtocol.respond { _ in (200,["status":"error","err_code":1016,"err_msg":privateResponse]) }
        do { _ = try await client.json(privateRequest);fatalError("Expected HTX rejection") } catch {}
        check(logs.snapshot().entries.first?.detail.contains("1016") == true && logs.snapshot().entries.first?.level == .error,"log API rejection codes even for HTTP 200")
        let rawToken="unlisted-raw-token",longBody=String(repeating:"business-data ",count:1000)+"RESPONSE-END"
        FundingMockProtocol.respond { _ in (503,Data(("refresh_token="+rawToken+"\n"+longBody).utf8)) }
        do { _ = try await client.json(privateRequest);fatalError("Expected plaintext failure") } catch {}
        check(logs.snapshot().entries.first?.detail.contains("RESPONSE-END") == true && logs.snapshot().entries.first?.detail.contains(rawToken) == false,"keep full non-JSON error bodies while removing credential key/value pairs")
        FundingMockProtocol.respond { _ in (503,[:]) }
        _ = try await client.contract(credential,now:end,scope:"",day:start,fields:["trx"])
        check(logs.snapshot().entries.contains { $0.level == .error && $0.message.contains("当前权益补录") },"backfill failure remains visible")
        logs.flush()
        let restoredLogs=HakoLogStore(fileURL:logFile).snapshot().entries
        check(restoredLogs.contains{$0.source == .crypto && $0.message.contains("当前权益补录")},"backfill failure survives log persistence")
        check(restoredLogs.map(\.text).joined().contains(privateResponse),"full response data survives persistence")
        for secret in [privateKey,privateSecret,privateHeader,bodyToken,responseToken,bearer,rawToken,"private-response-cookie"]+requestSignatures {
            check(!restoredLogs.map(\.text).joined().contains(secret),"persisted HTTP logs contain no known credentials")
        }
        let weeklyEnd=calendar.date(byAdding:.day,value:7,to:start)!
        let weeklyEndMS=weeklyEnd.timeIntervalSince1970*1000
        var feeWindows=Set<Double>()
        let current=CryptoCurrentContract(sampledAt:weeklyEnd,scope:"",trx:100,price:0.3,available:nil,unrealizedProfit:nil,liquidation:0.4,fundingTRX:nil,fundingRate:nil)
        FundingMockProtocol.respond { request in
            let params=try body(request)
            let from=(params["start_time"] as! NSNumber).doubleValue,to=(params["end_time"] as! NSNumber).doubleValue
            switch request.url!.path {
            case "/swap-api/v3/swap_financial_record":
                check(to-from < 48*3_600_000 && from >= startMS && to < weeklyEndMS,"financial chunks stay within 48 hours and seven completed days")
                feeWindows.insert(from)
                if from == startMS+2*86_400_000 { return (503,[:]) }
                if params["from_id"] != nil { return (200,["code":200,"data":[]]) }
                return (200,["code":200,"data":[
                    ["contract_code":"TRX-USD","ts":from,"type":30,"id":"income","query_id":1,"amount":"2"],
                    ["contract_code":"TRX-USD","ts":to,"type":31,"id":"expense","query_id":2,"amount":"0.5"]
                ]])
            default: fatalError("Batch preparation must query only missing source types")
            }
        }
        let weeklyRequests:[(day:Date,fields:Set<String>)]=[
            (start,["trx","funding_trx"]),
            (calendar.date(byAdding:.day,value:6,to:start)!,["trx","funding_trx"])
        ]
        let batch=try await client.contractHistory(CryptoCredential(key:"test",secret:"test"),now:weeklyEnd,requests:weeklyRequests,current:.success(current))
        check(feeWindows.count == 4,"reuse the current snapshot; only four financial windows cover seven days")
        FundingMockProtocol.respond { _ in fatalError("Daily consumers must reuse shared batch results") }
        let firstDay=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:weeklyEnd,scope:"",day:start,fields:["trx","funding_trx"],history:batch)
        let lastDay=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:weeklyEnd,scope:"",day:weeklyRequests[1].day,fields:["trx","funding_trx"],history:batch)
        check(firstDay.record.values["trx"] == 100 && firstDay.record.values["funding_trx"] == 2,"group settlement and fee records by Shanghai day")
        check(lastDay.record.values["trx"] == 100 && lastDay.record.values["funding_trx"] == 1.5,"last window covers exactly one day and sums signed fees")
        let failedDay=calendar.date(byAdding:.day,value:2,to:start)!
        let partial=try await client.contract(CryptoCredential(key:"test",secret:"test"),now:weeklyEnd,scope:"",day:failedDay,fields:["trx","funding_trx"],history:batch)
        check(partial.record.values["trx"] == 100 && partial.record.values["funding_trx"] == nil && partial.errors.count == 1,"failed financial chunk cannot erase independently acquired settlements")
        let backfilled=try await client.contract(credential,now:weeklyEnd,scope:"",day:start,fields:["trx","price","equity"],history:batch)
        check(backfilled.record.values["equity"] == 30 && backfilled.record.values["price"] == 0.3 && backfilled.record.sampledAt == weeklyEnd.timeIntervalSince1970,"current snapshot fills historical fields with actual collection time")
        let failed=CryptoContractHistory(current:.failure(HakoError(message:"current unavailable")))
        let missing=try await client.contract(credential,now:weeklyEnd,scope:"",day:start,fields:["trx","price","equity"],history:failed)
        check(missing.record.values.isEmpty && missing.errors.count == 1,"never fall back to stale equity on a fresh request failure")
        _ = try await client.contractHistory(CryptoCredential(key:"test",secret:"test"),now:weeklyEnd,requests:[])
        var valuations=[String]()
        FundingMockProtocol.respond { request in
            check(request.url!.path == "/swap-api/v1/swap_balance_valuation","total equity is queried directly, not calculated from TRX")
            let asset=try body(request)["valuation_asset"] as! String
            valuations.append(asset)
            if asset == "USDT" { return (200,["status":"error","err_code":1067]) }
            return (200,["status":"ok","data":[["valuation_asset":"USD","balance":"999.5"]]])
        }
        let valuation=try await client.contractTotalEquity(credential)
        check(valuation == 999.5 && valuations == ["USDT","USD"],"match storage valuation preference and USD fallback")
        var totalSnapshot=current;totalSnapshot.totalEquity=999.5
        let shared=CryptoContractHistory(current:.success(totalSnapshot))
        FundingMockProtocol.respond { _ in fatalError("Backfill must reuse the successful current snapshot") }
        let totalBackfill=try await client.contract(credential,now:weeklyEnd,scope:"",day:start,fields:["equity","trx"],history:shared)
        check(totalBackfill.record.values["equity"] == 999.5 && totalBackfill.record.values["trx"] == 100,"contract total valuation is independent of TRX holdings and price")
        let restored=try JSONDecoder().decode(CryptoCurrentContract.self,from:JSONEncoder().encode(totalSnapshot))
        check(restored.equity == 999.5,"total valuation survives cache persistence")
        print("Crypto funding: weekly range batching, 48-hour chunks, partial failures, full redacted HTTP logging, current equity backfill passed")
    }
}
