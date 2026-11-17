import Foundation

@main
struct InvestmentBookTests {
    static func main() throws {
        try ledgerAndDilutedCost()
        try firstPurchaseRequiresCash()
        try purchasesCanAutomaticallyFundCashShortfalls()
        try tradingFeesAffectCashAndDilutedCost()
        try futuresFeesStaySeparateFromMargin()

        try stockDistributionsKeepPurchaseCost()
        try fundsAndETFsRecordCashDividends()
        try genericBalancesSeparateValuationFromCashFlows()
        try genericBalancesValidateAndReplayHistory()
        try spotBalanceAdjustmentsUseTokenQuantity()
        try plansUseCashInExecutionOrder()
        try planSchedulesRespectCalendarDays()
        try planPeriodsCatchUpOnceAndRoundTrip()
        try currencyConversionRequiresQuote()
        try accountCurrencyRestrictsEntries()
        try stockConnectSettlesInRenminbi()
        try insuranceKeepsOnePolicyPosition()
        try renminbiInsuranceCountsCashValueAndRoundTrips()
        try insuranceWithdrawalsKeepPolicyAndMoveCash()
        try insuranceWithdrawalsAllowMissingValues()
        try typedAccountsFilterAssets()
        try fundWealthAccountsKeepBothKindsAndRoundTrip()
        try transfersMoveCashAsOneOperation()
        try depositsUseRecordedBalancesAndCashMovements()
        try balanceSheetKeepsDatedBalancesAndUsesInvestmentValuation()
        try balanceHistoryFiltersAndReplaysEditedRecords()
        try investmentHistoryRecordsOneFrozenSnapshotPerClosedMonth()
        try balanceTrendUsesEveryDailySnapshotBeforeFirstMonthClose()
        try balanceTrendKeepsMissingDaysAndManualBalances()
        try balanceTrendCarriesSnapshotsFromNovemberFirst()
        try balanceTrendStopsCarryAtNovemberFirst()
        try fundAndWealthHistoryTracksNetInvestment()
        try wealthUsesAmountsAndReportedBalances()
        try manualQuotesAreLimitedToInsurance()
        try holdingHistoryTracksQuantitiesAndAmounts()
        try dailyGainsRequireCompleteMarketPrices()
        try portfolioHistoryMatchesIndividualValuations()
        try dailySnapshotsUseBeijingCloseAndDatedRates()
        try deletedAndRecreatedHoldingsInvalidateSnapshotsWithoutCache()
        try changingHistoricalEntriesInvalidatesOnlyTheAffectedDays()
        try changingTransfersIsAtomic()
        try dailyQuotesReuseCachedMarketCloses()
        try serverRoundTripPreservesShortFuturesAndSnapshots()
        try archivesOnlyEmptyAccountsAndPreservesHistory()
        try deletesOnlyTheSelectedHoldingAndItsRecords()
        try deletesAccountsAndPairedTransfersAtomically()
        try deletesUnreferencedRegistrationsAndTheirQuotes()
        try deletionPreservesPlanReferences()
        print("Investment ledger checks passed")
    }

