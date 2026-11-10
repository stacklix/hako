import Foundation

struct InvestmentDailySnapshots: Codable {
    var through: Date
    var values: [Date: InvestmentValuation]
    var hasUSD: Bool? = nil
    var accountValues: [UUID: [Date: InvestmentAccountDay]]? = nil
}

struct InvestmentAccountDay: Codable {
    let cash: Decimal
    let holdings: Decimal?
    let gain: Decimal?
}

struct InvestmentSnapshotQuoteRequests {
    var assets: [UUID: [ClosedRange<Date>]] = [:]
    var rates: [InvestmentCurrency: [ClosedRange<Date>]] = [:]
}

extension InvestmentAsset {
    var usesUSEquityClose: Bool { currency == .usd && (kind == .stock || kind == .etf) }
}

struct InvestmentDailySnapshotReport {
    let day: Date
    let saved: Int
    let missing: Int
    let includesDay: Bool
    var latest: InvestmentValuation? = nil
    var missingExamples: [Date] = []
    var missingUSD = 0

    var totals: String {
        let cny = latest?.value.formatted(.currency(code: "CNY")) ?? "—"
        let usd = latest?.valueUSD?.formatted(.currency(code: "USD")) ?? "—"
        return "折算人民币总额 \(cny)\n折算美元总额 \(usd)"
    }

    var message: String {
        if saved == 0, missing == 0 { return "暂无已结束的记账日。" }
        var result = "已保存 \(saved) 天的日终快照。"
        if missing > 0 {
            let formatter = InvestmentBook.snapshotDateFormatter()
            let dates = missingExamples.map { formatter.string(from: $0) }.joined(separator: "、")
            result += "\(missing) 天缺少完整的估值数据\(dates.isEmpty ? "" : "，包括 " + dates)。"
        }
        if missingUSD > 0 { result += "\(missingUSD) 天缺少美元折算汇率。" }
        return result
    }
}

extension InvestmentBook {
    static func snapshotDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func usEquityClose(on sessionDay: Date) -> Date {
        var exchange = Calendar(identifier: .gregorian)
        exchange.timeZone = TimeZone(identifier: "America/New_York")!
        var date = calendar.dateComponents([.year, .month, .day], from: sessionDay)
        date.hour = 16
        return exchange.date(from: date) ?? addDays(1, to: sessionDay)
    }

    mutating func invalidateDailySnapshots(from day: Date) {
        guard var snapshots = dailySnapshots, day <= snapshots.through else { return }
        snapshots.through = Self.addDays(-1, to: day)
        snapshots.values = snapshots.values.filter { $0.key < day }
        snapshots.accountValues = snapshots.accountValues?.mapValues { $0.filter { $0.key < day } }
        dailySnapshots = snapshots
    }

    func needsDailySnapshots(through day: Date) -> Bool {
        guard let earliest, earliest <= day else { return false }
        return dailySnapshots.map { $0.through < day || $0.hasUSD != true } ?? true
    }

    func snapshotStart(rebuild: Bool) -> Date? {
        guard let earliest else { return nil }
        let existing = rebuild || dailySnapshots?.hasUSD != true ? nil : dailySnapshots
        let start = max(earliest, existing.map { Self.addDays(1, to: $0.through) } ?? earliest)
        return start
    }

    func makeDailySnapshots(through end: Date, rebuild: Bool) -> InvestmentDailySnapshots? {
        guard let start = snapshotStart(rebuild: rebuild), start <= end else { return nil }
        let keepExisting = !rebuild && dailySnapshots?.hasUSD == true
        var accounts = keepExisting ? dailySnapshots?.accountValues ?? [:] : [:]
        let history = portfolioHistory(on: Self.days(in: start...end), requiresDailyPrices: true) { date, id, value in
            accounts[id, default: [:]][date] = value
        }
        guard !Task.isCancelled else { return nil }
        var values = rebuild || dailySnapshots?.hasUSD != true ? [:] : dailySnapshots?.values ?? [:]
        for (day, var valuation) in history {
            valuation.valueUSD = valuation.value == 0 ? 0 :
                rateToCNY(.usd, on: day, requiresDailyPrice: true).map { valuation.value / $0 }
            values[day] = valuation
        }
        return InvestmentDailySnapshots(through: end, values: values, hasUSD: true, accountValues: accounts)
    }

    func dailySnapshotReport(through day: Date) -> InvestmentDailySnapshotReport {
        guard let earliest, earliest <= day else {
            return InvestmentDailySnapshotReport(day: day, saved: 0, missing: 0, includesDay: false)
        }
        let count = (Self.calendar.dateComponents([.day], from: earliest, to: day).day ?? 0) + 1
        let values = dailySnapshots?.values ?? [:]
        let saved = values.filter { $0.key >= earliest && $0.key <= day }
        var examples: [Date] = []
        if saved.count < count {
            var date = earliest
            while date <= day, examples.count < 3 {
                if values[date] == nil { examples.append(date) }
                date = Self.addDays(1, to: date)
            }
        }
        return InvestmentDailySnapshotReport(day: day, saved: saved.count, missing: count - saved.count,
                                             includesDay: values[day] != nil, latest: values[day],
                                             missingExamples: examples, missingUSD: saved.values.filter { $0.valueUSD == nil }.count)
    }

