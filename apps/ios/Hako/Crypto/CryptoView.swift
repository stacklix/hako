import SwiftUI
import Charts

struct CryptoView: View {
    private enum Tab: String, CaseIterable { case overview="概览",htx="HTX",binance="Binance",chain="链上资产" }
    @StateObject private var store = CryptoStore.shared
    @State private var tab = Tab.overview
    @State private var trends=false
    @State private var days=30
    @Environment(\.scenePhase) private var scenePhase
    private var latest: CryptoRecord? { store.portfolio.last }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("加密资产").font(.system(size:28,weight:.semibold))
                Text("\(store.busy ? "正在后台采集与同步…" : "私有库 · \(store.pendingCount) 条待同步")")
                    .font(.caption).foregroundStyle(.secondary)
                HakoUnderlineTabs(title:"资产来源",options:Tab.allCases,selection:$tab,label:{$0.rawValue})
                if let message=store.message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if tab == .overview {
                    amountPanel("总资产",value:latest?.values["total"])
                    if let latest {
                        VStack(spacing:16) {
                            source("HTX",value:latest.values["htx"],tab:.htx)
                            source("Binance",value:latest.values["binance"],tab:.binance)
                            source("链上资产",value:latest.values["chain"],tab:.chain)
                        }.cryptoPanel()
                        Text("采集时间：\(latest.date.formatted(date:.numeric,time:.shortened)) · 仅汇总已配置来源")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    CryptoTrend(title:"每日总资产",records:store.portfolio,keys:["total"],names:["总资产"],units:["USDT"])
                } else if tab == .htx {
                    Picker("HTX 页面",selection:$trends) { Text("资产概览").tag(false);Text("趋势图表").tag(true) }.pickerStyle(.segmented)
                    if trends {
                        Picker("统计范围",selection:$days) { Text("最近7天").tag(7);Text("最近30天").tag(30);Text("全部").tag(0) }
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:290),spacing:12)],spacing:12) {
                            ForEach(0..<6) { index in contractChart(index) }
                        }
                    } else {
                        amountPanel("HTX 总资产",value:latest?.values["htx"])
                        VStack(alignment:.leading,spacing:16) {
                            Text("TRX 币本位永续").font(.headline)
                            metric("合约权益",store.contracts.last?.values["trx"],"TRX")
                            metric("USDT 折值",contractValue,"USDT")
                            metric("昨日资金费净收入",store.contracts.last?.values["funding_trx"],"TRX")
                            metric("昨日实际结算费率总和",store.contracts.last?.values["funding_rate"].map{$0*100},"%",precision:4)
                            metric("强平价",store.contracts.last?.values["liquidation"],"USD/TRX",precision:4)
                            metric("累计资金费",store.contracts.isEmpty ? nil : store.contracts.reduce(0){$0+($1.values["funding_trx"] ?? 0)},"TRX")
                            if let last=store.contracts.last { Text("数据日期：\(last.day) · 当日最后一笔结算权益\n结算时点：\(last.date.formatted(date:.numeric,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
                        }.cryptoPanel()
                    }
                    Text("每日获取前一天（Asia/Shanghai）的合约权益、资金费及费率。USDT 折值采用结算前最近完整分钟的 TRX/USDT 价格。累计值仅包含已采集日期。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if tab == .binance {
                    amountPanel("Binance 总资产",value:latest?.values["binance"])
                    Text("通过只读接口汇总已开通钱包的 USDT 估值。每日成功同步后不再重复采集。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    amountPanel("链上资产",value:latest?.values["chain"])
                    VStack(alignment:.leading,spacing:12) {
                        NavigationLink("添加或管理观察地址") { CryptoWalletSettings() }
                        ForEach(store.wallets) { wallet in
                            VStack(alignment:.leading,spacing:5) {
                                Text(wallet.name).font(.subheadline.weight(.semibold))
                                Text(wallet.network+" · "+wallet.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let value=store.walletValues[wallet.id] { Text(value,format:.number.precision(.fractionLength(2))) + Text(" USDT") }
                            }
                            Divider()
                        }
                    }.cryptoPanel()
                }
                if store.portfolio.isEmpty && store.contracts.isEmpty {
                    Text("还没有采集数据。请先配置交易所只读 API、观察地址及主应用私有仓库。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical,18)
                }
                Text("快捷指令：同步加密资产。打开本页自动触发同一任务；已成功同步的日期自动跳过，失败可重试。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) {
            NavigationLink { CryptoSettingsView() } label: { Image(systemName:"slider.horizontal.3") }
                .accessibilityLabel("加密资产连接与地址设置")
        } }
        .refreshable { _ = await store.trigger() }
        .task(id:scenePhase) { if scenePhase == .active { _ = await store.trigger() } }
    }
    private var contractValue: Double? {
        guard let row=store.contracts.last else { return nil }
        if let legacy=row.values["legacy_contract_equity"] { return legacy }
        guard let trx=row.values["trx"],let price=row.values["price"] else { return nil };return trx*price
    }
    private func amountPanel(_ title:String,value:Double?) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline) { Text(value.map{String(format:"%.2f",$0)} ?? "—").font(.system(size:32,weight:.semibold)).monospacedDigit();Text("USDT").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
    }
    private func source(_ title:String,value:Double?,tab:Tab) -> some View {
        Button { self.tab=tab } label: { HStack { Text(title);Spacer();Text(value.map{String(format:"%.2f USDT",$0)} ?? "未配置").monospacedDigit();Image(systemName:"chevron.right").font(.caption) } }.buttonStyle(.plain)
    }
    private func metric(_ title:String,_ value:Double?,_ unit:String,precision:Int=2) -> some View {
        HStack { Text(title).font(.subheadline);Spacer();Text(value.map{String(format:"%.*f",precision,$0)} ?? "—").monospacedDigit();Text(unit).font(.caption).foregroundStyle(.secondary) }
    }
    private func contractChart(_ index:Int) -> some View {
        let titles=["TRX 与 USDT 总额","TRX 总额与 TRX 价格","USDT 总额与 TRX 价格","强平价格与 TRX 价格","每日资金费与费率","累计资金费用"]
        let keys=[["trx","usdt"],["trx","price"],["usdt","price"],["liquidation","price"],["funding_trx","rate_percent"],["cumulative"]]
        let names=[["TRX 权益","USDT 折值"],["TRX 权益","TRX 价格"],["USDT 折值","TRX 价格"],["强平价","TRX 价格"],["资金费","实际费率总和"],["资金费累计"]]
        let units=[["TRX","USDT"],["TRX","USDT/TRX"],["USDT","USDT/TRX"],["USD/TRX","USDT/TRX"],["TRX","%"],["TRX"]]
        var sum=0.0
        let rows=store.contracts.map { r -> CryptoRecord in
            var r=r
            if let fee=r.values["funding_trx"] { sum += fee;r.values["cumulative"]=sum }
            r.values["usdt"]=r.values["legacy_contract_equity"] ?? (r.values["trx"] ?? 0)*(r.values["price"] ?? 0)
            r.values["rate_percent"]=r.values["funding_rate"].map{$0*100};return r
        }
        let cutoff=CryptoDay.key(CryptoDay.calendar.date(byAdding:.day,value:-days,to:.now)!)
        return CryptoTrend(title:titles[index],records:rows.filter { days==0 || $0.day>=cutoff },keys:keys[index],names:names[index],units:units[index],sharedScale:index==3)
    }
}

extension View {
    func cryptoPanel() -> some View { padding(16).background(HakoStyle.card,in:RoundedRectangle(cornerRadius:14)) }
}

struct CryptoTrend: View {
    let title:String
    let records:[CryptoRecord]
    let keys:[String]
    let names:[String]
    let units:[String]
    var sharedScale=false
    @State private var selected:Date?
    private func range(_ key:String) -> (Double,Double) {
        let values=sharedScale ? records.flatMap { r in keys.compactMap { r.values[$0] } } : records.compactMap { $0.values[key] }
        let low=values.min() ?? 0,high=values.max() ?? 1,pad=max((high-low)*0.1,abs(high)*0.001,0.000001)
        return (low-pad,high+pad)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.subheadline.weight(.semibold))
            if records.isEmpty { Text("暂无历史数据").font(.caption).foregroundStyle(.secondary).frame(height:155) }
            else {
                Chart {
                    ForEach(Array(keys.enumerated()),id:\.offset) { index,key in
                        ForEach(records) { record in
                            if let value=record.values[key] {
                                let bounds=range(key)
                                LineMark(x:.value("日期",record.date),y:.value("相对刻度",(value-bounds.0)/(bounds.1-bounds.0)))
                                    .foregroundStyle(by:.value("指标",names[index]))
                                PointMark(x:.value("日期",record.date),y:.value("相对刻度",(value-bounds.0)/(bounds.1-bounds.0)))
                                    .foregroundStyle(by:.value("指标",names[index])).symbol(by:.value("指标",names[index]))
                            }
                        }
                    }
                }.chartYScale(domain:0...1).chartYAxis(.hidden)
                    .chartForegroundStyleScale(range:[Color(red:0.28,green:0.55,blue:0.5),Color(red:0.36,green:0.53,blue:0.75)])
                    .chartXSelection(value:$selected).frame(height:160)
                ForEach(Array(keys.enumerated()),id:\.offset) { index,key in
                    if let last=records.last,let value=last.values[key] {
                        let bounds=range(key)
                        Text("\(names[index]) · \(value.formatted(.number.precision(.significantDigits(6)))) \(units[index]) · 刻度 \(bounds.0.formatted(.number.precision(.significantDigits(4))))–\(bounds.1.formatted(.number.precision(.significantDigits(4))))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else { Text("\(names[index])：接口未返回有效值").font(.caption).foregroundStyle(.secondary) }
                }
                if let selected,let row=records.min(by:{abs($0.date.timeIntervalSince(selected))<abs($1.date.timeIntervalSince(selected))}) {
                    Text(row.day+" · "+keys.enumerated().map { i,k in names[i]+" "+(row.values[k].map{String(format:"%.4f",$0)} ?? "—")+" "+units[i] }.joined(separator:" · "))
                        .font(.caption).accessibilityAddTraits(.updatesFrequently)
                }
                if keys.count>1 && !sharedScale { Text("各指标独立刻度，仅比较变化趋势；数值范围见上方标注。").font(.caption2).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
    }
}
