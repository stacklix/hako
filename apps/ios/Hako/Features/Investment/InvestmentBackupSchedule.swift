import Foundation

enum InvestmentBackupSchedule {
    static func isDue(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.component(.weekday, from: date) == 1
    }
}
