import SwiftUI

struct ECSUsageGauge: View {
    let title: String
    let percent: Double?
    let color: Color
    let detail: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedPercent: Double = 0

    private var value: String { percent.map { String(format: "%.1f%%", $0) } ?? "—" }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            ZStack {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * displayedPercent / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .opacity(percent == nil ? 0 : 1)
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65).padding(.horizontal, 6)
            }
            .padding(5).aspectRatio(1, contentMode: .fit).frame(maxWidth: 112)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent == nil ? "暂无数据" : value + "，" + detail)
        .onChange(of: percent, initial: true) { _, newValue in
            let target = newValue.map { min(100, max(0, $0)) } ?? 0
            withAnimation(reduceMotion || newValue == nil ? nil : .easeOut(duration: 0.9)) {
                displayedPercent = target
            }
        }
    }
}
