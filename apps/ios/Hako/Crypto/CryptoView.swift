import SwiftUI
import Charts

struct CryptoView: View {
    private enum Tab: String, CaseIterable { case overview="概览",htx="HTX",binance="Binance",chain="链上资产" }
    private enum SyncPhase { case idle, syncing, succeeded, failed }
    @StateObject private var store = CryptoStore.shared
    @State private var tab = Tab.overview
    @State private var trends=false
    @State private var days=30
    @State private var syncMessage:String?
    @State private var syncPhase = SyncPhase.idle
    @Environment(\.scenePhase) private var scenePhase
    @State private var collecting = true
    @State private var collectionWindow: Date?
    private var latest: CryptoRecord? { store.portfolio.last }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                header
                HakoUnderlineTabs(title:"资产来源",options:Tab.allCases,selection:$tab,label:{$0.rawValue})
                if syncPhase == .failed, let message=syncMessage {
                    Label(message,systemImage:"exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                }
                if !collecting && !store.busy && syncPhase != .failed, let message=store.message {
                    Label("更新失败："+message,systemImage:"exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if tab == .overview {
                    amountPanel("总资产",value:latest?.values["total"])
                    if let latest {
                        VStack(spacing:16) {
                            source("HTX",value:latest.values["htx"],tab:.htx)
                            source("Binance",value:latest.values["binance"],tab:.binance)
                            source("链上资产",value:store.chainTotal,tab:.chain)
                        }.cryptoPanel()
                        Text("数据日期：\(latest.day) · 仅汇总已配置来源")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    CryptoTrend(title:"每日总资产",records:store.portfolio,keys:["total"],names:["总资产"],units:["USDT"])
                } else if tab == .htx {
                    Picker("HTX 页面",selection:$trends) { Text("资产概览").tag(false);Text("合约收益").tag(true) }.pickerStyle(.segmented)
                    Text("历史缺失权益按补录时的当前权益和价格填充，并非当日结算值；已有数据保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    if trends {
                        Picker("统计范围",selection:$days) {
                            Text("最近7天").tag(7)
                            Text("最近30天").tag(30)
                            Text("最近半年").tag(180)
                            Text("最近一年").tag(365)
                            Text("全部").tag(0)
                        }.pickerStyle(.menu)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:290),spacing:12)],spacing:12) {
                            ForEach(0..<6) { index in contractChart(index) }
                        }
                    } else {
                        amountPanel("HTX 总资产",value:latest?.values["htx"])
                        currentContractPanel
                        recentContractTable
                    }
                } else if tab == .binance {
                    amountPanel("Binance 总资产",value:store.binanceSnapshot?.total ?? latest?.values["binance"])
                    binanceDetails
                } else {
                    amountPanel("链上资产",value:store.chainTotal)
                    VStack(alignment:.leading,spacing:12) {
                        if store.wallets.isEmpty {
                            Text("暂无观察地址，可在右上角设置中添加。").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(Array(store.wallets.enumerated()),id:\.element.id) { index,wallet in
                            if index > 0 { Divider() }
                            NavigationLink {
                                CryptoWalletDetailView(wallet:wallet,store:store)
                            } label: {
                                HStack(spacing:12) {
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(wallet.name).font(.subheadline.weight(.semibold))
                                        Text(wallet.network+" · "+wallet.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(store.walletValues[wallet.id].map { $0.formatted(.number.precision(.fractionLength(2)))+" USDT" } ?? "暂无估值")
                                            .font(.headline).monospacedDigit()
                                        if let error=store.walletErrors[wallet.id] {
                                            Text("更新失败："+error).font(.caption).foregroundStyle(.red)
                                        }
                                    }
                                    Spacer(minLength:0)
                                    Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("查看该地址的总资产及各币种资产")
                        }
                    }.cryptoPanel()
                }
                if store.portfolio.isEmpty && store.contracts.isEmpty && store.currentContract == nil {
                    Text("还没有采集数据。请先配置交易所只读 API、观察地址及主应用私有仓库。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical,18)
                }
            }.padding(20)
        }
        .background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) {
            NavigationLink { CryptoSettingsView() } label: { Image(systemName:"slider.horizontal.3") }
                .accessibilityLabel("加密资产连接与地址设置")
        } }
        .onAppear { collecting=true;store.loadCachedData() }
        .onChange(of:scenePhase) { _,phase in
            if phase == .active && !collecting && collectionWindow != CryptoSyncPolicy.fundingRefreshWindow(now:.now) {
                Task { await collect() }
            }
        }
        .sensoryFeedback(trigger:syncPhase) { _,phase in
            switch phase {
            case .succeeded: .success
            case .failed: .error
            default: nil
            }
        }
        .task(id:syncPhase) {
            guard syncPhase == .succeeded else { return }
            do { try await Task.sleep(for:.seconds(5)) }
            catch { return }
            guard !Task.isCancelled else { return }
            syncPhase = .idle
        }
        .task {
            await collect()
            // Check newly settled funding and completed days even while the page stays open.
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(60)) }
                catch { return }
                if scenePhase == .active && !collecting && collectionWindow != CryptoSyncPolicy.fundingRefreshWindow(now:.now) {
                    await collect()
                }
            }
        }
    }
    @MainActor private func collect() async {
        collecting=true;collectionWindow=CryptoSyncPolicy.fundingRefreshWindow(now:.now);syncMessage=nil
        await store.collect()
        collecting=false
    }
    private var header: some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:7) {
                Text("加密资产").font(.system(size:28,weight:.semibold))
                if collecting || (store.busy && syncPhase != .syncing) {
                    HStack(spacing:6) {
                        ProgressView().controlSize(.small)
                        Text("更新中…")
                    }.font(.caption).foregroundStyle(.secondary)
                } else if store.pendingCount > 0 {
                    Text("\(store.pendingCount) 条待同步")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength:0)
            Button {
                guard syncPhase != .syncing && syncPhase != .succeeded else { return }
                syncPhase = .syncing
                syncMessage=nil
                Task {
                    let result=await store.trigger()
                    let succeeded=store.message == nil
                    syncPhase = succeeded ? .succeeded : .failed
                    syncMessage=succeeded ? nil : result
                }
            } label: {
                HStack(spacing:6) {
                    if syncPhase == .syncing {
                        ProgressView().controlSize(.small).tint(HakoStyle.background)
                        Text("同步中")
                    } else {
                        Label(syncPhase == .succeeded ? "已同步" : syncPhase == .failed ? "重试同步" : "同步资产",
                              systemImage:syncPhase == .succeeded ? "checkmark" : "arrow.triangle.2.circlepath")
                    }
                }.frame(minWidth:88)
            }
            .buttonStyle(HakoActionButtonStyle()).fixedSize(horizontal:true,vertical:false)
            .disabled(collecting || (store.busy && syncPhase != .syncing))
            .allowsHitTesting(syncPhase != .syncing && syncPhase != .succeeded)
            .accessibilityLabel(syncPhase == .syncing ? "资产同步中" : syncPhase == .succeeded ? "资产已同步" : "同步资产")
            .accessibilityHint(syncPhase == .syncing ? "请等待同步完成" : syncPhase == .succeeded ? "同步已完成，按钮即将恢复" : "将本机缓存同步到 GitHub，不重新查询资产接口")
        }
    }
    private var binanceDetails: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("资产详情").font(.headline)
            if let error=store.binanceError {
                Label("更新失败："+error,systemImage:"exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                if store.binanceSnapshot != nil {
                    Text("以下为上次成功获取的数据").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snapshot=store.binanceSnapshot {
                Text("更新于："+snapshot.sampledAt.formatted(date:.numeric,time:.standard))
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.visibleAccounts.isEmpty {
                    Text("暂无账户资产").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(snapshot.visibleAccounts) { account in
                    VStack(alignment:.leading,spacing:12) {
                        metric(account.name,account.balance,"USDT")
                        if let assets=account.visibleAssets {
                            ForEach(assets) { asset in
                                Divider()
                                VStack(alignment:.leading,spacing:8) {
                                    Text(asset.symbol).font(.subheadline.weight(.semibold))
                                    if asset.name != asset.symbol {
                                        Text(asset.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    metric("持有金额",asset.quantity,asset.equitySymbol == nil ? asset.symbol : "股",precision:8)
                                    metric("单价",asset.equitySymbol == nil ? asset.price : asset.equityUSDPrice,asset.equitySymbol == nil ? "USDT" : "USD",precision:8)
                                    metric("折算 USDT",asset.usdtValue,"USDT")
                                }.accessibilityElement(children:.combine)
                            }
                        } else {
                            Text("此账户暂未返回币种明细").font(.caption).foregroundStyle(.secondary)
                        }
                    }.cryptoPanel()
                }
                if snapshot.accounts.contains(where: { $0.assets?.contains(where: { $0.equitySymbol != nil }) == true }) {
                    Text("股票单价采用买卖报价中间值；USDT 折值按 USDC/USDT 行情估算。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(!store.binanceConfigured ? "请在右上角设置中配置 Binance 只读 API。" : store.busy ? "正在获取资产详情…" : "暂无资产详情，重新进入页面后将自动采集。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var currentContractPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("今日合约 · TRX 币本位永续").font(.headline)
            metric("当前权益",store.currentContract?.trx,"TRX")
            metric("合约总权益",store.currentContract?.totalEquity,"USDT")
            Text("合约总权益包含全部币本位合约；USD 估值按 USDT 等值记录。")
                .font(.caption).foregroundStyle(.secondary)
            metric("TRX 价格",store.currentContract?.price,"USDT/TRX",precision:3)
            metric("今日资金费净收入",store.currentContract?.fundingTRX,"TRX")
            metric("今日资金费率合计",store.currentContract?.fundingRate.map { $0 * 100 },"%",precision:4)
            metric("可用保证金",store.currentContract?.available,"TRX")
            metric("未实现盈亏",store.currentContract?.unrealizedProfit,"TRX")
            metric("强平价",store.currentContract?.liquidation,"USD/TRX",precision:3)
            if let current=store.currentContract {
                Text("更新于：" + current.sampledAt.formatted(Date.FormatStyle(date:.numeric,time:.standard,timeZone:CryptoDay.calendar.timeZone)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.cryptoPanel()
    }
    private var recentContractTable: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("最近7天").font(.headline)
            ScrollView(.horizontal) {
                Grid(horizontalSpacing:16,verticalSpacing:12) {
                    GridRow {
                        Text("日期").gridColumnAlignment(.leading)
                        Text("总 TRX").gridColumnAlignment(.trailing)
                        Text("资金费用 / TRX").gridColumnAlignment(.trailing)
                    }.foregroundStyle(.secondary)
                    ForEach(CryptoSyncPolicy.recentContractDays(now:.now),id:\.self) { date in
                        let day=CryptoDay.key(date)
                        let values=store.contracts.first(where:{$0.day==day})?.values
                        Divider().gridCellColumns(3)
                        GridRow {
                            Text(day)
                            Text(contractTableValue(values?["trx"]))
                            Text(contractTableValue(values?["funding_trx"],signed:true))
                        }.accessibilityElement(children:.combine)
                    }
                }.font(.caption).monospacedDigit().fixedSize(horizontal:true,vertical:false)
                    .frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
    }
    private func contractTableValue(_ value:Double?,signed:Bool=false) -> String {
        guard let value else { return "—" }
        return (signed && value>0 ? "+" : "")+value.formatted(.number.precision(.fractionLength(2)))
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
        let names=[["TRX 权益","合约总权益"],["TRX 权益","TRX 价格"],["合约总权益","TRX 价格"],["强平价","TRX 价格"],["资金费","资金费率总和"],["资金费累计"]]
        let units=[["TRX","USDT"],["TRX","USDT/TRX"],["USDT","USDT/TRX"],["USD/TRX","USDT/TRX"],["TRX","%"],["TRX"]]
        var sum=0.0
        let rows=store.contracts.map { r -> CryptoRecord in
            var r=r
            if let fee=r.values["funding_trx"] { sum += fee;r.values["cumulative"]=sum }
            r.values["usdt"]=r.equity
            r.values["rate_percent"]=r.values["funding_rate"].map{$0*100};return r
        }
        let component:Calendar.Component = (days == 180 || days == 365) ? .month : .day
        let offset = days == 180 ? -6 : days == 365 ? -12 : -days
        let cutoff=CryptoDay.key(CryptoDay.calendar.date(byAdding:component,value:offset,to:.now)!)
        return CryptoTrend(title:titles[index],records:rows.filter { days==0 || $0.day>=cutoff },keys:keys[index],names:names[index],units:units[index],sharedScale:index==3)
    }
}

private struct CryptoWalletDetailView: View {
    let wallet:CryptoWallet
    @ObservedObject var store:CryptoStore
    private var snapshot:CryptoWalletSnapshot? { store.walletSnapshot(wallet) }
    private var visibleAssets:[CryptoWalletAsset] {
        (snapshot?.assets ?? []).filter {
            CryptoWalletAsset.isIncluded($0.symbol)
        }.sorted { ($0.value ?? -1) > ($1.value ?? -1) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:8) {
                    Text(wallet.network).font(.subheadline).foregroundStyle(.secondary)
                    Text(wallet.address).font(.caption.monospaced()).textSelection(.enabled)
                    Text("折算总资产").font(.caption).foregroundStyle(.secondary).padding(.top,8)
                    Text("仅汇总 BTC、ETH、ATOM、TRX、USDT、USDC").font(.caption).foregroundStyle(.secondary)
                    Text(store.walletValues[wallet.id].map { $0.formatted(.number.precision(.fractionLength(2)))+" USDT" } ?? "暂无估值")
                        .font(.title.weight(.semibold)).monospacedDigit()
                    if let snapshot {
                        Text("更新于："+snapshot.sampledAt.formatted(date:.numeric,time:.standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
                if let error=store.walletErrors[wallet.id] {
                    Text((snapshot == nil ? "更新失败：" : "更新失败，当前显示上次数据：")+error).font(.caption).foregroundStyle(.red)
                }
                VStack(alignment:.leading,spacing:14) {
                    Text("币种资产").font(.headline)
                    Text("BTC · ETH · ATOM · TRX · USDT · USDC").font(.caption).foregroundStyle(.secondary)
                    if snapshot != nil {
                        if visibleAssets.isEmpty { Text("该地址暂无所选六种币种的资产").foregroundStyle(.secondary) }
                        ForEach(visibleAssets) { asset in
                            Divider()
                            VStack(alignment:.leading,spacing:6) {
                                Text(asset.symbol).font(.subheadline.weight(.semibold))
                                Text(asset.name).font(.caption).foregroundStyle(.secondary)
                                Text("数量："+asset.quantity.formatted(.number.precision(.fractionLength(0...8)))+" "+asset.symbol)
                                    .font(.subheadline).monospacedDigit()
                                Text(asset.value.map { "折合 "+$0.formatted(.number.precision(.fractionLength(2)))+" USDT" } ?? "暂无报价，未计入折算总额")
                                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }.accessibilityElement(children:.combine)
                        }
                    } else if store.busy {
                        ProgressView("正在获取币种资产…")
                    } else {
                        Text("暂无币种明细，重新进入资产页可更新。").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
            }.padding(20)
        }
        .background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle(wallet.name).navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func cryptoPanel() -> some View { padding(16).background(HakoStyle.card,in:RoundedRectangle(cornerRadius:14)) }
}

struct CryptoTrend: View {
    let title: String
    let records: [CryptoRecord]
    let keys: [String]
    let names: [String]
    let units: [String]
    var sharedScale = false
    @State private var selectedDay: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var independentScales: Bool { keys.count > 1 && !sharedScale }
    private var selectedRecord: CryptoRecord? { records.first { $0.day == selectedDay } }
    private var hasValues: Bool { records.contains { row in keys.contains { row.values[$0] != nil } } }
    private var tickDates: [Date] {
        let step = max(1, Int(ceil(Double(records.count) / 4)))
        return records.enumerated().compactMap { index, row in
            index % step == 0 || index == records.count - 1 ? row.date : nil
        }
    }
    private var dateDomain: ClosedRange<Date> {
        let first = records.first?.date ?? .now
        let last = records.last?.date ?? first
        return first == last ? first.addingTimeInterval(-43200)...last.addingTimeInterval(43200) : first...last
    }
    private func range(_ key: String) -> (Double, Double) {
        let values = sharedScale ? records.flatMap { r in keys.compactMap { r.values[$0] } } : records.compactMap { $0.values[key] }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.1, abs(high) * 0.001, 0.000001)
        return (low - pad, high + pad)
    }
    private func position(_ value: Double, key: String) -> Double {
        let bounds = range(key)
        return (value - bounds.0) / (bounds.1 - bounds.0)
    }
    private func digits(_ key: String) -> Int {
        key == "rate_percent" ? 4 : (["price", "liquidation"].contains(key) ? 3 : 2)
    }
    private func display(_ value: Double, key: String) -> String {
        String(format: "%.*f", digits(key), value)
    }
    private func axisLabel(_ fraction: Double, key: String) -> String {
        let bounds = range(key)
        let value = bounds.0 + fraction * (bounds.1 - bounds.0)
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...digits(key))))
    }
    private func color(_ index: Int) -> Color {
        index == 0 ? HakoStyle.adaptive(0x478d80, 0x78b8aa) : HakoStyle.adaptive(0x5b88bf, 0x8aaedb)
    }
    private func dateLabel(_ date: Date) -> String {
        let day = CryptoDay.key(date)
        return records.first?.day.prefix(4) == records.last?.day.prefix(4)
            ? String(day.suffix(5)).replacingOccurrences(of: "-", with: "/")
            : day.replacingOccurrences(of: "-", with: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text(independentScales ? "双刻度" : units.joined(separator: " / "))
                    .font(.system(size: 11)).foregroundStyle(HakoStyle.muted)
            }
            if !hasValues {
                Text("暂无历史数据").font(.caption).foregroundStyle(HakoStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                if independentScales {
                    HStack {
                        Text("左轴 · " + units[0]).foregroundStyle(color(0))
                        Spacer()
                        Text("右轴 · " + units[1]).foregroundStyle(color(1))
                    }.font(.system(size: 10))
                }
                renderedChart
                if let row = selectedRecord {
                    selectionDetails(row)
                }
            }
        }
        .foregroundStyle(HakoStyle.text)
        .frame(maxWidth: .infinity, alignment: .leading).cryptoPanel()
        .onChange(of: records) { _, _ in selectedDay = nil }
        .onChange(of: keys) { _, _ in selectedDay = nil }
    }

    @ChartContentBuilder
    private func marks(_ record: CryptoRecord, value: Double, index: Int, key: String) -> some ChartContent {
        let y = position(value, key: key)
        let label = Text(record.day + "，" + names[index])
        let description = Text(display(value, key: key) + " " + units[index])
        LineMark(x: .value("日期", record.date), y: .value(names[index], y), series: .value("指标", names[index]))
            .foregroundStyle(by: .value("指标", names[index]))
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .accessibilityLabel(label).accessibilityValue(description)
        PointMark(x: .value("日期", record.date), y: .value(names[index], y))
            .foregroundStyle(by: .value("指标", names[index]))
            .symbolSize(record.day == selectedDay ? 32 : 16)
            .opacity(selectedDay == nil || record.day == selectedDay ? 1 : 0.3)
            .accessibilityLabel(label).accessibilityValue(description)
    }

    private var renderedChart: some View {
        Chart {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                ForEach(records) { record in
                    if let value = record.values[key] {
                        marks(record, value: value, index: index, key: key)
                    }
                }
            }
            if let row = selectedRecord {
                RuleMark(x: .value("日期", row.date))
                    .foregroundStyle(HakoStyle.muted.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).zIndex(2)
            }
        }
        .chartForegroundStyleScale(domain: names, range: keys.indices.map { color($0) })
        .chartLegend(.hidden)
        .chartXScale(domain: dateDomain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: tickDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(dateLabel(date)).font(.system(size: 10)).foregroundStyle(HakoStyle.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7)).foregroundStyle(HakoStyle.line)
                AxisValueLabel {
                    if let fraction = value.as(Double.self), let key = keys.first {
                        Text(axisLabel(fraction, key: key)).font(.system(size: 10))
                            .foregroundStyle(independentScales ? color(0) : HakoStyle.muted)
                    }
                }
            }
            if independentScales {
                AxisMarks(position: .trailing, values: [0.0, 0.5, 1.0]) { value in
                    AxisValueLabel {
                        if let fraction = value.as(Double.self) {
                            Text(axisLabel(fraction, key: keys[1])).font(.system(size: 10)).foregroundStyle(color(1))
                        }
                    }
                }
            }
        }
        .chartXSelection(value: Binding<Date?>(get: { selectedRecord?.date }, set: { date in
            // Keep the chosen day and its values visible after lifting the finger.
            guard let date else { return }
            selectedDay = records.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }?.day
        }))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .simultaneousGesture(SpatialTapGesture().onEnded { event in
                        guard let anchor = proxy.plotFrame else { return }
                        let frame = geometry[anchor]
                        guard frame.contains(event.location),
                              let date = proxy.value(atX: event.location.x - frame.minX, as: Date.self),
                              let row = records.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else {
                            selectedDay = nil
                            return
                        }
                        selectedDay = selectedDay == row.day ? nil : row.day
                    })
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 160)
        .accessibilityLabel(title + "，" + zip(names, units).map { $0 + "，单位" + $1 }.joined(separator: "；"))
        .accessibilityHint("点击或左右拖动图表竖线，在下方查看所选日期的各项数据，松手后保留选择，再次点击可收起。")
    }

    private func selectionDetails(_ row: CryptoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(row.day).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { selectedDay = nil } label: {
                    Label("收起", systemImage: "chevron.up")
                        .font(.system(size: 11)).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(HakoStyle.muted)
                .accessibilityLabel("收起所选日期的数据")
            }
            valueDetails(row)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(HakoStyle.background, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityAddTraits(.updatesFrequently)
    }
    private func valueDetails(_ row: CryptoRecord) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 12) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(color(index)).frame(width: 6, height: 6)
                        Text(names[index]).font(.system(size: 11)).foregroundStyle(HakoStyle.muted)
                    }
                    Text(row.values[key].map { display($0, key: key) + " " + units[index] } ?? "暂无数据")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
