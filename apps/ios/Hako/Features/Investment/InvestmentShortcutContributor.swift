enum InvestmentShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register("更新投资账本") {
            let store = InvestmentStore.shared
            while store.loading || store.saving || store.refreshing {
                try await Task.sleep(for: .milliseconds(150))
            }
            await store.load(force: true)
            try Task.checkCancellation()
            if let error = store.loadError { throw InvestmentError.invalid(error) }
            guard store.hasLoaded else { throw InvestmentError.invalid("请先读取服务端投资账本。") }
            let priorRuns = store.book.planRuns
            do {
                try await store.refreshAndSettlePlans()
                let plans = store.book.planReport(since: priorRuns)
                let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
                guard let earliest = store.book.earliest, earliest <= end else {
                    return plans.message + "\n暂无已结束的记账日。"
                }
                try await store.refreshSnapshotHistory(fullHistory: false)
                let report = try await store.saveDailySnapshots()
                guard report.includesDay else {
                    throw InvestmentError.invalid(InvestmentText.date(report.day) + " 缺少完整的估值数据。" + report.message)
                }
                return plans.message + "\n" + InvestmentText.date(report.day) + " 的日终快照已保存。" + report.message + "\n" + report.totals
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let plans = store.book.planReport(since: priorRuns)
                throw InvestmentError.invalid((plans.hasResults ? plans.message + "\n" : "") + error.localizedDescription)
            }
        }
    }
}
