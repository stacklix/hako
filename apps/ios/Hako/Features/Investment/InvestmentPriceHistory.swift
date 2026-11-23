import Foundation

enum InvestmentHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case yearToDate = "今年", all = "建仓后", month = "近一月", quarter = "近三月", half = "近半年"
    case year = "近一年", twoYears = "近两年", fiveYears = "近五年"
    var id: Self { self }
    static let trend: [Self] = [.yearToDate, .month, .quarter, .half, .year, .twoYears, .fiveYears]

    func start(through today: Date, firstEntry: Date) -> Date {
        let today = InvestmentBook.day(today)
        let months: Int
        switch self {
        case .yearToDate: return InvestmentBook.calendar.dateInterval(of: .year, for: today)?.start ?? today
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
    static func uncoveredWindows(from start: Date, through end: Date, cached: [InvestmentQuote]) -> [ClosedRange<Date>] {
        let valid = cached.filter { $0.isDailyClose == true && $0.day <= end }.sorted { $0.day < $1.day }
        guard let first = valid.first, let last = valid.last else { return [start...end] }
        var result: [ClosedRange<Date>] = []
        if first.day > start { result.append(start...InvestmentBook.addDays(-1, to: first.day)) }
        if last.day < end { result.append(max(start, InvestmentBook.addDays(1, to: last.day))...end) }
        return result
    }

    // Subtract each persisted observation and completed query, including internal gaps.
    static func missingWindows(from start: Date, through end: Date, observations: [InvestmentQuote],
                               covered: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        guard start <= end else { return [] }
        let days = observations.filter { $0.price > 0 && $0.isDailyClose != false }.map { $0.day...$0.day }
        let ranges = (covered + days).sorted { $0.lowerBound < $1.lowerBound }
        var cursor = start
        var missing: [ClosedRange<Date>] = []
        for range in ranges where range.upperBound >= cursor && range.lowerBound <= end {
            if range.lowerBound > cursor {
                missing.append(cursor...min(end, InvestmentBook.addDays(-1, to: range.lowerBound)))
            }
            cursor = max(cursor, InvestmentBook.addDays(1, to: range.upperBound))
            if cursor > end { return missing }
        }
        if cursor <= end { missing.append(cursor...end) }
        return missing
    }

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
