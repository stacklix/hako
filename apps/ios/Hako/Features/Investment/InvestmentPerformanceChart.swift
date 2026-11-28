import Charts
import SwiftUI

struct InvestmentPerformanceChart: View {
    private enum Metric: String, CaseIterable {
        case value = "投资总额", gain = "盈亏曲线", rate = "盈亏率曲线"
        func amount(_ sample: InvestmentPerformanceSample) -> Decimal? {
            switch self { case .value: sample.value; case .gain: sample.gain; case .rate: sample.rate }
        }
    }
    private struct Request: Equatable, Sendable {
        let version: UUID
        let accountID: UUID?
        let start: Date
        let today: Date
        let range: InvestmentHistoryRange
    }
    private struct Loaded { let request: Request; let history: InvestmentPerformanceHistory }
    private struct BenchmarkRequest: Equatable {
        let benchmark: InvestmentBenchmark
        let start: Date
        let end: Date
        let retry: Int
    }
    private struct Point: Identifiable {
        let day: Date
        let value: Decimal
        let segment: Int
        var id: Date { day }
        var number: Double { NSDecimalNumber(decimal: value).doubleValue }
    }

    let book: InvestmentBook
    let bookVersion: UUID
    let accountID: UUID?
    let onLoadingChange: (Bool) -> Void
    @State private var metric = Metric.value
    @State private var range = InvestmentHistoryRange.month
    @State private var showsRanges = false
    @State private var showsBenchmarks = false
    @State private var benchmark = InvestmentBenchmark.sp500
    @State private var benchmarkQuotes: [InvestmentQuote] = []
    @State private var benchmarkError: String?
    @State private var benchmarkLoading = false
    @State private var benchmarkRetry = 0
    @State private var chartDay: Date?
    @State private var loaded: Loaded?

    init(book: InvestmentBook, bookVersion: UUID, accountID: UUID? = nil, onLoadingChange: @escaping (Bool) -> Void = { _ in }) {
        self.book = book; self.bookVersion = bookVersion; self.accountID = accountID
        self.onLoadingChange = onLoadingChange
    }

