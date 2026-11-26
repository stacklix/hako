enum InvestmentShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register(InvestmentBackup.shortcutName, group: "investment", order: 2) {
            try await InvestmentBackup.backupData()
        }
        registry.register("更新投资账本", group: "investment", order: 1) {
            let store = InvestmentStore.shared
            if store.loading || store.saving || store.refreshing {
                try await HakoExecutionDiagnostics.measure("等待当前投资操作结束") {
                    while store.loading || store.saving || store.refreshing {
                        try await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
            try await HakoExecutionDiagnostics.measure("读取服务端投资账本") {
                try await store.loadForSynchronization()
            }
            let priorRuns = store.book.planRuns
            do {
                try await HakoExecutionDiagnostics.measure("补充历史行情与汇率") {
                    try await store.refreshSnapshotHistory(fullHistory: false, includePlans: true, recentDays: 10, includeClosedMarkets: true)
                }
                try await store.settleHistoricalPlans()
                let plans = store.book.planReport(since: priorRuns)
                let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
                guard let earliest = store.book.earliest, earliest <= end else {
                    return plans.message + "\n暂无已结束的记账日。"
                }
                let report = try await HakoExecutionDiagnostics.measure("保存每日账本快照", success: { $0.message + "\n" + $0.totals }) { try await store.saveDailySnapshots() }
                guard report.includesDay else {
                    throw InvestmentError.invalid(InvestmentText.date(report.day) + " 缺少完整的估值数据。" + report.message)
                }
                return plans.message + "\n" + report.message + "\n" + report.totals
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let plans = store.book.planReport(since: priorRuns)
                throw InvestmentError.invalid((plans.hasResults ? plans.message + "\n" : "") + error.localizedDescription)
            }
        }
    }
}
