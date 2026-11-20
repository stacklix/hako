import Charts
import SwiftUI

struct InvestmentPriceChart: View {
    private struct Request: Equatable {
        let session: UUID
        let asset: InvestmentAsset
        let start: Date
        let end: Date
        let retry: Int
    }
    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    let asset: InvestmentAsset
    @Binding var range: InvestmentHistoryRange
    @Binding var showsRanges: Bool
    @State private var fetched: [InvestmentQuote] = []
    @State private var fetchedAsset: InvestmentAsset?
    @State private var fetchedSession: UUID?
    @State private var selectedDay: Date?
    @State private var selectedTradeIDs: Set<UUID> = []
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    @State private var loadToken = UUID()

    var body: some View {
        let today = InvestmentBook.day()
        let first = store.book.firstPositionDay(accountID: accountID, assetID: asset.id) ?? today
        let start = min(range.start(through: today, firstEntry: first), today)
        let request = Request(session: store.ledgerRevision, asset: asset, start: start, end: today, retry: retry)
        let window = start...today
        let local = fetchedAsset == asset && fetchedSession == request.session ? fetched : []
        let prices = InvestmentBook.priceHistory(asset: asset, cached: store.book.quotes[asset.id] ?? [], fetched: local, in: window)
        let trades = store.book.priceTrades(accountID: accountID, assetID: asset.id, in: window)
        let selectedTrades = trades.filter { selectedTradeIDs.contains($0.id) }
        let selected = selectedDay.flatMap { day in prices.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) } } ?? prices.last
        VStack(alignment: .leading, spacing: 9) {
            if !prices.isEmpty || !trades.isEmpty {
                chart(prices: prices, trades: trades, selected: selected, window: window)
                readout(prices: prices, selected: selected, trade: selectedTrades.first)
                HStack(spacing: 14) {
                    legend("买入", color: .green)
                    legend("卖出", color: .red)
                    Spacer(minLength: 4)
                    if loading { ProgressView().controlSize(.mini).accessibilityLabel("正在补齐历史行情") }
                }.font(.caption2).foregroundStyle(.secondary)
                if selectedTrades.isEmpty {
                    if let first = prices.first, let last = prices.last {
                        Text("行情覆盖 " + InvestmentText.date(first.day) + " — " + InvestmentText.date(last.day))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("缺少日线报价，当前仅显示成交流水圆点。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Divider()
                    ForEach(selectedTrades) { trade in tradeDetail(trade) }
                }
                Text(asset.kind == .fund ? "价格线为单位净值，圆点为实际成交净值。" : "价格线为日线收盘价，圆点为实际成交价。")
                    .font(.caption2).foregroundStyle(.secondary)
                if asset.usesUSEquityClose {
                    Text("美股行情按收盘对应的北京时间日期显示。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if asset.kind == .crypto {
                    Text("加密货币按北京时间日线显示美元价格，当天日线在收盘后补齐。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if loading {
                ProgressView("正在查询历史行情…").font(.subheadline).frame(maxWidth: .infinity, minHeight: 190)
            } else {
                Text("此时间范围暂无日线行情或成交记录。")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 130)
            }
            if let error {
                HStack(alignment: .top, spacing: 12) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("重试") { retry += 1 }.font(.caption).disabled(loading)
                }
            }
        }
        .onChange(of: range) { selectedDay = nil; selectedTradeIDs = [] }
        .task(id: request) { await load(request) }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title)
        }
    }

    private func readout(prices: [InvestmentPricePoint], selected: InvestmentPricePoint?, trade: InvestmentPriceTrade?) -> some View {
        let price = trade?.price ?? selected?.price
        let day = trade?.day ?? selected?.day
        let change = prices.first.flatMap { first in prices.last.map { ($0.price / first.price - 1) } }
        return HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.map { InvestmentText.date($0) + " · " } ?? "")
                    + Text(trade != nil ? "成交价" : asset.kind == .fund ? "单位净值" : "收盘价")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(price.map(InvestmentText.number) ?? "—").font(.subheadline.weight(.medium)).foregroundStyle(.primary).monospacedDigit()
                    Text(asset.currency.rawValue + " / " + asset.historyUnit)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(InvestmentText.percent(change)).foregroundStyle(InvestmentText.tint(change)).monospacedDigit()
                Text("区间涨跌幅")
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func chart(prices: [InvestmentPricePoint], trades: [InvestmentPriceTrade], selected: InvestmentPricePoint?,
                       window: ClosedRange<Date>) -> some View {
        let minimum = prices.map { NSDecimalNumber(decimal: $0.price).doubleValue }.min() ?? 0
        let maximum = prices.map { NSDecimalNumber(decimal: $0.price).doubleValue }.max() ?? 0
        let floor = max(0, minimum - max(maximum - minimum, abs(maximum) * 0.025, 0.00001) * 0.2)
        return Chart {
            ForEach(prices) { point in
                AreaMark(x: .value("日期", point.day), yStart: .value("下界", floor),
                         yEnd: .value("价格", NSDecimalNumber(decimal: point.price).doubleValue))
                    .foregroundStyle(InvestmentTrendStyle.curve.opacity(0.2))
                LineMark(x: .value("日期", point.day), y: .value("价格", NSDecimalNumber(decimal: point.price).doubleValue))
                    .foregroundStyle(InvestmentTrendStyle.curve).interpolationMethod(.linear)
                if prices.count == 1 {
                    PointMark(x: .value("日期", point.day), y: .value("价格", NSDecimalNumber(decimal: point.price).doubleValue))
                        .foregroundStyle(InvestmentTrendStyle.curve).symbolSize(18)
                }
            }
            ForEach(trades) { trade in
                PointMark(x: .value("日期", trade.day), y: .value("成交价", NSDecimalNumber(decimal: trade.price).doubleValue))
                    .foregroundStyle(trade.isBuy ? Color.green : Color.red)
                    .symbolSize(selectedTradeIDs.contains(trade.id) ? 55 : 32)
                    .accessibilityLabel(Text((trade.isBuy ? "买入" : "卖出") + "，" + InvestmentText.date(trade.day)))
                    .accessibilityValue(Text(InvestmentText.price(trade.price, asset.currency) + "，" + InvestmentText.number(trade.quantity) + asset.historyUnit))
            }
            if let selected, selectedDay != nil, selectedTradeIDs.isEmpty {
                RuleMark(x: .value("日期", selected.day)).foregroundStyle(HakoStyle.muted.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("日期", selected.day), y: .value("价格", NSDecimalNumber(decimal: selected.price).doubleValue))
                    .foregroundStyle(InvestmentTrendStyle.curve).symbolSize(35)
            }
        }
        .chartXScale(domain: window.lowerBound...max(window.upperBound, InvestmentBook.addDays(1, to: window.lowerBound)))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { axis in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                if let value = axis.as(Double.self) {
                    AxisValueLabel { Text(value.formatted(.number.precision(.fractionLength(0...4)))).font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HakoChartInteraction { point, toggle in
                        if showsRanges { showsRanges = false; return }
                        let nearby = toggle ? trades.filter { trade in
                            guard let x = proxy.position(forX: trade.day),
                                  let y = proxy.position(forY: NSDecimalNumber(decimal: trade.price).doubleValue) else { return false }
                            return abs(x - point.x) <= 16 && abs(y - point.y) <= 20
                        } : []
                        if !nearby.isEmpty {
                            let ids = Set(nearby.map(\.id))
                            selectedTradeIDs = ids == selectedTradeIDs ? [] : ids
                            selectedDay = nil
                        } else if let day = proxy.value(atX: min(max(0, point.x), frame.width), as: Date.self) {
                            selectedTradeIDs = []
                            let nearest = prices.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }
                            selectedDay = toggle && selectedDay == nearest?.day ? nil : nearest?.day
                        }
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .environment(\.calendar, InvestmentBook.calendar)
        .environment(\.timeZone, InvestmentBook.calendar.timeZone)
        .frame(height: 171)
        .accessibilityLabel(asset.name + "价格走势，单位 " + asset.currency.rawValue)
        .accessibilityHint("绿色圆点为买入，红色圆点为卖出。点击圆点查看成交，左右拖动查看价格。")
    }

    private func tradeDetail(_ trade: InvestmentPriceTrade) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text((trade.isBuy ? "买入" : "卖出") + (trade.isOpening ? " · 首次建仓" : ""))
                    .foregroundStyle(trade.isBuy ? Color.green : Color.red)
                Text(InvestmentText.date(trade.day)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text((asset.isStockConnect ? (trade.isBuy ? "买入单价 " : "卖出单价 ") : "成交价 ") + InvestmentText.price(trade.price, asset.currency))
                Text(InvestmentText.number(trade.quantity) + " " + asset.historyUnit).foregroundStyle(.secondary)
            }.monospacedDigit()
        }.font(.caption)
    }

    @MainActor private func load(_ request: Request) async {
        let token = UUID()
        loadToken = token
        loading = true
        error = nil
        if fetchedAsset != request.asset || fetchedSession != request.session { fetched = [] }
        selectedDay = nil
        selectedTradeIDs = []
        defer { if loadToken == token { loading = false } }
        do {
            let values = try await store.holdingPriceHistory(assetID: request.asset.id, from: request.start, through: request.end)
            try Task.checkCancellation()
            guard loadToken == token, store.ledgerRevision == request.session else { return }
            fetched = InvestmentBook.merge(fetched, values.quotes)
            fetchedAsset = request.asset
            fetchedSession = request.session
            error = values.warning
        } catch is CancellationError {
            return
        } catch {
            guard loadToken == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
