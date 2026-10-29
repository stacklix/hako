import SwiftUI
import Charts

struct CodexUsageChart: View {
    private enum Metric: String, CaseIterable { case calls = "调用数", tokens = "Token" }
    let usage: ConsoleCodexUsage
    @State private var selectedDate: String?
    @State private var selectedMetric: Metric = .calls
    private var metric: Metric { usage.countsUserMessages ? selectedMetric : .tokens }
    private var color: Color { metric == .calls ? .blue : .orange }
    private var maximum: Double { ConsoleCodexChartScale.maximum(for: usage.days.map { value(for: $0) }.max() ?? 0) }
    private var displayedDay: ConsoleCodexUsageDay? { usage.days.first { $0.date == selectedDate } ?? usage.days.last }
    private var total: Int64 { (metric == .calls ? usage.totalCalls : usage.totalTokens) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if usage.countsUserMessages {
                Picker("用量指标", selection: $selectedMetric) {
                    ForEach(Metric.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                }.pickerStyle(.segmented)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("7 天\(metric.rawValue)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(compact(Double(total))).font(.title2.weight(.semibold)).monospacedDigit()
                    .accessibilityLabel("7 天\(metric.rawValue)合计")
                    .accessibilityValue(total.formatted())
            }
            Chart {
                if let selectedDate, usage.days.contains(where: { $0.date == selectedDate }) {
                    RuleMark(x: .value("日期", selectedDate))
                        .foregroundStyle(Color.secondary.opacity(0.2)).accessibilityHidden(true)
                }
                ForEach(usage.days) { day in
                    BarMark(x: .value("日期", day.date), y: .value(metric.rawValue, Double(value(for: day))), width: .ratio(0.55))
                        .cornerRadius(4).foregroundStyle(color)
                        .opacity(selectedDate == nil || selectedDate == day.date ? 1 : 0.35)
                        .accessibilityLabel("\(day.date) \(metric.rawValue)")
                        .accessibilityValue("\(value(for: day).formatted()) \(metric == .calls ? "次" : "Token")")
                }
            }
            .chartYScale(domain: 0...maximum)
            .chartXScale(domain: usage.days.map(\.date))
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0].map { $0 * maximum }) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(compact(number)).font(.caption2) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: usage.days.map(\.date)) { value in
                    AxisValueLabel {
                        if let day = value.as(String.self) { Text(shortDate(day)).font(.caption2) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                            guard let anchor = proxy.plotFrame else { return }
                            let plot = geometry[anchor]
                            guard plot.contains(tap.location) else { return }
                            if let date = proxy.value(atX: tap.location.x - plot.minX, as: String.self),
                               usage.days.contains(where: { $0.date == date }) {
                                selectedDate = date
                            }
                        })
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 180)
            if let day = displayedDay {
                VStack(alignment: .leading, spacing: 9) {
                    Text(day.date + (selectedDate == nil ? " · 最近一天" : " · 已选日期"))
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("调用数", value: usage.countsUserMessages ? "\(day.requestCount.formatted()) 次" : "待更新 Agent")
                    LabeledContent("Token", value: day.totalTokens.formatted())
                }
                .font(.subheadline).monospacedDigit()
                .padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }
            if !usage.countsUserMessages {
                Text("请更新 Agent 后查看用户调用数；旧版模型请求次数不会显示为调用数。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Text("点击图表查看当天完整数字。").font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: usage.days.map(\.date)) { _, dates in
            if let selectedDate, !dates.contains(selectedDate) { self.selectedDate = nil }
        }
    }
    private func value(for day: ConsoleCodexUsageDay) -> Int64 { metric == .calls ? day.requestCount : day.totalTokens }
    private func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    private func shortDate(_ date: String) -> String { String(date.suffix(5)).replacingOccurrences(of: "-", with: "/") }
}