    var body: some View {
        let today = InvestmentBook.day()
        let first = (accountID.flatMap { book.account($0)?.earliest } ?? book.earliest) ?? today
        let start = max(first, range.start(through: today, firstEntry: first))
        let request = Request(version: bookVersion, accountID: accountID, start: start, today: today, range: range)
        // Keep the existing curve visible while refreshed snapshots are being calculated.
        let history = loaded?.request.accountID == accountID && loaded?.request.range == range ? loaded?.history : nil
        let points = chartPoints(history?.samples ?? [])
        let selected = chartDay.flatMap { day in points.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) } } ?? points.last
        let reference = benchmark.returns(quotes: benchmarkQuotes, samples: history?.samples ?? [])
        let benchmarkRequest = BenchmarkRequest(benchmark: benchmark, start: start, end: today, retry: benchmarkRetry)
        return InvestmentCard {
            HStack {
                Text("投资趋势").font(.headline)
                Spacer(minLength: 12)
                InvestmentTrendMenu(title: "选择时间范围", options: InvestmentHistoryRange.trend,
                    selection: $range, isExpanded: $showsRanges) { $0.rawValue }
            }.zIndex(40)
            InvestmentChartTabs(title: "走势图类型", options: Metric.allCases, selection: $metric) { $0.rawValue }
            if metric == .rate { comparisonLegend }
            if let selected, let history {
                chart(points, reference: reference, selected: selected, start: start, end: today)
                readout(selected, currency: history.currency, today: today)
                if metric == .rate { comparisonReadout(selected, reference: reference) }
            } else if history == nil {
                Color.clear.frame(height: 200)
            } else {
                Text(metric == .rate ? "此区间暂无完整的收益率记录。" : "此区间暂无完整估值记录。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
            if metric == .rate {
                benchmarkSelector
                if benchmarkLoading { Text("正在查询指数日线…").font(.caption2).foregroundStyle(.secondary) }
                if let benchmarkError {
                    HStack(alignment: .top) {
                        Text(benchmarkError).foregroundStyle(.secondary)
                        Spacer(minLength: 5)
                        Button("重试") { benchmarkRetry += 1 }.disabled(benchmarkLoading)
                    }.font(.caption)
                } else if !benchmarkLoading, reference.isEmpty, !points.isEmpty {
                    Text("基准缺少同一区间起点的已收盘行情，暂无法比较。").font(.caption2).foregroundStyle(.secondary)
                }
                Text("区间起点归零，组合剔除资金进出影响，非年化；基准按已发布的本币收盘价，不含分红及汇率。")
                    .font(.caption2).foregroundStyle(.secondary)
                if history?.samples.contains(where: { $0.value == nil || ($0.value ?? 0) > 0 && $0.rate == nil }) == true {
                    Text("区间估值或资金记录不完整，缺失后的收益率暂不计算。").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(metric == .gain ? "累计盈亏，切换范围不归零；缺少完整估值时不连线。" :
                     (accountID == nil ? "按人民币汇总投资总额，历史使用日终估值。" : "按账户币种汇总，历史使用日终估值。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let history, let last = history.samples.last, let firstDay = history.samples.first?.day {
                let detailDay = selected?.day ?? last.day
                let details = history.categories.compactMap { $0.detail(on: detailDay) }
                if accountID == nil {
                    accountDetails(details, start: firstDay, end: detailDay, currency: history.currency)
                } else {
                    holdingDetails(details, start: firstDay, end: detailDay, currency: history.currency)
                }
                if metric == .gain {
                    InvestmentPerformanceTreemap(details: history.categories.compactMap { $0.detail(on: last.day) },
                        currency: history.currency, start: firstDay, end: last.day, overview: accountID == nil)
                }
            }
        }
        .zIndex(showsRanges || showsBenchmarks ? 30 : 0)
        .onChange(of: range) { chartDay = nil; showsRanges = false }
        .onChange(of: metric) { showsRanges = false; showsBenchmarks = false }
        .onChange(of: showsRanges) { if showsRanges { showsBenchmarks = false } }
        .onChange(of: showsBenchmarks) { if showsBenchmarks { showsRanges = false } }
        .onDisappear { showsRanges = false; showsBenchmarks = false }
        .task(id: request) { await load(request) }
        .onChange(of: loaded?.request == request, initial: true) { _, complete in onLoadingChange(!complete) }
        .task(id: metric == .rate ? benchmarkRequest : nil) { if metric == .rate { await loadBenchmark(benchmarkRequest) } }
    }

    private func chartPoints(_ samples: [InvestmentPerformanceSample]) -> [Point] {
        var segment = 0
        return samples.compactMap { sample in
            guard let amount = metric.amount(sample) else { segment += 1; return nil }
            return Point(day: sample.day, value: amount, segment: segment)
        }
    }

    private var comparisonLegend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) { Rectangle().fill(InvestmentTrendStyle.curve).frame(width: 17, height: 2); Text("投资组合") }
            HStack(spacing: 5) {
                Rectangle().stroke(InvestmentTrendStyle.benchmark, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(width: 17, height: 1)
                Text(benchmark.rawValue)
            }
        }.font(.caption2).foregroundStyle(.secondary).accessibilityElement(children: .combine)
    }

    private var benchmarkSelector: some View {
        HStack {
            Text("比较基准").font(.caption).foregroundStyle(.secondary)
            Spacer()
            InvestmentTrendMenu(title: "选择比较基准", options: InvestmentBenchmark.allCases,
                selection: $benchmark, isExpanded: $showsBenchmarks) { $0.rawValue }
        }.zIndex(35)
    }

    private func readout(_ selected: Point, currency: InvestmentCurrency, today: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(InvestmentText.date(selected.day) + (selected.day == today ? " · 暂估" : "")).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("组合 " + (metric == .rate ? InvestmentText.percent(selected.value) : InvestmentText.money(selected.value, currency, signed: metric == .gain)))
                .foregroundStyle(metric == .value ? Color.primary : InvestmentTrendStyle.tint(selected.value))
        }.font(.caption).monospacedDigit()
    }

    private func comparisonReadout(_ selected: Point, reference: [Date: Decimal]) -> some View {
        HStack {
            Text(benchmark.rawValue + " " + InvestmentText.percent(reference[selected.day])).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let value = reference[selected.day] {
                let difference = selected.value - value
                Text(difference == 0 ? "持平" : (difference > 0 ? "领先 " : "落后 ") +
                     (abs(difference) * 100).formatted(.number.precision(.fractionLength(2))) + "个百分点")
                    .foregroundStyle(InvestmentTrendStyle.tint(difference))
            }
        }.font(.caption).monospacedDigit()
    }

    private func chart(_ points: [Point], reference: [Date: Decimal], selected: Point, start: Date, end: Date) -> some View {
        let references = metric == .rate ? reference.sorted { $0.key < $1.key } : []
        return Chart {
            RuleMark(y: .value("零轴", 0)).foregroundStyle(HakoStyle.muted.opacity(0.5))
            ForEach(points) { point in
                AreaMark(x: .value("日期", point.day), y: .value("金额", point.number),
                         series: .value("连续区间", "组合-\(point.segment)"), stacking: .unstacked)
                    .foregroundStyle(InvestmentTrendStyle.curve.opacity(0.2))
                LineMark(x: .value("日期", point.day), y: .value("金额", point.number), series: .value("连续区间", "组合-\(point.segment)"))
                    .foregroundStyle(InvestmentTrendStyle.curve)
            }
            ForEach(references, id: \.key) { day, amount in
                LineMark(x: .value("日期", day), y: .value("金额", NSDecimalNumber(decimal: amount).doubleValue),
                         series: .value("连续区间", "比较基准"))
                    .foregroundStyle(InvestmentTrendStyle.benchmark).lineStyle(StrokeStyle(lineWidth: 1.8, dash: [5, 4]))
            }
            RuleMark(x: .value("日期", selected.day)).foregroundStyle(HakoStyle.muted.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            PointMark(x: .value("日期", selected.day), y: .value("金额", selected.number)).foregroundStyle(InvestmentTrendStyle.curve)
            if metric == .rate, let amount = reference[selected.day] {
                PointMark(x: .value("日期", selected.day), y: .value("金额", NSDecimalNumber(decimal: amount).doubleValue))
                    .foregroundStyle(InvestmentTrendStyle.benchmark)
            }
        }
        .chartXScale(domain: start...max(end, InvestmentBook.addDays(1, to: start)))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { axis in
                if let day = axis.as(Date.self) { AxisValueLabel { Text(InvestmentBalanceStyle.shortDay(day)).font(.caption2) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { axis in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                if let amount = axis.as(Double.self) {
                    AxisValueLabel { Text(axisLabel(amount)).font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HakoChartInteraction { point, toggle in
                        if showsRanges || showsBenchmarks { showsRanges = false; showsBenchmarks = false; return }
                        guard let day = proxy.value(atX: min(max(point.x, 0), frame.width), as: Date.self),
                              let nearest = points.min(by: { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }) else { return }
                        chartDay = toggle && chartDay == nearest.day ? nil : nearest.day
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height)).position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .environment(\.calendar, InvestmentBook.calendar).environment(\.timeZone, InvestmentBook.calendar.timeZone)
        .frame(height: 171).accessibilityLabel(metric.rawValue + (metric == .rate ? "，单位百分比" : "，单位账户币种"))
        .accessibilityHint("点击或左右拖动查看日期和数值，再次点击收起选择。")
    }

    private func axisLabel(_ value: Double) -> String {
        if metric == .rate { return value.formatted(.percent.precision(.fractionLength(0...2))) }
        let large = abs(value) >= 10_000
        return (large ? value / 10_000 : value).formatted(.number.precision(.fractionLength(0...2))) + (large ? "万" : "")
    }

    private func accountDetails(_ details: [InvestmentPerformanceDetail], start: Date, end: Date,
                                currency: InvestmentCurrency) -> some View {
        VStack(alignment: .leading, spacing: metric == .rate ? 12 : 10) {
            Divider()
            if metric == .rate {
                HStack(alignment: .firstTextBaseline) {
                    Text("各账户累计盈亏率").font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(InvestmentText.date(end)).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(details) { detail in
                    HStack(alignment: .firstTextBaseline) {
                        Text(detail.name).lineLimit(2)
                        Spacer(minLength: 12)
                        detailNumber(detail.cumulativeRate, currency: currency, signed: true)
                    }
                    .font(.caption).monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text(metric == .value ? "各账户总额" : "各账户盈亏").font(.subheadline.weight(.medium))
                Text(InvestmentText.date(start) + " — " + InvestmentText.date(end)).font(.caption2).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
                    GridRow {
                        Text("账户").frame(maxWidth: .infinity, alignment: .leading)
                        Text(metric == .value ? "区间变动" : "区间盈亏").gridColumnAlignment(.trailing)
                        Text(metric == .value ? "期末总额" : "累计盈亏").gridColumnAlignment(.trailing)
                    }.font(.caption2).foregroundStyle(.secondary)
                    ForEach(details) { detail in
                        GridRow {
                            Text(detail.name).lineLimit(2)
                            detailNumber(metric == .value ? detail.change : detail.periodGain,
                                         currency: currency, signed: true)
                            detailNumber(metric == .value ? detail.value : detail.gain,
                                         currency: currency, signed: metric != .value)
                        }.font(.caption)
                    }
                }.monospacedDigit()
            }
        }.padding(.top, 5)
    }

    private func holdingDetails(_ details: [InvestmentPerformanceDetail], start: Date, end: Date,
                                currency: InvestmentCurrency) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(metric == .value ? "标的总额明细" : metric == .gain ? "标的区间盈亏" : "标的区间收益率").font(.subheadline.weight(.medium))
            Text(InvestmentText.date(start) + " — " + InvestmentText.date(end)).font(.caption2).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Text("标的").frame(maxWidth: .infinity, alignment: .leading)
                    Text(metric == .value ? "区间变动" : metric == .gain ? "区间盈亏" : "区间收益率").gridColumnAlignment(.trailing)
                    Text(metric == .value ? "期末总额" : metric == .gain ? "累计盈亏" : "累计盈亏率").gridColumnAlignment(.trailing)
                }.font(.caption2).foregroundStyle(.secondary)
                ForEach(details) { detail in
                    GridRow {
                        Text(detail.name).lineLimit(2)
                        detailNumber(metric == .value ? detail.change : metric == .gain ? detail.periodGain : detail.rate,
                                     currency: currency, signed: true)
                        detailNumber(metric == .value ? detail.value : metric == .gain ? detail.gain : detail.cumulativeRate,
                                     currency: currency, signed: metric != .value)
                    }.font(.caption)
                }
            }.monospacedDigit()
        }.padding(.top, 5)
    }

    private func detailNumber(_ value: Decimal?, currency: InvestmentCurrency, signed: Bool) -> some View {
        Text(metric == .rate ? InvestmentText.percent(value) : InvestmentText.money(value, currency, signed: signed))
            .foregroundStyle(signed ? InvestmentTrendStyle.tint(value) : Color.primary).lineLimit(1).minimumScaleFactor(0.7)
    }

    private func load(_ request: Request) async {
        guard loaded?.request != request else { return }
        let book = book
        let worker = Task.detached(priority: .userInitiated) {
            book.performanceHistory(accountID: request.accountID, from: request.start, through: request.today)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        loaded = .init(request: request, history: result)
    }

    private func loadBenchmark(_ request: BenchmarkRequest) async {
        benchmarkQuotes = []; benchmarkError = nil; benchmarkLoading = true
        do {
            let quotes = try await InvestmentBenchmarkCache.shared.history(request.benchmark, from: request.start, through: request.end, refresh: request.retry > 0)
            guard !Task.isCancelled else { return }
            benchmarkQuotes = quotes; benchmarkLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            benchmarkLoading = false; benchmarkError = error.localizedDescription
        }
    }
}
