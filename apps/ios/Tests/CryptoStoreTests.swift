import Foundation

// Host configuration is not used: tests inject an in-memory repository and temporary cache.
enum AppServices {
    static func privateGitHub() -> any GitHubRepositoryAccess { fatalError("Inject test repository") }
}

private final class AssetMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock=NSLock()
    static var handler: ((URLRequest) throws -> Any)!
    static var requests:[URLRequest]=[]
    static func configure(_ handler:@escaping (URLRequest) throws -> Any) {
        lock.lock();defer { lock.unlock() };Self.handler=handler;requests=[]
    }
    static func paths(_ path:String) -> [URLRequest] {
        lock.lock();defer { lock.unlock() };return requests.filter { $0.url!.path == path }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock();let handler=Self.handler!;Self.requests.append(request);Self.lock.unlock()
        do {
            let object=try handler(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

private final class AssetRepository: GitHubRepositoryAccess {
    let storageScope=UUID().uuidString
    var files:[String:String]=[:]
    var reads=0
    var commits:[[String:String]]=[]
    var failWrites=false
    var staleOnce=false
    var pauseNextRead=false
    var blocked=false
    var resume:CheckedContinuation<Void,Never>?
    func listFiles(in directory:String) async throws -> GitHubDirectorySnapshot {
        reads+=1
        if pauseNextRead {
            pauseNextRead=false;blocked=true
            await withCheckedContinuation { resume=$0 }
            blocked=false
        }
        return GitHubDirectorySnapshot(head:"head",entries:files.keys.filter{$0.hasPrefix(directory+"/")}.map {
            .init(name:URL(fileURLWithPath:$0).lastPathComponent,kind:"blob")
        })
    }
    func readFile(at path:String,revision:String?) async throws -> GitHubFileSnapshot {
        GitHubFileSnapshot(head:"head",text:files[path],lastCommitAt:nil)
    }
    func commit(files:[String:String],expectedHead:String,message:GitHubCommitMessage) async throws -> GitHubCommitResult {
        guard !files.isEmpty else { return .unchanged }
        if failWrites { throw HakoError(message:"test upload failure") }
        if staleOnce { staleOnce=false;return .staleHead }
        commits.append(files);self.files.merge(files){_,new in new};return .committed("head")
    }
}

@main struct CryptoStoreTests {
    @MainActor static func main() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("hako-assets-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AssetMockProtocol.self]
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let repository=AssetRepository()
        let htx=CryptoCredential(key:"test-htx",secret:"test-secret")
        let binance=CryptoCredential(key:"test-binance",secret:"test-secret")
        let days=CryptoSyncPolicy.recentContractDays(now:.now)
        let today=CryptoDay.calendar.startOfDay(for:.now)
        let lower=days.last!.timeIntervalSince1970*1000
        var rateRows:[[String:Any]]=[]
        for day in days {
            for hour in [0,8,16] { rateRows.append(["contract_code":"TRX-USD","funding_time":(day.timeIntervalSince1970+Double(hour)*3600)*1000,"funding_rate":"0.0001"]) }
        }
        rateRows.append(["contract_code":"TRX-USD","funding_time":today.timeIntervalSince1970*1000,"funding_rate":"0.0002"])
        let existing=CryptoRecord(kind:"htx-trx",day:CryptoDay.key(days[2]),sampledAt:0,scope:"",values:["trx":999,"price":0.3,"equity":299.7,"liquidation":0.4,"funding_trx":7,"funding_rate":0.01])
        let ancient=CryptoRecord(kind:"htx-trx",day:CryptoDay.key(CryptoDay.calendar.date(byAdding:.day,value:-8,to:today)!),sampledAt:0,scope:"",values:["trx":1,"price":0.3,"equity":0.3])
        let cacheFile=directory.appendingPathComponent("crypto/"+CryptoDay.hash(repository.storageScope)+".json")
        try FileManager.default.createDirectory(at:cacheFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(CryptoStore.Cache(records:[existing,ancient])).write(to:cacheFile)
        func makeStore()->CryptoStore {
            CryptoStore(repositoryProvider:{repository},client:CryptoClient(session:session),loadCredential:{$0 == "htx" ? htx : binance},loadWallets:{[]},cacheDirectory:directory)
        }
        func configure(total:Double=100, failDay:String?=nil, failBinance:Bool=false, incompleteHTX:Bool=false, failRates:Bool=false, currentTRX:Double=2000, failCurrent:Bool=false, currentLiquidation:Double?=0.4) {
            AssetMockProtocol.configure { request in
                switch request.url!.path {
                case "/v2/account/valuation": return ["success":true,"data":["updated":["success":!incompleteHTX],"profitAccountBalanceList":[["success":true]],"totalBalance":total]]
                case "/market/detail/merged": return ["tick":["close":1]]
                case "/sapi/v1/asset/wallet/balance":
                    if failBinance { throw HakoError(message:"test unavailable") };return [["balance":"50"]]
                case "/swap-api/v1/swap_user_settlement_records":
                    var bodyData=request.httpBody ?? Data()
                    if bodyData.isEmpty,let stream=request.httpBodyStream {
                        stream.open();defer { stream.close() }
                        var buffer=[UInt8](repeating:0,count:4096)
                        while stream.hasBytesAvailable {
                            let count=stream.read(&buffer,maxLength:buffer.count)
                            if count <= 0 { break };bodyData.append(contentsOf:buffer.prefix(count))
                        }
                    }
                    let body=try JSONSerialization.jsonObject(with:bodyData) as! [String:Any]
                    let start=(body["start_time"] as! NSNumber).doubleValue,end=(body["end_time"] as! NSNumber).doubleValue
                    precondition(start >= lower && end < today.timeIntervalSince1970*1000 && end-start == 86_400_000-1,"only the seven completed days")
                    let day=CryptoDay.key(Date(timeIntervalSince1970:start/1000))
                    precondition(day != existing.day,"existing local date must never be requested")
                    if day == failDay { throw HakoError(message:"test missing day") }
                    return ["data":["total_page":1,"settlement_records":[["settlement_time":start+16*3_600_000,"margin_balance":100]]]]
                case "/swap-api/v3/swap_financial_record": return ["code":200,"data":[]]
                case "/swap-api/v1/swap_historical_funding_rate":
                    if failRates { throw HakoError(message:"test rate unavailable") }
                    return ["data":["total_page":1,"data":rateRows]]
                case "/market/history/kline": return ["data":[["id":days[0].timeIntervalSince1970+16*3600-60,"close":0.3]]]
                case "/api/v3/klines":
                    let q=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
                    let start=Double(q.first{$0.name=="startTime"}!.value!)!
                    precondition(request.value(forHTTPHeaderField:"X-MBX-APIKEY") == nil)
                    return [[start,"0","0","0","0.3","0",start+59_999]]
                case "/swap-api/v1/swap_account_info":
                    if failCurrent { throw HakoError(message:"test current account unavailable") }
                    return ["data":[["contract_code":"TRX-USD","margin_balance":currentTRX,"margin_available":1500,"profit_unreal":-12.5,"liquidation_price":currentLiquidation as Any? ?? NSNull()]]]
                default: fatalError("Unexpected endpoint: \(request.url!)")
                }
            }
        }
        let store=makeStore()
        let failed=CryptoDay.key(days[4])
        configure(failDay:failed)
        store.loadCachedData()
        precondition(store.contracts.count == 2 && AssetMockProtocol.requests.isEmpty && repository.reads == 0,"cached records are published before any network request")
        await store.collect()
        precondition(repository.reads == 0 && repository.commits.isEmpty,"entry must never access GitHub")
        precondition(store.portfolio.last?.values["total"] == 150 && store.contracts.count == 7,"successful days and totals update even when one day fails")
        precondition(store.contracts.first{$0.id==existing.id} == existing && store.contracts.contains(ancient))
        precondition(store.pendingCount == 6 && AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").count == 6)
        precondition(store.currentContract?.trx == 2000 && store.currentContract?.equity == 2000 && store.currentContract?.available == 1500 && store.currentContract?.unrealizedProfit == -12.5,"current account fields are displayed independently of historical settlements")
        precondition(store.currentContract?.fundingTRX == 0 && store.currentContract?.fundingRate == 0.0002,"today funding is included in the published snapshot")
        precondition(store.currentContract?.liquidation == 0.4 && store.currentContract?.scope == CryptoDay.hash(htx.key))
        precondition(store.contracts.allSatisfy { $0.day != CryptoDay.key(today) },"today's snapshot never becomes a historical archive row")
        configure(total:200)
        await store.collect()
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").count == 1,"only failed date is retried, including pending rows as present")
        precondition(store.contracts.count == 8 && store.portfolio.last?.values["total"] == 250 && store.pendingCount == 7)
        precondition(repository.reads == 0 && repository.commits.isEmpty)
        let restored=makeStore()
        configure(total:300)
        restored.loadCachedData()
        precondition(restored.portfolio.last?.values["total"] == 250 && AssetMockProtocol.requests.isEmpty,"reentry immediately displays the previous cached total")
        precondition(restored.currentContract == store.currentContract,"current contract cache restores before network queries")
        await restored.collect()
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").isEmpty,"pending rows survive restart")
        precondition(restored.portfolio.last?.values["total"] == 350,"fresh results update the published display")
        let diskReader=makeStore()
        diskReader.loadCachedData()
        precondition(diskReader.portfolio.last?.values["total"] == 350,"fresh results also survive in the disk cache")
        // Existing GitHub contract wins even when the local pending row differs.
        var remote=restored.contracts.first{$0.day==CryptoDay.key(days[0])}!;remote.values["trx"]=777;remote.values["equity"]=233.1
        repository.files[remote.path]=try CryptoRecord.encode([existing,ancient,remote],kind:"htx-trx")
        repository.failWrites=true
        configure(total:400)
        _ = await restored.trigger()
        precondition(restored.message != nil && restored.pendingCount > 0,"upload failures retain pending rows")
        precondition(AssetMockProtocol.requests.isEmpty,"explicit synchronization never queries asset APIs")
        precondition(restored.contracts.first{$0.id==remote.id}?.values["trx"] == 777,"remote existing contracts cannot be overwritten")
        repository.failWrites=false;repository.staleOnce=true
        configure(total:500)
        _ = await restored.trigger()
        precondition(restored.message == nil && restored.pendingCount == 0)
        precondition(AssetMockProtocol.requests.isEmpty && restored.portfolio.last?.values["total"] == 350,"sync retries upload the cached total without collecting again")
        let uploaded=try CryptoRecord.decode(repository.files[remote.path]!,kind:"htx-trx",year:String(remote.day.prefix(4)))
        precondition(uploaded.count == 8 && uploaded.first{$0.id==remote.id}?.values["trx"] == 777)
        let portfolioPath=restored.portfolio.last!.path
        let savedTotal=repository.files[portfolioPath]
        configure(total:600,failBinance:true)
        await restored.collect()
        precondition(restored.message != nil && restored.portfolio.last?.values["total"] == 350,"partial source failure never overwrites the displayed complete total")
        _ = await restored.trigger()
        precondition(repository.files[portfolioPath] == savedTotal,"failed collection leaves the archived total intact")
        configure(total:600,incompleteHTX:true)
        await restored.collect()
        precondition(restored.message == nil && repository.files[portfolioPath] == savedTotal,"incomplete HTX valuation stays silent and preserves the complete total")
        // A manual trigger queued behind entry collection must still perform a GitHub sync.
        let before=repository.reads
        configure(total:700)
        let entry=Task { await restored.collect() }
        while !restored.busy { await Task.yield() }
        async let manual:String=restored.trigger()
        async let repeated:String=restored.trigger()
        _ = await (entry.value,manual,repeated)
        precondition(repository.reads > before && restored.pendingCount == 0)
        precondition(AssetMockProtocol.paths("/v2/account/valuation").count == 1,"entry and overlapping sync requests query each asset source only once")
        precondition(restored.portfolio.last?.values["total"] == 750 && restored.pendingCount == 0,"sync waits for the fresh cache")
        // Entry during an upload must wait and then collect, rather than treating the upload as a query.
        configure(total:800)
        repository.pauseNextRead=true
        let upload=Task { await restored.trigger() }
        while !repository.blocked { await Task.yield() }
        let nextEntry=Task { await restored.collect() }
        await Task.yield()
        repository.resume?.resume();repository.resume=nil
        _ = await (upload.value,nextEntry.value)
        precondition(AssetMockProtocol.paths("/v2/account/valuation").count == 1 && restored.portfolio.last?.values["total"] == 850)
        precondition(restored.pendingCount == 1,"entry refresh stays local even after waiting for an upload")
        // Missing fields are collected in the same seven-day flow as missing dates.
        let fieldsRepository=AssetRepository()
        var completeDays=days.map { day in
            CryptoRecord(kind:"htx-trx",day:CryptoDay.key(day),sampledAt:0,scope:"",values:["trx":999,"price":0.3,"equity":299.7,"liquidation":0.4,"funding_trx":7,"funding_rate":0.01])
        }
        completeDays[0].values.removeValue(forKey:"funding_trx")
        completeDays[0].values.removeValue(forKey:"liquidation")
        completeDays[1].values.removeValue(forKey:"funding_rate")
        completeDays[6].values["funding_trx"]=0;completeDays[6].values["funding_rate"]=0
        let fieldsFile=directory.appendingPathComponent("crypto/"+CryptoDay.hash(fieldsRepository.storageScope)+".json")
        try JSONEncoder().encode(CryptoStore.Cache(records:completeDays+[ancient])).write(to:fieldsFile)
        let fieldsStore=CryptoStore(repositoryProvider:{fieldsRepository},client:CryptoClient(session:session),loadCredential:{$0 == "htx" ? htx : binance},loadWallets:{[]},cacheDirectory:directory)
        configure(failRates:true)
        await fieldsStore.collect()
        precondition(fieldsStore.contracts.first{$0.day==completeDays[1].day}?.values["funding_rate"] == nil,"failed field remains missing")
        let filledFee=fieldsStore.contracts.first{$0.day==completeDays[0].day}!
        precondition(filledFee.values["funding_trx"] == 0 && filledFee.values["trx"] == 999 && filledFee.values["equity"] == 299.7,"fill zero fee and preserve every existing value")
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").isEmpty && AssetMockProtocol.paths("/api/v3/klines").isEmpty,"missing fee or rate must not require equity or minute history")
        configure()
        await fieldsStore.collect()
        let filledRate=fieldsStore.contracts.first{$0.day==completeDays[1].day}!
        precondition(abs(filledRate.values["funding_rate"]! - 0.0003) < 1e-12 && filledRate.values["funding_trx"] == 7)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_historical_funding_rate").count == 2 && AssetMockProtocol.paths("/swap-api/v3/swap_financial_record").count == 1,"retry just the missing rate, preserve zero values and out-of-window rows")
        precondition(fieldsStore.contracts.contains(ancient) && fieldsRepository.reads == 0 && fieldsRepository.commits.isEmpty)
        var remoteDays=completeDays
        remoteDays[1].values["trx"]=777;remoteDays[1].values["equity"]=233.1
        fieldsRepository.files[existing.path]=try CryptoRecord.encode(remoteDays+[ancient],kind:"htx-trx")
        fieldsRepository.failWrites=true
        configure()
        _ = await fieldsStore.trigger()
        precondition(fieldsStore.pendingCount > 0 && fieldsStore.message != nil && AssetMockProtocol.requests.isEmpty,"only explicit sync uploads missing-field patches and retains failures")
        fieldsRepository.failWrites=false;fieldsRepository.staleOnce=true
        _ = await fieldsStore.trigger()
        let fieldArchive=try CryptoRecord.decode(fieldsRepository.files[existing.path]!,kind:"htx-trx",year:String(existing.day.prefix(4)))
        let rateArchive=fieldArchive.first{$0.day==filledRate.day}!
        precondition(rateArchive.values["trx"] == 777 && rateArchive.values["equity"] == 233.1 && rateArchive.values["funding_rate"] == filledRate.values["funding_rate"],"GitHub merge fills only blank fields, never replaces existing contract values")
        precondition(fieldArchive.first{$0.day==filledFee.day}?.values["funding_trx"] == 0 && fieldArchive.contains(ancient))
        configure()
        await fieldsStore.collect()
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_historical_funding_rate").count == 1 && AssetMockProtocol.paths("/swap-api/v3/swap_financial_record").count == 1,"complete history is not requested; only today funding is refreshed")
        let historicalBefore=fieldsStore.contracts
        let pendingBefore=fieldsStore.pendingCount
        configure(currentTRX:1234.56,currentLiquidation:nil)
        await fieldsStore.collect()
        precondition(fieldsStore.currentContract?.trx == 1234.56 && fieldsStore.currentContract?.equity == 1234.56 && fieldsStore.currentContract?.liquidation == nil)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_account_info").count == 1,"complete history only needs one current account query per entry")
        precondition(fieldsStore.contracts == historicalBefore && fieldsStore.pendingCount == pendingBefore,"current snapshot neither changes historical values nor adds an archive row")
        let currentSnapshot=fieldsStore.currentContract
        let cached=try JSONDecoder().decode(CryptoStore.Cache.self,from:Data(contentsOf:fieldsFile))
        precondition(cached.currentContract == currentSnapshot,"new current data is saved to disk as well as published")
        configure(failCurrent:true)
        await fieldsStore.collect()
        precondition(fieldsStore.currentContract == currentSnapshot,"failed current query retains the old snapshot and its timestamp")
        configure(currentLiquidation:0)
        await fieldsStore.collect()
        precondition(fieldsStore.currentContract?.liquidation == nil,"zero liquidation is unavailable, not a valid price")
        print("Crypto store: cache-first display, fresh cache persistence, single entry collection, cache-only sync, failure retention and serialized operations passed")
    }
}
