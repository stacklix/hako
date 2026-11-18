import Charts
import SwiftUI

struct InvestmentHoldingChart: View {
    private struct Request: Equatable, Sendable {
        let version: UUID
        let accountID: UUID
        let assetID: UUID
        let today: Date
        let range: InvestmentHistoryRange
    }
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var range: InvestmentHistoryRange
    @State private var display: InvestmentHoldingChartDisplay
    @State private var showsRanges = false
    @State private var selectedDay: Date?
    @State private var loadedRequest: Request?
    @State private var points: [InvestmentHoldingHistoryPoint] = []
    private var book: InvestmentBook { store.book }
    private var bookVersion: UUID { store.bookVersion }
    private var holdingTitle: String { asset.historyUsesInvestment ? "净投入变化" : (asset.historyUsesAmount ? "资产金额变化" : "持仓数量变化") }
    private var showsPrice: Bool { asset.supportsPriceHistory && display == .price }
    private var showsProfit: Bool { display == .profit }

    init(store: InvestmentStore, account: InvestmentAccount, asset: InvestmentAsset) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account
        self.asset = asset
        _display = State(initialValue: asset.holdingChartDisplays[0])
        _range = State(initialValue: .quarter)
    }

    var body: some View {
        let request = Request(version: bookVersion, accountID: account.id, assetID: asset.id,
                              today: InvestmentBook.day(), range: range)
        let visible = loadedRequest == request ? points : []
        let selected = selectedDay.flatMap { day in
            visible.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }
        } ?? visible.last
        InvestmentCard {
            HStack {
                Text("资产走势").font(.headline)
                Spacer(minLength: 12)
                InvestmentHistoryRangeSelector(selection: $range, isExpanded: $showsRanges)
            }.zIndex(30)
            InvestmentChartTabs(title: "走势图类型", options: asset.holdingChartDisplays, selection: $display) {
                switch $0 {
                case .price: "价格走势"
                case .holding: asset.historyUsesAmount ? holdingTitle : "持仓数量"
                case .profit: "盈亏曲线"
                }
            }
            if showsPrice {
                InvestmentPriceChart(store: store, accountID: account.id, asset: asset, range: $range, showsRanges: $showsRanges)
            } else if showsProfit {
                InvestmentProfitChart(store: store, account: account, asset: asset, range: range, showsRanges: $showsRanges)
            } else {
                if let selected {
                    chart(visible, selected: selected)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(InvestmentText.date(selected.day) + " · " + holdingTitle)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(asset.historyUsesAmount ? InvestmentText.money(selected.value, account.currency) : InvestmentText.number(selected.value) + " " + asset.historyUnit)
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                    }.padding(.top, 4)
                    Text(visible.count == 1 ? "目前仅有一天记录，积累记录后显示走势。" : (asset.historyUsesInvestment ? "按买入金额（含费用）减去卖出及分红回款计算，不随报价变化。" : (asset.historyUsesAmount ? "按历史余额或估值显示金额，缺少数据的日期不连线。" : "按每日持仓数量显示，包含买卖与数量调整。")))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if loadedRequest != request {
                    ProgressView("正在计算持仓变化…")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 175)
                } else {
                    Text("暂无可用记录，请先补充持仓数据。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .zIndex(showsRanges ? 10 : 0)
        .onChange(of: range) { selectedDay = nil }
        .onChange(of: display) { showsRanges = false; selectedDay = nil }
        .onDisappear { showsRanges = false }
        .task(id: showsPrice || showsProfit ? nil : request) { if !showsPrice && !showsProfit { await load(request) } }
    }

    private func chart(_ values: [InvestmentHoldingHistoryPoint], selected: InvestmentHoldingHistoryPoint) -> some View {
        let minimum = values.map { NSDecimalNumber(decimal: $0.value).doubleValue }.min() ?? 0
        let maximum = values.map { NSDecimalNumber(decimal: $0.value).doubleValue }.max() ?? 0
        let floor = minimum - max(maximum - minimum, abs(maximum) * 0.025, 0.00001) * 0.2
        return Chart {
            ForEach(values) { point in
                AreaMark(x: .value("日期", point.day), yStart: .value("下界", floor),
                         yEnd: .value("金额", NSDecimalNumber(decimal: point.value).doubleValue),
                         series: .value("连续区间", point.segment))
                    .interpolationMethod(asset.historyUsesAmount && !asset.historyUsesInvestment ? .linear : .stepEnd)
                    .foregroundStyle(InvestmentTrendStyle.curve.opacity(0.2))
                LineMark(x: .value("日期", point.day),
                         y: .value(asset.historyUsesAmount ? "金额" : "数量", NSDecimalNumber(decimal: point.value).doubleValue),
                         series: .value("连续区间", point.segment))
                    .interpolationMethod(asset.historyUsesAmount && !asset.historyUsesInvestment ? .linear : .stepEnd)
                    .foregroundStyle(InvestmentTrendStyle.curve)
                PointMark(x: .value("日期", point.day),
                          y: .value(asset.historyUsesAmount ? "金额" : "数量", NSDecimalNumber(decimal: point.value).doubleValue))
                    .foregroundStyle(InvestmentTrendStyle.curve).symbolSize(12)
            }
            RuleMark(x: .value("日期", selected.day))
                .foregroundStyle(HakoStyle.muted.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            PointMark(x: .value("日期", selected.day),
                      y: .value(asset.historyUsesAmount ? "金额" : "数量", NSDecimalNumber(decimal: selected.value).doubleValue))
                .foregroundStyle(InvestmentTrendStyle.curve).symbolSize(45)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { axis in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                if let value = axis.as(Double.self) {
                    AxisValueLabel {
                        Text(value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HakoChartInteraction { point, toggle in
                        if showsRanges { showsRanges = false; return }
                        let x = min(max(point.x, 0), frame.width)
                        guard let day = proxy.value(atX: x, as: Date.self),
                              let nearest = values.min(by: { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }) else { return }
                        selectedDay = toggle && selectedDay == nearest.day ? nil : nearest.day
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .environment(\.calendar, InvestmentBook.calendar)
        .environment(\.timeZone, InvestmentBook.calendar.timeZone)
        .frame(height: 171)
        .accessibilityLabel(asset.historyUsesAmount ? "以" + account.currency.rawValue + "计价的资产金额变化" : "持仓数量变化，单位" + asset.historyUnit)
        .accessibilityHint("点击或左右拖动查看日期和数据，松手保留选择，再次点击收起。")
    }

    private func load(_ request: Request) async {
        guard loadedRequest != request else { return }
        let book = self.book
        let worker = Task.detached(priority: .userInitiated) {
            guard let account = book.account(request.accountID),
                  let earliest = account.events.filter({ $0.assetID == request.assetID }).map(\.day).min() else {
                return [InvestmentHoldingHistoryPoint]()
            }
            let start = max(earliest, request.range.start(through: request.today, firstEntry: earliest))
            var dates: [Date] = []
            var day = start
            while day <= request.today, !Task.isCancelled {
                dates.append(day)
                day = InvestmentBook.addDays(1, to: day)
            }
            return book.holdingHistory(accountID: request.accountID, assetID: request.assetID, on: dates, today: request.today)
        }
        let values = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        selectedDay = nil
        points = values
        loadedRequest = request
    }
}
