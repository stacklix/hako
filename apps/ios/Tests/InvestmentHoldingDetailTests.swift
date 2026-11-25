import Foundation

@main struct InvestmentHoldingDetailTests {
    static func day(_ n: Int) -> Date { InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: n + 1))! }

    static func main() throws {
        try profitIncludesSalesFeesDividendsAndBonusShares()
        try profitKeepsGapsAndUsesSettlementCurrency()
        try depositsAndManualAssetsHaveProfitWithoutMarketHistory()
        try spotBalanceEditsPreserveSameDayOrderAndPrecision()
        print("Investment holding details: cumulative profit, cash flows, gaps, balance edits and deletion passed")
    }

    static func depositsAndManualAssetsHaveProfitWithoutMarketHistory() throws {
        for kind in [InvestmentKind.deposit, .certificate] {
            let owner = InvestmentAccount(name: "存款", currency: .cny, type: .deposits)
            var book = InvestmentBook(accounts: [owner])
            let id = try book.register(.init(name: "存款", code: "DEPOSIT", market: "", kind: kind, currency: .cny,
                                            depositTerms: .init(annualRate: Decimal(string: "0.02")!, maturity: day(15))))
            try book.post(.init(day: day(1), kind: .opening, assetID: id, quantity: 1, price: 130, settledAmount: 130), accountID: owner.id)
            try book.post(.init(day: day(2), kind: .adjustment, assetID: id, settledAmount: 133), accountID: owner.id)
            try book.post(.init(day: day(3), kind: .income, assetID: id, amount: 3, settledAmount: 130), accountID: owner.id)
            try book.post(.init(day: day(4), kind: .sell, assetID: id, quantity: 1, price: 40, settledAmount: 92), accountID: owner.id)
            try book.post(.init(day: day(5), kind: .sell, assetID: id, quantity: 1, price: 93, settledAmount: 0), accountID: owner.id)
            let history = book.profitHistory(accountID: owner.id, assetID: id, on: (0...6).map(day), today: day(6))
            precondition(history.map(\.value) == [0, 0, 3, 3, 5, 6, 6], "Interest payout must not double count income; full withdrawal preserves realized profit")
            precondition(book.quotes[id]?.isEmpty != false, "Balance-based assets need no market quotes")
            precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [day(6)], today: day(6)).first?.value == 6)
        }
        for kind in [InvestmentKind.wealth, .insurance, .generic] {
            let currency: InvestmentCurrency = kind == .insurance ? .hkd : (kind == .generic ? .usd : .cny)
            let type: InvestmentAccountType = kind == .insurance ? .insurance : (kind == .generic ? .crypto : .fundWealth)
            let owner = InvestmentAccount(name: "手动估值", currency: currency, type: type)
            var book = InvestmentBook(accounts: [owner])
            let id = try book.register(.init(name: "手动估值", code: "MANUAL", market: "", kind: kind, currency: currency))
            try book.post(.init(day: day(1), kind: .opening, assetID: id, quantity: 1, price: 100,
                                settledAmount: kind == .wealth ? 100 : nil), accountID: owner.id)
            if kind.usesBalance {
                try book.post(.init(day: day(2), kind: .adjustment, assetID: id, settledAmount: 110), accountID: owner.id)
            } else {
                book.addQuotes([.init(day: day(1), price: 100, source: "手动录入"),
                                .init(day: day(2), price: 110, source: "手动录入")], assetID: id)
            }
            let history = book.profitHistory(accountID: owner.id, assetID: id, on: [day(1), day(2), day(3)], today: day(4))
            precondition(history.map(\.value) == [0, 10, 10], "Manual valuations carry forward without daily market prices")
        }
    }

    static func profitIncludesSalesFeesDividendsAndBonusShares() throws {
        let owner = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "股票", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        try book.post(.init(day: day(1), kind: .opening, assetID: id, quantity: 10, price: 10), accountID: owner.id)
        let opening = book.accounts[0].events.last!
        try book.post(.init(day: day(2), kind: .sell, assetID: id, quantity: 2, price: 12, fee: 1), accountID: owner.id)
        let sale = book.accounts[0].events.last!
        try book.recordDistribution(assetID: id, accountID: owner.id, cash: 5, on: day(2))
        let dividend = book.accounts[0].events.last!
        try book.recordDistribution(assetID: id, accountID: owner.id, cash: 0, shares: 2, on: day(3))
        let bonus = book.accounts[0].events.last!
        try book.post(.init(day: day(4), kind: .sell, assetID: id, quantity: 10, price: 11, fee: 2), accountID: owner.id)
        let closing = book.accounts[0].events.last!
        book.addQuotes([(1, 10), (2, 12), (3, 11), (4, 11)].map { .init(day: day($0.0), price: Decimal($0.1), isDailyClose: true) }, assetID: id)
        precondition(book.cashChange(for: opening, accountID: owner.id) == 0)
        precondition(book.cashChange(for: sale, accountID: owner.id) == 23)
        precondition(book.cashChange(for: dividend, accountID: owner.id) == 5)
        precondition(book.cashChange(for: bonus, accountID: owner.id) == 0)
        let full = book.profitHistory(accountID: owner.id, assetID: id, on: (0...5).map(day), today: day(5))
        precondition(full.map(\.value) == [0, 0, 24, 38, 36, 36])
        let slice = book.profitHistory(accountID: owner.id, assetID: id, on: [day(3), day(4)], today: day(5))
        precondition(slice.map(\.value) == [38, 36], "A time filter cannot reset lifetime gain")
        book.dailySnapshots = .init(through: day(5), values: [:])
        try book.deleteEvent(closing, accountID: owner.id, today: day(5))
        precondition(book.dailySnapshots?.through == day(3))
        precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [day(4)], today: day(5)).first?.value == 38)
        try book.deleteEvent(dividend, accountID: owner.id, today: day(5))
        precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [day(4)], today: day(5)).first?.value == 33)
    }

    static func profitKeepsGapsAndUsesSettlementCurrency() throws {
        let owner = InvestmentAccount(name: "港股通", currency: .cny, type: .securities)
        let other = InvestmentAccount(name: "另一账户", currency: .usd, events: [.init(day: day(1), kind: .dividend, assetID: UUID(), amount: 1)], type: .crypto)
        var book = InvestmentBook(accounts: [owner, other])
        let id = try book.register(.init(name: "腾讯", code: "00700.HK", market: InvestmentAsset.stockConnectMarket, kind: .stock, currency: .hkd))
        try book.post(.init(day: day(1), kind: .opening, assetID: id, quantity: 10, price: 10, settledAmount: 90), accountID: owner.id)
        book.addQuotes((1...3).map { .init(day: day($0), price: $0 == 3 ? 12 : 10, isDailyClose: true) }, assetID: id)
        book.addExchangeRates([.init(day: day(1), price: Decimal(string: "0.9")!, isDailyClose: true),
                               .init(day: day(3), price: Decimal(string: "0.8")!, isDailyClose: true)], for: .hkd)
        let history = book.profitHistory(accountID: owner.id, assetID: id, on: [day(1), day(2), day(3)], today: day(4))
        precondition(history.map(\.day) == [day(1), day(2), day(3)] && history.map(\.value) == [0, 0, 6])
        precondition(Set(history.map(\.segment)).count == 1, "A missing daily FX observation must carry forward")
        book.fx[.hkd] = (1...3).map { .init(day: day($0), price: 1, isDailyClose: true) }
        book.quotes[id] = [.init(day: day(1), price: 10, isDailyClose: true), .init(day: day(3), price: 12, isDailyClose: true)]
        let missingPrice = book.profitHistory(accountID: owner.id, assetID: id, on: [day(1), day(2), day(3)], today: day(4))
        precondition(missingPrice.map(\.day) == [day(1), day(2), day(3)] && missingPrice.map(\.value) == [10, 10, 30])
        precondition(Set(missingPrice.map(\.segment)).count == 1)
        book.quotes[id] = [.init(day: day(3), price: 12, isDailyClose: true)]
        let noEarlierPrice = book.profitHistory(accountID: owner.id, assetID: id, on: [day(1), day(2), day(3)], today: day(4))
        precondition(noEarlierPrice.map(\.day) == [day(3)], "Future prices must not fill earlier gaps")
    }

    static func spotBalanceEditsPreserveSameDayOrderAndPrecision() throws {
        let owner = InvestmentAccount(name: "现货", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try book.post(.init(day: day(1), kind: .opening, assetID: id, quantity: 10, price: 1), accountID: owner.id)
        try book.adjustSpotBalance(assetID: id, accountID: owner.id, balance: 12, on: day(3))
        let first = book.accounts[0].events.last!
        try book.adjustSpotBalance(assetID: id, accountID: owner.id, balance: 11, on: day(3))
        let second = book.accounts[0].events.last!
        precondition(book.positionBefore(first, accountID: owner.id)?.quantity == 10)
        precondition(book.positionBefore(second, accountID: owner.id)?.quantity == 12)
        precondition(book.cashChange(for: first, accountID: owner.id) == 0)
        do {
            _ = try book.spotBalanceReplacement(first, accountID: owner.id,
                balance: Decimal(string: "9.9876543210987654321")!, on: day(3))
            preconditionFailure("Balance edits must reject more than three decimal places")
        } catch is InvestmentError { }
        let exact = Decimal(string: "9.987")!
        let edited = try book.spotBalanceReplacement(first, accountID: owner.id, balance: exact, on: day(3))
        precondition(edited.kind == .spotAdjustment && edited.quantity == exact - 10)
        try book.replaceEvent(first, with: edited, accountID: owner.id, today: day(5))
        let corrected = try book.ledger(book.accounts[0], through: day(5))
        precondition(corrected.positions[id]?.quantity == exact - 1)
        let current = book.accounts[0].events.first { $0.id == first.id }!
        let moved = try book.spotBalanceReplacement(current, accountID: owner.id, balance: 10, on: day(4))
        precondition(moved.kind == .stakingReward && moved.quantity == 1, "Moving past another adjustment must exclude the original record")
        book.dailySnapshots = .init(through: day(5), values: [:])
        try book.replaceEvent(current, with: moved, accountID: owner.id, today: day(5))
        precondition(book.dailySnapshots?.through == day(2))
        let movedLedger = try book.ledger(book.accounts[0], through: day(5))
        precondition(movedLedger.positions[id]?.quantity == 10)
        do { _ = try book.spotBalanceReplacement(current, accountID: owner.id, balance: 9, on: day(4)); preconditionFailure("Stale record") }
        catch is InvestmentError { }
        book.addQuotes((1...5).map { .init(day: day($0), price: 1, isDailyClose: true) }, assetID: id)
        precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [day(3), day(4)], today: day(5)).map(\.value) == [-1, 0])
        try book.deleteEvent(second, accountID: owner.id, today: day(5))
        precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [day(4)], today: day(5)).first?.value == 1)
    }
}
