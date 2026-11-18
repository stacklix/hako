import Charts
import SwiftUI

struct InvestmentProfitChart: View {
    private struct Request: Equatable, Sendable {
        let version: UUID
        let session: UUID
        let accountID: UUID
        let assetID: UUID
        let start: Date
        let today: Date
        let retry: Int
    }
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    let range: InvestmentHistoryRange
    @Binding var showsRanges: Bool
    @State private var points: [InvestmentHoldingHistoryPoint] = []
    @State private var change: Decimal?
    @State private var selectedDay: Date?
    @State private var loaded: Request?
    @State private var warning: String?
    @State private var missingDays = 0
    @State private var retry = 0
    @State private var token = UUID()

    var body: some View {
        let today = InvestmentBook.day()
        let first = store.book.firstPositionDay(accountID: account.id, assetID: asset.id) ?? today
        let start = min(range.start(through: today, firstEntry: first), today)
        let request = Request(version: store.bookVersion, session: store.ledgerRevision, accountID: account.id, assetID: asset.id,
                              start: start, today: today, retry: retry)
        let visible = loaded == request ? points : []
        let selected = selectedDay.flatMap { day in visible.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) } } ?? visible.last
        VStack(alignment: .leading, spacing: 9) {
            if let selected {
                chart(visible, selected: selected, start: start, today: today)
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(InvestmentText.date(selected.day) + " · 累计盈亏").font(.caption).foregroundStyle(.secondary)
                        Text(InvestmentText.money(selected.value, account.currency, signed: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(InvestmentText.money(change, account.currency, signed: true)).monospacedDigit()
                            .foregroundStyle(InvestmentText.tint(change))
                        Text("区间盈亏变化").foregroundStyle(.secondary)
                    }.font(.caption)
                }.padding(.top, 4)
                Text("估值记录 " + InvestmentText.date(visible.first!.day) + " — " + InvestmentText.date(visible.last!.day))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if loaded != request {
                ProgressView("正在计算盈亏曲线…").font(.subheadline).frame(maxWidth: .infinity, minHeight: 210)
            } else {
                Text("此时间范围缺少可用的估值记录。")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150)
            }
            Text("累计盈亏包含持仓浮盈亏、已实现盈亏及分红，扣除交易费用。切换范围不将累计盈亏归零。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(asset.kind.usesBalance
                 ? "按已记录余额和实际收支计算，支取利息计入盈亏；不按约定利率预估未到账利息。"
                 : (asset.kind.isManual ? "按截至所选日期已录入的估值计算，缺少估值时不补值。"
                    : "余额调整和送股按实际数量计入估值；当天使用最新可用报价，历史缺失不补值。"))
                .font(.caption2).foregroundStyle(.secondary)
            if missingDays > 0, loaded == request {
                Text("有 \(missingDays) 天缺少完整估值，曲线在缺失处断开。区间起点缺少估值时，盈亏变化显示为 —。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let warning, loaded == request {
                HStack(alignment: .top) {
                    Text(warning).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("重试") { retry += 1 }
                }.font(.caption)
            }
        }
        .task(id: request) { await load(request) }
    }

    private func chart(_ values: [InvestmentHoldingHistoryPoint], selected: InvestmentHoldingHistoryPoint,
                       start: Date, today: Date) -> some View {
        Chart {
            RuleMark(y: .value("盈亏平衡", 0))
                .foregroundStyle(HakoStyle.muted.opacity(0.6))
                .annotation(position: .top, alignment: .leading) { Text("盈亏平衡").font(.caption2).foregroundStyle(.secondary) }
            ForEach(values) { point in
                AreaMark(x: .value("日期", point.day), y: .value("累计盈亏", NSDecimalNumber(decimal: point.value).doubleValue),
                         series: .value("连续区间", point.segment), stacking: .unstacked)
                    .foregroundStyle(InvestmentTrendStyle.curve.opacity(0.2))
                LineMark(x: .value("日期", point.day), y: .value("累计盈亏", NSDecimalNumber(decimal: point.value).doubleValue),
                         series: .value("连续区间", point.segment))
                    .foregroundStyle(InvestmentTrendStyle.curve).interpolationMethod(.linear)
                if values.count == 1 {
                    PointMark(x: .value("日期", point.day), y: .value("累计盈亏", NSDecimalNumber(decimal: point.value).doubleValue))
                        .foregroundStyle(InvestmentTrendStyle.curve).symbolSize(30)
                }
            }
            if selectedDay != nil {
                RuleMark(x: .value("日期", selected.day))
                    .foregroundStyle(HakoStyle.muted.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("日期", selected.day), y: .value("累计盈亏", NSDecimalNumber(decimal: selected.value).doubleValue))
                    .foregroundStyle(InvestmentTrendStyle.curve).symbolSize(45)
            }
        }
        .chartXScale(domain: start...max(today, InvestmentBook.addDays(1, to: start)))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { axis in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                if let value = axis.as(Double.self) {
                    AxisValueLabel { Text(value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))).font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HakoChartInteraction { point, toggle in
                        if showsRanges { showsRanges = false; return }
                        guard let day = proxy.value(atX: min(max(point.x, 0), frame.width), as: Date.self),
                              let nearest = values.min(by: { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }) else { return }
                        selectedDay = toggle && selectedDay == nearest.day ? nil : nearest.day
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height)).position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .environment(\.calendar, InvestmentBook.calendar).environment(\.timeZone, InvestmentBook.calendar.timeZone)
        .frame(height: 171)
        .accessibilityLabel(asset.displayName + "累计盈亏曲线，单位" + account.currency.rawValue)
        .accessibilityHint("点击或左右拖动查看日期及累计盈亏。")
    }

    @MainActor private func load(_ request: Request) async {
        let currentToken = UUID()
        token = currentToken
        selectedDay = nil
        warning = nil
        var values: [InvestmentQuote] = []
        var message: String?
        do {
            let history = try await store.holdingPriceHistory(assetID: asset.id, from: InvestmentBook.addDays(-8, to: request.start), through: request.today)
            values = history.quotes
            message = history.warning
        } catch is CancellationError { return }
        catch { message = error.localizedDescription }
        guard !Task.isCancelled, token == currentToken, store.bookVersion == request.version, store.ledgerRevision == request.session else { return }
        var book = store.book
        book.quotes[asset.id] = InvestmentBook.merge(book.quotes[asset.id] ?? [], values)
        let calculationBook = book
        let accountID = account.id, assetID = asset.id
        let worker = Task.detached(priority: .userInitiated) {
            let baseline = InvestmentBook.addDays(-1, to: request.start)
            let count = InvestmentBook.calendar.dateComponents([.day], from: baseline, to: request.today).day ?? 0
            let dates = (0...max(0, count)).map { InvestmentBook.addDays($0, to: baseline) }
            return calculationBook.profitHistory(accountID: accountID, assetID: assetID,
                                                 on: dates, today: request.today)
        }
        let history = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, token == currentToken, store.bookVersion == request.version, store.ledgerRevision == request.session else { return }
        points = history.filter { $0.day >= request.start }
        missingDays = (InvestmentBook.calendar.dateComponents([.day], from: request.start, to: request.today).day ?? 0) + 1 - points.count
        change = history.first(where: { $0.day == InvestmentBook.addDays(-1, to: request.start) }).flatMap { first in
            points.last.map { $0.value - first.value }
        }
        warning = message
        loaded = request
    }
}
