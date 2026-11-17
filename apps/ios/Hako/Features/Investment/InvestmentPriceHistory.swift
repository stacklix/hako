import Foundation

enum InvestmentHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case all = "建仓后", month = "近1个月", quarter = "近3个月", half = "近半年"
    case year = "近1年", twoYears = "近2年", fiveYears = "近5年"
    var id: Self { self }

    func start(through today: Date, firstEntry: Date) -> Date {
        let today = InvestmentBook.day(today)
        let months: Int
        switch self {
        case .all: return InvestmentBook.day(firstEntry)
        case .month: months = 1
        case .quarter: months = 3
        case .half: months = 6
        case .year: months = 12
        case .twoYears: months = 24
        case .fiveYears: months = 60
        }
        return InvestmentBook.calendar.date(byAdding: .month, value: -months, to: today) ?? today
    }

    // Bound requests so a provider's per-response row limit cannot truncate long histories.
    static func quoteWindows(from start: Date, through end: Date) -> [ClosedRange<Date>] {
        var first = InvestmentBook.day(start)
        let end = InvestmentBook.day(end)
        var result: [ClosedRange<Date>] = []
        while first <= end {
            let last = min(InvestmentBook.addDays(364, to: first), end)
            result.append(first...last)
            first = InvestmentBook.addDays(1, to: last)
        }
        return result
    }
}

struct InvestmentPricePoint: Identifiable, Sendable {
    let day: Date
    let price: Decimal
    var id: Date { day }
}

struct InvestmentPriceHistoryResult {
    let quotes: [InvestmentQuote]
    let warning: String?
}

struct InvestmentPriceTrade: Identifiable, Sendable {
    let id: UUID
    let day: Date
    let price: Decimal
    let quantity: Decimal
    let isBuy: Bool
    let isOpening: Bool
}

enum InvestmentHoldingChartDisplay: Hashable { case price, holding, profit }

extension InvestmentAsset {
    var supportsPriceHistory: Bool { [.stock, .fund, .etf, .crypto].contains(kind) }
    var holdingChartDisplays: [InvestmentHoldingChartDisplay] {
        supportsPriceHistory ? [.price, .holding, .profit] : [.holding, .profit]
    }
}

extension InvestmentBook {
    func firstPositionDay(accountID: UUID, assetID: UUID) -> Date? {
        account(accountID)?.events.filter {
            $0.assetID == assetID && ($0.kind == .buy || $0.kind == .opening) && $0.quantity > 0
        }.map(\.day).min()
    }

    func priceTrades(accountID: UUID, assetID: UUID, in window: ClosedRange<Date>) -> [InvestmentPriceTrade] {
        guard let account = account(accountID) else { return [] }
        return orderedEvents(account, through: window.upperBound).compactMap { event in
            guard event.assetID == assetID, window.contains(event.day), event.price > 0, event.quantity > 0,
                  [.opening, .buy, .sell].contains(event.kind) else { return nil }
            return InvestmentPriceTrade(id: event.id, day: event.day, price: event.price, quantity: event.quantity,
                                        isBuy: event.kind != .sell, isOpening: event.kind == .opening)
        }
    }

    static func priceHistory(asset: InvestmentAsset, cached: [InvestmentQuote], fetched: [InvestmentQuote],
                             in window: ClosedRange<Date>) -> [InvestmentPricePoint] {
        guard asset.supportsPriceHistory else { return [] }
        // Manual estimates and intraday prices are not historical market closes.
        func closes(_ quotes: [InvestmentQuote]) -> [InvestmentQuote] {
            quotes.filter { $0.price > 0 && $0.isDailyClose == true && $0.source != "手动录入" }
        }
        return merge(closes(cached), closes(fetched)).compactMap { quote in
            let day = asset.usesUSEquityClose ? addDays(1, to: quote.day) : quote.day
            guard window.contains(day) else { return nil }
            return InvestmentPricePoint(day: day, price: quote.price)
        }
    }
}
