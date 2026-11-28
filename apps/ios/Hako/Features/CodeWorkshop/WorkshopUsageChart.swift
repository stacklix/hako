import SwiftUI
import Charts

struct WorkshopUsageChart: View {
    let usage: WorkshopUsageSnapshot
    @State private var selectedDate: String?
    private let ticks = [0.0, 0.25, 0.5, 0.75, 1.0]
    private var callsMaximum: Double { axisMaximum(for: usage.days.map(\.requestCount).max() ?? 0) }
    private var tokensMaximum: Double { axisMaximum(for: usage.days.map(\.totalTokens).max() ?? 0) }
    private var displayedDay: WorkshopUsageDay? { usage.days.first { $0.date == selectedDate } ?? usage.days.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                legend("请求次数 · 左轴", color: .blue)
                Spacer()
                legend("Token · 右轴", color: .orange)
            }
            Chart {
                if let selectedDate, let day = usage.days.first(where: { $0.date == selectedDate }) {
                    RuleMark(x: .value("日期", selectedDate))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day.date).foregroundStyle(.secondary)
                                if usage.countsUserMessages {
                                    Text("\(day.requestCount.formatted()) 次请求").foregroundStyle(.blue)
                                }
                                Text("\(day.totalTokens.formatted()) token").foregroundStyle(.orange)
                            }
                            .font(.caption).monospacedDigit()
                            .padding(8)
                            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            }
                        }
                        .zIndex(1)
                }
                ForEach(usage.days) { day in
                    if usage.countsUserMessages {
                        BarMark(x: .value("日期", day.date), y: .value("比例", Double(day.requestCount) / callsMaximum), width: .ratio(0.75))
                            .position(by: .value("指标", "请求次数"))
                            .foregroundStyle(.blue)
                            .opacity(selectedDate == nil || selectedDate == day.date ? 1 : 0.4)
                            .accessibilityLabel("\(day.date) 请求次数")
                            .accessibilityValue("\(day.requestCount.formatted()) 次")
                    }
                    BarMark(x: .value("日期", day.date), y: .value("比例", Double(day.totalTokens) / tokensMaximum), width: .ratio(0.75))
                        .position(by: .value("指标", "Token"))
                        .foregroundStyle(.orange)
                        .opacity(selectedDate == nil || selectedDate == day.date ? 1 : 0.4)
                        .accessibilityLabel("\(day.date) Token 用量")
                        .accessibilityValue("\(day.totalTokens.formatted()) token")
                }
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: usage.days.map(\.date))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let fraction = value.as(Double.self), usage.countsUserMessages {
                            Text(compact(fraction * callsMaximum)).foregroundStyle(.blue)
                        }
                    }
                }
                AxisMarks(position: .trailing, values: ticks) { value in
                    AxisValueLabel {
                        if let fraction = value.as(Double.self) {
                            Text(compact(fraction * tokensMaximum)).foregroundStyle(.orange)
                        }
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
            .frame(height: 200)
            if let day = displayedDay {
                VStack(alignment: .leading, spacing: 5) {
                    Text(day.date).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(usage.countsUserMessages ? "\(day.requestCount.formatted()) 次请求" : "请求次数未知").foregroundStyle(.blue)
                            Text("\(day.totalTokens.formatted()) token").foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(usage.countsUserMessages ? "\(day.requestCount.formatted()) 次请求" : "请求次数未知").foregroundStyle(.blue)
                            Text("\(day.totalTokens.formatted()) token").foregroundStyle(.orange)
                        }
                    }
                }.font(.caption).monospacedDigit().accessibilityElement(children: .combine)
            }
            Text("左右轴使用独立刻度。点击柱子查看当天完整数字。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .onChange(of: usage.days.map(\.date)) { _, dates in
            if let selectedDate, !dates.contains(selectedDate) { self.selectedDate = nil }
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func axisMaximum(for value: Int64) -> Double {
        guard value > 0 else { return 4 }
        let rawStep = Double(value) / 4
        let magnitude = pow(10, floor(log10(rawStep)))
        let fraction = rawStep / magnitude
        let factor = [1.0, 2.0, 2.5, 5.0, 10.0].first { $0 >= fraction } ?? 10
        return 4 * max(1, ceil(factor * magnitude))
    }
    private func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    private func shortDate(_ date: String) -> String { String(date.suffix(5)).replacingOccurrences(of: "-", with: "/") }
}
