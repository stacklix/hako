import SwiftUI
import UIKit

// Visual tokens from the approved sports prototype, local to this child app.
enum SportsStyle {
    static let background = adaptive(0xf5f5f7, 0x151517)
    static let card = adaptive(0xffffff, 0x242427)
    static let text = adaptive(0x202124, 0xf2f2f4)
    static let muted = adaptive(0x76777d, 0xaaaab0)
    static let line = adaptive(0xe9e9ee, 0x38383c)
    static let orderedTypes = ["Swimming", "Biking", "Walking", "Hiking"]

    static func color(_ type: String) -> Color {
        switch type {
        case "Swimming": adaptive(0x478d80, 0x78b8aa)
        case "Biking": adaptive(0x5b88bf, 0x8aaedb)
        case "Walking": adaptive(0xbf9651, 0xd3b27b)
        case "Hiking": adaptive(0x9472b1, 0xbfa0d8)
        default: muted
        }
    }
    static func symbol(_ type: String) -> String {
        switch type {
        case "Swimming": "water.waves"
        case "Biking": "bicycle"
        case "Hiking": "mountain.2"
        default: "figure.walk"
        }
    }
    static func types(in records: [SportsRecord]) -> [String] {
        let present = Set(records.map(\.type))
        return orderedTypes.filter(present.contains) + present.subtracting(orderedTypes).sorted()
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
    func sportsPanel(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(SportsStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SportsMetricValue: View {
    let title: String
    let value: String
    let unit: String
    @ScaledMetric(relativeTo: .title3) private var numberSize = 22.0
    @ScaledMetric(relativeTo: .caption2) private var labelSize = 11.0

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: labelSize)).foregroundStyle(SportsStyle.muted)
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
        Text(value).font(.system(size: numberSize, weight: .semibold)).monospacedDigit()
            .foregroundStyle(SportsStyle.text).fixedSize()
    }
    private var unitLabel: some View {
        Text(unit).font(.system(size: labelSize)).foregroundStyle(SportsStyle.muted).fixedSize()
    }
}
