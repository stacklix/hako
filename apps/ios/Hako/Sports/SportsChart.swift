import SwiftUI
import Charts

struct SportsChart: View {
    let records: [SportsRecord]
    let metric: SportsMetric
    let cumulative: Bool
    // nil means all years: each x category is a year, matching the reference page.
    let year: Int?
    @State private var selectedPeriod: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var types: [String] { SportsStyle.types(in: records) }
    private var data: SportsChartData {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: .now)
        let lastMonth = year == currentYear
            ? max(calendar.component(.month, from: .now), records.map(\.month).max() ?? 1) : 12
        return SportsStatistics.chart(records, metric: metric, cumulative: cumulative, year: year, months: lastMonth)
    }
    private var categories: [String] { year == nil ? data.periods : (1...12).map { "\($0)月" } }
    private var tickPeriods: [String] {
        if year != nil { return ["1月", "4月", "7月", "10月", "12月"] }
        let step = max(1, Int(ceil(Double(categories.count) / 5)))
        return categories.enumerated().compactMap { index, period in
            index % step == 0 || index == categories.count - 1 ? period : nil
        }
    }
    private var title: String { (cumulative ? "累计" : year == nil ? "每年" : "每月") + metric.title }
    private var selectedValues: [SportsPeriodPoint] { selectedPeriod.map(data.values(in:)) ?? [] }
    private var selectionTitle: String {
        guard let selectedPeriod else { return "" }
        return year.map { "\($0) 年 \(selectedPeriod)" } ?? "\(selectedPeriod) 年"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text(metric.unit).font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
            }
            if data.points.isEmpty {
                Text(year == nil ? "暂无运动数据" : "本年度暂无数据").font(.caption).foregroundStyle(SportsStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                renderedChart
                legend
            }
        }
        .sportsPanel()
        .onChange(of: year) { _, _ in selectedPeriod = nil }
        .onChange(of: metric) { _, _ in selectedPeriod = nil }
        .onChange(of: cumulative) { _, _ in selectedPeriod = nil }
    }

    private var renderedChart: some View {
        Chart {
            ForEach(data.points) { point in
                if cumulative {
                    LineMark(x: .value("统计周期", point.period), y: .value(metric.unit, point.value),
                             series: .value("运动类型", point.type))
                        .foregroundStyle(by: .value("运动类型", point.type))
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("统计周期", point.period), y: .value(metric.unit, point.value))
                        .foregroundStyle(by: .value("运动类型", point.type)).symbolSize(16)
                } else {
                    // Periods are categorical bands, rather than continuous integer coordinates.
                    // A proportional width on the old continuous scale collapsed the bars to zero.
                    BarMark(x: .value("统计周期", point.period), y: .value(metric.unit, point.value),
                            width: .ratio(0.56), stacking: .standard)
                        .foregroundStyle(by: .value("运动类型", point.type)).cornerRadius(1)
                }
            }
            if let selectedPeriod, categories.contains(selectedPeriod) {
                RuleMark(x: .value("统计周期", selectedPeriod))
                    .foregroundStyle(SportsStyle.muted.opacity(0.3))
                    .zIndex(-1)
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        selectionPopover
                    }
            }
        }
        .chartForegroundStyleScale(domain: types, range: types.map { SportsStyle.color($0) })
        .chartLegend(.hidden)
        .chartXScale(domain: categories)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: tickPeriods) { value in
                AxisValueLabel {
                    if let period = value.as(String.self) {
                        Text(period).font(.system(size: 10)).foregroundStyle(SportsStyle.muted).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7)).foregroundStyle(SportsStyle.line)
                AxisValueLabel().font(.system(size: 10)).foregroundStyle(SportsStyle.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let anchor = proxy.plotFrame else { return }
                        let frame = geometry[anchor]
                        guard frame.contains(event.location),
                              let period = proxy.value(atX: event.location.x - frame.minX, as: String.self) else {
                            selectedPeriod = nil
                            return
                        }
                        selectedPeriod = selectedPeriod == period ? nil : period
                    })
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 160)
        .accessibilityLabel((year.map { "\($0) 年" } ?? "全部年份") + title + "，单位" + metric.unit)
        .accessibilityHint("点击图表显示该周期的合计及各运动类型数据，再次点击可收起。")
    }

    private var selectionPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectionTitle).font(.system(size: 12, weight: .semibold))
            HStack {
                Text(cumulative ? "累计合计" : "合计")
                Spacer()
                Text(valueLabel(selectedValues.reduce(0) { $0 + $1.value })).monospacedDigit()
            }.font(.system(size: 11, weight: .semibold))
            ForEach(types, id: \.self) { type in
                HStack(spacing: 5) {
                    Circle().fill(SportsStyle.color(type)).frame(width: 6, height: 6)
                    Text(type)
                    Spacer(minLength: 8)
                    Text(valueLabel(selectedValues.first { $0.type == type }?.value ?? 0)).monospacedDigit()
                }.font(.system(size: 11))
            }
        }
        .foregroundStyle(SportsStyle.text).padding(10).frame(width: 185)
        .background(SportsStyle.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SportsStyle.line) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func valueLabel(_ value: Double) -> String {
        String(format: metric == .count ? "%.0f" : "%.2f", value) + " " + metric.unit
    }
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { legendItems }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading, spacing: 8) { legendItems }
        }
    }
    @ViewBuilder private var legendItems: some View {
        ForEach(types, id: \.self) { type in
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(SportsStyle.color(type)).frame(width: 7, height: 7)
                Text(type).font(.system(size: 10)).foregroundStyle(SportsStyle.muted).fixedSize()
            }
        }
    }
}
