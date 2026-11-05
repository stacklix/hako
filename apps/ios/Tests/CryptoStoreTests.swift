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
            client?.urlProtocol(self,didLoad:try (object as? Data) ?? JSONSerialization.data(withJSONObject:object))
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
    var failReads=false
    var staleOnce=false
    var pauseNextRead=false
    var blocked=false
    var resume:CheckedContinuation<Void,Never>?
    func listFiles(in directory:String) async throws -> GitHubDirectorySnapshot {
        reads+=1
        if failReads { throw HakoError(message:"test archive unavailable") }
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
        let now=CryptoDay.calendar.date(from:DateComponents(year:2026,month:11,day:5,hour:12))!
        let days=CryptoSyncPolicy.recentContractDays(now:now)
        let today=CryptoDay.calendar.startOfDay(for:now)
        let lower=days.last!.timeIntervalSince1970*1000
        var rateRows:[[String:Any]]=[]
        for day in days {
            for hour in [0,8,16] { rateRows.append(["contract_code":"TRX-USD","funding_time":(day.timeIntervalSince1970+Double(hour)*3600)*1000,"funding_rate":"0.0001"]) }
        }
        for hour in [0,8] { rateRows.append(["contract_code":"TRX-USD","funding_time":(today.timeIntervalSince1970+Double(hour)*3600)*1000,"funding_rate":"0.0002"]) }
        let existing=CryptoRecord(kind:"htx-trx",day:CryptoDay.key(days[2]),sampledAt:0,scope:"",values:["trx":999,"price":0.3,"equity":299.7,"liquidation":0.4,"funding_trx":7,"funding_rate":0.01])
        let ancient=CryptoRecord(kind:"htx-trx",day:CryptoDay.key(CryptoDay.calendar.date(byAdding:.day,value:-8,to:today)!),sampledAt:0,scope:"",values:["trx":1,"price":0.3,"equity":0.3])
        let cacheFile=directory.appendingPathComponent("crypto/"+CryptoDay.hash(repository.storageScope)+".json")
        try FileManager.default.createDirectory(at:cacheFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(CryptoStore.Cache(records:[existing,ancient],archiveLoaded:true,archivedPortfolioDays:[])).write(to:cacheFile)
        func makeStore()->CryptoStore {
            CryptoStore(repositoryProvider:{repository},client:CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)),loadCredential:{$0 == "htx" ? htx : binance},loadWallets:{[]},cacheDirectory:directory,nowProvider:{now})
        }
        func configure(total:Double=100, failDay:String?=nil, failBinance:Bool=false, incompleteHTX:Bool=false, failRates:Bool=false, currentTRX:Double=2000, failCurrent:Bool=false, currentLiquidation:Double?=0.4) {
            AssetMockProtocol.configure { request in
                switch request.url!.path {
                case "/v2/account/valuation": return ["success":true,"data":["updated":["success":!incompleteHTX],"profitAccountBalanceList":[["success":true]],"totalBalance":total]]
                case "/market/detail/merged": return ["tick":["close":1]]
                case "/swap-api/v1/swap_balance_valuation": return ["data":[["valuation_asset":"USDT","balance":currentTRX]]]
                case "/sapi/v1/asset/wallet/balance":
                    if failBinance { throw HakoError(message:"test unavailable") }
                    let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
                    precondition(query.contains { $0.name == "needBalanceDetail" && $0.value == "true" },"request per-asset details")
                    precondition(query.contains { $0.name == "quoteAsset" && $0.value == "USDT" })
                    return [["walletName":"Spot","balance":"50","assetBalances":[
                        ["asset":"USDT","assetName":"TetherUS","free":"40","locked":"7","freeze":"2","withdrawing":"1"],
                        ["asset":"BTC","free":"0","locked":"0","freeze":"0","withdrawing":"0"]
                    ]]]
                case "/swap-api/v1/swap_user_settlement_records": fatalError("Retired settlement API must never be requested")
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
        let failed=CryptoDay.key(days[0])
        configure(failDay:failed)
        store.loadCachedData()
        precondition(store.contracts.count == 2 && AssetMockProtocol.requests.isEmpty && repository.reads == 0,"cached records are published before any network request")
        await store.collect(force:true)
        precondition(store.binanceSnapshot?.total == 50 && store.binanceSnapshot?.accounts.first?.assets?.count == 1,"account and nonzero asset details are cached")
        let binanceAsset=store.binanceSnapshot!.accounts[0].assets![0]
        precondition(binanceAsset.quantity == 50 && binanceAsset.free == 40 && binanceAsset.locked == 7 && binanceAsset.frozen == 2 && binanceAsset.withdrawing == 1,"all asset balance components survive parsing")
        let omitted=try CryptoClient.binanceSnapshot([["walletName":"Futures","balance":"3"]],scope:"test")
        precondition(omitted.total == 3 && omitted.accounts[0].assets == nil,"missing details remain unavailable rather than empty balances")
        do {
            _ = try CryptoClient.binanceSnapshot([["balance":"NaN"]],scope:"test")
            preconditionFailure("invalid balances must fail")
        } catch {}
        precondition(repository.reads == 0 && repository.commits.isEmpty,"entry must never access GitHub")
        precondition(store.portfolio.last?.values["total"] == 150 && store.contracts.count == 8,"successful fields and totals update even when one day's settlement fails")
        let filledYesterday=store.contracts.first{$0.day==failed}!
        precondition(filledYesterday.values["trx"] == 2000 && filledYesterday.values["equity"] == 2000 && filledYesterday.values["price"] == 1,"missing history copies current TRX equity, price and valuation")
        precondition(store.message == nil,"retired settlement API cannot cause update failures")
        precondition(store.contracts.first{$0.id==existing.id} == existing && store.contracts.contains(ancient))
        precondition(store.pendingCount == 7 && AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").isEmpty,"retired settlement interface is never called")
        precondition(store.currentContract?.trx == 2000 && store.currentContract?.equity == 2000 && store.currentContract?.available == 1500 && store.currentContract?.unrealizedProfit == -12.5,"current account fields are displayed independently of historical settlements")
        precondition(store.currentContract?.fundingTRX == 0 && store.currentContract?.fundingRate == 0.04,"today funding is included in the published snapshot")
        precondition(store.currentContract?.liquidation == 0.4 && store.currentContract?.scope == CryptoDay.hash(htx.key))
        precondition(store.contracts.allSatisfy { $0.day != CryptoDay.key(today) },"today's snapshot never becomes a historical archive row")
        configure(total:200)
        await store.collect(force:true)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").isEmpty,"complete historical equity never requests retired settlements")
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_historical_funding_rate").isEmpty && AssetMockProtocol.paths("/swap-api/v3/swap_financial_record").isEmpty,"neither cached today funding nor completed historical funding is fetched again when retrying yesterday's settlement")
        precondition(store.contracts.count == 8 && store.portfolio.last?.values["total"] == 250 && store.pendingCount == 7)
        precondition(repository.reads == 0 && repository.commits.isEmpty)
        let restored=makeStore()
        configure(total:300)
        restored.loadCachedData()
        precondition(restored.binanceSnapshot == store.binanceSnapshot,"Binance details restore before querying the API")
        precondition(restored.portfolio.last?.values["total"] == 250 && AssetMockProtocol.requests.isEmpty,"reentry immediately displays the previous cached total")
        precondition(restored.currentContract == store.currentContract,"current contract cache restores before network queries")
        await restored.collect(force:true)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_historical_funding_rate").isEmpty && AssetMockProtocol.paths("/swap-api/v3/swap_financial_record").isEmpty,"funding cache persists across store recreation in the same settlement period")
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
        let priorBinance=restored.binanceSnapshot
        await restored.collect(force:true)
        precondition(restored.binanceSnapshot == priorBinance && restored.binanceError != nil,"failed Binance queries retain the previous snapshot with a visible error")
        precondition(restored.message != nil && restored.portfolio.last?.values["total"] == 350,"partial source failure never overwrites the displayed complete total")
        _ = await restored.trigger()
        precondition(repository.files[portfolioPath] == savedTotal,"failed collection leaves the archived total intact")
        configure(total:600,incompleteHTX:true)
        await restored.collect(force:true)
        precondition(restored.message?.contains("HTX 总资产：") == true && restored.message?.contains("data.updated.success") == true && restored.message?.contains("今日总资产未更新") == true,"incomplete HTX valuation explains the missing daily total")
        precondition(restored.portfolio.last?.values["total"] == 350 && repository.files[portfolioPath] == savedTotal,"incomplete HTX valuation preserves cached and archived complete totals")
        precondition(AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count == 1 && restored.binanceError == nil,"HTX valuation failure does not stop other sources")
        for (response,reason) in [
            (["success":false] as [String:Any],"接口 success"),
            (["success":true] as [String:Any],"缺少 data"),
            (["success":true,"data":["updated":["success":true]]] as [String:Any],"profitAccountBalanceList"),
            (["success":true,"data":["updated":["success":true],"profitAccountBalanceList":[["success":false]]]] as [String:Any],"账户 success")
        ] {
            AssetMockProtocol.configure { _ in response }
            do {
                _ = try await CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)).htxTotal(htx)
                preconditionFailure("incomplete HTX response must report an error")
            } catch {
                precondition(error.localizedDescription.contains(reason) && error.localizedDescription.contains("今日总资产未更新"))
            }
        }
        // A manual trigger queued behind entry collection must still perform a GitHub sync.
        let before=repository.reads
        configure(total:700)
        let entry=Task { await restored.collect(force:true) }
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
        do { try restored.clearCache();preconditionFailure("clearing an active sync must fail") } catch {}
        let nextEntry=Task { await restored.collect(force:true) }
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
        try JSONEncoder().encode(CryptoStore.Cache(records:completeDays+[ancient],archiveLoaded:true,archivedPortfolioDays:[])).write(to:fieldsFile)
        let fieldsStore=CryptoStore(repositoryProvider:{fieldsRepository},client:CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)),loadCredential:{$0 == "htx" ? htx : binance},loadWallets:{[]},cacheDirectory:directory,nowProvider:{now})
        configure(failRates:true)
        await fieldsStore.collect(force:true)
        precondition(fieldsStore.contracts.first{$0.day==completeDays[1].day}?.values["funding_rate"] == nil,"failed field remains missing")
        let filledFee=fieldsStore.contracts.first{$0.day==completeDays[0].day}!
        precondition(filledFee.values["funding_trx"] == 0 && filledFee.values["trx"] == 999 && filledFee.values["equity"] == 299.7,"fill zero fee and preserve every existing value")
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_user_settlement_records").isEmpty && AssetMockProtocol.paths("/api/v3/klines").isEmpty,"missing fee or rate must not require equity or minute history")
        configure()
        await fieldsStore.collect(force:true)
        let filledRate=fieldsStore.contracts.first{$0.day==completeDays[1].day}!
        precondition(abs(filledRate.values["funding_rate"]! - 0.03) < 1e-12 && filledRate.values["funding_trx"] == 7)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_historical_funding_rate").count == 2 && AssetMockProtocol.paths("/swap-api/v3/swap_financial_record").isEmpty,"retry missing rates independently while reusing successfully cached funding cash flow")
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
        await fieldsStore.collect(force:true)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_historical_funding_rate").isEmpty && AssetMockProtocol.paths("/swap-api/v3/swap_financial_record").isEmpty,"complete history and cached today funding are not requested again before settlement")
        let historicalBefore=fieldsStore.contracts
        let pendingBefore=fieldsStore.pendingCount
        configure(currentTRX:1234.56,currentLiquidation:nil)
        await fieldsStore.collect(force:true)
        precondition(fieldsStore.currentContract?.trx == 1234.56 && fieldsStore.currentContract?.equity == 1234.56 && fieldsStore.currentContract?.liquidation == nil)
        precondition(AssetMockProtocol.paths("/swap-api/v1/swap_account_info").count == 1,"complete history only needs one current account query per entry")
        precondition(fieldsStore.contracts == historicalBefore && fieldsStore.pendingCount == pendingBefore,"current snapshot neither changes historical values nor adds an archive row")
        let currentSnapshot=fieldsStore.currentContract
        let cached=try JSONDecoder().decode(CryptoStore.Cache.self,from:Data(contentsOf:fieldsFile))
        precondition(cached.currentContract == currentSnapshot,"new current data is saved to disk as well as published")
        configure(failCurrent:true)
        await fieldsStore.collect(force:true)
        precondition(fieldsStore.currentContract == currentSnapshot,"failed current query retains the old snapshot and its timestamp")
        configure(currentLiquidation:0)
        await fieldsStore.collect(force:true)
        precondition(fieldsStore.currentContract?.liquidation == nil,"zero liquidation is unavailable, not a valid price")
        AssetMockProtocol.configure { request in
            if request.url!.path == "/api/v3/ticker/price" {
                precondition(request.value(forHTTPHeaderField:"X-MBX-APIKEY") == nil,"public price requests never carry credentials")
                return [["symbol":"BTCUSDT","price":"100000"],["symbol":"FOOBTC","price":"0.00002"],["symbol":"DEADUSDT","price":"0"]]
            }
            return [["walletName":"Spot","balance":"3.9","assetBalances":[
                ["asset":"BTC","free":"0.000009","locked":"0","freeze":"0","withdrawing":"0"],
                ["asset":"FOO","free":"1","locked":"0","freeze":"0","withdrawing":"0"],
                ["asset":"USDT","free":"1","locked":"0","freeze":"0","withdrawing":"0"]
            ]]]
        }
        let priced=try await CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)).binanceSnapshot(binance)
        precondition(priced.accounts[0].visibleAssets!.map(\.symbol) == ["FOO","USDT"],"filter dust by converted value rather than token quantity")
        precondition(priced.accounts[0].visibleAssets![0].price == 2 && priced.accounts[0].visibleAssets![0].usdtValue == 2,"convert BTC quoted holdings to USDT")
        precondition(priced.total == 3.9,"dust filtering preserves the exchange reported total")
        AssetMockProtocol.configure { request in
            switch request.url!.path {
            case "/sapi/v1/equity/market/quote":
                precondition(request.value(forHTTPHeaderField:"X-MBX-APIKEY") == binance.key)
                let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
                precondition(!query.contains { $0.name == "signature" },"stock market data needs the API key but no signature")
                let ticker=query.first { $0.name == "symbol" }!.value!
                if ticker == "EMPTY" { return Data() }
                if ticker == "FAIL" { throw HakoError(message:"test quote unavailable") }
                precondition(ticker == "AAPL","strip only EQ_ before requesting stock quotes")
                return ["symbol":"AAPL","bidPrice":"180","askPrice":"182"]
            case "/api/v3/ticker/price": return [["symbol":"USDCUSDT","price":"0.99"],["symbol":"EQ_AAPLUSDT","price":"9999"]]
            default: return [["walletName":"Stock","balance":"1000","assetBalances":[
                ["asset":"EQ_AAPL","free":"2","locked":"0","freeze":"0","withdrawing":"0"],
                ["asset":"EQ_EMPTY","free":"1","locked":"0","freeze":"0","withdrawing":"0"],
                ["asset":"EQ_FAIL","free":"1","locked":"0","freeze":"0","withdrawing":"0"]
            ]]]
            }
        }
        let stocks=try await CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)).binanceSnapshot(binance)
        let apple=stocks.accounts[0].assets!.first { $0.symbol == "EQ_AAPL" }!
        precondition(apple.equityUSDPrice == 181 && abs(apple.usdtValue! - 358.38) < 0.00001,"stock midpoint is in USD; USDT uses the documented USDC proxy")
        precondition(stocks.accounts[0].visibleAssets!.count == 3 && stocks.total == 1000,"empty or failed stock quotes never hide holdings or change exchange totals")
        precondition(stocks.accounts[0].assets!.filter { $0.symbol != "EQ_AAPL" }.allSatisfy { $0.price == nil && $0.equityUSDPrice == nil })
        let crossed=try CryptoClient.binanceEquityMidpoint(["bidPrice":"182","askPrice":"180"])
        let zero=try CryptoClient.binanceEquityMidpoint(["bidPrice":"0","askPrice":"180"])
        precondition(crossed == nil && zero == nil,"invalid or one-sided quotes do not invent a stock price")
        let stockHandler=AssetMockProtocol.handler!
        AssetMockProtocol.configure { request in
            if request.url!.path == "/api/v3/ticker/price" { throw HakoError(message:"test conversion unavailable") }
            return try stockHandler(request)
        }
        let unconverted=try await CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)).binanceSnapshot(binance)
        let usdOnly=unconverted.accounts[0].assets!.first { $0.equitySymbol == "AAPL" }!
        precondition(usdOnly.equityUSDPrice == 181 && usdOnly.price == nil && usdOnly.isVisible,"missing USDT conversion preserves USD stock quotes without assuming USD equals USDT")
        // A cold entry reads the archive without posting or querying asset APIs.
        let coldRepository=AssetRepository()
        let archived=CryptoRecord(kind:"htx-trx",day:"2026-09-26",sampledAt:0,scope:"",values:["funding_rate":0.022])
        coldRepository.files[archived.path]=try CryptoRecord.encode([archived],kind:"htx-trx")
        let coldFile=directory.appendingPathComponent("crypto/"+CryptoDay.hash(coldRepository.storageScope)+".json")
        func coldStore()->CryptoStore {
            CryptoStore(repositoryProvider:{coldRepository},client:CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)),loadCredential:{_ in CryptoCredential()},loadWallets:{[]},cacheDirectory:directory,nowProvider:{now})
        }
        AssetMockProtocol.configure { _ in fatalError("Archive-only entry must not query asset APIs") }
        let cold=coldStore()
        cold.loadCachedData()
        precondition(cold.contracts.isEmpty && coldRepository.reads == 0)
        await cold.collect(force:true)
        precondition(cold.message == nil && cold.contracts.first?.values["funding_rate"] == 0.022 && cold.cache.archiveLoaded == true)
        precondition(coldRepository.reads == 2 && coldRepository.commits.isEmpty && cold.pendingCount == 0 && AssetMockProtocol.requests.isEmpty,"cold bootstrap is read-only and does not create pending rows")
        let warm=coldStore();warm.loadCachedData()
        await warm.collect(force:true)
        precondition(warm.contracts == cold.contracts && coldRepository.reads == 2,"persisted archive cache avoids fetching GitHub again")
        let otherCache=directory.appendingPathComponent("crypto/unrelated.json")
        try Data("preserve".utf8).write(to:otherCache)
        let archiveBefore=coldRepository.files
        try warm.clearCache()
        precondition(warm.cacheGeneration == 1 && warm.contracts.isEmpty && warm.portfolio.isEmpty && warm.currentContract == nil && warm.pendingCount == 0 && !FileManager.default.fileExists(atPath:coldFile.path))
        precondition(FileManager.default.fileExists(atPath:otherCache.path) && coldRepository.files == archiveBefore && coldRepository.commits.isEmpty,"clear is scoped to this local cache")
        coldRepository.failReads=true
        await warm.collect(force:true)
        precondition(warm.message?.contains("test archive unavailable") == true && warm.cache.archiveLoaded != true && warm.contracts.isEmpty,"archive failure remains visible and retryable")
        coldRepository.failReads=false
        await warm.collect(force:true)
        precondition(warm.message == nil && warm.cache.archiveLoaded == true && warm.contracts.first?.values["funding_rate"] == 0.022,"entry after clearing retries and rebuilds from GitHub")
        // Clearing explicitly discards pending records and live snapshots.
        let percentCurrent=CryptoCurrentContract(sampledAt:now,scope:"",trx:1,price:0.3,available:nil,unrealizedProfit:nil,liquidation:nil,fundingTRX:0,fundingRate:0.04)
        try JSONEncoder().encode(CryptoStore.Cache(records:[archived],pending:[archived],currentContract:percentCurrent,archiveLoaded:true)).write(to:coldFile)
        let pendingStore=coldStore();pendingStore.loadCachedData()
        precondition(pendingStore.pendingCount == 1 && pendingStore.currentContract?.fundingRate == 0.04)
        try pendingStore.clearCache()
        precondition(pendingStore.pendingCount == 0 && pendingStore.currentContract == nil && pendingStore.contracts.isEmpty,"clear removes unsynced records and current snapshots")
        try Data("corrupt cache".utf8).write(to:coldFile)
        let corrupt=coldStore();corrupt.loadCachedData()
        precondition(corrupt.message != nil)
        try corrupt.clearCache()
        await corrupt.collect(force:true)
        precondition(corrupt.message == nil && corrupt.contracts.count == 1,"clear also recovers unreadable caches")
        // Existing daily balances suppress only the reminder; explicit sync still uploads fresh values.
        let reminderRepository=AssetRepository()
        let remoteBalance=CryptoRecord(kind:"portfolio",day:CryptoDay.key(now),sampledAt:0,scope:"",values:["total":0,"binance":0])
        reminderRepository.files[remoteBalance.path]=try CryptoRecord.encode([remoteBalance],kind:"portfolio")
        let reminderFile=directory.appendingPathComponent("crypto/"+CryptoDay.hash(reminderRepository.storageScope)+".json")
        // Older caches lack the remote-day index and must read GitHub once to populate it.
        try JSONEncoder().encode(CryptoStore.Cache(archiveLoaded:true)).write(to:reminderFile)
        func reminderStore()->CryptoStore {
            CryptoStore(repositoryProvider:{reminderRepository},client:CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)),loadCredential:{$0 == "binance" ? binance : CryptoCredential()},loadWallets:{[]},cacheDirectory:directory,nowProvider:{now})
        }
        configure()
        let reminder=reminderStore()
        await reminder.collect(force:true)
        precondition(reminder.message == nil && reminderRepository.reads == 2 && reminderRepository.commits.isEmpty)
        precondition(reminder.pendingCount == 1 && reminder.pendingReminderCount == 0 && reminder.portfolio.last?.values["total"] == 50,"GitHub balance including zero hides the reminder without discarding the fresh local balance")
        let reminderRestored=reminderStore()
        reminderRestored.loadCachedData()
        precondition(reminderRestored.pendingCount == 1 && reminderRestored.pendingReminderCount == 0,"remote-day knowledge survives reopening")
        _=await reminderRestored.trigger()
        let updatedBalance=try CryptoRecord.decode(reminderRepository.files[remoteBalance.path]!,kind:"portfolio",year:"2026")
        precondition(reminderRestored.message == nil && reminderRestored.pendingCount == 0 && updatedBalance.first?.values["total"] == 50,"manual sync still uploads the hidden same-day balance")
        var reminderCache=reminderRestored.cache
        let missingBalance=CryptoRecord(kind:"portfolio",day:"2026-11-04",sampledAt:0,scope:"",values:["total":1])
        reminderCache.pending=[remoteBalance,missingBalance,archived]
        try JSONEncoder().encode(reminderCache).write(to:reminderFile)
        let mixedReminder=reminderStore()
        mixedReminder.loadCachedData()
        precondition(mixedReminder.pendingCount == 3 && mixedReminder.pendingReminderCount == 2,"missing balance dates and contract rows still appear in the reminder")
        try mixedReminder.clearCache()
        precondition(mixedReminder.cache.archivedPortfolioDays == nil && mixedReminder.pendingReminderCount == 0,"clearing removes remote-day metadata as well")
        // Automatic entry collection reuses only successful, same-day snapshots for six hours.
        let ttlRepository=AssetRepository()
        var ttlNow=now
        var ttlCredential=binance
        func ttlStore()->CryptoStore {
            CryptoStore(repositoryProvider:{ttlRepository},client:CryptoClient(session:session,logStore:HakoLogStore(fileURL:nil)),loadCredential:{$0 == "binance" ? ttlCredential : CryptoCredential()},loadWallets:{[]},cacheDirectory:directory,nowProvider:{ttlNow})
        }
        configure()
        let ttl=ttlStore()
        await ttl.collect()
        precondition(ttl.message == nil && ttl.cache.assetsUpdatedAt == now && !ttl.assetsExpired)
        let calls=AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count
        let reads=ttlRepository.reads
        ttlNow=now.addingTimeInterval(6*60*60-1)
        await ttl.collect()
        let reopened=ttlStore()
        await reopened.collect()
        precondition(AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count == calls && ttlRepository.reads == reads,"valid cache survives re-entry and process recreation without API or GitHub reads")
        ttlNow=now.addingTimeInterval(6*60*60)
        precondition(reopened.assetsExpired)
        await reopened.collect()
        precondition(AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count == calls+1,"exactly six hours expires the snapshot")
        ttlCredential.secret="changed-secret"
        await reopened.collect()
        precondition(AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count == calls+2,"changed credentials invalidate an otherwise fresh snapshot")
        ttlNow=CryptoDay.calendar.date(bySettingHour:23,minute:59,second:0,of:now)!
        await reopened.collect(force:true)
        let lateCalls=AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count
        ttlNow=ttlNow.addingTimeInterval(60)
        precondition(reopened.assetsExpired)
        await reopened.collect()
        precondition(AssetMockProtocol.paths("/sapi/v1/asset/wallet/balance").count == lateCalls+1,"midnight invalidates a one-minute-old snapshot")
        ttlNow=ttlNow.addingTimeInterval(6*60*60)
        configure(failBinance:true)
        let successfulAt=reopened.cache.assetsUpdatedAt
        await reopened.collect()
        precondition(reopened.message != nil && reopened.assetsExpired && reopened.cache.assetsUpdatedAt == successfulAt,"a failed refresh preserves data and never renews cache lifetime")
        configure()
        await reopened.collect()
        precondition(reopened.message == nil && !reopened.assetsExpired,"failed refresh is retried on the next entry")
        try reopened.clearCache()
        precondition(reopened.assetsExpired && reopened.cache.assetsUpdatedAt == nil,"clearing cache invalidates the successful collection timestamp")
        print("Crypto store: cache bootstrap, scoped clearing, archive retry, cache-only sync, pending reminders and source collection passed")
    }
}
