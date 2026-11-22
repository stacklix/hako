import SwiftUI
import Charts

struct CryptoBinanceAnalyticsView: View {
    let records: [CryptoRecord]
    let snapshot: CryptoBinanceSnapshot?
    private enum Range: String, CaseIterable {
        case week="近一周", month="近一个月", quarter="近三个月", year="今年", all="全部", custom="自定义日期"
    }
    @State private var range=Range.month
    @State private var customStart=CryptoDay.calendar.startOfDay(for:.now)
    @State private var customEnd=CryptoDay.calendar.startOfDay(for:.now)
    @State private var draftStart=CryptoDay.calendar.startOfDay(for:.now)
    @State private var draftEnd=CryptoDay.calendar.startOfDay(for:.now)
    @State private var showsDates=false
    @State private var selectedDate: Date?
    private var today: Date { CryptoDay.calendar.startOfDay(for:.now) }
    private var first: Date { min(today,records.filter { $0.values["binance"] != nil }.map(\.date).min() ?? today) }
    private var end: Date { range == .custom ? min(customEnd,today) : today }
    private var start: Date {
        let calendar=CryptoDay.calendar
        switch range {
        case .week: return max(first,calendar.date(byAdding:.day,value:-7,to:end) ?? end)
        case .month: return max(first,calendar.date(byAdding:.month,value:-1,to:end) ?? end)
        case .quarter: return max(first,calendar.date(byAdding:.month,value:-3,to:end) ?? end)
        case .year: return max(first,calendar.dateInterval(of:.year,for:end)?.start ?? end)
        case .all: return min(first,end)
        case .custom: return min(customStart,end)
        }
    }
    private var samples: [CryptoBinanceHistory.Sample] {
        CryptoBinanceHistory.samples(records,snapshot:snapshot,from:start,through:end)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Text("资产趋势").font(.headline)
                    Spacer(minLength:8)
                    Menu {
                        ForEach(Range.allCases,id:\.self) { option in
                            Button(option.rawValue) {
                                if option == .custom {
                                    draftStart=start;draftEnd=end;showsDates=true
                                } else { range=option;selectedDate=nil }
                            }
                        }
                    } label: {
                        HStack(spacing:4) { Text(range.rawValue);Image(systemName:"chevron.down").font(.caption2) }
                            .font(.caption).frame(minHeight:44)
                    }.accessibilityLabel("选择 Binance 趋势日期范围")
                }
                Text(CryptoDay.key(start)+" — "+CryptoDay.key(end)).font(.caption).foregroundStyle(.secondary)
                valueChart
            }
            .padding(16).background(HakoStyle.card,in:RoundedRectangle(cornerRadius:18))
            if let snapshot {
                CryptoBinanceDistributionView(snapshot:snapshot)
            } else {
                Text("暂无 Binance 资产分布，请先采集账户资产。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented:$showsDates) {
            SettingsSheet(title:"日期范围",saveEnabled:draftStart <= draftEnd,onSave:{
                customStart=draftStart;customEnd=draftEnd
                range = .custom;selectedDate=nil;showsDates=false
            },saveAccessibilityLabel:"应用日期范围") {
                Form {
                    DatePicker("开始日期",selection:$draftStart,in:min(first,today)...today,displayedComponents:.date)
                        .environment(\.calendar,CryptoDay.calendar).environment(\.timeZone,CryptoDay.calendar.timeZone)
                    DatePicker("结束日期",selection:$draftEnd,in:min(first,today)...today,displayedComponents:.date)
                        .environment(\.calendar,CryptoDay.calendar).environment(\.timeZone,CryptoDay.calendar.timeZone)
                    if draftStart > draftEnd { Text("开始日期不能晚于结束日期").foregroundStyle(.red) }
                }
            }
        }
    }
    private var valueChart: some View {
        let available=samples.filter { $0.value != nil }
        let chosen=selectedDate.flatMap { date in available.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } } ?? available.last
        return VStack(alignment:.leading,spacing:10) {
            HStack { Text("资产总额").font(.subheadline.weight(.semibold));Spacer();Text("USDT").font(.caption).foregroundStyle(.secondary) }
            Text(chosen?.value.map(CryptoBinanceDisplay.amount) ?? "—").font(.system(size:30,weight:.medium)).monospacedDigit()
            if available.isEmpty {
                Text("所选区间暂无 Binance 资产记录").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,minHeight:160)
            } else {
                Chart {
                    ForEach(available) { point in
                        if let amount=point.value {
                            LineMark(x:.value("日期",point.date),y:.value("资产总额",amount),series:.value("连续记录",point.segment))
                                .foregroundStyle(CryptoBinanceDisplay.curve)
                            PointMark(x:.value("日期",point.date),y:.value("资产总额",amount))
                                .foregroundStyle(CryptoBinanceDisplay.curve).symbolSize(available.count == 1 ? 30 : 5)
                        }
                    }
                    if let chosen,let amount=chosen.value {
                        RuleMark(x:.value("所选日期",chosen.date)).foregroundStyle(HakoStyle.muted.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth:1,dash:[3,3]))
                        PointMark(x:.value("日期",chosen.date),y:.value("资产总额",amount))
                            .foregroundStyle(CryptoBinanceDisplay.curve).symbolSize(35)
                    }
                }
                .chartXScale(domain:start...max(end,CryptoDay.calendar.date(byAdding:.day,value:1,to:start)!))
                .chartYScale(domain:.automatic(includesZero:false))
                .chartXAxis {
                    AxisMarks(values:CryptoDay.chartTicks(from:start,through:end,desiredCount:3)) { axis in
                        if let date=axis.as(Date.self) {
                            AxisValueLabel { Text(String(CryptoDay.key(date).dropFirst(5)).replacingOccurrences(of:"-",with:"/")).font(.caption2) }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position:.trailing,values:.automatic(desiredCount:3)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor=proxy.plotFrame {
                            let frame=geometry[anchor]
                            HakoChartInteraction { point,toggle in
                                guard let date=proxy.value(atX:min(max(0,point.x),frame.width),as:Date.self),
                                      let nearest=available.min(by:{ abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
                                selectedDate=toggle && selectedDate == nearest.date ? nil : nearest.date
                            }.frame(width:max(0,frame.width),height:max(0,frame.height)).position(x:frame.midX,y:frame.midY)
                        }
                    }
                }
                .frame(height:170)
                .environment(\.calendar,CryptoDay.calendar).environment(\.timeZone,CryptoDay.calendar.timeZone)
                HStack {
                    Text(chosen.map { CryptoDay.key($0.date) } ?? "—").foregroundStyle(.secondary)
                    Spacer(minLength:4)
                    Text(chosen?.value.map { CryptoBinanceDisplay.amount($0)+" USDT" } ?? "—")
                }.font(.caption).monospacedDigit()
            }
            Text("每日资产记录；缺失日期不连线。当天快照更新今日估值。")
                .font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children:.contain).accessibilityLabel("Binance 资产总额趋势")
    }
}

