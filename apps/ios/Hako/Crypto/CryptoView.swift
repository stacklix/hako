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
    @State private var didCollect = false
    private var latest: CryptoRecord? { store.portfolio.last }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                header
                HakoUnderlineTabs(title:"资产来源",options:Tab.allCases,selection:$tab,label:{$0.rawValue})
                if let message=syncMessage {
                    Label(message,systemImage:syncPhase == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(syncPhase == .succeeded ? .green : .red)
                        .textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                }
                if tab == .overview {
                    amountPanel("总资产",value:latest?.values["total"])
                    if let latest {
                        VStack(spacing:16) {
                            source("HTX",value:latest.values["htx"],tab:.htx)
                            source("Binance",value:latest.values["binance"],tab:.binance)
                            source("链上资产",value:latest.values["chain"],tab:.chain)
                        }.cryptoPanel()
                        Text("数据日期：\(latest.day) · 仅汇总已配置来源")
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
                        currentContractPanel
                        VStack(alignment:.leading,spacing:16) {
                            Text("历史合约 · TRX 币本位永续").font(.headline)
                            metric("合约权益",store.contracts.last?.values["trx"],"TRX")
                            metric("USDT 折值",contractValue,"USDT")
                            metric("当日资金费净收入",store.contracts.last?.values["funding_trx"],"TRX")
                            metric("当日资金费率总和",store.contracts.last?.values["funding_rate"].map{$0*100},"%",precision:4)
                            metric("强平价",store.contracts.last?.values["liquidation"],"USD/TRX",precision:3)
                            metric("累计资金费",store.contracts.isEmpty ? nil : store.contracts.reduce(0){$0+($1.values["funding_trx"] ?? 0)},"TRX")
                            if let last=store.contracts.last { Text("数据日期：\(last.day) · 当日最后一笔结算权益").font(.caption).foregroundStyle(.secondary) }
                        }.cryptoPanel()
                    }
                } else if tab == .binance {
                    amountPanel("Binance 总资产",value:latest?.values["binance"])
                } else {
                    amountPanel("链上资产",value:latest?.values["chain"])
                    VStack(alignment:.leading,spacing:12) {
                        NavigationLink("添加或管理观察地址") { CryptoSettingsView() }
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
        .onAppear { store.loadCachedData() }
        .sensoryFeedback(trigger:syncPhase) { _,phase in
            switch phase {
            case .succeeded: .success
            case .failed: .error
            default: nil
            }
        }
        .task {
            guard !didCollect else { return }
            didCollect=true
            syncMessage=nil
            await store.collect()
        }
    }
    private var header: some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:7) {
                Text("加密资产").font(.system(size:28,weight:.semibold))
                Text("私有库 · \(store.pendingCount) 条待同步")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            Button {
                guard syncPhase != .syncing else { return }
                syncPhase = .syncing
                syncMessage=nil
                Task {
                    let result=await store.trigger()
                    let succeeded=store.message == nil
                    syncPhase = succeeded ? .succeeded : .failed
                    syncMessage=succeeded ? "已同步到 GitHub" : result
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
            .accessibilityLabel(syncPhase == .syncing ? "资产同步中" : "同步资产")
            .accessibilityHint(syncPhase == .syncing ? "请等待同步完成" : "将本机缓存同步到 GitHub，不重新查询资产接口")
        }
    }
    private var currentContractPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("今日合约 · TRX 币本位永续").font(.headline)
            metric("当前权益",store.currentContract?.trx,"TRX")
            metric("USDT 折值",store.currentContract?.equity,"USDT")
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
    private var contractValue: Double? {
        store.contracts.last?.equity
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
        let names=[["TRX 权益","USDT 折值"],["TRX 权益","TRX 价格"],["USDT 折值","TRX 价格"],["强平价","TRX 价格"],["资金费","资金费率总和"],["资金费累计"]]
        let units=[["TRX","USDT"],["TRX","USDT/TRX"],["USDT","USDT/TRX"],["USD/TRX","USDT/TRX"],["TRX","%"],["TRX"]]
        var sum=0.0
        let rows=store.contracts.map { r -> CryptoRecord in
            var r=r
            if let fee=r.values["funding_trx"] { sum += fee;r.values["cumulative"]=sum }
            r.values["usdt"]=r.equity
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
                    .foregroundStyle(HakoStyle.muted.opacity(0.3)).zIndex(-1)
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
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
        .accessibilityHint("点击图表，在下方查看当日各项数据，再次点击可收起。")
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
