import Charts
import SwiftUI

struct InvestmentHoldingChart: View {
    private struct Request: Equatable, Sendable {
        let version: UUID
        let accountID: UUID
        let assetID: UUID
        let today: Date
        let range: InvestmentRange
    }
    let book: InvestmentBook
    let bookVersion: UUID
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var range = InvestmentRange.month
    @State private var selectedDay: Date?
    @State private var loadedRequest: Request?
    @State private var points: [InvestmentHoldingHistoryPoint] = []

    var body: some View {
        let request = Request(version: bookVersion, accountID: account.id, assetID: asset.id,
                              today: InvestmentBook.day(), range: range)
        let visible = loadedRequest == request ? points : []
        let selected = selectedDay.flatMap { day in
            visible.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }
        } ?? visible.last
        InvestmentCard {
            Text(asset.historyUsesInvestment ? "净投入变化" : (asset.historyUsesAmount ? "资产金额变化" : "持仓数量变化")).font(.headline)
            HakoUnderlineTabs(title: "资产变化范围", options: InvestmentRange.chart, selection: $range) { $0.rawValue }
                .background(alignment: .bottom) { Divider() }
                .onChange(of: range) { selectedDay = nil }
            if let selected {
                chart(visible, selected: selected)
                HStack {
                    Text(InvestmentText.date(selected.day) + (selected.day == request.today ? " · 当前" : ""))
                    Spacer(minLength: 8)
                    Text(asset.historyUsesAmount ? InvestmentText.money(selected.value, account.currency) : InvestmentText.number(selected.value) + " " + asset.historyUnit).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
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
        .task(id: request) { await load(request) }
    }

    private func chart(_ values: [InvestmentHoldingHistoryPoint], selected: InvestmentHoldingHistoryPoint) -> some View {
        Chart {
            ForEach(values) { point in
                LineMark(x: .value("日期", point.day),
                         y: .value(asset.historyUsesAmount ? "金额" : "数量", NSDecimalNumber(decimal: point.value).doubleValue),
                         series: .value("连续区间", point.segment))
                    .interpolationMethod(asset.historyUsesAmount && !asset.historyUsesInvestment ? .linear : .stepEnd)
                    .foregroundStyle(Color.teal)
                PointMark(x: .value("日期", point.day),
                          y: .value(asset.historyUsesAmount ? "金额" : "数量", NSDecimalNumber(decimal: point.value).doubleValue))
                    .foregroundStyle(Color.teal).symbolSize(12)
            }
            RuleMark(x: .value("日期", selected.day))
                .foregroundStyle(HakoStyle.muted.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            PointMark(x: .value("日期", selected.day),
                      y: .value(asset.historyUsesAmount ? "金额" : "数量", NSDecimalNumber(decimal: selected.value).doubleValue))
                .foregroundStyle(Color.teal).symbolSize(45)
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
        .frame(height: 175)
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
            let start = max(earliest, request.range.start(from: request.today, earliest: earliest))
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
