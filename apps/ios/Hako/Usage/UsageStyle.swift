import SwiftUI
import UIKit

// Child-owned tokens; this application does not depend on another child's UI.
enum UsageStyle {
    static let background = adaptive(0xf5f5f7, 0x151517)
    static let card = adaptive(0xffffff, 0x242427)
    static let text = adaptive(0x202124, 0xf2f2f4)
    static let muted = adaptive(0x76777d, 0xaaaab0)
    static let line = adaptive(0xe9e9ee, 0x38383c)
    static let series = adaptive(0x478d80, 0x78b8aa)
    static func color(_ series: UsageDailySeries) -> Color {
        switch series {
        case .daily, .week: self.series
        case .month: adaptive(0x5b88bf, 0x8aaedb)
        case .quarter: adaptive(0xbf9651, 0xd3b27b)
        case .halfYear: adaptive(0x9472b1, 0xbfa0d8)
        }
    }
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func usagePanel(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(UsageStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct UsageMetricValue: View {
    let title: String
    let value: String
    let unit: String
    @ScaledMetric(relativeTo: .title3) private var numberSize = 22.0
    @ScaledMetric(relativeTo: .caption2) private var labelSize = 11.0
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: labelSize)).foregroundStyle(UsageStyle.muted)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 2) { number; unitLabel }
                VStack(spacing: 2) { number; unitLabel }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value) \(unit)")
    }
    private var number: some View {
        Text(value).font(.system(size: numberSize, weight: .semibold)).monospacedDigit().fixedSize()
    }
    private var unitLabel: some View {
        Text(unit).font(.system(size: labelSize)).foregroundStyle(UsageStyle.muted).fixedSize()
    }
}