    func dailyPortfolio(on dates: [Date]) -> [Date: InvestmentValuation] {
        if usesServerSnapshots {
            let today = Self.day()
            var result = portfolioHistory(on: dates.filter { $0 >= today }, requiresDailyPrices: true)
            for day in dates where day < today { result[day] = dailySnapshots?.values[day] }
            return result
        }
        guard let snapshots = dailySnapshots, let earliest else {
            return portfolioHistory(on: dates, requiresDailyPrices: true)
        }
        let pending = dates.filter { $0 < earliest || $0 > snapshots.through }
        var result = portfolioHistory(on: pending, requiresDailyPrices: true)
        for day in dates where day >= earliest && day <= snapshots.through {
            result[day] = snapshots.values[day]
        }
        return result
    }

    func dailyQuoteWindow(through end: Date, fullHistory: Bool = false) -> ClosedRange<Date>? {
        guard let earliest, earliest <= end else { return nil }
        guard !fullHistory, let snapshots = dailySnapshots, snapshots.hasUSD == true else { return earliest...end }
        let next = max(earliest, Self.addDays(1, to: snapshots.through))
        let recent = max(earliest, Self.addDays(-6, to: end))
        let firstGap = Self.missingQuoteWindow(in: recent...end) { day in
            snapshots.values[day]?.valueUSD != nil
        }?.lowerBound
        let start = min(next, firstGap ?? next)
        return start <= end ? start...end : nil
    }

    func missingDailyMarketData(in window: ClosedRange<Date>) -> InvestmentSnapshotQuoteRequests {
        var requests = InvestmentSnapshotQuoteRequests()
        func includeAsset(_ id: UUID, on day: Date) {
            guard let asset = assets[id], !asset.kind.isManual || asset.kind == .cryptoContract,
                  positionQuote(for: asset, on: day, requiresDailyPrices: true) == nil else { return }
            // The session closing on this Beijing day may be Friday in New York.
            let continuous = asset.kind == .crypto || asset.kind == .cryptoContract
            let marketDay = asset.usesUSEquityClose ? Self.addDays(-1, to: day) : day
            let first = continuous ? marketDay : Self.weekdayMarketDate(on: marketDay)
            let last = asset.usesUSEquityClose ? first : marketDay
            Self.addQuoteWindow(first...last, to: &requests.assets[id, default: []])
        }
        visitDailyLedgers(on: Self.days(in: window)) { day, ledgers in
            var currencies = Set<InvestmentCurrency>()
            for (account, ledger) in zip(accounts, ledgers) {
                if ledger.cash != 0 || ledger.flows != 0 {
                    currencies.insert(account.currency)
                    currencies.insert(.usd)
                }
                for (id, position) in ledger.positions {
                    if position.quantity != 0 || position.realized != 0 { currencies.insert(account.currency) }
                    guard position.quantity != 0, let asset = assets[id] else { continue }
                    currencies.insert(.usd)
                    if asset.isStockConnect { currencies.insert(.hkd) }
                    if position.settledDay != day { includeAsset(id, on: day) }
                    if let collateral = asset.collateralAssetID { includeAsset(collateral, on: day) }
                }
            }
            for currency in currencies where rateToCNY(currency, on: day, requiresDailyPrice: true) == nil {
                Self.addQuoteWindow(Self.weekdayMarketDate(on: day)...day, to: &requests.rates[currency, default: []])
            }
        }
        return requests
    }

    static func addQuoteWindow(_ range: ClosedRange<Date>, to ranges: inout [ClosedRange<Date>]) {
        if let previous = ranges.last, range.lowerBound <= addDays(1, to: previous.upperBound) {
            ranges[ranges.count - 1] = min(previous.lowerBound, range.lowerBound)...max(previous.upperBound, range.upperBound)
        } else {
            ranges.append(range)
        }
    }

    private static func days(in window: ClosedRange<Date>) -> [Date] {
        let count = calendar.dateComponents([.day], from: window.lowerBound, to: window.upperBound).day ?? 0
        return (0...count).map { addDays($0, to: window.lowerBound) }
    }

    static func weekdayMarketDate(on day: Date) -> Date {
        switch calendar.component(.weekday, from: day) {
        case 1: addDays(-2, to: day)
        case 7: addDays(-1, to: day)
        default: day
        }
    }

    static func missingQuoteWindow(in window: ClosedRange<Date>, hasValue: (Date) -> Bool) -> ClosedRange<Date>? {
        var first: Date?
        var last: Date?
        var day = window.lowerBound
        while day <= window.upperBound {
            if !hasValue(day) {
                first = first ?? day
                last = day
            }
            day = Self.addDays(1, to: day)
        }
        guard let first, let last else { return nil }
        return first...last
    }
}
