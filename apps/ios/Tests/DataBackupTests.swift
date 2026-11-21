import Foundation

@main struct DataBackupTests {
    @MainActor static func main() async throws {
        let formatter = ISO8601DateFormatter()
        for (value, due) in [("2026-11-21T15:59:59Z", false), ("2026-11-21T16:00:00Z", true),
                             ("2026-11-22T15:59:59Z", true), ("2026-11-22T16:00:00Z", false)] {
            precondition(InvestmentBackupSchedule.isDue(at: formatter.date(from: value)!) == due)
        }
        var first = HakoBackupTarget(name: "Drive", googleDriveConnectionID: UUID())
        var second = HakoBackupTarget(name: "NAS", provider: .webDAV, webDAV: .init(serverURL: "https://nas.example/dav/", username: "backup"))
        var disabled = HakoBackupTarget(name: "Disabled", enabled: false)
        let third = HakoBackupTarget(name: "Other Drive", googleDriveConnectionID: UUID())
        var calls: [UUID] = [], reports: [HakoBackupReport] = []
        let date = formatter.date(from: "2026-11-21T16:01:02Z")!
        let plan = HakoBackupFile(subdirectory: "账本", fileName: "backup-{date}-{time}.zip")
        let coordinator = HakoBackupCoordinator(upload: { target, data, app, file, mime, at in
            calls.append(target.id)
            precondition(data == Data("backup".utf8) && app == "investment" && mime == "application/zip" && at == date)
            let rendered = try file.resolved(at: at)
            precondition(rendered.fileName == "backup-2026-11-22-000102000.zip")
            if target.id == first.id { throw HakoBackupError(message: "offline") }
            return target.name + "/" + rendered.fileName
        }, record: { reports.append($0) })
        do {
            _ = try await coordinator.backup(targets: [first, disabled, second, third], data: Data("backup".utf8),
                applicationID: "investment", file: plan, mimeType: "application/zip", at: date)
            preconditionFailure("Partial failure reported success")
        } catch { precondition(error.localizedDescription.contains("offline") && error.localizedDescription.contains("NAS")) }
        precondition(calls == [first.id, second.id, third.id], "Failed destination prevented later destinations")
        precondition(reports.count == 3 && reports.last!.destinations.count == 3 && reports.last!.expectedCount == 3)
        precondition(reports.last!.destinations.filter(\.succeeded).count == 2 && !reports.last!.succeeded)
        let encoded = try JSONEncoder().encode(reports.last!)
        let decoded = try JSONDecoder().decode(HakoBackupReport.self, from: encoded)
        precondition(decoded.destinations.count == 3)
        first.enabled = false; second.enabled = false; disabled.enabled = false
        calls = []
        do {
            _ = try await coordinator.backup(targets: [first, second, disabled], data: Data("backup".utf8),
                applicationID: "investment", file: plan, mimeType: "application/zip", at: date)
            preconditionFailure("Missing targets accepted")
        } catch {}
        precondition(calls.isEmpty)
        let success = HakoBackupCoordinator(upload: { _, _, _, _, _, _ in "ok" }, record: { reports.append($0) })
        let result = try await success.backup(targets: [third], data: Data("backup".utf8), applicationID: "investment", file: plan, mimeType: "application/zip", at: date)
        precondition(result.succeeded)
        print("PASS: Beijing Sunday boundaries, provider-neutral backup contract, multi-target fan-out, partial failure persistence, disabled targets and empty configuration")
    }
}