    static func ledgerAndDilutedCost() throws {
        let account = InvestmentAccount(name: "银河证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(InvestmentAsset(name: "测试", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        let first = date(1), second = date(2), third = date(3)
        try book.post(.init(day: first, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: first, kind: .opening, assetID: asset, quantity: 10, price: 10), accountID: account.id)
        try book.post(.init(day: second, kind: .buy, assetID: asset, quantity: 10, price: 20), accountID: account.id)
        try book.post(.init(day: third, kind: .sell, assetID: asset, quantity: 5, price: 24), accountID: account.id)
        try book.post(.init(day: third, kind: .adjustment, amount: 5), accountID: account.id)
        book.addQuotes([.init(day: third, price: 25)], assetID: asset)
        let recorded = book.accounts[0]
        let ledger = try book.ledger(recorded, through: third, includeRows: true)
        let position = try require(ledger.positions[asset])
        precondition(ledger.cash == 925 && ledger.flows == 1100 && ledger.cashIncome == 5)
        precondition(position.quantity == 15 && position.netCost == 180 && position.lastEntry == 20)
        precondition(ledger.cashRows.map(\.change) == [1000, -200, 120, 5])
        precondition(book.value(recorded, on: third)?.gain == 200)
        do {
            try book.post(.init(day: second, kind: .withdrawal, amount: -850), accountID: account.id)
            preconditionFailure("A backdated overdraft must be rejected")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.count == 5)
    }

    static func firstPurchaseRequiresCash() throws {
        let account = InvestmentAccount(name: "证券账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        let day = date(1)
        let purchase = InvestmentEvent(day: day, kind: .buy, assetID: id, quantity: 10, price: 10)
        do {
            try book.post(purchase, accountID: account.id)
            preconditionFailure("A first purchase must have enough cash")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.isEmpty)
        try book.post(.init(day: day, kind: .deposit, amount: 130), accountID: account.id)
        try book.post(purchase, accountID: account.id)
        let ledger = try book.ledger(book.accounts[0], through: day, includeRows: true)
        precondition(ledger.cash == 30 && ledger.flows == 130 && ledger.cashRows.map(\.change) == [130, -100])
        precondition(ledger.positions[id]?.netCost == 100 && ledger.positions[id]?.lastEntry == 10)
    }

    static func purchasesCanAutomaticallyFundCashShortfalls() throws {
        let account = InvestmentAccount(name: "证券账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "600000", market: "", kind: .stock, currency: .cny))
        let day = date(1)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 10, price: 10, fee: 5),
                      accountID: account.id, autoFundCash: true)
        try book.post(.init(day: day, kind: .deposit, amount: 30), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 4, price: 10, fee: 5),
                      accountID: account.id, autoFundCash: true)
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 4, price: 10, fee: 5),
                      accountID: account.id, autoFundCash: true)
        let ledger = try book.ledger(book.accounts[0], through: day, includeRows: true)
        precondition(ledger.cashRows.map(\.change) == [105, -105, 30, 15, -45, 100, -45])
        precondition(ledger.cash == 55 && ledger.flows == 250 && ledger.positions[id]?.netCost == 195)

        try book.post(.init(day: date(2), kind: .withdrawal, amount: -55), accountID: account.id)
        let previousEvents = book.accounts[0].events.map(\.id)
        do {
            try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 6, price: 10),
                          accountID: account.id, autoFundCash: true)
            preconditionFailure("A purchase and its top-up must both roll back if a later event would overdraw")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.map(\.id) == previousEvents)
    }

    static func tradingFeesAffectCashAndDilutedCost() throws {
        let account = InvestmentAccount(name: "证券账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "600000", market: "", kind: .stock, currency: .cny))
        let day = date(1)
        let buy = InvestmentEvent(day: day, kind: .buy, assetID: id, quantity: 100, price: 10, fee: 5)
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        do {
            try book.post(buy, accountID: account.id)
            preconditionFailure("The purchase must also cover its fee")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.count == 1)
        try book.post(.init(day: day, kind: .deposit, amount: 5), accountID: account.id)
        try book.post(buy, accountID: account.id)
        let purchased = try book.ledger(book.accounts[0], through: day)
        precondition(purchased.cash == 0 && purchased.positions[id]?.netCost == 1005)

        try book.post(.init(day: date(2), kind: .sell, assetID: id, quantity: 40, price: 12, fee: 3), accountID: account.id)
        let partial = try book.ledger(book.accounts[0], through: date(2))
        precondition(partial.cash == 477 && partial.positions[id]?.netCost == 528)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 60, price: 12, fee: 3), accountID: account.id)
        let restored = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))
        let sold = try restored.ledger(restored.accounts[0], through: date(3), includeRows: true)
        precondition(sold.cashRows.map(\.change) == [1000, 5, -1005, 477, 717])
        precondition(sold.positions[id]?.realized == 189 && restored.portfolio(on: date(3))?.gain == 189)
    }

    static func futuresFeesStaySeparateFromMargin() throws {
        let account = InvestmentAccount(name: "期货账户", currency: .cny, type: .futures)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试合约", code: "CU1811.SHF", market: "", kind: .future, currency: .cny, multiplier: 10))
        let day = date(1)
        try book.post(.init(day: day, kind: .deposit, amount: 200), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 1, price: 100, margin: 100, fee: 5), accountID: account.id)
        let opened = try book.ledger(book.accounts[0], through: day)
        precondition(opened.cash == 95 && opened.positions[id]?.margin == 100 && opened.positions[id]?.netCost == 105)
        try book.post(.init(day: date(2), kind: .sell, assetID: id, quantity: 1, price: 105, fee: 6), accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: date(2))
        precondition(closed.cash == 239 && closed.positions[id]?.realized == 39)
    }















    static func stockDistributionsKeepPurchaseCost() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let stock = try book.register(.init(name: "股票", code: "600000", market: "", kind: .stock, currency: .cny))
        let purchase = date(1), distribution = date(2)
        try book.post(.init(day: purchase, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: purchase, kind: .buy, assetID: stock, quantity: 10, price: 10), accountID: account.id)
        do {
            try book.recordDistribution(assetID: stock, accountID: account.id, cash: 10, shares: Decimal(string: "0.5")!,
                                        on: distribution)
            preconditionFailure("Invalid bonus shares must also reject the cash entry")
        } catch InvestmentError.invalid {}
        precondition(book.accounts[0].events.count == 2)
        try book.recordDistribution(assetID: stock, accountID: account.id, cash: 10, shares: 2, on: distribution)
        book.addQuotes([.init(day: distribution, price: Decimal(string: "9.5")!)], assetID: stock)
        let ledger = try book.ledger(book.accounts[0], through: distribution, includeRows: true)
        precondition(ledger.cash == 10 && ledger.flows == 100 && ledger.cashRows.map(\.change) == [100, -100, 10])
        precondition(ledger.positions[stock]?.quantity == 12 && ledger.positions[stock]?.netCost == 100)
        precondition(ledger.positions[stock]?.realized == 10 && book.value(book.accounts[0], on: distribution)?.gain == 24)
    }

    static func fundsAndETFsRecordCashDividends() throws {
        let cases: [(InvestmentAccount, InvestmentAsset)] = [
            (.init(name: "基金账户", currency: .cny, type: .fundWealth),
             .init(name: "测试基金", code: "110022.OF", market: "", kind: .fund, currency: .cny)),
            (.init(name: "美元证券账户", currency: .usd, type: .securities),
             .init(name: "QQQ", code: "QQQ", market: "", kind: .etf, currency: .usd)),
        ]
        for (account, asset) in cases {
            var book = InvestmentBook(accounts: [account])
            let assetID = try book.register(asset)
            let purchase = date(1), distribution = date(2)
            try book.post(.init(day: purchase, kind: .deposit, amount: 100), accountID: account.id)
            try book.post(.init(day: purchase, kind: .buy, assetID: assetID, quantity: 10, price: 5), accountID: account.id)
            try book.recordDistribution(assetID: assetID, accountID: account.id, cash: 8, on: distribution)
            do {
                try book.recordDistribution(assetID: assetID, accountID: account.id, cash: 8, shares: 1, on: distribution)
                preconditionFailure("An unsupported distribution must not post its cash portion")
            } catch InvestmentError.invalid {}
            let ledger = try book.ledger(book.accounts[0], through: distribution, includeRows: true)
            precondition(ledger.cash == 58 && ledger.flows == 100)
            precondition(ledger.positions[assetID]?.quantity == 10 && ledger.positions[assetID]?.netCost == 50)
            precondition(ledger.positions[assetID]?.realized == 8)
            precondition(ledger.cashRows.last?.event.kind == .dividend && ledger.cashRows.last?.event.assetID == assetID)
        }
    }

    static func spotBalanceAdjustmentsUseTokenQuantity() throws {
        let account = InvestmentAccount(name: "加密货币", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let token = try book.register(.init(name: "Ether", code: "ETH", market: "", kind: .crypto, currency: .usd))
        let purchase = date(1), reward = date(2)
        try book.post(.init(day: purchase, kind: .deposit, amount: 2000), accountID: account.id)
        try book.post(.init(day: purchase, kind: .buy, assetID: token, quantity: 1, price: 2000), accountID: account.id)
        let total = Decimal(string: "1.01")!
        try book.adjustSpotBalance(assetID: token, accountID: account.id, balance: total, on: reward)
        let ledger = try book.ledger(book.accounts[0], through: reward, includeRows: true)
        precondition(ledger.positions[token]?.quantity == total && ledger.positions[token]?.netCost == 2000)
        precondition(ledger.cash == 0 && ledger.cashRows.count == 2 && book.accounts[0].events.last?.kind == .stakingReward)
        try book.adjustSpotBalance(assetID: token, accountID: account.id, balance: 1, on: reward)
        let corrected = try book.ledger(book.accounts[0], through: reward)
        precondition(corrected.positions[token]?.quantity == 1 && corrected.positions[token]?.netCost == 2000)
        precondition(book.accounts[0].events.last?.kind == .spotAdjustment)
    }

    static func plansUseCashInExecutionOrder() throws {
        let account = InvestmentAccount(name: "定投账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(InvestmentAsset(name: "测试ETF", code: "510300", market: "XSHG", kind: .etf, currency: .cny))
        let first = date(1), second = date(2), third = date(3)
        book.plans = [
            InvestmentPlan(accountID: account.id, assetID: asset, amount: 100, schedule: try .init(frequency: .monthly, day: 1), nextDay: first),
            InvestmentPlan(accountID: account.id, amount: 105, schedule: try .init(frequency: .monthly, day: 2), nextDay: second)
        ]
        book.runPlans(through: first)
        precondition(book.plans[0].nextDay == first && book.accounts[0].events.isEmpty)
        let priorRuns = book.planRuns
        book.addQuotes([.init(day: third, price: 6)], assetID: asset)
        book.runPlans(through: third)
        book.runPlans(through: third)
        let ledger = try book.ledger(book.accounts[0], through: third)
        precondition(ledger.cash == 9 && ledger.positions[asset]?.quantity == 16)
        precondition(book.accounts[0].events.map(\.kind) == [.deposit, .buy])
        precondition(book.plans.allSatisfy { $0.nextDay > third })
        let report = book.planReport(since: priorRuns)
        precondition(report.executed == 2 && report.skipped == 0 && report.waiting == 0)
    }

    static func planSchedulesRespectCalendarDays() throws {
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            InvestmentBook.calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let daily = try InvestmentPlanSchedule(frequency: .daily, day: 0)
        precondition(daily.first(after: date(2026, 11, 1)) == date(2026, 11, 2))
        precondition(daily.next(after: date(2026, 12, 31)) == date(2027, 1, 1))
        let weekly = try InvestmentPlanSchedule(frequency: .weekly, day: 1)
        precondition(weekly.first(after: date(2026, 11, 1)) == date(2026, 11, 2))
        precondition(weekly.next(after: date(2026, 11, 2)) == date(2026, 11, 9))
        precondition(weekly.summary == "每周一")
        let biweekly = try InvestmentPlanSchedule(frequency: .biweekly, day: 1)
        precondition(biweekly.first(after: date(2026, 11, 1)) == date(2026, 11, 2))
        precondition(biweekly.next(after: date(2026, 11, 2)) == date(2026, 11, 16))
        precondition(biweekly.next(after: date(2026, 11, 16)) == date(2026, 11, 30))
        let monthly = try InvestmentPlanSchedule(frequency: .monthly, day: 31)
        precondition(monthly.next(after: date(2026, 1, 31)) == date(2026, 2, 28))
        precondition(monthly.next(after: date(2026, 2, 28)) == date(2026, 3, 31))
        precondition(monthly.first(after: date(2028, 2, 1)) == date(2028, 2, 29))
        let restored = try JSONDecoder().decode(InvestmentPlanSchedule.self, from: JSONEncoder().encode(monthly))
        precondition(restored == monthly)
        let invalidSchedules: [(InvestmentPlanFrequency, Int)] = [
            (.daily, 1), (.weekly, 0), (.weekly, 8), (.biweekly, 0), (.biweekly, 8), (.monthly, 0), (.monthly, 32)
        ]
        for (frequency, day) in invalidSchedules {
            do { _ = try InvestmentPlanSchedule(frequency: frequency, day: day); preconditionFailure("invalid plan schedule") }
            catch is InvestmentError { }
        }
    }

    static func planPeriodsCatchUpOnceAndRoundTrip() throws {
        let monday = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let account = InvestmentAccount(name: "周期测试", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let daily = InvestmentPlan(accountID: account.id, amount: 10, schedule: try .init(frequency: .daily, day: 0), nextDay: monday)
        let weekly = InvestmentPlan(accountID: account.id, amount: 100, schedule: try .init(frequency: .weekly, day: 1), nextDay: monday)
        let biweekly = InvestmentPlan(accountID: account.id, amount: 1000, schedule: try .init(frequency: .biweekly, day: 1), nextDay: monday)
        let monthly = InvestmentPlan(accountID: account.id, amount: 10000, schedule: try .init(frequency: .monthly, day: 2), nextDay: monday)
        book.plans = [daily, weekly, biweekly, monthly]
        precondition(!book.runPlans(through: InvestmentBook.addDays(-1, to: monday)))
        let through = InvestmentBook.addDays(21, to: monday)
        precondition(book.runPlans(through: through))
        precondition(book.planRuns.filter { $0.planID == daily.id }.count == 22)
        precondition(book.planRuns.filter { $0.planID == weekly.id }.map(\.day) == [0, 7, 14, 21].map { InvestmentBook.addDays($0, to: monday) })
        precondition(book.planRuns.filter { $0.planID == biweekly.id }.map(\.day) == [0, 14].map { InvestmentBook.addDays($0, to: monday) })
        let ledger = try book.ledger(book.accounts[0], through: through)
        precondition(ledger.cash == 12620)
        let report = book.planReport(since: [])
        precondition(report.executed == 29 && report.skipped == 0 && report.waiting == 0)
        let previousRuns = book.planRuns
        precondition(!book.runPlans(through: through))
        book.plans[0].nextDay = monday
        precondition(book.runPlans(through: through))
        precondition(book.accounts[0].events.count == 29 && book.planRuns.count == 29)
        precondition(!book.planReport(since: previousRuns).hasResults)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(restored.plans == book.plans && restored.planRuns.count == book.planRuns.count)
        precondition(tables["investment_plans"]?.allSatisfy { $0["month_day"] == nil && $0["frequency"] != nil } == true)

        var waiting = InvestmentBook(accounts: [account])
        let asset = try waiting.register(.init(name: "报价等待", code: "510300", market: "XSHG", kind: .etf, currency: .cny))
        waiting.plans = [.init(accountID: account.id, assetID: asset, amount: 100,
                              schedule: try .init(frequency: .daily, day: 0), nextDay: monday)]
        precondition(waiting.runPlans(through: monday))
        precondition(!waiting.runPlans(through: monday))
        precondition(waiting.planRuns.first?.status == "waiting")
        let firstRuns = waiting.planRuns
        let waitingReport = waiting.planReport(since: firstRuns)
        precondition(waitingReport.executed == 0 && waitingReport.skipped == 0 && waitingReport.waiting == 1)
        precondition(waiting.runPlans(through: InvestmentBook.addDays(1, to: monday)))
        precondition(waiting.planRuns.map(\.status) == ["skipped", "waiting"] && waiting.accounts[0].events.isEmpty)
        let skippedReport = waiting.planReport(since: firstRuns)
        precondition(skippedReport.executed == 0 && skippedReport.skipped == 1 && skippedReport.waiting == 1)
        waiting.plans[0].enabled = false
        precondition(!waiting.planReport(since: waiting.planRuns).hasResults)
    }

    static func balanceSheetKeepsDatedBalancesAndUsesInvestmentValuation() throws {
        let account = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        let first = date(1), second = date(2), third = date(3)
        var book = InvestmentBook(accounts: [account])
        let oldLedger = try JSONEncoder().encode(book)
        book = try JSONDecoder().decode(InvestmentBook.self, from: oldLedger)
        precondition(book.balanceSheet == nil)
        try book.post(.init(day: second, kind: .deposit, amount: 100), accountID: account.id)
        book.fx[.usd] = [.init(day: third, price: 7)]

        var sheet = InvestmentBalanceLedger()
        try sheet.add("存款", category: .cash, amount: 300, at: first)
        try sheet.add("房贷", category: .liabilities, amount: 500, at: first)
        try sheet.update(sheet.accounts[1].id, amount: 450, at: second)
        try sheet.update(sheet.accounts[1].id, amount: 450, at: third)
        try sheet.update(sheet.accounts[1].id, amount: 0, at: third.addingTimeInterval(60))
        book.balanceSheet = sheet
        book = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))

        let before = book.balanceSnapshot(on: first, today: first)
        precondition(before.assets == 300 && before.liabilities == 500 && before.net == -200)
        let missing = book.balanceSnapshot(on: second, today: second)
        precondition(missing.assets == nil && missing.liabilities == 450 && missing.net == nil)
        let after = book.balanceSnapshot(on: third, today: third)
        precondition(after.investment == book.portfolio(on: third)?.value && after.assets == 1000)
        precondition(after.liabilities == 0 && after.net == 1000)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let confirmed = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: tables))
        let liability = confirmed.balanceSheet?.accounts.first { $0.category == .liabilities }
        precondition(liability?.latest(on: first)?.amount == 500)
        precondition(liability?.latest(on: InvestmentBook.addDays(-1, to: first)) == nil)
        let changes = book.balanceChanges(through: third, limit: 5)
        precondition(changes.count == 4 && changes.first?.before == 450 && changes.first?.after == 0)
        precondition(changes[1].before == 500 && changes[1].after == 450)
        precondition(changes.allSatisfy { $0.category != .investments })
        let deficit = InvestmentBalanceSnapshot(day: third, manual: [.cash: 300, .liabilities: 500],
                                                investment: -50, updatedAt: nil)
        precondition(deficit.assets == 300 && deficit.liabilities == 550 && deficit.net == -250)
    }

    static func balanceHistoryFiltersAndReplaysEditedRecords() throws {
        let first = date(1), second = date(2), third = date(3), end = date(31)
        var ledger = InvestmentBalanceLedger(investmentMonthEnds: [end: 800])
        try ledger.add("储蓄卡", category: .cash, amount: 100, at: first)
        try ledger.add("储蓄卡", category: .receivables, amount: 700, at: third)
        let accountID = ledger.accounts[0].id
        try ledger.update(accountID, amount: 120, at: second)
        try ledger.update(accountID, amount: 180, at: third.addingTimeInterval(3600))
        var book = InvestmentBook()
        book.balanceSheet = ledger

        let recent = book.balanceChanges(through: end, limit: 1, filter: .account(accountID))
        precondition(recent.count == 1 && recent[0].after == 180)
        let months = book.balanceChanges(through: end, limit: 10, filter: .investment)
        precondition(months.count == 1 && months[0].manualRecord == nil)
        let original = recent[0].manualRecord!.record
        try ledger.replaceRecord(original, accountID: accountID, amount: 150, on: first, now: end)
        do {
            try ledger.deleteRecord(original, accountID: accountID)
            preconditionFailure("An older editor must not delete the changed record")
        } catch InvestmentError.invalid {}
        book.balanceSheet = ledger
        let changes = book.balanceChanges(through: end, limit: 10, filter: .account(accountID))
        precondition(changes.map(\.after) == [120, 150, 100] && changes[0].before == 150)
        precondition(changes[1].manualRecord?.record.id == original.id && changes[1].day == first)
        precondition(book.balanceSnapshot(on: first).manual[.cash] == 150)

        try ledger.deleteRecord(changes[0].manualRecord!.record, accountID: accountID)
        book.balanceSheet = ledger
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let saved = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: tables))
        precondition(saved.balanceSnapshot(on: second).manual[.cash] == 150)
        let remaining = saved.balanceChanges(through: end, limit: 10, filter: .account(accountID))
        precondition(remaining.map(\.after) == [150, 100])
        for change in remaining { try ledger.deleteRecord(change.manualRecord!.record, accountID: accountID) }
        precondition(ledger.accounts[0].id == accountID && ledger.accounts[0].records.isEmpty)
    }

    static func investmentHistoryRecordsOneFrozenSnapshotPerClosedMonth() throws {
        let local = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        let foreign = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [local, foreign])
        let first = date(1), octoberEnd = date(31)
        let novemberStart = InvestmentBook.addDays(1, to: octoberEnd)
        let novemberEnd = InvestmentBook.addDays(29, to: novemberStart)
        let decemberStart = InvestmentBook.addDays(1, to: novemberEnd)
        try book.post(.init(day: first, kind: .deposit, amount: 300), accountID: local.id)
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: foreign.id)
        try book.post(.init(day: date(15), kind: .deposit, amount: 20), accountID: foreign.id)
        precondition(!book.recordCompletedInvestmentMonths(before: octoberEnd))
        precondition(!book.recordCompletedInvestmentMonths(before: novemberStart))
        precondition(book.balanceSnapshot(on: octoberEnd, today: novemberStart).investment == nil)

        book.fx[.usd] = [.init(day: octoberEnd, price: 7)]
        precondition(book.recordCompletedInvestmentMonths(before: novemberStart))
        let saved = try JSONEncoder().encode(book)
        book = try JSONDecoder().decode(InvestmentBook.self, from: saved)
        book.fx[.usd] = [.init(day: octoberEnd, price: 8)]
        precondition(!book.recordCompletedInvestmentMonths(before: novemberEnd))
        precondition(book.balanceSnapshot(on: octoberEnd, today: novemberStart).investment == 1140)
        precondition(book.balanceSnapshot(on: novemberStart, today: novemberStart).investment == 1260)
        precondition(book.balanceSnapshot(on: novemberStart, today: novemberEnd).investment == 1140)

        precondition(book.recordCompletedInvestmentMonths(before: decemberStart))
        precondition(!book.recordCompletedInvestmentMonths(before: decemberStart))
        let snapshots = book.balanceChanges(through: decemberStart, limit: 5)
        precondition(snapshots.map(\.day) == [novemberEnd, octoberEnd])
        precondition(snapshots.map(\.after) == [1260, 1140] && snapshots.first?.before == 1140)
        precondition(snapshots.allSatisfy { $0.name == "投资理财" && $0.category == .investments })
        precondition(book.balanceDates(from: first, through: decemberStart) == [first, octoberEnd, novemberEnd, decemberStart])
    }

    static func balanceTrendUsesEveryDailySnapshotBeforeFirstMonthClose() throws {
        let account = InvestmentAccount(name: "趋势测试", currency: .cny, type: .securities)
        let first = date(10), second = date(11), today = date(12)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: today, kind: .deposit, amount: 100), accountID: account.id)
        var manual = InvestmentBalanceLedger()
        try manual.add("流动资金", category: .cash, amount: 300, at: first)
        try manual.add("负债", category: .liabilities, amount: 200, at: first)
        book.balanceSheet = manual
        book.dailySnapshots = InvestmentDailySnapshots(through: second, values: [
            first: .init(value: 100, gain: 0), second: .init(value: 120, gain: 20)
        ])
        book.usesServerSnapshots = true

        precondition(book.balanceSheet?.investmentSnapshots.isEmpty == true)
        precondition(book.balanceSnapshot(on: first, today: today).net == nil)
        let points = book.balanceTrend(from: first, through: today)
        precondition(points.map(\.id) == [first, second, today])
        precondition(points.map { $0.snapshot.investment } == [100, 120, 200])
        precondition(points.map { $0.snapshot.net } == [200, 220, 300])
        precondition(Set(points.map(\.segment)).count == 1)
        precondition(book.balanceTrend(from: second, through: today).map(\.id) == [second, today])
        precondition(book.balanceTrend(from: today, through: today).count == 1)
        precondition(book.balanceTrend(from: today, through: first).isEmpty)
    }

    static func balanceTrendKeepsMissingDaysAndManualBalances() throws {
        let first = date(10), second = date(11), third = date(12), fourth = date(13), today = date(14)
        let account = InvestmentAccount(name: "趋势缺口测试", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: first, kind: .deposit, amount: 150), accountID: account.id)
        var manual = InvestmentBalanceLedger()
        try manual.add("流动资金", category: .cash, amount: 50, at: date(9))
        try manual.add("负债", category: .liabilities, amount: 200, at: date(9))
        book.balanceSheet = manual
        book.dailySnapshots = InvestmentDailySnapshots(through: fourth, values: [
            first: .init(value: 100, gain: 0), third: .init(value: 140, gain: 40)
        ])
        book.usesServerSnapshots = true
        let points = book.balanceTrend(from: date(9), through: today)
        precondition(points.map(\.id) == [date(9), first, second, third, fourth, today])
        precondition(points.map { $0.snapshot.net } == [-150, -50, nil, -10, nil, 0])
        precondition(points[1].segment != points[3].segment && points[3].segment != points[5].segment)
        precondition(points[2].snapshot.liabilities == 200 && points[4].snapshot.assets == nil)

        var manualOnly = InvestmentBook()
        manualOnly.usesServerSnapshots = true
        manualOnly.balanceSheet = manual
        let balances = manualOnly.balanceTrend(from: first, through: today)
        precondition(balances.count == 5 && balances.allSatisfy { $0.snapshot.net == -150 })
    }

    static func balanceTrendCarriesSnapshotsFromNovemberFirst() throws {
        let first = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let before = InvestmentBook.addDays(-1, to: first), second = InvestmentBook.addDays(1, to: first)
        let third = InvestmentBook.addDays(2, to: first), fourth = InvestmentBook.addDays(3, to: first)
        let fifth = InvestmentBook.addDays(4, to: first), today = InvestmentBook.addDays(5, to: first)
        let account = InvestmentAccount(name: "快照沿用", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: before, kind: .deposit, amount: 500), accountID: account.id)
        var manual = InvestmentBalanceLedger()
        try manual.add("流动资金", category: .cash, amount: 50, at: first)
        try manual.update(manual.accounts[0].id, amount: 80, at: third)
        try manual.add("负债", category: .liabilities, amount: 40, at: first)
        book.balanceSheet = manual
        book.dailySnapshots = InvestmentDailySnapshots(through: fifth, values: [
            before: .init(value: 90, gain: 0), first: .init(value: 100, gain: 0), fourth: .init(value: 140, gain: 0)
        ])
        book.usesServerSnapshots = true

        let points = book.balanceTrend(from: first, through: today)
        precondition(points.map { $0.snapshot.investment } == [100, 100, 100, 140, 140, 500])
        precondition(points.map { $0.snapshot.net } == [110, 110, 140, 180, 180, 540])
        precondition(points.map(\.investmentSnapshotDay) == [first, first, first, fourth, fourth, today])
        precondition(Set(points.map(\.segment)).count == 1)
        let trimmed = book.balanceTrend(from: third, through: today)
        precondition(trimmed.first?.snapshot.investment == 100 && trimmed.first?.investmentSnapshotDay == first)
        precondition(book.dailyPortfolio(on: [second, third, fifth]).isEmpty)
        precondition(book.dailySnapshots?.values.count == 3 && book.dailySnapshots?.values[second] == nil)

        let foreign = InvestmentAccount(name: "今日估值缺失", currency: .usd, type: .securities)
        var missingToday = InvestmentBook(accounts: [foreign])
        try missingToday.post(.init(day: first, kind: .deposit, amount: 100), accountID: foreign.id)
        missingToday.dailySnapshots = InvestmentDailySnapshots(through: fifth, values: [first: .init(value: 700, gain: 0)])
        missingToday.usesServerSnapshots = true
        precondition(missingToday.portfolio(on: today) == nil)
        let carriedToday = missingToday.balanceTrend(from: today, through: today).first
        precondition(carriedToday?.snapshot.investment == 700 && carriedToday?.investmentSnapshotDay == first)
    }

    static func balanceTrendStopsCarryAtNovemberFirst() throws {
        let first = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let before = InvestmentBook.addDays(-1, to: first), third = InvestmentBook.addDays(2, to: first)
        let fifth = InvestmentBook.addDays(4, to: first), sixth = InvestmentBook.addDays(5, to: first)
        let today = InvestmentBook.addDays(6, to: first)
        let account = InvestmentAccount(name: "快照回溯边界", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: before, kind: .deposit, amount: 500), accountID: account.id)
        book.dailySnapshots = InvestmentDailySnapshots(through: sixth, values: [
            before: .init(value: 90, gain: 0), third: .init(value: 0, gain: 0), fifth: .init(value: -20, gain: 0)
        ])
        book.usesServerSnapshots = true
        let points = book.balanceTrend(from: before, through: today)
        precondition(points.map { $0.snapshot.investment } == [90, nil, nil, 0, 0, -20, -20, 500])
        precondition(points[1].investmentSnapshotDay == nil && points[2].investmentSnapshotDay == nil)
        precondition(points[0].segment != points[3].segment)
        precondition(points[3].segment == points[6].segment)
        precondition(points[4].investmentSnapshotDay == third && points[6].investmentSnapshotDay == fifth)
        precondition(points[6].snapshot.assets == 0 && points[6].snapshot.liabilities == 20 && points[6].snapshot.net == -20)
        precondition(book.balanceTrend(from: first, through: today).first?.snapshot.investment == nil)
    }

    static func currencyConversionRequiresQuote() throws {
        let account = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let day = date(1)
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
        precondition(book.portfolio(on: day) == nil)
        precondition(book.portfolio(on: day, currency: .usd)?.value == 100)
        precondition(book.convert(100, from: .usd, to: .cny, on: day) == nil)
        precondition(book.convert(0, from: .hkd, to: .usd, on: day) == 0)
        let cny = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        let hkd = InvestmentAccount(name: "港元账户", currency: .hkd, type: .insurance)
        book.accounts.append(contentsOf: [cny, hkd])
        try book.post(.init(day: day, kind: .deposit, amount: 720), accountID: cny.id)
        try book.post(.init(day: day, kind: .deposit, amount: 800), accountID: hkd.id)
        precondition(book.portfolio(on: day, currency: .usd) == nil)
        book.fx[.usd] = [.init(day: day, price: Decimal(string: "7.2")!)]
        book.fx[.hkd] = [.init(day: day, price: Decimal(string: "0.9")!)]
        precondition(book.convert(100, from: .usd, to: .cny, on: day) == 720)
        precondition(book.convert(720, from: .cny, to: .usd, on: day) == 100)
        precondition(book.convert(800, from: .hkd, to: .cny, on: day) == 720)
        precondition(book.convert(800, from: .hkd, to: .usd, on: day) == 100)
        precondition(book.portfolio(on: day)?.value == 2160 && book.portfolio(on: day)?.gain == 0)
        precondition(book.portfolio(on: day, currency: .usd)?.value == 300)
    }

    static func accountCurrencyRestrictsEntries() throws {
        let usd = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        let hkd = InvestmentAccount(name: "港元账户", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [usd, hkd])
        let day = date(1)

        for (account, code, venue, kind) in [
            (usd, "BRK.B", "XNYS", InvestmentKind.stock),
            (hkd, "POLICY-A", "", .insurance)
        ] {
            let id = try book.register(.init(name: code, code: code, market: venue, kind: kind, currency: account.currency))
            try book.post(.init(day: day, kind: .opening, assetID: id, quantity: 1, price: 10), accountID: account.id)
        }

        for (account, code, venue, kind, currency) in [
            (usd, "600519.SH", "", InvestmentKind.stock, InvestmentCurrency.usd),
            (usd, "00700.HK", "", .stock, .usd),
            (usd, "09010.HK", "", .etf, .usd),
            (usd, "VOD.L", "", .stock, .usd),
            (usd, "CU1811", "", .future, .usd),
            (usd, "ESZ6", "XCME", .future, .usd),
            (usd, "VFIAX", "", .fund, .usd),
            (usd, "900901.SH", "", .stock, .usd),
            (hkd, "200002.SZ", "", .stock, .hkd),
            (hkd, "AAPL", "", .stock, .hkd),
            (hkd, "000001", "", .stock, .hkd),
            (hkd, "09010.HK", "", .etf, .hkd),
            (hkd, "80700.HK", "", .stock, .hkd),
            (hkd, "AAPL", "XNAS", .stock, .usd)
        ] {
            let id = try book.register(.init(name: code, code: code, market: venue, kind: kind, currency: currency))
            for event in [InvestmentEventKind.opening, .buy] {
                do {
                    try book.post(.init(day: day, kind: event, assetID: id, quantity: 1, price: 10, margin: 1), accountID: account.id)
                    preconditionFailure("Entry must match the account currency")
                } catch InvestmentError.invalid {}
            }
        }
        precondition(book.accounts.map { $0.events.count } == [1, 1])
        let cny = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        book.accounts.append(cny)
        let hk = try book.register(.init(name: "港股", code: "0700", market: "", kind: .stock, currency: .cny))
        do {
            try book.post(.init(day: day, kind: .opening, assetID: hk, quantity: 1, price: 10), accountID: cny.id)
            preconditionFailure("Hong Kong listings must be rejected in every account")
        } catch InvestmentError.invalid {}
        for (code, kind, type) in [
            ("AAPL", InvestmentKind.stock, InvestmentAccountType.securities), ("VFIAX", .fund, .fundWealth),
            ("CLZ6.NYM", .future, .futures), ("000001.SH", .stock, .securities)
        ] {
            let asset = InvestmentAsset(name: code, code: code, market: "", kind: kind, currency: .cny)
            let account = InvestmentAccount(name: "人民币账户", currency: .cny, type: type)
            do {
                try asset.validateEntry(in: account)
                preconditionFailure("Foreign instruments and indices cannot be recorded as mainland securities")
            } catch InvestmentError.invalid {}
        }
    }

    static func insuranceKeepsOnePolicyPosition() throws {
        let account = InvestmentAccount(name: "保险账户", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [account])
        let asset = InvestmentAsset(name: "测试保单", code: "POLICY-A", market: "", kind: .insurance, currency: .hkd)
        let id = try book.register(asset)
        try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 200), accountID: account.id)
        try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 1, price: 75), accountID: account.id)
        book.addQuotes([.init(day: date(2), price: 0)], assetID: id)
        let current = try book.ledger(book.accounts[0], through: date(2))
        precondition(current.cash == 125 && current.positions[id]?.quantity == 1 && current.positions[id]?.netCost == 175)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 125)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 130), accountID: account.id)
        precondition(book.value(book.accounts[0], on: date(3))?.gain == -45)
    }

    static func renminbiInsuranceCountsCashValueAndRoundTrips() throws {
        let cny = InvestmentAccount(name: "人民币保险", currency: .cny, type: .insurance)
        let hkd = InvestmentAccount(name: "港币保险", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [cny, hkd])
        let policy = try book.register(.init(name: "人民币保单", code: "POLICY-CNY", market: "", kind: .insurance, currency: .cny))
        let hkPolicy = try book.register(.init(name: "港币保单", code: "POLICY-HKD", market: "", kind: .insurance, currency: .hkd))
        try book.post(.init(day: date(1), kind: .opening, assetID: policy, quantity: 1, price: 10_000), accountID: cny.id)
        precondition(book.value(book.accounts[0], on: date(1)) == nil, "Missing cash value must not fall back to premiums")
        book.addQuotes([.init(day: date(1), price: 8_000, source: "手动录入")], assetID: policy)
        precondition(book.portfolio(on: date(1))?.value == 8_000 && book.portfolio(on: date(1))?.gain == -2_000)
        try book.post(.init(day: date(1), kind: .opening, assetID: hkPolicy, quantity: 1, price: 10_000), accountID: hkd.id)
        book.addQuotes([.init(day: date(1), price: 8_000, source: "手动录入")], assetID: hkPolicy)
        book.addExchangeRates([.init(day: date(1), price: Decimal(string: "0.9")!, isDailyClose: true)], for: .hkd)
        precondition(book.portfolio(on: date(1))?.value == 15_200)
        try book.post(.init(day: date(2), kind: .deposit, amount: 2_000), accountID: cny.id)
        try book.post(.init(day: date(2), kind: .buy, assetID: policy, quantity: 1, price: 2_000), accountID: cny.id)
        book.addQuotes([.init(day: date(2), price: 9_000, source: "手动录入"),
                        .init(day: date(3), price: 0, source: "手动录入")], assetID: policy)
        let ledger = try book.ledger(book.accounts[0], through: date(2))
        precondition(ledger.positions[policy]?.quantity == 1 && ledger.positions[policy]?.netCost == 12_000)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 9_000)
        precondition(book.portfolio(on: date(2))?.value == 16_200, "Premiums are costs and cannot be added to assets again")
        precondition(book.value(book.accounts[0], on: date(3))?.value == 0)
        try book.post(.init(day: date(4), kind: .sell, assetID: policy, quantity: 1, price: 9_500), accountID: cny.id)
        precondition(book.value(book.accounts[0], on: date(4))?.gain == -2_500)
        precondition(book.profitHistory(accountID: cny.id, assetID: policy, on: (1...4).map(date), today: date(4)).map(\.value) == [-2_000, -3_000, -12_000, -2_500])
        let records = InvestmentServerRecords()
        let restored = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
        precondition(restored.accounts[0].currency == .cny && restored.accounts[0].type == .insurance)
        precondition(restored.value(restored.accounts[0], on: date(4))?.gain == -2_500)
    }

    static func insuranceWithdrawalsKeepPolicyAndMoveCash() throws {
        for currency in [InvestmentCurrency.cny, .hkd] {
            let owner = InvestmentAccount(name: "保险", currency: currency, type: .insurance)
            var book = InvestmentBook(accounts: [owner])
            let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: currency))
            try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 10_000), accountID: owner.id)
            book.addQuotes([.init(day: date(1), price: 8_000), .init(day: date(2), price: 8_100)], assetID: id)
            let first = InvestmentEvent(day: date(2), kind: .insuranceWithdrawal, assetID: id, amount: 2_000, settledAmount: 6_000)
            try book.post(first, accountID: owner.id)
            let second = InvestmentEvent(day: date(2), kind: .insuranceWithdrawal, assetID: id, amount: 500)
            try book.post(second, accountID: owner.id)
            let ledger = try book.ledger(book.accounts[0], through: date(2), includeRows: true)
            precondition(ledger.cash == 2_500 && ledger.flows == 10_000)
            precondition(ledger.positions[id]?.quantity == 1 && ledger.positions[id]?.netCost == 10_000)
            precondition(ledger.cashRows.map(\.change) == [2_000, 500])
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_000)
            precondition(book.value(book.accounts[0], on: date(2))?.gain == -2_000)
            precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [date(1), date(2)], today: date(2)).map(\.value) == [-2_000, -2_000])
            precondition(book.holdingHistory(accountID: owner.id, assetID: id, on: [date(2)], today: date(2)).last?.value == 5_500)
            book.addQuotes([.init(day: date(3), price: 5_800)], assetID: id)
            precondition(book.value(book.accounts[0], on: date(3))?.gain == -1_700)
            precondition(book.value(book.accounts[0], on: date(2))?.gain == -2_000)
            let records = InvestmentServerRecords()
            let restored = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
            precondition(restored.accounts[0].events.contains { $0.kind == .insuranceWithdrawal && $0.settledAmount == nil })
            precondition(restored.value(restored.accounts[0], on: date(2))?.gain == -2_000)
            let savedFirst = try require(book.accounts[0].events.first { $0.id == first.id })
            let savedSecond = try require(book.accounts[0].events.first { $0.id == second.id })
            var edited = savedFirst
            edited.amount = 2_500
            edited.settledAmount = 5_900
            try book.replaceEvent(savedFirst, with: edited, accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_400)
            try book.deleteEvent(savedSecond, accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_400)
            try book.deleteEvent(try require(book.accounts[0].events.first { $0.id == first.id }), accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_100)
            let afterDeletion = try book.ledger(book.accounts[0], through: date(2))
            precondition(afterDeletion.cash == 0)
            try book.post(first, accountID: owner.id)
            try book.post(.init(day: date(4), kind: .sell, assetID: id, quantity: 1, price: 6_100), accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(4))?.gain == -1_900)
            precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [date(4)], today: date(4)).last?.value == -1_900)
            do {
                try book.post(.init(day: date(5), kind: .insuranceWithdrawal, assetID: id, amount: 1), accountID: owner.id)
                preconditionFailure("A closed policy cannot be withdrawn")
            } catch is InvestmentError { }
        }
    }

    static func insuranceWithdrawalsAllowMissingValues() throws {
        let owner = InvestmentAccount(name: "保险", currency: .cny, type: .insurance)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: .cny))
        try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 10_000), accountID: owner.id)
        let withdrawal = InvestmentEvent(day: date(2), kind: .insuranceWithdrawal, assetID: id, amount: 1_000)
        try book.post(withdrawal, accountID: owner.id)
        let ledger = try book.ledger(book.accounts[0], through: date(2))
        precondition(ledger.cash == 1_000 && ledger.positions[id]?.quantity == 1)
        precondition(book.value(book.accounts[0], on: date(2)) == nil)
        book.addQuotes([.init(day: date(1), price: 500)], assetID: id)
        precondition(book.value(book.accounts[0], on: date(2)) == nil, "A stale insufficient valuation cannot become negative or zero")
        book.addQuotes([.init(day: date(3), price: 4_000)], assetID: id)
        precondition(book.value(book.accounts[0], on: date(3))?.value == 5_000)
        let savedWithdrawal = try require(book.accounts[0].events.first { $0.id == withdrawal.id })
        var explicitZero = savedWithdrawal
        explicitZero.settledAmount = 0
        try book.replaceEvent(savedWithdrawal, with: explicitZero, accountID: owner.id)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 1_000)
        let zeroValueLedger = try book.ledger(book.accounts[0], through: date(2))
        precondition(zeroValueLedger.positions[id]?.quantity == 1)
        for (amount, balance) in [(Decimal(0), Optional<Decimal>.none), (-1, nil), (1, -1)] {
            do {
                try book.post(.init(day: date(3), kind: .insuranceWithdrawal, assetID: id, amount: amount, settledAmount: balance), accountID: owner.id)
                preconditionFailure("Invalid withdrawal accepted")
            } catch is InvestmentError { }
        }
    }

    static func stockConnectSettlesInRenminbi() throws {
        let cny = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        let hkd = InvestmentAccount(name: "港元账户", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [cny, hkd])
        precondition(InvestmentAsset.stockConnectCode("700") == "00700.HK")
        precondition(InvestmentAsset.stockConnectCode("0700.hk") == "00700.HK")
        precondition(InvestmentAsset.stockConnectCode("80700.HK") == nil)
        precondition(InvestmentAsset.stockConnectCode("09010.HK") == nil)
        let asset = InvestmentAsset(name: "腾讯控股", code: "00700.HK",
            market: InvestmentAsset.stockConnectMarket, kind: .stock, currency: .hkd)
        let id = try book.register(asset)
        let opening = InvestmentEvent(day: date(1), kind: .opening, assetID: id, quantity: 10, price: 20, settledAmount: 185)
        do {
            try book.post(opening, accountID: hkd.id)
            preconditionFailure("Stock Connect requires a CNY account")
        } catch InvestmentError.invalid {}
        try book.post(opening, accountID: cny.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: cny.id)
        do {
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 22, settledAmount: 102, fee: 3),
                          accountID: cny.id)
            preconditionFailure("Stock Connect settlement already includes fees")
        } catch InvestmentError.invalid {}
        do {
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 22), accountID: cny.id)
            preconditionFailure("Stock Connect requires the broker settlement amount")
        } catch InvestmentError.invalid {}
        try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 22, settledAmount: 102), accountID: cny.id)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 4, price: 25, settledAmount: 89), accountID: cny.id)
        book.addQuotes([.init(day: date(3), price: 24)], assetID: id)
        book.fx[.hkd] = [.init(day: date(4), price: Decimal(string: "0.9")!)]
        let saved = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))
        let account = saved.accounts[0]
        let ledger = try saved.ledger(account, through: date(4), includeRows: true)
        let position = try require(ledger.positions[id])
        precondition(ledger.cash == 987 && ledger.flows == 1185)
        precondition(ledger.cashRows.map(\.change) == [1000, -102, 89])
        precondition(position.quantity == 11 && position.netCost == 198 && position.lastEntry == 22)
        precondition(saved.value(account, on: date(3)) == nil)
        precondition(saved.positionValue(position, asset: asset, on: date(4)) == Decimal(string: "237.6"))
        precondition(saved.portfolio(on: date(4))?.gain == Decimal(string: "39.6"))
    }

    static func typedAccountsFilterAssets() throws {
        func allows(_ type: InvestmentAccountType, _ currency: InvestmentCurrency, _ kind: InvestmentKind,
                    _ code: String, market: String = "") -> Bool {
            let account = InvestmentAccount(name: "账户", currency: currency, type: type)
            let asset = InvestmentAsset(name: code, code: code, market: market, kind: kind,
                                        currency: market == InvestmentAsset.stockConnectMarket ? .hkd : currency)
            return (try? asset.validateEntry(in: account)) != nil
        }
        precondition(allows(.securities, .cny, .stock, "600519"))
        precondition(allows(.securities, .cny, .etf, "510300"))
        precondition(allows(.securities, .cny, .stock, "00700.HK", market: InvestmentAsset.stockConnectMarket))
        precondition(!allows(.fundWealth, .cny, .stock, "00700.HK", market: InvestmentAsset.stockConnectMarket))
        precondition(!allows(.securities, .cny, .option, "10001313.SH"))
        precondition(!allows(.securities, .cny, .option, "IO2611-C-4000.CFX"))
        precondition(!allows(.futures, .cny, .option, "IO2611-C-4000.CFX"))
        precondition(!allows(.futures, .cny, .option, "10001313.SH"))
        precondition(allows(.fundWealth, .cny, .fund, "110022.OF"))
        precondition(!allows(.fundWealth, .cny, .fund, "501018.SH"))
        precondition(allows(.fundWealth, .cny, .wealth, "理财产品"))
        precondition(!allows(.fundWealth, .cny, .stock, "600519"))
        precondition(!InvestmentAccountType.available(in: .usd).contains(.fundWealth))
        precondition(allows(.securities, .usd, .etf, "QQQ", market: "XNAS"))
        precondition(allows(.crypto, .usd, .crypto, "BTC"))
        precondition(!allows(.securities, .usd, .crypto, "BTC"))
        precondition(allows(.insurance, .hkd, .insurance, "POLICY"))
        precondition(allows(.insurance, .cny, .insurance, "人民币保单"))
        precondition(!allows(.insurance, .usd, .insurance, "POLICY"))
        precondition(!allows(.securities, .cny, .insurance, "POLICY"))
        precondition(!allows(.insurance, .cny, .insurance, "POLICY", market: "XSHG"))
    }

    static func fundWealthAccountsKeepBothKindsAndRoundTrip() throws {
        let account = InvestmentAccount(name: "基金理财", currency: .cny, type: .fundWealth)
        var book = InvestmentBook(accounts: [account])
        let fund = try book.register(.init(name: "场外基金", code: "110022.OF", market: "OF", kind: .fund, currency: .cny))
        let wealth = try book.register(.init(name: "银行理财", code: "理财", market: "", kind: .wealth, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: fund, quantity: 100, price: 2), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: wealth, quantity: 1, price: 300, settledAmount: 300), accountID: account.id)
        book.addQuotes([.init(day: date(2), price: 3)], assetID: fund)
        try book.adjustAssetBalance(assetID: wealth, accountID: account.id, balance: 330, on: date(2))
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        precondition(tables["investment_accounts"]?.first?["account_type"] == "fund_wealth")
        let saved = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(saved.accounts.count == 1 && saved.accounts[0].type == .fundWealth)
        let ledger = try saved.ledger(saved.accounts[0], through: date(2))
        precondition(ledger.cash == 500 && ledger.positions[fund]?.quantity == 100 && ledger.positions[wealth]?.depositBalance == 330)
        precondition(tables["investment_manual_prices"]?.isEmpty == true)
        precondition(saved.value(saved.accounts[0], on: date(2))?.value == 1130)
        precondition(saved.value(saved.accounts[0], on: date(2))?.gain == 130)
    }

    static func transfersMoveCashAsOneOperation() throws {
        let bank = InvestmentAccount(name: "银行", currency: .cny, type: .deposits)
        let broker = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        let foreign = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [bank, broker, foreign])
        let first = date(1), second = date(2)
        try book.post(.init(day: first, kind: .deposit, amount: 1000), accountID: bank.id)
        do {
            try book.transfer(from: bank.id, to: broker.id, amount: 200, remaining: 799, on: second)
            preconditionFailure("An incorrect remaining balance must reject both entries")
        } catch InvestmentError.invalid {}
        do {
            try book.transfer(from: bank.id, to: foreign.id, amount: 350, remaining: 650, on: second)
            preconditionFailure("Cross-currency transfers need the actual receipt")
        } catch InvestmentError.invalid {}
        precondition(book.accounts.map { $0.events.count } == [1, 0, 0])
        try book.transfer(from: bank.id, to: broker.id, amount: 200, remaining: 800, on: second)
        precondition(book.portfolio(on: second)?.value == 1000 && book.portfolio(on: second)?.gain == 0)
        try book.transfer(from: bank.id, to: foreign.id, amount: 350, remaining: 450, received: 50, on: second)
        let events = book.accounts.compactMap { $0.events.last }
        precondition(events[0].transferID == events[2].transferID && events[0].transferID != nil)
        precondition(events[0].transferAccountID == foreign.id && events[2].transferAccountID == bank.id)
        let balances = try book.accounts.map { try book.ledger($0, through: second).cash }
        precondition(balances == [450, 200, 50])
        book.fx[.usd] = [.init(day: second, price: 7)]
        precondition(book.portfolio(on: second)?.value == 1000 && book.portfolio(on: second)?.gain == 0)
    }

    static func depositsUseRecordedBalancesAndCashMovements() throws {
        let account = InvestmentAccount(name: "存款", currency: .cny, type: .deposits)
        var book = InvestmentBook(accounts: [account])
        let first = date(1), adjustment = date(2), interest = date(3), withdrawal = date(4), maturity = date(5)
        let asset = InvestmentAsset(name: "大额存单", code: "UNIQUE", market: "", kind: .certificate, currency: .cny,
                                    depositTerms: .init(annualRate: Decimal(string: "0.02")!, maturity: maturity))
        let id = try book.register(asset)
        try book.post(.init(day: first, kind: .deposit, amount: 200), accountID: account.id)
        try book.post(.init(day: first, kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 100), accountID: account.id)
        try book.post(.init(day: first, kind: .buy, assetID: id, quantity: 1, price: 30, settledAmount: 130), accountID: account.id)
        try book.post(.init(day: adjustment, kind: .adjustment, assetID: id, settledAmount: 133), accountID: account.id)
        try book.post(.init(day: interest, kind: .income, assetID: id, amount: 3, settledAmount: 130), accountID: account.id)
        try book.post(.init(day: withdrawal, kind: .sell, assetID: id, quantity: 1, price: 40, settledAmount: 92), accountID: account.id)
        precondition(book.portfolio(on: first)?.gain == 0)
        precondition(book.portfolio(on: adjustment, requiresDailyPrices: true)?.gain == 3)
        let interestLedger = try book.ledger(book.accounts[0], through: interest)
        precondition(interestLedger.cash == 73 && interestLedger.positions[id]?.netCost == 130)
        precondition(book.portfolio(on: interest)?.gain == 3)
        precondition(book.portfolio(on: withdrawal)?.gain == 5)
        try book.post(.init(day: maturity, kind: .sell, assetID: id, quantity: 1, price: 93, settledAmount: 0), accountID: account.id)
        let ledger = try book.ledger(book.accounts[0], through: maturity, includeRows: true)
        precondition(ledger.cashRows.map(\.change) == [200, -100, -30, 3, 40, 93])
        precondition(book.portfolio(on: maturity)?.gain == 6 && ledger.positions[id]?.realized == 6)

        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        var reloaded = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: tables))
        precondition(reloaded.asset(id)?.depositTerms == asset.depositTerms)
        precondition(reloaded.portfolio(on: withdrawal)?.gain == 5)
        let original = reloaded.accounts[0].events.first { $0.kind == .adjustment }!
        var edited = original
        edited.settledAmount = 132
        try reloaded.replaceEvent(original, with: edited, accountID: account.id)
        precondition(reloaded.portfolio(on: adjustment)?.gain == 2)
        precondition(reloaded.portfolio(on: maturity)?.gain == 6)
    }

    static func dailyGainsRequireCompleteMarketPrices() throws {
        let friday = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let saturday = InvestmentBook.addDays(1, to: friday)
        let sunday = InvestmentBook.addDays(2, to: friday)
        let monday = InvestmentBook.addDays(3, to: friday)
        let stockAccount = InvestmentAccount(name: "股票", currency: .cny, type: .securities)
        var stocks = InvestmentBook(accounts: [stockAccount])
        let stock = try stocks.register(.init(name: "测试股票", code: "600000", market: "", kind: .stock, currency: .cny))
        try stocks.post(.init(day: friday, kind: .deposit, amount: 100), accountID: stockAccount.id)
        try stocks.post(.init(day: friday, kind: .buy, assetID: stock, quantity: 10, price: 2), accountID: stockAccount.id)
        stocks.addQuotes([.init(day: friday, price: 3)], assetID: stock)
        let stockGains = stocks.dailyGains(from: friday, through: monday)
        precondition(stockGains[friday] == 10 && stockGains[saturday] == 0 && stockGains[sunday] == 0)
        precondition(stockGains[monday] == nil)

        let cryptoAccount = InvestmentAccount(name: "现货", currency: .usd, type: .crypto)
        var crypto = InvestmentBook(accounts: [cryptoAccount])
        let token = try crypto.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try crypto.post(.init(day: friday, kind: .deposit, amount: 100), accountID: cryptoAccount.id)
        try crypto.post(.init(day: friday, kind: .buy, assetID: token, quantity: 10, price: 2), accountID: cryptoAccount.id)
        crypto.fx[.usd] = [.init(day: friday, price: 7)]
        crypto.addQuotes([.init(day: friday, price: 3, isDailyClose: true),
                          .init(day: saturday, price: 4, source: "盘中报价"),
                          .init(day: sunday, price: 5, isDailyClose: true)], assetID: token)
        let incomplete = crypto.dailyGains(from: friday, through: sunday)
        precondition(incomplete[friday] == 70 && incomplete[saturday] == nil && incomplete[sunday] == nil)
        crypto.addQuotes([.init(day: saturday, price: 4, isDailyClose: true)], assetID: token)
        crypto.addQuotes([.init(day: saturday, price: 99, source: "盘中报价")], assetID: token)
        let completed = crypto.dailyGains(from: friday, through: sunday)
        precondition(completed[friday] == 70 && completed[saturday] == 70 && completed[sunday] == 70)
    }

    static func portfolioHistoryMatchesIndividualValuations() throws {
        let cny = InvestmentAccount(name: "境内", currency: .cny, type: .securities)
        let usd = InvestmentAccount(name: "境外", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [cny, usd])
        let stock = try book.register(.init(name: "测试股票", code: "600000", market: "", kind: .stock, currency: .cny))
        try book.post(.init(day: date(2), kind: .deposit, amount: 100), accountID: cny.id)
        try book.post(.init(day: date(2), kind: .buy, assetID: stock, quantity: 10, price: 5), accountID: cny.id)
        try book.post(.init(day: date(4), kind: .sell, assetID: stock, quantity: 3, price: 8, fee: 1), accountID: cny.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 20), accountID: cny.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: usd.id)
        book.addQuotes([.init(day: date(3), price: 7), .init(day: date(4), price: 8)], assetID: stock)
        book.fx[.usd] = [.init(day: date(2), price: 7), .init(day: date(4), price: Decimal(string: "7.1")!)]
        let days = [date(5), date(3), date(1), date(2), date(3), date(4)]

        for currency in [InvestmentCurrency.cny, .usd] {
            let history = book.portfolioHistory(on: days, currency: currency)
            for day in days {
                let individual = book.portfolio(on: day, currency: currency)
                precondition(history[day]?.value == individual?.value && history[day]?.gain == individual?.gain)
            }
        }
        book.accounts[0].events.append(.init(day: date(4), kind: .withdrawal, amount: -1000))
        let history = book.portfolioHistory(on: days)
        precondition(history[date(3)] != nil && history[date(4)] == nil && history[date(5)] == nil)
    }

    static func dailySnapshotsUseBeijingCloseAndDatedRates() throws {
        let summer = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!
        let winter = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let calendar = InvestmentBook.calendar
        precondition(calendar.component(.hour, from: InvestmentBook.usEquityClose(on: summer)) == 4)
        precondition(calendar.component(.hour, from: InvestmentBook.usEquityClose(on: winter)) == 5)

        let thursday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        let friday = InvestmentBook.addDays(1, to: thursday)
        let saturday = InvestmentBook.addDays(2, to: thursday)
        let monday = InvestmentBook.addDays(4, to: thursday)
        let usd = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [usd])
        let stock = try book.register(.init(name: "美股", code: "AAPL", market: "", kind: .stock, currency: .usd))
        try book.post(.init(day: friday, kind: .deposit, amount: 100), accountID: usd.id)
        try book.post(.init(day: friday, kind: .buy, assetID: stock, quantity: 10, price: 5), accountID: usd.id)
        book.addExchangeRates([.init(day: friday, price: 7), .init(day: monday, price: 8)], for: .usd)
        book.addQuotes([.init(day: thursday, price: 6, isDailyClose: true),
                        .init(day: friday, price: 9, isDailyClose: false)], assetID: stock)
        book.dailySnapshots = book.makeDailySnapshots(through: monday, rebuild: true)
        precondition(book.dailySnapshots?.values[friday]?.value == 770)
        precondition(book.dailySnapshots?.values[friday]?.gain == 70)
        precondition(book.dailySnapshots?.values[saturday] == nil && book.dailySnapshots?.values[monday] == nil)

        book.addQuotes([.init(day: friday, price: 7, isDailyClose: true)], assetID: stock)
        precondition(book.dailySnapshots?.values[friday] == nil)
        book.dailySnapshots = book.makeDailySnapshots(through: monday, rebuild: false)
        precondition(book.dailySnapshots?.values[saturday]?.value == 840)
        precondition(book.dailySnapshots?.values[monday]?.value == 960)
        precondition(book.dailyGains(from: friday, through: saturday)[saturday] == 70)
        book.addExchangeRates([.init(day: monday, price: 9)], for: .usd)
        precondition(book.dailySnapshots?.values[saturday]?.value == 840 && book.dailySnapshots?.values[monday] == nil)
        try book.post(.init(day: monday, kind: .deposit, amount: 20), accountID: usd.id)
        book.dailySnapshots = book.makeDailySnapshots(through: monday, rebuild: false)
        let restored = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))
        precondition(restored.dailyPortfolio(on: [monday])[monday]?.value == 1260)
        precondition(restored.dailySnapshotReport(through: monday).latest?.valueUSD == 140)
        precondition(restored.dailySnapshotReport(through: monday).includesDay)
        precondition(restored.makeDailySnapshots(through: monday, rebuild: false) == nil)
    }

    static func changingHistoricalEntriesInvalidatesOnlyTheAffectedDays() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(3), kind: .adjustment, amount: 30), accountID: account.id)
        let first = try require(book.account(account.id)?.events.first)
        let later = try require(book.account(account.id)?.events.last)
        book.addExchangeRates([.init(day: date(1), price: 5), .init(day: date(2), price: 10),
                               .init(day: date(3), price: 10), .init(day: date(4), price: 10)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: true)
        precondition(book.dailySnapshots?.values[date(1)]?.valueUSD == 20)

        var earlier = later
        earlier.day = date(2)
        earlier.amount = 50
        try book.replaceEvent(later, with: earlier, accountID: account.id)
        precondition(book.snapshotStart(rebuild: false) == date(2))
        precondition(book.dailySnapshots?.values[date(1)]?.value == 100)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.values[date(2)]?.valueUSD == 15)

        let confirmedEarlier = try require(book.account(account.id)?.events.last)
        var moved = confirmedEarlier
        moved.day = date(4)
        try book.replaceEvent(confirmedEarlier, with: moved, accountID: account.id)
        precondition(book.snapshotStart(rebuild: false) == date(2))
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.values[date(2)]?.valueUSD == 10)
        try book.deleteEvent(try require(book.account(account.id)?.events.last), accountID: account.id)
        precondition(book.snapshotStart(rebuild: false) == date(4))
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        try book.deleteEvent(first, accountID: account.id)
        precondition(book.earliest == nil && book.dailySnapshots?.values.isEmpty == true)
    }

    static func changingTransfersIsAtomic() throws {
        let source = InvestmentAccount(name: "人民币", currency: .cny, type: .securities)
        let target = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [source, target])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: source.id)
        try book.transfer(from: source.id, to: target.id, amount: 70, remaining: 30, received: 10, on: date(2))
        let incoming = try require(book.account(target.id)?.events.first)
        var edited = incoming
        edited.day = date(3)
        edited.amount = 12
        try book.replaceEvent(incoming, with: edited, accountID: target.id, counterpartAmount: -84)
        let outgoing = try require(book.account(source.id)?.events.last)
        precondition(outgoing.day == date(3) && outgoing.amount == -84)
        try book.post(.init(day: date(4), kind: .withdrawal, amount: -10), accountID: target.id)
        do {
            try book.deleteEvent(outgoing, accountID: source.id)
            preconditionFailure("A transfer that funds a later withdrawal must remain intact")
        } catch InvestmentError.insufficientCash {}
        precondition(book.account(source.id)?.events.contains(outgoing) == true)
        precondition(book.account(target.id)?.events.contains(where: { $0.id == edited.id && $0.amount == edited.amount }) == true)
        try book.deleteEvent(try require(book.account(target.id)?.events.last), accountID: target.id)
        try book.deleteEvent(outgoing, accountID: source.id)
        precondition(book.account(source.id)?.events.count == 1 && book.account(target.id)?.events.isEmpty == true)
    }

    static func dailyQuotesReuseCachedMarketCloses() throws {
        let monday = InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 10, day: 6))!
        let friday = InvestmentBook.addDays(-3, to: monday)
        let saturday = InvestmentBook.addDays(-2, to: monday)
        let tuesday = InvestmentBook.addDays(1, to: monday)
        let account = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "AAPL", market: "", kind: .stock, currency: .usd))
        try book.post(.init(day: saturday, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: saturday, kind: .buy, assetID: id, quantity: 1, price: 100), accountID: account.id)
        let historyStart = InvestmentBook.addDays(-30, to: friday)
        let missing = book.missingDailyMarketData(in: historyStart...tuesday)
        precondition(missing.assets[id] == [friday...friday, monday...monday])
        precondition(missing.rates[.usd] == [friday...tuesday])
        book.addQuotes([.init(day: friday, price: 100, isDailyClose: true),
                        .init(day: monday, price: 110, isDailyClose: false)], assetID: id)
        precondition(book.missingDailyMarketData(in: monday...tuesday).assets[id] == [monday...monday])
        book.addQuotes([.init(day: monday, price: 110, isDailyClose: true)], assetID: id)
        book.addExchangeRates([.init(day: friday, price: 7), .init(day: monday, price: 7), .init(day: tuesday, price: 7)], for: .usd)
        let complete = book.missingDailyMarketData(in: historyStart...tuesday)
        precondition(complete.assets.isEmpty && complete.rates.isEmpty)
        book.dailySnapshots = book.makeDailySnapshots(through: tuesday, rebuild: true)
        precondition(book.dailyQuoteWindow(through: tuesday) == nil)
    }

    static func serverRoundTripPreservesShortFuturesAndSnapshots() throws {
        let account = InvestmentAccount(name: "期货", currency: .cny, type: .futures)
        var book = InvestmentBook(accounts: [account])
        let long = InvestmentAsset(name: "沪铜", code: "CU2612.SHF", market: "SHFE", kind: .future,
                                   currency: .cny, multiplier: 5, contractSide: .long)
        var short = long
        short.id = UUID()
        short.contractSide = .short
        let longID = try book.register(long)
        let shortID = try book.register(short)
        precondition(longID != shortID)
        try book.post(.init(day: date(1), kind: .deposit, amount: 1_000), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: shortID, quantity: 2, price: 100, margin: 50), accountID: account.id)
        try book.post(.init(day: date(2), kind: .derivativeSettlement, assetID: shortID, amount: 100, price: 90), accountID: account.id)
        book.addQuotes([.init(day: date(3), price: 85, source: "test", isDailyClose: true)], assetID: shortID)
        book.addExchangeRates([.init(day: date(2), price: 5), .init(day: date(3), price: 5)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(3), rebuild: true)
        precondition(book.dailySnapshots?.values[date(2)]?.value == 1_100)
        precondition(book.dailySnapshots?.values[date(3)]?.value == 1_150)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 3)
        precondition(tables["market_derivative_specs"]?.count == 1)
        precondition(tables["investment_derivative_event_details"]?.contains { $0["trade_action"] == "open_short" } == true)
        let state = InvestmentServerState(generation: 4, revision: 3, through: records.day.string(from: date(3)), tables: tables)
        let restored = try records.decode(state)
        precondition(restored.usesServerSnapshots)
        precondition(restored.assets[shortID]?.contractSide == .short)
        precondition(restored.dailySnapshots?.values[date(3)]?.valueUSD == 230)
        precondition(restored.dailySnapshots?.accountValues?[account.id]?[date(3)]?.gain == 150)
    }

    static func archivesOnlyEmptyAccountsAndPreservesHistory() throws {
        let account = InvestmentAccount(name: "可归档", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = InvestmentAsset(name: "股票", code: "600000", market: "XSHG", kind: .stock, currency: .cny)
        let id = try book.register(asset)
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 10, price: 10), accountID: account.id)
        precondition(book.archiveBlocker(accountID: account.id) != nil, "Missing quotes do not make a held position empty")
        do { try book.setArchived(true, accountID: account.id); preconditionFailure("Nonzero holdings must not archive") }
        catch is InvestmentError { }
        try book.post(.init(day: date(2), kind: .sell, assetID: id, quantity: 10, price: 10), accountID: account.id)
        precondition(book.archiveBlocker(accountID: account.id) != nil, "Cash still prevents archiving")
        try book.post(.init(day: date(2), kind: .withdrawal, amount: -100), accountID: account.id)
        book.plans = [.init(accountID: account.id, amount: 100, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3))]
        let events = try require(book.account(account.id)).events
        let position = try require(book.ledger(book.accounts[0]).positions[id])
        precondition(book.positionIsEmpty(position, assetID: id))
        precondition(!book.positionIsEmpty(.init(quantity: 0, margin: 1), assetID: id))
        try book.setArchived(true, accountID: account.id, at: date(3))
        precondition(book.visibleAccounts(showArchived: false).isEmpty)
        precondition(book.visibleAccounts(showArchived: true).count == 1)
        precondition(book.accounts[0].events == events && !book.plans[0].enabled)
        do { try book.post(.init(day: date(3), kind: .deposit, amount: 1), accountID: account.id); preconditionFailure("Archived accounts are read only") }
        catch is InvestmentError { }
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        var restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(restored.accounts[0].archivedAt == date(3))
        let roundTrip = try records.encode(restored, revision: 1)
        precondition(roundTrip["investment_events"] == tables["investment_events"])
        try restored.setArchived(false, accountID: account.id)
        precondition(restored.visibleAccounts(showArchived: false).count == 1 && !restored.plans[0].enabled)
        try restored.post(.init(day: date(3), kind: .deposit, amount: 1), accountID: account.id)
    }

    static func deletesOnlyTheSelectedHoldingAndItsRecords() throws {
        let left = InvestmentAccount(name: "左", currency: .cny, type: .securities)
        let right = InvestmentAccount(name: "右", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [left, right])
        let id = try book.register(.init(name: "共享标的", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        for account in [left, right] {
            try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
            try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 10), accountID: account.id)
            let event = try require(book.account(account.id)?.events.last)
            let plan = InvestmentPlan(accountID: account.id, assetID: id, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3))
            book.plans.append(plan)
            book.planRuns.append(.init(planID: plan.id, day: date(1), status: "executed", eventID: event.id, executedAt: date(1), detail: nil))
        }
        book.watched = [id]
        book.addQuotes([.init(day: date(2), price: 10)], assetID: id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(2), rebuild: true)
        book.balanceSheet = InvestmentBalanceLedger(investmentMonthEnds: [date(0): 100, date(31): 200])
        let rightEvents = try require(book.account(right.id)).events
        try book.deleteInvestment(accountID: left.id, assetID: id)
        let ledger = try book.ledger(try require(book.account(left.id)))
        precondition(ledger.positions[id] == nil && ledger.cash == 100)
        precondition(book.account(right.id)?.events == rightEvents && book.asset(id) != nil && book.watched == [id])
        precondition(book.plans.count == 1 && book.plans[0].accountID == right.id && book.planRuns.count == 1)
        precondition(book.dailySnapshots?.through == date(0))
        precondition(book.balanceSheet?.investmentSnapshots == [date(0): 100])
        let records = InvestmentServerRecords()
        let rows = try records.encode(book, revision: 2)
        precondition(rows["investment_events"]?.filter { $0["account_id"] == left.id.uuidString }.count == 1)
    }

    static func deletesAccountsAndPairedTransfersAtomically() throws {
        let source = InvestmentAccount(name: "来源", currency: .cny, type: .securities)
        let target = InvestmentAccount(name: "目标", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [source, target])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: source.id)
        try book.transfer(from: source.id, to: target.id, amount: 50, remaining: 50, on: date(2))
        try book.post(.init(day: date(3), kind: .withdrawal, amount: -40), accountID: target.id)
        let before = book.accounts.map(\.events)
        do { try book.deleteInvestment(accountID: source.id); preconditionFailure("Removing spent transfer proceeds must fail atomically") }
        catch is InvestmentError { }
        precondition(book.accounts.map(\.events) == before && book.accounts.count == 2)
        try book.deleteEvent(try require(book.account(target.id)?.events.last), accountID: target.id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(3), rebuild: true)
        try book.deleteInvestment(accountID: source.id)
        precondition(book.accounts.count == 1 && book.accounts[0].id == target.id && book.accounts[0].events.isEmpty)
        precondition(book.dailySnapshots?.accountValues?[source.id] == nil)
        let rows = try InvestmentServerRecords().encode(book, revision: 3)
        precondition(rows["investment_account_daily_snapshots"]?.allSatisfy { $0["account_id"] != source.id.uuidString } == true)
    }

    static func deletesUnreferencedRegistrationsAndTheirQuotes() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let used = try book.register(.init(name: "持仓标的", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        let planned = try book.register(.init(name: "定投标的", code: "600001", market: "XSHG", kind: .stock, currency: .cny))
        let unrelated = try book.register(.init(name: "独立登记", code: "600002", market: "XSHG", kind: .stock, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: used, quantity: 1, price: 10), accountID: account.id)
        for id in [used, planned, unrelated] { book.addQuotes([.init(day: date(2), price: 10, source: "测试行情")], assetID: id) }
        book.plans = [.init(accountID: account.id, assetID: planned, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3))]
        precondition(book.deletionMessage(accountID: account.id, assetID: used).contains("同时删除无其他引用的标的登记及报价：持仓标的"))
        try book.deleteInvestment(accountID: account.id, assetID: used)
        precondition(book.asset(used) == nil && book.quotes[used] == nil)
        precondition(book.asset(planned) != nil && book.asset(unrelated) != nil && book.quotes[unrelated]?.count == 1)
        let ledger = try book.ledger(try require(book.account(account.id)))
        precondition(ledger.cash == 100 && ledger.positions.isEmpty)
        try book.deleteInvestment(accountID: account.id)
        precondition(book.asset(planned) == nil && book.quotes[planned] == nil && book.plans.isEmpty)
        precondition(book.assets.count == 1 && book.asset(unrelated) != nil)
        let records = InvestmentServerRecords()
        let rows = try records.encode(book, revision: 2)
        precondition(rows["investment_assets"]?.count == 1 && rows["market_instruments"]?.count == 1 && rows["market_daily_prices"]?.count == 1)
        let restored = try records.decode(.init(generation: 1, revision: 2, tables: rows))
        precondition(restored.asset(unrelated) != nil && restored.accounts.isEmpty)
    }

    static func deletionPreservesPlanReferences() throws {
        let owner = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        let other = InvestmentAccount(name: "另一账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [owner, other])
        let id = try book.register(.init(name: "测试", code: "600000", market: "SH", kind: .stock, currency: .cny))
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 10, price: 1), accountID: owner.id, autoFundCash: true)
        book.plans = [.init(accountID: other.id, assetID: id, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3), enabled: false)]
        try book.deleteInvestment(accountID: owner.id)
        precondition(book.asset(id) != nil && book.plans.count == 1)
    }

    static func genericBalancesSeparateValuationFromCashFlows() throws {
        let owner = InvestmentAccount(name: "Binance", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "策略账户", code: UUID().uuidString, market: "", kind: .generic, currency: .usd))
        precondition(owner.kinds == [.crypto, .generic])
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 10000, settledAmount: 10400), accountID: owner.id, autoFundCash: true)
        precondition(book.value(book.accounts[0], on: date(1))?.gain == 400)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 10800, on: date(2))
        let adjusted = try book.ledger(book.accounts[0], through: date(2), includeRows: true)
        precondition(adjusted.cash == 0 && adjusted.flows == 10000 && adjusted.cashRows.count == 2)
        precondition(adjusted.positions[id]?.depositBalance == 10800 && book.value(book.accounts[0], on: date(2))?.gain == 800)
        try book.post(.init(day: date(3), kind: .buy, assetID: id, quantity: 1, price: 1000), accountID: owner.id, autoFundCash: true)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 500), accountID: owner.id)
        let moved = try book.ledger(book.accounts[0], through: date(3))
        precondition(moved.cash == 500 && moved.positions[id]?.depositBalance == 11300)
        precondition(book.value(book.accounts[0], on: date(3))?.gain == 800)
        try book.post(.init(day: date(4), kind: .sell, assetID: id, quantity: 1, price: 11300), accountID: owner.id)
        let closed = try book.ledger(book.accounts[0], through: date(4))
        precondition(closed.positions[id]?.quantity == 0 && closed.positions[id]?.realized == 800)
        try book.post(.init(day: date(5), kind: .buy, assetID: id, quantity: 1, price: 2000), accountID: owner.id)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 0, on: date(6))
        precondition(book.value(book.accounts[0], on: date(6))?.gain == -1200)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 2100, on: date(7))
        precondition(book.value(book.accounts[0], on: date(7), requiresDailyPrices: true)?.gain == 900)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        precondition(tables["market_instruments"]?.isEmpty == true)
        precondition(tables["investment_assets"]?.first?["asset_type"] == "generic")
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(restored.value(restored.accounts[0], on: date(7))?.gain == 900)
        precondition(!restored.assets[id]!.kind.supportsPlan && !restored.assets[id]!.kind.requiresCatalog)
    }

    static func genericBalancesValidateAndReplayHistory() throws {
        let owner = InvestmentAccount(name: "通用", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "策略", code: UUID().uuidString, market: "", kind: .generic, currency: .usd))
        let repeated = try book.register(.init(name: "策略", code: UUID().uuidString, market: "", kind: .generic, currency: .usd))
        precondition(id == repeated)
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 0), accountID: owner.id, autoFundCash: true)
        precondition(book.value(book.accounts[0], on: date(1))?.gain == -100)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 150, on: date(2))
        for event in [InvestmentEvent(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 151),
                      .init(day: date(3), kind: .buy, assetID: id, quantity: 1, price: 10, settledAmount: 170),
                      .init(day: date(3), kind: .adjustment, assetID: id, settledAmount: -1)] {
            let before = book.accounts[0].events
            do { try book.post(event, accountID: owner.id, autoFundCash: true); preconditionFailure("invalid balance operation") }
            catch is InvestmentError { }
            precondition(book.accounts[0].events == before)
        }
        do { try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 150, on: date(2)); preconditionFailure("unchanged balance") }
        catch is InvestmentError { }
        let original = book.accounts[0].events.last!
        var edited = original; edited.settledAmount = 175
        try book.replaceEvent(original, with: edited, accountID: owner.id)
        precondition(book.value(book.accounts[0], on: date(1))?.gain == -100)
        precondition(book.value(book.accounts[0], on: date(2))?.gain == 75)
        try book.deleteEvent(book.accounts[0].events.last!, accountID: owner.id)
        precondition(book.value(book.accounts[0], on: date(2))?.gain == -100)
        do { try book.assets[id]!.validateEntry(in: .init(name: "人民币", currency: .cny, type: .securities)); preconditionFailure("generic currency") }
        catch is InvestmentError { }
    }

    static func holdingHistoryTracksQuantitiesAndAmounts() throws {
        let account = InvestmentAccount(name: "持仓", currency: .usd, type: .crypto)
        let other = InvestmentAccount(name: "另一账户", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account, other])
        let token = try book.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try book.post(.init(day: date(1), kind: .opening, assetID: token, quantity: 2, price: 10), accountID: account.id)
        try book.post(.init(day: date(1), kind: .opening, assetID: token, quantity: 99, price: 10), accountID: other.id)
        try book.adjustSpotBalance(assetID: token, accountID: account.id, balance: 3, on: date(3))
        try book.post(.init(day: date(4), kind: .sell, assetID: token, quantity: 1, price: 12), accountID: account.id)
        book.addQuotes([.init(day: date(1), price: 10, isDailyClose: true),
                        .init(day: date(3), price: 11, isDailyClose: true),
                        .init(day: date(4), price: 12, isDailyClose: true),
                        .init(day: date(5), price: 13)], assetID: token)
        let days = (0...6).map { InvestmentBook.addDays($0 - 1, to: date(1)) }
        let points = book.holdingHistory(accountID: account.id, assetID: token, on: days, today: date(5))
        precondition(points.map(\.day) == [date(1), date(2), date(3), date(4), date(5)])
        precondition(points.map(\.value) == [2, 2, 3, 2, 2], "Quantity history must be independent of quotes and other accounts")
        precondition(points.allSatisfy { $0.segment == 0 }, "Missing prices must not create gaps in quantity history")
        let one = book.holdingHistory(accountID: account.id, assetID: token, on: [date(5)], today: date(5))
        precondition(one.count == 1 && one[0].value == 2)
        try book.post(.init(day: date(6), kind: .sell, assetID: token, quantity: 2, price: 13), accountID: account.id)
        let closed = book.holdingHistory(accountID: account.id, assetID: token, on: [date(6)], today: date(6))
        precondition(closed.first?.value == 0, "Closing a holding must show zero without requiring a quote")

        let cash = InvestmentAccount(name: "手工资产", currency: .usd, type: .crypto)
        var manual = InvestmentBook(accounts: [cash])
        let balance = try manual.register(.init(name: "余额", code: "BALANCE", market: "", kind: .generic, currency: .usd))
        try manual.post(.init(day: date(1), kind: .opening, assetID: balance, quantity: 1, price: 100), accountID: cash.id)
        try manual.post(.init(day: date(2), kind: .adjustment, assetID: balance, settledAmount: 150), accountID: cash.id)
        let balances = manual.holdingHistory(accountID: cash.id, assetID: balance, on: [date(1), date(2)], today: date(3))
        precondition(balances.map(\.value) == [100, 150], "Manual balances must not require market quotes")
    }

    static func deletedAndRecreatedHoldingsInvalidateSnapshotsWithoutCache() throws {
        let owner = InvestmentAccount(name: "重建持仓", currency: .usd, type: .crypto)
        var original = InvestmentBook(accounts: [owner])
        let id = try original.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try original.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 10, price: 1), accountID: owner.id)
        original.addQuotes((1...4).map { .init(day: date($0), price: 1, isDailyClose: true) }, assetID: id)
        original.addExchangeRates((1...4).map { .init(day: date($0), price: 7) }, for: .usd)
        original.dailySnapshots = original.makeDailySnapshots(through: date(4), rebuild: true)
        var deleted = original
        try deleted.deleteInvestment(accountID: owner.id, assetID: id)
        precondition(deleted.snapshotInputChange(comparedTo: original) == date(1))
        // The previous cutoff may be absent after the last holding is removed.
        deleted.dailySnapshots = nil
        var recreated = deleted
        let nextID = try recreated.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try recreated.post(.init(day: date(2), kind: .opening, assetID: nextID, quantity: 20, price: 2), accountID: owner.id)
        precondition(recreated.snapshotInputChange(comparedTo: deleted) == date(2))
        precondition(recreated.snapshotInputChange(comparedTo: recreated) == nil)
        recreated.addQuotes((2...4).map { .init(day: date($0), price: 2, isDailyClose: true) }, assetID: nextID)
        recreated.dailySnapshots = recreated.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(recreated.dailySnapshots?.values[date(2)]?.value == 280)
        precondition(recreated.inconsistentDailySnapshotStart(through: date(4)) == nil)
        var stale = recreated
        stale.dailySnapshots?.values[date(2)] = .init(value: 70, gain: 0, valueUSD: 10)
        precondition(stale.inconsistentDailySnapshotStart(through: date(4)) == date(2), "Loading stale persisted snapshots must trigger automatic repair")
        let records = InvestmentServerRecords()
        let tables = try records.encode(recreated, revision: 3)
        let loaded = try records.decode(.init(generation: 3, revision: 3, through: records.day.string(from: date(4)), tables: tables))
        precondition(loaded.dailySnapshots?.values[date(2)]?.value == 280)
        var moved = recreated
        let event = try require(moved.account(owner.id)?.events.first)
        var changed = event
        changed.day = date(1)
        try moved.replaceEvent(event, with: changed, accountID: owner.id)
        precondition(moved.snapshotInputChange(comparedTo: recreated) == date(1))
    }

    static func fundAndWealthHistoryTracksNetInvestment() throws {
        for kind in [InvestmentKind.fund, .wealth] {
            let account = InvestmentAccount(name: kind.rawValue, currency: .cny, type: .fundWealth)
            var book = InvestmentBook(accounts: [account])
            let id = try book.register(.init(name: "投入测试", code: "000001", market: "", kind: kind, currency: .cny))
            try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
            if kind == .wealth {
                try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 100), accountID: account.id)
                try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 200), accountID: account.id)
                try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 100, settledAmount: 100), accountID: account.id)
                try book.adjustAssetBalance(assetID: id, accountID: account.id, balance: 110, on: date(4))
                try book.post(.init(day: date(5), kind: .sell, assetID: id, quantity: 1, price: 110, settledAmount: 0), accountID: account.id)
                let points = book.holdingHistory(accountID: account.id, assetID: id, on: (1...5).map(date), today: date(5))
                precondition(points.map(\.value) == [100, 200, 100, 100, -10])
                continue
            }
            try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 10, price: 10, fee: 1), accountID: account.id)
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 20, fee: 2), accountID: account.id)
            try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 4, price: 25, fee: 1), accountID: account.id)
            try book.post(.init(day: date(5), kind: .sell, assetID: id, quantity: 11, price: 10, fee: 1), accountID: account.id)
            book.addQuotes([.init(day: date(4), price: 99)], assetID: id)
            let points = book.holdingHistory(accountID: account.id, assetID: id, on: (1...5).map(date), today: date(5))
            precondition(points.map(\.value) == [101, 203, 104, 104, -5], "Fund and wealth charts must show net invested cash, independent of quantity and quotes")
            precondition(book.asset(id)?.historyUsesInvestment == true && book.asset(id)?.historyUsesAmount == true)
        }
        let etf = InvestmentAsset(name: "ETF", code: "TEST", market: "", kind: .etf, currency: .cny)
        precondition(!etf.historyUsesAmount, "ETF remains a quantity-based asset")
    }

    static func wealthUsesAmountsAndReportedBalances() throws {
        let account = InvestmentAccount(name: "理财余额", currency: .cny, type: .fundWealth)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "银行理财", code: "PRODUCT", market: "", kind: .wealth, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 500, settledAmount: 500), accountID: account.id)
        try book.adjustAssetBalance(assetID: id, accountID: account.id, balance: 520, on: date(2))
        precondition(book.value(book.accounts[0], on: date(2))?.gain == 20)
        try book.post(.init(day: date(3), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 620), accountID: account.id)
        try book.post(.init(day: date(4), kind: .income, assetID: id, amount: 20, settledAmount: 600), accountID: account.id)
        precondition(book.value(book.accounts[0], on: date(4))?.gain == 20, "An income withdrawal must not count already valued gains twice")
        try book.post(.init(day: date(5), kind: .sell, assetID: id, quantity: 1, price: 200, settledAmount: 405), accountID: account.id)
        precondition(book.value(book.accounts[0], on: date(5))?.gain == 25)
        try book.post(.init(day: date(6), kind: .sell, assetID: id, quantity: 1, price: 410, settledAmount: 0), accountID: account.id)
        let ledger = try book.ledger(book.accounts[0], through: date(6))
        precondition(ledger.cash == 1030 && ledger.positions[id]?.depositBalance == 0 && ledger.positions[id]?.quantity == 0)
        precondition(book.value(book.accounts[0], on: date(6))?.gain == 30)
        precondition(book.quotes[id]?.isEmpty != false, "Wealth balances must not require unit NAV quotes")
        do {
            try book.post(.init(day: date(7), kind: .buy, assetID: id, quantity: 1, price: 100), accountID: account.id)
            preconditionFailure("A wealth cash movement requires the reported balance")
        } catch is InvestmentError { }
        do {
            try book.post(.init(day: date(7), kind: .buy, assetID: id, quantity: 2, price: 100, settledAmount: 200), accountID: account.id)
            preconditionFailure("Wealth amounts cannot be multiplied by a user-entered share count")
        } catch is InvestmentError { }
    }

    static func manualQuotesAreLimitedToInsurance() throws {
        for kind in InvestmentKind.allCases { precondition(kind.supportsManualQuote == (kind == .insurance)) }
        for (kind, code) in [(InvestmentKind.stock, "600036"), (.etf, "510300"), (.fund, "110022.OF"), (.future, "RB2701.SHF"), (.option, "10012189.SH"), (.wealth, "PRODUCT")] {
            var book = InvestmentBook()
            let id = try book.register(.init(name: "自动行情", code: code, market: "", kind: kind, currency: .cny))
            book.addQuotes([.init(day: date(1), price: 10, source: "东方财富", isDailyClose: true)], assetID: id)
            book.addQuotes([.init(day: date(1), price: 99, source: "手动录入")], assetID: id)
            precondition(book.quote(id, on: date(1))?.price == 10 && book.quote(id, on: date(1))?.source == "东方财富")
        }
    }

    static func date(_ day: Int) -> Date {
        InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 10, day: day))!
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw InvestmentError.invalid("Missing test value") }
        return value
    }
}
