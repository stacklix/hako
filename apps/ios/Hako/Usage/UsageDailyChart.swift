import SwiftUI
import Charts

struct UsageDailyChart: View {
    // Includes all years: a trailing average can need history preceding the selected year.
    let values: [UsageDayValue]
    let year: Int
    let movingAverages: Bool
    @State private var selectedDay: String?
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
        let data = points
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
                if movingAverages { legend }
                if let selectedDay {
                    selection(data.filter { $0.day == selectedDay }, day: selectedDay)
                } else {
                    Text("点击日期查看具体时长").font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
                }
                if movingAverages {
                    Text("按最近 7 / 30 / 90 / 180 个自然日内已有记录取均值，含当天；缺失日期不计为 0，记录不足时按已有天数计算。")
                        .font(.system(size: 11)).foregroundStyle(UsageStyle.muted).lineSpacing(3)
                }
            }
        }
        .usagePanel()
        .onChange(of: year) { _, _ in selectedDay = nil }
        .onChange(of: values) { _, _ in selectedDay = nil }
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
        .chartLegend(.hidden).chartXScale(domain: domain(data))
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
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let anchor = proxy.plotFrame else { return }
                        let frame = geometry[anchor]
                        guard frame.contains(event.location),
                              let date = proxy.value(atX: event.location.x - frame.minX, as: Date.self),
                              let point = data.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else {
                            selectedDay = nil; return
                        }
                        selectedDay = selectedDay == point.day ? nil : point.day
                    })
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 250 : 180)
        .environment(\.calendar, UsageDates.calendar)
        .environment(\.timeZone, UsageDates.calendar.timeZone)
        .accessibilityLabel("\(year) 年\(title)，单位小时")
        .accessibilityHint("点击日期，在图表下方查看每日时长或各条均线的具体数值。")
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
