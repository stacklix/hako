import Foundation
import SwiftData

@MainActor final class Recorder {
    static let shared = Recorder()
    private let syncDirectory = "screen-time"
    private var busy = false
    func run(collect: Bool, requestAuthorization: Bool = false) async throws -> String {
        let operation = collect ? "采集使用时间并同步" : "合并本地与 GitHub 记录"
        HakoLog.record(.usage, "开始\(operation)")
        do {
            let result = try await execute(collect: collect, requestAuthorization: requestAuthorization)
            HakoLog.record(.usage, "\(operation)完成", detail: result)
            return result
        } catch {
            // Provider error descriptions may contain response data. Record type/code only.
            HakoLog.record(.usage, error is CancellationError ? .info : .error, "\(operation)\(error is CancellationError ? "已取消" : "失败")",
                detail: "错误类型：\(String(reflecting: type(of: error)))\n错误代码：\((error as NSError).code)")
            throw error
        }
    }
    private func execute(collect: Bool, requestAuthorization: Bool) async throws -> String {
        guard !busy else { throw HakoError(message: "另一个记录或同步任务正在运行，请稍后重试。") }
        busy = true; defer { busy = false }
        let context = try UsageDatabase.context()
        var backfill = UsageBackfill.Result()
        if collect {
            try await ScreenTime.prepareAuthorization(requestAuthorization: requestAuthorization)
            backfill = try await UsageBackfill.insertMissing(days: UsageDay.recentWeek(), context: context) {
                try await ScreenTime.collect($0)
            }
        }
        if !collect {
            let client = UsageGitHub(repository: AppServices.gitHub())
            let result = try await UsageSync.merge(context: context, client: client, directory: syncDirectory)
            let summary = "合并完成：共 \(result.days) 天。本地新增 \(result.inserted) 天，GitHub 新增 \(result.githubInserted) 天，本地更新 \(result.updated) 天。"
            return result.days == 0 ? summary + "双方均没有记录，请先获取app使用时间。" : summary
        }
        let all = try context.fetch(FetchDescriptor<DailyUsage>(sortBy: [SortDescriptor(\DailyUsage.day)]))
        guard !all.isEmpty else {
            throw HakoError(message: backfill.failures.isEmpty ? "还没有本地记录，请先补齐最近7天。" : backfill.failures.joined(separator: "\n"))
        }
        let client = UsageGitHub(repository: AppServices.gitHub())
        let grouped = Dictionary(grouping: all) { String($0.day.prefix(4)) }
        for year in grouped.keys.sorted() {
            let records = grouped[year]!
            let rows = records.map(\.csvRow)
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

enum UsageShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register("使用时间") {
            try await Recorder.shared.run(collect: true)
        }
    }
}
