enum InvestmentShortcutContributor {
    @MainActor static func registerShortcuts(in registry: HakoShortcutRegistry) {
        registry.register("记录每日投资快照") {
            let store = InvestmentStore.shared
            await store.load(force: true)
            if let error = store.loadError { throw InvestmentError.invalid(error) }
            await store.settleDuePlans()
            let end = InvestmentBook.addDays(-1, to: InvestmentBook.day())
            guard let earliest = store.book.earliest, earliest <= end else {
                return "暂无已结束的记账日。"
            }
            try await store.refreshSnapshotHistory(fullHistory: false)
            let report = try await store.saveDailySnapshots()
            guard report.includesDay else {
                throw InvestmentError.invalid(InvestmentText.date(report.day) + " 缺少完整的估值数据。" + report.message)
            }
            return InvestmentText.date(report.day) + " 的日终快照已保存。" + report.message + "\n" + report.totals
        }
    }
}
