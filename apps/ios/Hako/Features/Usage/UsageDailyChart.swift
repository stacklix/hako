import SwiftUI
import Charts

struct UsageDailyChart: View {
    // Includes all years: a trailing average can need history preceding the selected year.
    let values: [UsageDayValue]
    let year: Int
    let movingAverages: Bool
    @State private var selectedDay: String?
    @State private var cachedPoints: [UsageDailyValue] = []
    @State private var visibleRange: ClosedRange<Date>?
    @State private var pinchOrigin: ClosedRange<Date>?
    @State private var panOrigin: ClosedRange<Date>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var series: [UsageDailySeries] {
        movingAverages ? [.week, .month, .quarter, .halfYear] : [.daily]
    }
    private var points: [UsageDailyValue] {
        series.flatMap { UsageStatistics.days(values, year: year, series: $0) }
    }
    private var title: String { movingAverages ? "每日使用时长均线" : "每日使用时长" }
    private func domain(_ points: [UsageDailyValue]) -> ClosedRange<Date> {
        let first = points.map(\.date).min() ?? .now
        let last = points.map(\.date).max() ?? first
        return first.addingTimeInterval(-43_200)...last.addingTimeInterval(43_200)
    }
    var body: some View {
        let data = cachedPoints
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text("小时").font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
            }
            if data.isEmpty {
                Text("本年度暂无使用记录").font(.caption).foregroundStyle(UsageStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart(data)
                if let visibleRange {
                    HStack {
                        Text(visibleRange.lowerBound..<visibleRange.upperBound, format: .interval.day().month())
                            .font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
                        Spacer()
                        Button("还原范围") { self.visibleRange = nil; selectedDay = nil }
                            .font(.caption).foregroundStyle(.blue).frame(minHeight: 44).buttonStyle(.plain)
                    }
                    .environment(\.timeZone, UsageDates.calendar.timeZone)
                }
                if movingAverages { legend }
                if let selectedDay {
                    selection(data.filter { $0.day == selectedDay }, day: selectedDay)
                } else {
                    Text("双指缩放 · 左右滑动平移 · 按住查看数据").font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
                }
                if movingAverages {
                    Text("按最近 7 / 30 / 90 / 180 个自然日内已有记录取均值，含当天；缺失日期不计为 0，记录不足时按已有天数计算。")
                        .font(.system(size: 11)).foregroundStyle(UsageStyle.muted).lineSpacing(3)
                }
            }
        }
        .usagePanel()
        .onAppear { cachedPoints = points }
        .onChange(of: year) { _, _ in refresh() }
        .onChange(of: values) { _, _ in refresh() }
        .onChange(of: movingAverages) { _, _ in refresh() }
    }

    private func refresh() {
        cachedPoints = points
        selectedDay = nil
        visibleRange = nil
        pinchOrigin = nil
        panOrigin = nil
    }

    private func chart(_ data: [UsageDailyValue]) -> some View {
        Chart {
            ForEach(data) { point in
                if movingAverages {
                    LineMark(x: .value("日期", point.date), y: .value("小时", point.hours),
                             series: .value("均线", point.series.rawValue))
                        .foregroundStyle(by: .value("均线", point.series.rawValue))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if point.day == selectedDay || data.count == series.count {
                        PointMark(x: .value("日期", point.date), y: .value("小时", point.hours))
                            .foregroundStyle(by: .value("均线", point.series.rawValue)).symbolSize(24)
                    }
                } else {
                    BarMark(x: .value("日期", point.date, unit: .day), y: .value("小时", point.hours), width: .ratio(0.65))
                        .foregroundStyle(UsageStyle.series).cornerRadius(1)
                        .opacity(selectedDay == nil || point.day == selectedDay ? 1 : 0.3)
                }
            }
            if let selectedDay, let date = UsageDates.date(selectedDay) {
                RuleMark(x: .value("日期", date)).foregroundStyle(UsageStyle.muted.opacity(0.3)).zIndex(-1)
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.rawValue), range: series.map { UsageStyle.color($0) })
        .chartLegend(.hidden).chartXScale(domain: visibleRange ?? domain(data))
        .chartPlotStyle { plot in plot.clipped() }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                    .font(.system(size: 10)).foregroundStyle(UsageStyle.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7)).foregroundStyle(UsageStyle.line)
                AxisValueLabel().font(.system(size: 10)).foregroundStyle(UsageStyle.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    UsageChartInteraction(
                        canPan: visibleRange.map { $0.upperBound.timeIntervalSince($0.lowerBound) < domain(data).upperBound.timeIntervalSince(domain(data).lowerBound) - 1 } ?? false,
                        select: { point, toggle in
                            select(at: CGPoint(x: point.x + frame.minX, y: point.y + frame.minY),
                                   proxy: proxy, frame: frame, data: data, toggle: toggle)
                        },
                        zoom: { scale, fraction, phase in
                            switch phase {
                            case .began:
                                pinchOrigin = visibleRange ?? domain(data)
                                panOrigin = nil
                            case .changed:
                                guard let origin = pinchOrigin else { return }
                                visibleRange = UsageChartRange.zoom(origin, full: domain(data), magnification: scale, anchor: fraction)
                                selectedDay = nil
                            case .ended, .cancelled, .failed: pinchOrigin = nil
                            default: break
                            }
                        },
                        pan: { fraction, phase in
                            switch phase {
                            case .began: panOrigin = visibleRange ?? domain(data)
                            case .changed:
                                guard pinchOrigin == nil, let origin = panOrigin else { return }
                                visibleRange = UsageChartRange.pan(origin, full: domain(data), fraction: fraction)
                                selectedDay = nil
                            case .ended, .cancelled, .failed: panOrigin = nil
                            default: break
                            }
                        }
                    )
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 250 : 180)
        .environment(\.calendar, UsageDates.calendar)
        .environment(\.timeZone, UsageDates.calendar.timeZone)
        .accessibilityLabel("\(year) 年\(title)，单位小时")
        .accessibilityHint("双指缩放日期范围，放大后左右滑动平移。点击或按住左右滑动，在图表下方查看数据，松手保留选择。")
        .accessibilityAction(named: Text("放大日期范围")) {
            visibleRange = UsageChartRange.zoom(visibleRange ?? domain(data), full: domain(data), magnification: 2, anchor: 0.5)
            selectedDay = nil
        }
        .accessibilityAction(named: Text("缩小日期范围")) {
            visibleRange = UsageChartRange.zoom(visibleRange ?? domain(data), full: domain(data), magnification: 0.5, anchor: 0.5)
            selectedDay = nil
        }
    }

    private func select(at location: CGPoint, proxy: ChartProxy, frame: CGRect, data: [UsageDailyValue], toggle: Bool) {
        // Clamp horizontal movement to the chart edges, keeping the first/last day selected.
        let x = min(max(location.x - frame.minX, 0), frame.width)
        let range = visibleRange ?? domain(data)
        guard let date = proxy.value(atX: x, as: Date.self),
              let point = data.filter({ range.contains($0.date) })
                .min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
        selectedDay = toggle && selectedDay == point.day ? nil : point.day
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(series, id: \.self) { item in
                HStack(spacing: 6) {
                    Capsule().fill(UsageStyle.color(item)).frame(width: 13, height: 3).accessibilityHidden(true)
                    Text(item.rawValue).font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
                }
            }
        }
    }
    private func selection(_ points: [UsageDailyValue], day: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(UsageDates.title(day)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { selectedDay = nil } label: {
                    Label("收起", systemImage: "chevron.up").font(.caption).frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(UsageStyle.muted)
            }
            ForEach(points) { point in
                HStack {
                    Text(point.series.rawValue).font(.system(size: 12)).foregroundStyle(UsageStyle.muted)
                    Spacer()
                    Text(String(format: "%.2f 小时", point.hours)).font(.system(size: 12)).monospacedDigit()
                }
            }
        }
        .padding(12).background(UsageStyle.series.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}
