import Foundation
import SwiftData
import AppIntents

@MainActor final class Recorder {
    static let shared = Recorder()
    private let syncDirectory = "screen-time"
    private var busy = false
    func run(collect: Bool, requestAuthorization: Bool = false) async throws -> String {
        guard !busy else { throw HakoError(message: "另一个记录或同步任务正在运行，请稍后重试。") }
        busy = true; defer { busy = false }
        let context = try Database.context()
        var backfill = UsageBackfill.Result()
        if collect {
            if requestAuthorization { try await ScreenTime.authorizeIfNeeded() }
            try ScreenTime.checkAuthorization()
            backfill = try await UsageBackfill.insertMissing(days: UsageDay.recentWeek(), context: context) {
                try await ScreenTime.collect($0)
            }
        }
        let all = try context.fetch(FetchDescriptor<DailyUsage>(sortBy: [SortDescriptor(\DailyUsage.day)]))
        guard !all.isEmpty else {
            throw HakoError(message: backfill.failures.isEmpty ? "还没有本地记录，请先补齐最近7天。" : backfill.failures.joined(separator: "\n"))
        }
        let client = GitHubClient(settings: .load(), token: try TokenStore.read())
        let grouped = Dictionary(grouping: all) { String($0.day.prefix(4)) }
        for year in grouped.keys.sorted() {
            let records = grouped[year]!
            let rows = records.map { record in
                var row = [record.day, record.timeZone, String(Int(record.totalSeconds.rounded()))]
                for index in 0..<5 {
                    if index < record.apps.count {
                        let app = record.apps[index]
                        row += [app.bundleID, String(Int(app.seconds.rounded()))]
                    } else { row += ["", ""] }
                }
                return row
            }
            try await client.push(directory: syncDirectory, year: year, rows: rows)
            for record in records { record.syncedAt = .now }
            try context.save()
        }
        if !backfill.failures.isEmpty {
            throw HakoError(message: "已新增 \(backfill.inserted) 天，跳过已有 \(backfill.skipped) 天，并同步可用记录。以下日期未能读取，下次会重试：\n" + backfill.failures.joined(separator: "\n"))
        }
        return collect ? "最近7天已检查（不含今天）：新增 \(backfill.inserted) 天，已有 \(backfill.skipped) 天。GitHub 已补齐缺失日期，已有行保持不变。" : "GitHub 已补齐本地记录中的缺失日期，已有行保持不变。"
    }
}

struct RecordRecentWeekIntent: AppIntent {
    static var title: LocalizedStringResource = "获取app使用时间并同步"
    static var description = IntentDescription("读取最近7个完整自然日（不含今天）的使用时间和 Top 5 App。本地和 GitHub 均仅插入缺失日期，保留已有记录。请先在 Hako 完成授权与 GitHub 设置。")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await Recorder.shared.run(collect: true)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
struct HakoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordRecentWeekIntent(), phrases: ["用\(.applicationName)获取应用使用时间并同步"], shortTitle: "获取app使用时间并同步", systemImageName: "clock")
    }
}