private enum CryptoBinanceDisplay {
    static let curve=HakoStyle.adaptive(0x247e68,0x64c6aa)
    static func amount(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    static func percent(_ value: Double?) -> String { value.map { ($0*100).formatted(.number.precision(.fractionLength(1)))+"%" } ?? "—" }
    static func color(_ name: String,index: Int,isAsset: Bool) -> Color {
        if !isAsset {
            if name == "Stock" { return HakoStyle.adaptive(0x477bbc,0x8eafeb) }
            if name == "Funding" { return curve }
            if name == "Earn" { return HakoStyle.adaptive(0xbc7f2d,0xd6ab65) }
        }
        let palette: [Color] = [
            curve,HakoStyle.adaptive(0x477bbc,0x8eafeb),HakoStyle.adaptive(0xbc7f2d,0xd6ab65),
            HakoStyle.adaptive(0x9b5eaa,0xc49bd5),HakoStyle.adaptive(0xbc5c64,0xe3979f),
            HakoStyle.adaptive(0x328fa1,0x81c7d4),HakoStyle.adaptive(0x818a34,0xbac879),
            HakoStyle.adaptive(0x8b7262,0xbda99b)
        ]
        return palette[index % palette.count]
    }
}

private struct CryptoBinanceDistributionView: View {
    let snapshot: CryptoBinanceSnapshot
    @State private var categoryID: String?
    @State private var highlighted: String?
    private var categories: [CryptoBinanceCategory] { CryptoBinanceCategory.categories(snapshot) }
    private var category: CryptoBinanceCategory? { categories.first { $0.id == categoryID } }
    private var parts: [CryptoBinanceDistributionPart] {
        if let category { return CryptoBinanceDistributionPart.assets(category,total:snapshot.total) }
        return CryptoBinanceDistributionPart.categories(categories,total:snapshot.total)
    }
    private var total: Double? {
        if let category { return category.value }
        return snapshot.total
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("资产分布").font(.headline)
                Spacer(minLength:8)
                Text("最新快照 · "+CryptoDay.key(snapshot.sampledAt)).font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    if let category {
                        Button {
                            highlighted=category.id;categoryID=nil
                        } label: { Label("全部资产",systemImage:"chevron.left").font(.caption).frame(minHeight:44) }
                        .buttonStyle(.plain).accessibilityLabel("返回全部资产分布")
                        Spacer(minLength:8)
                        Text(category.name).font(.subheadline.weight(.semibold))
                    } else { Text("全部资产").font(.subheadline.weight(.semibold)) }
                }
                if CryptoBinanceDistributionPart.canChart(parts,total:total) {
                    pie.frame(maxWidth:.infinity)
                } else {
                    Text("估值不完整、含负值或暂无余额，无法绘制占比饼图。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:110)
                }
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    Text((category?.name ?? "Binance")+" 总资产").foregroundStyle(.secondary)
                    Text(total.map(CryptoBinanceDisplay.amount) ?? "—").font(.title3.weight(.medium)).monospacedDigit()
                    Text("USDT").foregroundStyle(.secondary)
                }.font(.caption).frame(maxWidth:.infinity)
                if let category {
                    Text("占 Binance 总资产 "+CryptoBinanceDisplay.percent(CryptoBinanceDistributionPart.ratio(category.value,of:snapshot.total)))
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity)
                } else {
                    Text("点击高亮，右侧箭头查看每项资产占比")
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity)
                }
                if parts.isEmpty { Text("交易所未提供此分类的资产明细。").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(parts.enumerated()),id:\.element.id) { index,part in
                    if index > 0 { Divider() }
                    allocationRow(part,index:index)
                }
            }.padding(16).background(HakoStyle.card,in:RoundedRectangle(cornerRadius:18))
            Text("分布使用最新持仓快照，日期范围仅作用于资产趋势。未提供报价的资产保留在列表中，以 — 显示。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of:snapshot.scope) { categoryID=nil;highlighted=nil }
        .onChange(of:parts.map(\.id)) { _,ids in if let highlighted,!ids.contains(highlighted) { self.highlighted=nil } }
    }
    private var pie: some View {
        Chart(Array(parts.enumerated()),id:\.element.id) { index,part in
            if let value=part.value, value > 0 {
                SectorMark(angle:.value(part.name,value),angularInset:0)
                    .foregroundStyle(CryptoBinanceDisplay.color(part.name,index:index,isAsset:category != nil))
                    .opacity(highlighted == nil || highlighted == part.id ? 1 : 0.35)
                    .annotation(position:.overlay) {
                        if let ratio=part.categoryRatio,ratio >= 0.06 {
                            Text(CryptoBinanceDisplay.percent(ratio)).font(.caption2.weight(.semibold)).foregroundStyle(.black.opacity(0.8))
                        }
                    }
                    .accessibilityLabel(part.name)
                    .accessibilityValue(CryptoBinanceDisplay.amount(value)+" USDT，"+CryptoBinanceDisplay.percent(part.categoryRatio))
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { _ in
            GeometryReader { geometry in
                HakoChartInteraction { point,toggle in
                    let x=point.x-geometry.size.width/2,y=point.y-geometry.size.height/2
                    guard hypot(x,y) <= min(geometry.size.width,geometry.size.height)/2,let total,total > 0 else { return }
                    let angle=(atan2(y,x)+Double.pi/2+2*Double.pi).truncatingRemainder(dividingBy:2*Double.pi)
                    var cumulative=0.0
                    for part in parts {
                        cumulative += max(0,part.value ?? 0)
                        if angle/(2*Double.pi)*total < cumulative {
                            highlighted=toggle && highlighted == part.id ? nil : part.id
                            break
                        }
                    }
                }
            }
        }
        .frame(width:190,height:190)
    }
    private func allocationRow(_ part: CryptoBinanceDistributionPart,index: Int) -> some View {
        HStack(spacing:4) {
            Button { highlighted=highlighted == part.id ? nil : part.id } label: {
                VStack(alignment:.leading,spacing:7) {
                    HStack(spacing:7) {
                        Circle().fill(CryptoBinanceDisplay.color(part.name,index:index,isAsset:category != nil)).frame(width:7,height:7)
                        Text(part.name).font(.subheadline.weight(highlighted == part.id ? .semibold : .medium))
                        Spacer(minLength:4)
                        Text(part.value.map(CryptoBinanceDisplay.amount) ?? "—").font(.subheadline).monospacedDigit()
                    }
                    Text(category == nil ? "总资产占比 "+CryptoBinanceDisplay.percent(part.totalRatio) :
                         "分类内 "+CryptoBinanceDisplay.percent(part.categoryRatio)+" · 总资产 "+CryptoBinanceDisplay.percent(part.totalRatio))
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,minHeight:56,alignment:.leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("高亮 "+part.name).accessibilityAddTraits(highlighted == part.id ? .isSelected : [])
            if category == nil,let item=categories.first(where:{$0.id == part.id}),item.assets?.isEmpty == false {
                Button { categoryID=part.id;highlighted=nil } label: {
                    Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                        .frame(width:44,height:44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("查看 "+part.name+" 内每项资产占比")
            }
        }
        .padding(.horizontal,5).padding(.vertical,4)
        .background(highlighted == part.id ? HakoStyle.line.opacity(0.6) : .clear,in:RoundedRectangle(cornerRadius:8))
    }
}
