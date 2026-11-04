import Foundation
import Combine

@MainActor final class CryptoStore: ObservableObject {
    static let shared = CryptoStore()
    private var running: Task<Void, Never>?
    func trigger() async -> String {
        if let running { await running.value }
        else {
            let task = Task { await self.refresh() }; running=task; await task.value; running=nil
        }
        if let message { return message }
        return "资产同步已检查：昨日 TRX 合约与今日总资产已同步的任务自动跳过。待同步 \(pendingCount) 条。"
    }
    struct Cache: Codable { var records: [CryptoRecord] = []; var pending: [CryptoRecord] = []; var syncedAt: Date?; var walletBalances: [String:Double]?; var legacyImported: Bool? }
    @Published private(set) var cache = Cache()
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var wallets: [CryptoWallet] = []
    @Published private(set) var walletValues: [UUID: Double] = [:]
    @Published private(set) var scope = ""
    @Published private(set) var contractScope = ""
    private var file: URL?
    var portfolio: [CryptoRecord] { cache.records.filter { $0.kind == "portfolio" && $0.scope == scope }.sorted { $0.day < $1.day } }
    var contracts: [CryptoRecord] { cache.records.filter { $0.kind == "htx-trx" && $0.scope == contractScope }.sorted { $0.day < $1.day } }
    var pendingCount: Int { cache.pending.count }
    private func persist(_ value: Cache) throws {
        guard let file else { throw HakoError(message:"资产缓存尚未就绪。") }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:file,options:.atomic); cache=value
    }
    func refresh() async {
        guard !busy else { return }; busy=true; message=nil; defer { busy=false }
        do {
            let repository = AppServices.privateGitHub()
            let nextFile = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("crypto/"+CryptoDay.hash(repository.storageScope)+".json")
            if file != nextFile {
                cache = Cache(); walletValues = [:]; file=nil
                if FileManager.default.fileExists(atPath:nextFile.path) { cache=try JSONDecoder().decode(Cache.self,from:Data(contentsOf:nextFile)) }
                file=nextFile
            }
            wallets=try CryptoWallet.load()
            walletValues=Dictionary(uniqueKeysWithValues:wallets.compactMap { wallet in
                cache.walletBalances?[wallet.identity].map { (wallet.id,$0) }
            })
            let htx=try CryptoCredential.load("htx"), binance=try CryptoCredential.load("binance")
            contractScope=CryptoDay.hash(htx.key)
            scope=CryptoDay.hash(htx.key+"|"+binance.key+"|"+wallets.map(\.identity).sorted().joined(separator:"|"))
            let now=Date.now, dates=CryptoSyncPolicy.dates(now:now), today=dates.today, yesterday=dates.yesterday
            let hasSources=htx.configured || binance.configured || !wallets.isEmpty
            func done(_ kind: String, _ day: String, _ scope: String) -> Bool {
                CryptoSyncPolicy.confirmed(cache.records,pending:cache.pending,kind:kind,day:day,scope:scope)
            }
            let needsLegacy=htx.configured && cache.legacyImported != true
            if !needsLegacy && cache.pending.isEmpty && hasSources && done("portfolio",today,scope) && (!htx.configured || done("htx-trx",yesterday,contractScope)) { return }
            // Pull history even if exchange APIs are unavailable. Keep unsent local snapshots.
            do { try await synchronize(repository) } catch { message="私有库同步："+error.localizedDescription }
            var migrationError:String?
            if needsLegacy {
                do {
                    let history=await CryptoHistoricalAPI.fetch(htx,until:CryptoDay.calendar.startOfDay(for:now))
                    var failures=history.failures,legacy:[CryptoRecord]=[]
                    do { legacy=try await CryptoLegacyBackfill.fetch(scope:contractScope,before:today) }
                    catch { failures.append("历史 CSV 读取暂未成功") }
                    let imported=CryptoLegacyBackfill.combine(api:history.fields,times:history.times,legacy:legacy,existing:cache.records,scope:contractScope,before:today)
                    let changed=imported.filter { row in !cache.records.contains(row) }
                    var value=cache;value.records=CryptoRecord.merge(value.records,changed);value.pending=CryptoRecord.merge(value.pending,changed);value.legacyImported=failures.isEmpty;try persist(value)
                    try await synchronize(repository)
                    if !failures.isEmpty { migrationError=failures.joined(separator:"；")+"；已保留可用字段，下次会重试。" }
                } catch { migrationError="历史补齐："+error.localizedDescription }
            }
            let client=CryptoClient()
            let needTotal = !done("portfolio",today,scope)
            var totals:[String:Double]=[:], errors:[String]=[]
            var acquired:[CryptoRecord]=[]
            if htx.configured {
                if needTotal { do { totals["htx"]=try await client.htxTotal(htx) } catch { errors.append("HTX 总资产："+error.localizedDescription) } }
                if !done("htx-trx",yesterday,contractScope) { do { acquired.append(try await client.contract(htx,now:now,scope:contractScope)) } catch { errors.append("TRX 合约："+error.localizedDescription) } }
            }
            if binance.configured && needTotal {
                do { totals["binance"]=try await client.binanceTotal(binance) } catch { errors.append("Binance："+error.localizedDescription) }
            }
            var chain = 0.0, chainComplete=true
            for wallet in wallets where needTotal {
                do { let value=try await client.walletTotal(wallet); walletValues[wallet.id]=value; chain+=value }
                catch { chainComplete=false; errors.append(wallet.name+"："+error.localizedDescription) }
            }
            if !wallets.isEmpty && chainComplete { totals["chain"]=chain }
            let complete = (!htx.configured || totals["htx"] != nil) && (!binance.configured || totals["binance"] != nil) && chainComplete
            if needTotal && complete && !totals.isEmpty {
                totals["total"]=totals.values.reduce(0,+)
                acquired.append(CryptoRecord(kind:"portfolio",day:CryptoDay.key(now),sampledAt:now.timeIntervalSince1970,scope:scope,values:totals))
            }
            if !acquired.isEmpty {
                var value=cache; value.records=CryptoRecord.merge(value.records,acquired); value.pending=CryptoRecord.merge(value.pending,acquired)
                if acquired.contains(where:{$0.kind=="portfolio"}) {
                    value.walletBalances=Dictionary(uniqueKeysWithValues:wallets.compactMap { wallet in walletValues[wallet.id].map { (wallet.identity,$0) } })
                }
                try persist(value)
                do { try await synchronize(repository) } catch { errors.append("私有库同步："+error.localizedDescription) }
            }
            if !hasSources { errors.append("尚未配置资产来源，请先设置交易所 API 或观察地址。") }
            if let migrationError { errors.append(migrationError) }
            if !errors.isEmpty { message=errors.joined(separator:"\n") }
        } catch { message=error.localizedDescription }
    }
    private func synchronize(_ repository: any GitHubRepositoryAccess) async throws {
        for attempt in 0..<3 {
            var remote:[CryptoRecord]=[], head:String?
            for kind in ["htx-trx","portfolio"] {
                let directory=try await repository.listFiles(in:"data/crypto/"+kind)
                if let head, head != directory.head { throw HakoError(message:"资产仓库正在更新，请重试同步。") }
                head=directory.head
                for entry in directory.entries where entry.kind == "blob" && entry.name.range(of:"^[0-9]{4}\\.csv$",options:.regularExpression) != nil {
                    let snapshot=try await repository.readFile(at:"data/crypto/"+kind+"/"+entry.name,revision:head)
                    guard let text=snapshot.text else { throw HakoError(message:"资产年度文件不可读取。") }
                    remote += try CryptoRecord.decode(text,kind:kind,year:String(entry.name.prefix(4)))
                }
            }
            var value=cache
            value.records=CryptoRecord.merge(remote,value.pending)
            let paths=Set(value.pending.map(\.path))
            var files:[String:String]=[:]
            for path in paths { files[path]=CryptoRecord.encode(value.records.filter { $0.path == path }) }
            let result=try await repository.commit(files:files,expectedHead:head!,message:GitHubCommitMessage(headline:"Update private asset snapshots"))
            if result == .staleHead { if attempt == 2 { throw HakoError(message:"私有库持续变化，请稍后重试。") }; continue }
            value.pending=[];value.syncedAt = .now;try persist(value);message=nil;return
        }
    }
}
