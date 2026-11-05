import Foundation
import Combine

@MainActor final class CryptoStore: ObservableObject {
    static let shared = CryptoStore()
    private var running: Task<Void, Never>?
    private var runningSyncs = false
    private let repositoryProvider: () -> any GitHubRepositoryAccess
    private let client: CryptoClient
    private let loadCredential: (String) throws -> CryptoCredential
    private let loadWallets: () throws -> [CryptoWallet]
    private let cacheDirectory: URL
    private let nowProvider: () -> Date

    init(repositoryProvider: @escaping () -> any GitHubRepositoryAccess = AppServices.privateGitHub,
         client: CryptoClient = CryptoClient(),
         loadCredential: @escaping (String) throws -> CryptoCredential = CryptoCredential.load,
         loadWallets: @escaping () throws -> [CryptoWallet] = CryptoWallet.load,
         cacheDirectory: URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0],
         nowProvider: @escaping () -> Date = { .now }) {
        self.repositoryProvider=repositoryProvider;self.client=client
        self.loadCredential=loadCredential;self.loadWallets=loadWallets;self.cacheDirectory=cacheDirectory;self.nowProvider=nowProvider
    }

    // Restore synchronously before checking whether the cached assets are still valid.
    func loadCachedData() {
        guard !busy else { return }
        do { try restoreLocalData(repositoryProvider()) }
        catch { message=error.localizedDescription }
    }
    // Collection updates the published cache; explicit synchronization never queries asset APIs.
    func collect(force: Bool = false) async { await run(sync:false,force:force) }
    var assetsExpired: Bool { !CryptoSyncPolicy.canReuseAssets(updatedAt:cache.assetsUpdatedAt,now:nowProvider()) }
    var pricesExpired: Bool { !CryptoSyncPolicy.canReusePrices(updatedAt:cache.pricesUpdatedAt,now:nowProvider()) }
    func trigger() async -> String {
        await run(sync:true)
        return message ?? "本机缓存已同步到 GitHub。"
    }
    private func run(sync: Bool, force: Bool = false) async {
        if let running {
            let satisfies = sync == runningSyncs
            await running.value
            if !satisfies { await run(sync:sync,force:force) }
            return
        }
        runningSyncs=sync
        let task=Task {
            await self.refresh(sync:sync,force:force)
            self.running=nil;self.runningSyncs=false
        }
        running=task
        await task.value
    }
    struct Cache: Codable {
        var records: [CryptoRecord] = []
        var pending: [CryptoRecord] = []
        var syncedAt: Date?
        var walletBalances: [String:Double]?
        var currentContract: CryptoCurrentContract?
        var walletSnapshots: [String:CryptoWalletSnapshot]?
        var binanceSnapshot: CryptoBinanceSnapshot?
        var htxSnapshot: CryptoHTXSnapshot?
        var archiveLoaded = false
        var archivedPortfolioDays: Set<String>?
        var assetsUpdatedAt: Date?
        var assetsScope: String?
        var pricesUpdatedAt: Date?
    }

    @Published private(set) var cache = Cache()
    @Published private(set) var busy = false
    @Published private(set) var cacheGeneration = 0
    @Published var message: String?
    @Published private(set) var wallets: [CryptoWallet] = []
    @Published private(set) var walletValues: [UUID: Double] = [:]
    @Published private(set) var walletErrors: [UUID: String] = [:]
    @Published private(set) var binanceError: String?
    @Published private(set) var binanceConfigured = false
    @Published private(set) var binanceScope = ""
    @Published private(set) var htxConfigured = false
    @Published private(set) var htxScope = ""
    var htxSnapshot: CryptoHTXSnapshot? {
        guard htxConfigured, let snapshot = cache.htxSnapshot, snapshot.scope == htxScope else { return nil }
        return snapshot
    }
    var binanceSnapshot: CryptoBinanceSnapshot? {
        guard binanceConfigured, let snapshot=cache.binanceSnapshot, snapshot.scope == binanceScope else { return nil }
        return snapshot
    }
    func walletSnapshot(_ wallet:CryptoWallet) -> CryptoWalletSnapshot? { cache.walletSnapshots?[wallet.identity]?.includedOnly }
    var chainHoldings: [CryptoChainHolding] {
        CryptoChainHolding.aggregate(wallets.compactMap { wallet in walletSnapshot(wallet).map { (wallet,$0) } })
    }
    var chainTotal:Double? {
        guard !wallets.isEmpty else { return nil }
        let snapshots=wallets.compactMap { walletSnapshot($0) }
        guard snapshots.count == wallets.count else { return nil }
        return snapshots.reduce(0) { $0 + $1.total }
    }
    @Published private(set) var scope = ""
    @Published private(set) var contractScope = ""
    private var file: URL?
    var portfolio: [CryptoRecord] { cache.records.filter { $0.kind == "portfolio" }.sorted { $0.day < $1.day } }
    var contracts: [CryptoRecord] { cache.records.filter { $0.kind == "htx-trx" }.sorted { $0.day < $1.day } }
    var currentContract: CryptoCurrentContract? {
        guard let current=cache.currentContract, contractScope.isEmpty || current.scope == contractScope else { return nil }
        return current
    }
    var pendingCount: Int { cache.pending.count }
    var pendingReminderCount: Int {
        cache.pending.filter { record in
            record.kind != "portfolio" || !(cache.archivedPortfolioDays?.contains(record.day) ?? false)
        }.count
    }
    func clearCache() throws {
        guard !busy, running == nil else { throw HakoError(message:"资产正在更新或同步，请完成后再清空缓存。") }
        let repository=repositoryProvider()
        let target=cacheDirectory.appendingPathComponent("crypto/"+CryptoDay.hash(repository.storageScope)+".json")
        if FileManager.default.fileExists(atPath:target.path) { try FileManager.default.removeItem(at:target) }
        cache=Cache();file=nil;walletValues=[:];walletErrors=[:];binanceError=nil;message=nil
        scope="";contractScope=""
        cacheGeneration+=1
    }
    private func persist(_ value: Cache) throws {
        guard let file else { throw HakoError(message:"资产缓存尚未就绪。") }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:file,options:.atomic); cache=value
    }
    private func restoreLocalData(_ repository: any GitHubRepositoryAccess) throws {
        let nextFile = cacheDirectory
            .appendingPathComponent("crypto/"+CryptoDay.hash(repository.storageScope)+".json")
        if file != nextFile {
            cache = Cache(); walletValues = [:]; walletErrors = [:]; file=nil
            let exists=FileManager.default.fileExists(atPath:nextFile.path)
            if exists { cache=try JSONDecoder().decode(Cache.self,from:Data(contentsOf:nextFile)) }
            file=nextFile
        }
        wallets=try loadWallets()
        let htx = try loadCredential("htx")
        htxConfigured = htx.configured
        htxScope = CryptoDay.hash(htx.key+"|"+htx.secret)
        let binance=try loadCredential("binance")
        binanceConfigured=binance.configured
        let nextBinanceScope=CryptoDay.hash(binance.key)
        if binanceScope != nextBinanceScope { binanceError=nil }
        binanceScope=nextBinanceScope
        walletValues=Dictionary(uniqueKeysWithValues:wallets.compactMap { wallet in
            walletSnapshot(wallet).map { (wallet.id,$0.total) }
        })
    }
    private func saveAcquired(_ record: CryptoRecord) throws {
        let existing=cache.records.first { $0.id == record.id && $0.kind == "htx-trx" }
        let filled=existing?.fillingMissingContractFields(from:record) ?? record
        if let existing, filled.values == existing.values { return }
        let row=try filled.normalized()
        var value=cache
        value.records=CryptoRecord.merge(value.records,[row]);value.pending=CryptoRecord.merge(value.pending,[row])
        if row.kind == "portfolio" {
            value.walletBalances=Dictionary(uniqueKeysWithValues:wallets.compactMap { wallet in walletValues[wallet.id].map { (wallet.identity,$0) } })
        }
        try persist(value)
    }
    private func refresh(sync: Bool, force: Bool) async {
        busy=true;message=nil
        let operation=sync ? "资产同步" : "资产更新"
        if sync { client.logStore.append(source:.crypto,level:.info,message:operation+"开始") }
        defer {
            if let message {
                client.logStore.append(source:.crypto,level:.error,message:operation+"出现错误",detail:message,fullDetail:true)
            } else if sync {
                client.logStore.append(source:.crypto,level:.info,message:operation+"完成")
            }
            busy=false
        }
        do {
            let repository=repositoryProvider()
            try restoreLocalData(repository)
            let htx=try loadCredential("htx"), binance=try loadCredential("binance")
            contractScope=CryptoDay.hash(htx.key)
            scope=CryptoDay.hash(htx.key+"|"+binance.key+"|"+wallets.map(\.identity).sorted().joined(separator:"|"))
            var errors:[String]=[]
            if sync {
                try await synchronize(repository)
                return
            }
            let now=nowProvider()
            let assetsScope=CryptoDay.hash(htx.key+"|"+htx.secret+"|"+binance.key+"|"+binance.secret+"|"+wallets.map(\.identity).sorted().joined(separator:"|"))
            if !force && cache.assetsScope == assetsScope && CryptoSyncPolicy.canReuseAssets(updatedAt:cache.assetsUpdatedAt,now:now) {
                if pricesExpired { try await refreshPrices(htx:htx,binance:binance) }
                try await refreshHTXDetails(htx,now:now,force:false)
                return
            }
            if cache.archiveLoaded != true || cache.archivedPortfolioDays == nil {
                do { try await rebuildArchiveCache(repository) }
                catch { errors.append("GitHub 历史缓存："+error.localizedDescription) }
            }
            // Inspect local records first. Network requests are derived only from this missing-data plan.
            let contractRequests: [(day:Date,fields:Set<String>)] = htx.configured
                ? CryptoSyncPolicy.recentContractDays(now:now).compactMap { day in
                    let existing=cache.records.first { $0.kind == "htx-trx" && $0.day == CryptoDay.key(day) }
                    let fields=existing?.missingContractFields ?? CryptoRecord.contractFields
                    return fields.isEmpty ? nil : (day,fields)
                } : []
            var totals:[String:Double]=[:]
            var currentResult:Result<CryptoCurrentContract,Error>?
            if htx.configured {
                do { totals["htx"]=try await client.htxTotal(htx) } catch { errors.append("HTX 总资产："+error.localizedDescription) }
                do {
                    let current=try await client.currentContract(htx,scope:contractScope,now:now,cached:cache.currentContract)
                    currentResult = .success(current)
                    var value=cache;value.currentContract=current
                    try persist(value)
                } catch { currentResult = .failure(error);errors.append("今日 TRX 合约："+error.localizedDescription) }
                try await refreshHTXDetails(htx,now:now,force:force)
            }
            if binance.configured {
                binanceError=nil
                do {
                    let snapshot=try await client.binanceSnapshot(binance)
                    var value=cache;value.binanceSnapshot=snapshot
                    try persist(value)
                    totals["binance"]=snapshot.total
                    binanceError=snapshot.quoteError
                    if let error=snapshot.quoteError { errors.append("Binance 报价："+error) }
                } catch {
                    binanceError=error.localizedDescription
                    errors.append("Binance："+error.localizedDescription)
                }
            }
            var chain=0.0,chainComplete=true
            walletErrors=[:]
            for wallet in wallets {
                do {
                    let snapshot=try await client.walletSnapshot(wallet)
                    var value=cache
                    if value.walletSnapshots == nil { value.walletSnapshots=[:] }
                    if value.walletBalances == nil { value.walletBalances=[:] }
                    value.walletSnapshots?[wallet.identity]=snapshot
                    value.walletBalances?[wallet.identity]=snapshot.total
                    try persist(value)
                    walletValues[wallet.id]=snapshot.total;chain+=snapshot.total
                }
                catch {
                    chainComplete=false;walletErrors[wallet.id]=error.localizedDescription
                    errors.append(wallet.name+"："+error.localizedDescription)
                }
            }
            if !wallets.isEmpty && chainComplete { totals["chain"]=chain }
            let complete=(!htx.configured || totals["htx"] != nil) && (!binance.configured || totals["binance"] != nil) && chainComplete
            if complete && !totals.isEmpty {
                totals["total"]=totals.values.reduce(0,+)
                try saveAcquired(CryptoRecord(kind:"portfolio",day:CryptoDay.key(now),sampledAt:now.timeIntervalSince1970,scope:scope,values:totals))
            }
            let history=try await client.contractHistory(htx,now:now,requests:contractRequests,current:currentResult)
            for request in contractRequests {
                do {
                    let result=try await client.contract(htx,now:now,scope:contractScope,day:request.day,fields:request.fields,history:history)
                    if !result.record.values.isEmpty { try saveAcquired(result.record) }
                    errors += result.errors.map { CryptoDay.key(request.day)+" TRX 合约 · "+$0 }
                }
                catch { errors.append(CryptoDay.key(request.day)+" TRX 合约："+error.localizedDescription) }
            }
            if !htx.configured && !binance.configured && wallets.isEmpty && cache.records.isEmpty { errors.append("尚未配置资产来源，请先设置交易所 API 或观察地址。") }
            if errors.isEmpty {
                var value=cache;value.assetsUpdatedAt=now;value.assetsScope=assetsScope;value.pricesUpdatedAt=now
                try persist(value)
            }
            message=errors.isEmpty ? nil : errors.joined(separator:"\n")
        } catch { message=error.localizedDescription }
    }
    private func refreshHTXDetails(_ credential: CryptoCredential, now: Date, force: Bool) async throws {
        guard credential.configured else { return }
        let previous = htxSnapshot
        guard force || previous?.balanceVersion != CryptoHTXSnapshot.currentBalanceVersion ||
                !CryptoSyncPolicy.canReuseAssets(updatedAt:previous?.sampledAt,now:now) else { return }
        let snapshot = try await client.htxAssetDetails(credential,scope:htxScope,now:now,previous:previous)
        var value = cache
        value.htxSnapshot = snapshot
        try persist(value)
    }

    private func refreshPrices(htx:CryptoCredential,binance:CryptoCredential) async throws {
        var errors:[String]=[]
        if binance.configured,let snapshot=binanceSnapshot {
            do {
                let quoted=try await client.binancePrices(snapshot,credential:binance)
                var value=cache;value.binanceSnapshot=quoted
                try persist(value);binanceError=quoted.quoteError
                if let error=quoted.quoteError { errors.append("Binance 报价："+error) }
            } catch { binanceError=error.localizedDescription;errors.append("Binance 报价："+error.localizedDescription) }
        }
        var prices:[String:Double]=["USDT":1]
        var symbols=Set(wallets.flatMap { walletSnapshot($0)?.assets.map(\.symbol) ?? [] })
        if htx.configured,currentContract != nil { symbols.insert("TRX") }
        for symbol in symbols.sorted() where prices[symbol] == nil {
            do { prices[symbol]=try await client.price(symbol) }
            catch { errors.append(symbol+" 报价："+error.localizedDescription) }
        }
        var value=cache
        if let snapshot = htxSnapshot {
            value.htxSnapshot = try await client.htxAssetPrices(snapshot)
        }
        if htx.configured,var current=currentContract,let price=prices["TRX"] {
            current.price=price;value.currentContract=current
        }
        for wallet in wallets {
            guard var snapshot=walletSnapshot(wallet) else { continue }
            snapshot.assets=snapshot.assets.map { asset in
                var asset=asset
                if let price=prices[asset.symbol] { asset.value=asset.quantity * price }
                return asset
            }
            snapshot.total=snapshot.assets.compactMap(\.value).reduce(0,+)
            value.walletSnapshots?[wallet.identity]=snapshot
            value.walletBalances?[wallet.identity]=snapshot.total
            walletValues[wallet.id]=snapshot.total
        }
        // Quote refreshes never renew balance timestamps or create pending archive rows.
        if errors.isEmpty { value.pricesUpdatedAt=nowProvider() }
        try persist(value)
        message=errors.isEmpty ? nil : errors.joined(separator:"\n")
    }
    private func readArchive(_ repository: any GitHubRepositoryAccess) async throws -> (records:[CryptoRecord],head:String) {
        var remote:[CryptoRecord]=[], head:String?
        for kind in ["htx-trx","portfolio"] {
            let directory=try await repository.listFiles(in:"data/crypto/"+kind)
            if let head, head != directory.head { throw HakoError(message:"资产仓库正在更新，请重试同步。") }
            head=directory.head
            for entry in directory.entries where entry.kind == "blob" && entry.name.range(of:"^[0-9]{4}\\.csv$",options:.regularExpression) != nil {
                let snapshot=try await repository.readFile(at:"data/crypto/"+kind+"/"+entry.name,revision:head)
                guard let text=snapshot.text else { throw HakoError(message:"资产年度文件不可读取。") }
                let year=String(entry.name.prefix(4))
                remote += try CryptoRecord.decode(text,kind:kind,year:year)
            }
        }
        guard let head else { throw HakoError(message:"资产仓库版本缺失。") }
        return (remote,head)
    }
    private func rebuildArchiveCache(_ repository:any GitHubRepositoryAccess) async throws {
        let archive=try await readArchive(repository)
        var value=cache
        let local=Dictionary(uniqueKeysWithValues:value.records.map { ($0.id,$0) })
        let remote=archive.records.map { record in
            var record=record
            record.scope=record.kind == "htx-trx" ? contractScope : scope
            if record.kind == "htx-trx",let acquired=local[record.id] {
                record=record.fillingMissingContractFields(from:acquired)
            }
            return record
        }
        let archivedContracts=Set(remote.filter{$0.kind == "htx-trx"}.map(\.id))
        value.records=CryptoRecord.merge(remote,value.records.filter{!archivedContracts.contains($0.id)})
        value.archiveLoaded=true
        value.archivedPortfolioDays=Set(archive.records.filter { $0.kind == "portfolio" && $0.values["total"] != nil }.map(\.day))
        try persist(value)
    }
    private func synchronize(_ repository: any GitHubRepositoryAccess) async throws {
        for attempt in 0..<3 {
            let archive=try await readArchive(repository)
            var remote=archive.records
            let head=archive.head
            var value=cache
            value.archiveLoaded=true
            value.archivedPortfolioDays=Set(remote.filter { $0.kind == "portfolio" && $0.values["total"] != nil }.map(\.day))
            // Source identity stays in the local cache; archives have one row per day.
            remote = remote.map { row in
                var row=row
                if let local=cache.records.first(where:{ $0.id == row.id }),
                   let normalized=try? local.normalized(), normalized.values == row.values {
                    row.scope=local.scope;row.sampledAt=local.sampledAt
                } else { row.scope = row.kind == "htx-trx" ? contractScope : scope }
                return row
            }
            let archivedContracts=Dictionary(uniqueKeysWithValues:remote.filter { $0.kind == "htx-trx" }.map { ($0.id,$0) })
            value.pending=try value.pending.compactMap { pending in
                if let archived=archivedContracts[pending.id] {
                    let filled=archived.fillingMissingContractFields(from:pending)
                    return filled.values == archived.values ? nil : try filled.normalized()
                }
                return try pending.normalized()
            }
            value.records=CryptoRecord.merge(remote,value.pending)
            let paths=Set(value.pending.map(\.path))
            var files:[String:String]=[:]
            for path in paths {
                let kind = path.split(separator:"/")[2]
                files[path]=try CryptoRecord.encode(value.records.filter { $0.path == path },kind:String(kind))
            }
            // Keep the merged cache visible even if uploading fails; pending rows remain retryable.
            try persist(value)
            let result=try await repository.commit(files:files,expectedHead:head,message:GitHubCommitMessage(headline:"Update private asset snapshots"))
            if result == .staleHead { if attempt == 2 { throw HakoError(message:"私有库持续变化，请稍后重试。") }; continue }
            value.archivedPortfolioDays=Set(value.records.filter { $0.kind == "portfolio" && $0.values["total"] != nil }.map(\.day))
            value.pending=[];value.syncedAt = .now;try persist(value);message=nil;return
        }
    }
}
