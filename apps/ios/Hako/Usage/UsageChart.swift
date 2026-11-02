import SwiftUI
import Charts

struct UsageChart: View {
    let values: [UsageDayValue]
    let year: Int
    let metric: UsageChartMetric
    @State private var selected: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var points: [UsageMonthValue] { UsageStatistics.months(values, year: year, metric: metric) }
    private var categories: [String] { (1...12).map { "\($0)月" } }
    private var selectedValue: UsageMonthValue? { points.first { $0.period == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(metric.title).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text("小时").font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
            }
            if values.isEmpty {
                Text("本年度暂无使用记录").font(.caption).foregroundStyle(UsageStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart
                if let selectedValue {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(year) 年 \(selectedValue.month) 月").font(.system(size: 13, weight: .semibold))
                            Text(String(format: "%.1f 小时", selectedValue.hours)).font(.system(size: 12)).monospacedDigit()
                        }
                        Spacer()
                        Button { selected = nil } label: {
                            Label("收起", systemImage: "chevron.up").font(.caption).frame(minHeight: 44)
                        }.buttonStyle(.plain).foregroundStyle(UsageStyle.muted)
                    }
                    .padding(12).background(UsageStyle.series.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                } else {
                    Text("点击月份查看具体时长").font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
                }
            }
        }
        .usagePanel()
        .onChange(of: year) { _, _ in selected = nil }
        .onChange(of: metric) { _, _ in selected = nil }
        .onChange(of: values) { _, _ in selected = nil }
    }
    private var chart: some View {
        Chart {
            ForEach(points) { point in
                if metric == .cumulative {
                    LineMark(x: .value("月份", point.period), y: .value("小时", point.hours))
                        .foregroundStyle(UsageStyle.series).lineStyle(StrokeStyle(lineWidth: 2.2))
                    PointMark(x: .value("月份", point.period), y: .value("小时", point.hours))
                        .foregroundStyle(UsageStyle.series).symbolSize(point.period == selected ? 32 : 16)
                } else {
                    BarMark(x: .value("月份", point.period), y: .value("小时", point.hours), width: .ratio(0.56))
                        .foregroundStyle(UsageStyle.series).cornerRadius(1)
                        .opacity(selected == nil || selected == point.period ? 1 : 0.3)
                }
            }
            if let selected {
                RuleMark(x: .value("月份", selected)).foregroundStyle(UsageStyle.muted.opacity(0.3)).zIndex(-1)
            }
        }
        .chartLegend(.hidden).chartXScale(domain: categories)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: ["1月", "4月", "7月", "10月", "12月"]) { value in
                AxisValueLabel {
                    if let period = value.as(String.self) {
                        Text(period).font(.system(size: 10)).foregroundStyle(UsageStyle.muted).fixedSize()
                    }
                }
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
                              let period = proxy.value(atX: event.location.x - frame.minX, as: String.self) else {
                            selected = nil; return
                        }
                        selected = selected == period ? nil : period
                    })
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 160)
        .accessibilityLabel("\(year) 年\(metric.title)，单位小时")
        .accessibilityHint("点击月份，在图表下方查看具体数据。")
    }
}
