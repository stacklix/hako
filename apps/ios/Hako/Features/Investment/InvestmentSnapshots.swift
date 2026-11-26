import Foundation

struct InvestmentDataIssue: Identifiable, Sendable {
    enum Level: String, Sendable { case error = "影响计算", notice = "请留意" }
    let id: Int
    let level: Level
    let title: String
    let location: String
    let detail: String
    var dates: [Date]

    var dateRanges: String {
        let formatter = InvestmentBook.snapshotDateFormatter()
        var ranges: [(Date, Date)] = []
        for date in Set(dates).sorted() {
            if let last = ranges.last, InvestmentBook.addDays(1, to: last.1) == date {
                ranges[ranges.count - 1].1 = date
            } else { ranges.append((date, date)) }
        }
        return ranges.map { start, end in
            formatter.string(from: start) + (start == end ? "" : " 至 " + formatter.string(from: end))
        }.joined(separator: "；")
    }
}

struct InvestmentDataReport: Sendable {
    let checkedAt: Date
    let firstDay: Date?
    let lastDay: Date
    let accounts: Int
    let events: Int
    let snapshotDays: Int
    let latestSnapshotDay: Date?
    let missingSnapshotDays: Int
    var snapshotDirtyFrom: Date? = nil
    var issues: [InvestmentDataIssue]
    var errors: Int { issues.filter { $0.level == .error }.count }
    var notices: Int { issues.filter { $0.level == .notice }.count }
}

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
    var usesPublishedFundNAV: Bool { kind == .fund && currency == .cny && mainlandSymbol?.venue == "OF" }

    var usesUSEquityClose: Bool { currency == .usd && (kind == .stock || kind == .etf) }

    func marketClose(on sessionDay: Date) -> Date {
        if usesUSEquityClose { return InvestmentBook.usEquityClose(on: sessionDay) }
        let hour = kind == .crypto ? 24 : (isHongKongEquity || isStockConnect ? 16 : 15)
        return InvestmentBook.calendar.date(byAdding: .hour, value: hour, to: InvestmentBook.day(sessionDay))!
    }

    func lastClosedMarketDay(at now: Date) -> Date {
        var day = InvestmentBook.day(now)
        if usesUSEquityClose || kind == .crypto { day = InvestmentBook.addDays(-1, to: day) }
        if marketClose(on: day) > now { day = InvestmentBook.addDays(-1, to: day) }
        return kind == .crypto ? day : InvestmentBook.weekdayMarketDate(on: day)
    }
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
        if let snapshots = dailySnapshots, snapshots.through >= day, snapshots.hasUSD == true { return false }
        guard let earliest, earliest <= day else { return false }
        return true
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
        var accountValues: [UUID: [Date: InvestmentAccountDay]] = [:]
        if keepExisting {
            for account in accounts {
                guard let first = account.earliest,
                      let history = dailySnapshots?.accountValues?[account.id] else { continue }
                accountValues[account.id] = history.filter { $0.key >= first && $0.key <= end }
            }
        }
        let history = portfolioHistory(on: Self.days(in: start...end), requiresDailyPrices: true) { date, id, value in
            accountValues[id, default: [:]][date] = value
        }
        guard !Task.isCancelled else { return nil }
        var values = rebuild || dailySnapshots?.hasUSD != true ? [:] : dailySnapshots?.values ?? [:]
        for (day, var valuation) in history {
            valuation.valueUSD = valuation.value == 0 ? 0 :
                rateToCNY(.usd, on: day, requiresDailyPrice: true).map { valuation.value / $0 }
            values[day] = valuation
        }
        return InvestmentDailySnapshots(through: end, values: values, hasUSD: true, accountValues: accountValues)
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

    func historicalMarketDataRequests(through end: Date, fullHistory: Bool,
                                      includePlans: Bool = false, notBefore first: Date? = nil,
                                      closedMarketsAt now: Date? = nil) -> InvestmentSnapshotQuoteRequests {
        let window = dailyQuoteWindow(through: end, fullHistory: fullHistory).flatMap { range -> ClosedRange<Date>? in
            let start = max(first ?? range.lowerBound, range.lowerBound)
            return start <= range.upperBound ? start...range.upperBound : nil
        }
        var requests = window.map { missingDailyMarketData(in: $0) } ?? InvestmentSnapshotQuoteRequests()
        // Snapshot completeness is independent of whether yesterday's FX was
        // finalized. Both app entry and Shortcuts must check this even with no gaps.
        if let earliest, earliest <= end {
            let last = Self.weekdayMarketDate(on: end)
            var currencies = Set(accounts.map(\.currency)).union([.usd])
            if assets.values.contains(where: \.isStockConnect) { currencies.insert(.hkd) }
            for currency in currencies where currency != .cny {
                var pending = (fx[currency] ?? []).filter {
                    $0.day >= earliest && $0.day <= last && $0.isDailyClose != true
                }.map { $0.day...$0.day }
                if last >= earliest, !(fx[currency] ?? []).contains(where: {
                    $0.day == last && $0.price > 0 && $0.isDailyClose == true
                }) { pending.append(last...last) }
                let ranges = requests.rates[currency, default: []] + pending
                requests.rates[currency] = []
                for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    Self.addQuoteWindow(range, to: &requests.rates[currency, default: []])
                }
                if requests.rates[currency]?.isEmpty == true { requests.rates.removeValue(forKey: currency) }
            }
        }
        if includePlans {
            for plan in plans.sorted(by: { $0.nextDay < $1.nextDay }) {
                guard plan.enabled, plan.nextDay <= end,
                      let account = account(plan.accountID), !account.isArchived else { continue }
                // New deposits and first purchases can introduce valuation needs before any ledger exists.
                let first = Self.weekdayMarketDate(on: plan.nextDay)
                for currency in Set([account.currency, .usd]) where currency != .cny {
                    let ranges = requests.rates[currency, default: []] + [first...end]
                    requests.rates[currency] = []
                    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                        Self.addQuoteWindow(range, to: &requests.rates[currency, default: []])
                    }
                }
                if let id = plan.assetID, let asset = assets[id], asset.supportsPlan {
                    let session = asset.usesUSEquityClose ? Self.addDays(-1, to: plan.nextDay) : plan.nextDay
                    let ranges = requests.assets[id, default: []] + [Self.weekdayMarketDate(on: session)...end]
                    requests.assets[id] = []
                    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                        Self.addQuoteWindow(range, to: &requests.assets[id, default: []])
                    }
                }
            }
        }
        if let first {
            func bounded(_ ranges: [ClosedRange<Date>], weekdaysOnly: Bool = false) -> [ClosedRange<Date>]? {
                let result = ranges.compactMap { range -> ClosedRange<Date>? in
                    var start = max(first, range.lowerBound)
                    let last = min(end, range.upperBound)
                    if weekdaysOnly {
                        while [1, 7].contains(Self.calendar.component(.weekday, from: start)) {
                            start = Self.addDays(1, to: start)
                        }
                    }
                    return start <= last ? start...last : nil
                }
                return result.isEmpty ? nil : result
            }
            requests.assets = requests.assets.compactMapValues { bounded($0) }
            requests.rates = requests.rates.compactMapValues { bounded($0, weekdaysOnly: true) }
        }
        if let now {
            let today = Self.day(now)
            var ids = Set<UUID>()
            visitDailyLedgers(on: [today]) { _, ledgers in
                for (account, ledger) in zip(accounts, ledgers) where !account.isArchived {
                    for (id, position) in ledger.positions where position.quantity != 0 { ids.insert(id) }
                }
            }
            if includePlans {
                for plan in plans where plan.enabled && plan.nextDay <= today {
                    if let id = plan.assetID, let account = account(plan.accountID), !account.isArchived { ids.insert(id) }
                }
            }
            for id in ids {
                guard let asset = assets[id], !asset.kind.isManual else { continue }
                let session = asset.lastClosedMarketDay(at: now)
                guard first.map({ session >= $0 }) ?? true,
                      !(quotes[id] ?? []).contains(where: { $0.day == session && $0.price > 0 && $0.isDailyClose == true }) else { continue }
                // Valuation may carry an earlier price, but that does not fill the latest session's quote.
                let ranges = requests.assets[id, default: []] + [session...session]
                requests.assets[id] = []
                for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    Self.addQuoteWindow(range, to: &requests.assets[id, default: []])
                }
            }
        }
        return requests
    }

    func missingDailyMarketData(in window: ClosedRange<Date>) -> InvestmentSnapshotQuoteRequests {
        var requests = InvestmentSnapshotQuoteRequests()
        func includeAsset(_ id: UUID, on day: Date) {
            guard let asset = assets[id], !asset.kind.isManual,
                  positionQuote(for: asset, on: day, requiresDailyPrices: true) == nil else { return }
            // The session closing on this Beijing day may be Friday in New York.
            let continuous = asset.kind == .crypto
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


extension InvestmentBook {
    // Compare source records rather than relying on a cached snapshot cutoff. The cache
    // can already be truncated or absent when a holding is deleted and registered again.
    func snapshotInputChange(comparedTo previous: InvestmentBook) -> Date? {
        var first: Date?
        func include(_ day: Date?) {
            if let day { first = min(first ?? day, day) }
        }
        let oldAccounts = Dictionary(uniqueKeysWithValues: previous.accounts.map { ($0.id, $0) })
        let newAccounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for id in Set(oldAccounts.keys).union(newAccounts.keys) {
            let old = oldAccounts[id], new = newAccounts[id]
            let before = Dictionary(uniqueKeysWithValues: (old?.events ?? []).map { ($0.id, $0) })
            let after = Dictionary(uniqueKeysWithValues: (new?.events ?? []).map { ($0.id, $0) })
            for eventID in Set(before.keys).union(after.keys) where before[eventID] != after[eventID] {
                include(before[eventID]?.day)
                include(after[eventID]?.day)
            }
            if old?.currency != new?.currency || old?.type != new?.type {
                include(old?.events.map(\.day).min())
                include(new?.events.map(\.day).min())
            }
        }
        for id in Set(assets.keys).union(previous.assets.keys) where assets[id] != previous.assets[id] {
            include((accounts + previous.accounts).flatMap(\.events).filter { $0.assetID == id }.map(\.day).min())
        }
        return first
    }
}
