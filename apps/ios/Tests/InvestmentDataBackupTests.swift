import Foundation

// Exercise the investment export path without server or destination access.
enum InvestmentBackup {}
@MainActor final class InvestmentStore {
    static let shared = InvestmentStore()
    var exports = 0
    func exportLedger() async throws -> Data { exports += 1; return Data("ledger".utf8) }
}
@MainActor enum AppServices {
    static let service = BackupService()
    static func dataBackup() -> any HakoDataBackupAccess { service }
}
@MainActor final class BackupService: HakoDataBackupAccess {
    var calls = 0
    var failure = false
    func backup(data: Data, applicationID: String, file: HakoBackupFile, mimeType: String, at date: Date) async throws -> HakoBackupReport {
        calls += 1
        precondition(data == Data("ledger".utf8) && applicationID == "investment" && mimeType == "application/zip")
        if failure { throw HakoBackupError(message: "upload failed") }
        return HakoBackupReport(completedAt: date, byteCount: data.count, expectedCount: 1,
            destinations: [.init(id: UUID(), name: "test", path: "ledger.zip", failure: nil)])
    }
    func latestReport(applicationID: String) -> HakoBackupReport? { nil }
}

@main struct InvestmentDataBackupTests {
    @MainActor static func main() async throws {
        let formatter = ISO8601DateFormatter()
        let saturday = formatter.date(from: "2026-11-21T10:00:00Z")!
        let sunday = formatter.date(from: "2026-11-21T16:00:00Z")!
        do {
            _ = try await InvestmentBackup.backupData(at: saturday)
            preconditionFailure("Scheduled backup ran on Saturday")
        } catch is HakoShortcutSkip {}
        precondition(InvestmentStore.shared.exports == 0 && AppServices.service.calls == 0)
        do {
            _ = try await HakoShortcutExecution.manual.withValue(true) {
                try await InvestmentBackup.backupData(at: saturday)
            }
            preconditionFailure("An in-app sync or retry bypassed the schedule without an explicit override")
        } catch is HakoShortcutSkip {}
        precondition(InvestmentStore.shared.exports == 0 && AppServices.service.calls == 0)
        _ = try await HakoShortcutExecution.manual.withValue(true) {
            try await HakoShortcutExecution.scheduleOverride.withValue(true) {
                try await InvestmentBackup.backupData(at: saturday)
            }
        }
        precondition(InvestmentStore.shared.exports == 1 && AppServices.service.calls == 1)
        precondition(!HakoShortcutExecution.isManual && !HakoShortcutExecution.ignoresSchedule)
        do {
            _ = try await HakoShortcutExecution.scheduleOverride.withValue(true) {
                try await InvestmentBackup.backupData(at: saturday)
            }
            preconditionFailure("An external shortcut used an override without a manual trigger")
        } catch is HakoShortcutSkip {}
        do {
            _ = try await InvestmentBackup.backupData(at: saturday)
            preconditionFailure("Manual execution bypass leaked into scheduled backup")
        } catch is HakoShortcutSkip {}
        _ = try await InvestmentBackup.backupData(at: sunday)
        precondition(InvestmentStore.shared.exports == 2 && AppServices.service.calls == 2)
        AppServices.service.failure = true
        do {
            _ = try await HakoShortcutExecution.manual.withValue(true) {
                try await HakoShortcutExecution.scheduleOverride.withValue(true) {
                    try await InvestmentBackup.backupData(at: saturday)
                }
            }
            preconditionFailure("Manual backup ignored upload failure")
        } catch let error as HakoBackupError { precondition(error.message == "upload failed") }
        precondition(!HakoShortcutExecution.isManual && !HakoShortcutExecution.ignoresSchedule && AppServices.service.calls == 3)
        print("PASS: weekday sync/retry skips without export, explicit single manual backup, Sunday execution, failure propagation and scoped override")
    }
}
