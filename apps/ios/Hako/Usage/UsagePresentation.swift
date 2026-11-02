import Foundation

struct UsageDayValue: Equatable {
    let day: String
    let seconds: Double
    var year: Int { Int(day.prefix(4)) ?? 0 }
    var month: Int { Int(day.dropFirst(5).prefix(2)) ?? 0 }
}

enum UsageChartMetric: String, CaseIterable {
    case total, average, cumulative
    var title: String {
        switch self {
        case .total: "每月使用时长"
        case .average: "每月日均时长"
        case .cumulative: "累计使用时长"
        }
    }
}

struct UsageMonthValue: Identifiable, Equatable {
    let month: Int
    let hours: Double
    var id: Int { month }
    var period: String { "\(month)月" }
}

enum UsageStatistics {
    static func months(_ values: [UsageDayValue], year: Int, metric: UsageChartMetric) -> [UsageMonthValue] {
        let selected = values.filter { $0.year == year }
        var accumulated = 0.0
        return (1...12).map { month in
            let days = selected.filter { $0.month == month }
            let hours = days.reduce(0) { $0 + $1.seconds } / 3600
            accumulated += hours
            let value: Double
            switch metric {
            case .total: value = hours
            case .average: value = days.isEmpty ? 0 : hours / Double(days.count)
            case .cumulative: value = accumulated
            }
            return UsageMonthValue(month: month, hours: value)
        }
    }
}

enum UsageDates {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    static func formatter() -> DateFormatter {
        let value = DateFormatter()
        value.calendar = calendar
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = calendar.timeZone
        value.dateFormat = "yyyy-MM-dd"
        value.isLenient = false
        return value
    }
    static func date(_ day: String) -> Date? {
        let format = formatter()
        guard let date = format.date(from: day), format.string(from: date) == day else { return nil }
        return date
    }
    static func key(_ components: DateComponents) -> String? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        return date(key) == nil ? nil : key
    }
    static func canSelect(_ components: DateComponents, available: Set<String>) -> Bool {
        key(components).map(available.contains) ?? false
    }
    static func title(_ day: String) -> String {
        guard let date = date(day) else { return day }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!) 年 \(parts.month!) 月 \(parts.day!) 日"
    }
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return "\(minutes / 60)小时 \(minutes % 60)分"
    }
}
