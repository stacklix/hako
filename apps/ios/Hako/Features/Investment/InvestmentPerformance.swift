import Foundation

struct InvestmentPerformanceSample: Identifiable, Sendable {
    let day: Date
    let value: Decimal?
    let gain: Decimal?
    let flow: Decimal?
    var rate: Decimal? = nil
    var id: Date { day }
}

struct InvestmentPerformanceCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let assetID: UUID?
    let samples: [InvestmentPerformanceSample]

    func detail(on day: Date) -> InvestmentPerformanceDetail? {
        guard let first = samples.first, let last = samples.last(where: { $0.day <= day }) else { return nil }
        return InvestmentPerformanceDetail(id: id, name: name, assetID: assetID, value: last.value,
            change: first.value.flatMap { start in last.value.map { $0 - start } },
            gain: last.gain, periodGain: first.gain.flatMap { start in last.gain.map { $0 - start } },
            rate: last.rate, cumulativeRate: last.value.flatMap { value in
                last.gain.flatMap { gain in value - gain > 0 ? gain / (value - gain) : nil }
            })
    }
}

struct InvestmentPerformanceDetail: Identifiable, Sendable {
    let id: String
    let name: String
    let assetID: UUID?
    let value: Decimal?
    let change: Decimal?
    let gain: Decimal?
    let periodGain: Decimal?
    let rate: Decimal?
    let cumulativeRate: Decimal?
}

struct InvestmentPerformanceHistory: Sendable {
    let currency: InvestmentCurrency
    let samples: [InvestmentPerformanceSample]
    let categories: [InvestmentPerformanceCategory]

    static func normalized(_ samples: [InvestmentPerformanceSample]) -> [InvestmentPerformanceSample] {
        var previous: InvestmentPerformanceSample?
        var unit: Decimal?
        var broken = false
        return samples.map { input in
            var sample = input
            defer { previous = input }
            guard !broken, let value = input.value, input.gain != nil else { broken = true; return sample }
            if let before = previous {
                guard let old = before.value else { broken = true; return sample }
                if let current = unit {
                    if old == 0, value == 0, input.flow == 0 {
                        sample.rate = current - 1
                        return sample
                    }
                    guard old > 0, let flow = input.flow else { broken = true; return sample }
                    unit = current * ((value - flow) / old)
                } else if old == 0, value > 0 {
                    // No capital existed before this first funded closing valuation.
                    unit = 1
                } else if old != 0 || value < 0 {
                    broken = true
                }
            } else if value > 0 {
                unit = 1
            } else if value < 0 {
                broken = true
            }
            sample.rate = unit.map { $0 - 1 }
            return sample
        }
    }
}

extension InvestmentBook {
    /// Read source ledgers once per requested day. Existing server snapshots remain
    /// authoritative for historical account/portfolio amounts; gaps are not filled.
    func performanceHistory(accountID: UUID? = nil, from requested: Date, through today: Date) -> InvestmentPerformanceHistory {
        let target = accountID.flatMap { account($0) }
        let currency = target?.currency ?? .cny
        let earliest = accountID == nil ? self.earliest : target?.earliest
        guard let earliest, earliest <= today else {
            return .init(currency: currency, samples: [], categories: [])
        }
        let start = max(earliest, Self.day(requested))
        guard start <= today else { return .init(currency: currency, samples: [], categories: []) }
        var dates: [Date] = []
        var date = start
        while date <= today, !Task.isCancelled { dates.append(date); date = Self.addDays(1, to: date) }
        var scoped = self
        if let target { scoped.accounts = [target] }
        let accountStarts = scoped.accounts.map(\.earliest)
        let portfolio = accountID == nil ? dailyPortfolio(on: dates.filter { $0 < today }) : [:]
        let assetIDs = target.map { account in
            Set(account.events.filter { $0.day <= today }.compactMap(\.assetID)).sorted { $0.uuidString < $1.uuidString }
        } ?? []
        var samples: [InvestmentPerformanceSample] = []
        var categorySamples: [String: [InvestmentPerformanceSample]] = [:]
        var previousFlows: [UUID: Decimal] = [:]
        var previousPositionNet: [String: Decimal] = [:]

        scoped.visitDailyLedgers(on: dates) { day, ledgers in
            var nativeValues: [InvestmentValuation?] = []
            var totalFlow: Decimal? = 0
            for (index, account) in scoped.accounts.enumerated() {
                let ledger = ledgers[index]
                let native: InvestmentValuation?
                if accountStarts[index].map({ day < $0 }) ?? true {
                    native = .init(value: 0, gain: 0)
                } else if day < today, usesServerSnapshots {
                    native = dailySnapshots?.accountValues?[account.id]?[day].flatMap { saved in
                        saved.holdings.flatMap { holdings in saved.gain.map { InvestmentValuation(value: saved.cash + holdings, gain: $0) } }
                    }
                } else {
                    native = scoped.value(ledger, on: day, requiresDailyPrices: day < today)
                }
                nativeValues.append(native)
                let change = previousFlows[account.id].map { ledger.flows - $0 } ?? 0
                previousFlows[account.id] = ledger.flows
                let flow = performanceConvert(change, from: account.currency, to: currency, on: day, today: today)
                totalFlow = totalFlow.flatMap { sum in flow.map { sum + $0 } }
                if accountID == nil {
                    let value = native.flatMap { performanceConvert($0.value, from: account.currency, to: .cny, on: day, today: today) }
                    let gain = native.flatMap { performanceConvert($0.gain, from: account.currency, to: .cny, on: day, today: today) }
                    categorySamples[account.id.uuidString, default: []].append(.init(day: day, value: value, gain: gain, flow: flow))
                }
            }
            let valuation = target != nil ? nativeValues.first.flatMap { $0 }
                : (day == today ? self.portfolio(on: day) : portfolio[day])
            samples.append(.init(day: day, value: valuation?.value, gain: valuation?.gain, flow: totalFlow))
            if target != nil, let ledger = ledgers.first {
                var invested: Decimal = 0
                for id in assetIDs {
                    let key = id.uuidString
                    let position = ledger.positions[id] ?? InvestmentPosition()
                    let net = position.netCost - position.realized
                    invested += net
                    let flow = previousPositionNet[key].map { net - $0 } ?? 0
                    previousPositionNet[key] = net
                    let value = self.asset(id).flatMap { scoped.positionValue(position, asset: $0, on: day, requiresDailyPrices: day < today) }
                    categorySamples[key, default: []].append(.init(day: day, value: value, gain: value.map { $0 - net }, flow: flow))
                }
                let net = ledger.flows - invested
                let key = "cash"
                let flow = previousPositionNet[key].map { net - $0 } ?? 0
                previousPositionNet[key] = net
                categorySamples[key, default: []].append(.init(day: day, value: ledger.cash, gain: ledger.cash - net, flow: flow))
            }
        }
        func completed(_ input: [InvestmentPerformanceSample]) -> [InvestmentPerformanceSample] {
            let known = Dictionary(uniqueKeysWithValues: input.map { ($0.day, $0) })
            return InvestmentPerformanceHistory.normalized(dates.map { day in
                known[day] ?? .init(day: day, value: nil, gain: nil, flow: nil)
            })
        }
        let categories: [InvestmentPerformanceCategory]
        if target != nil {
            categories = assetIDs.map { id in
                .init(id: id.uuidString, name: asset(id)?.displayName ?? "缺失标的", assetID: id,
                      samples: completed(categorySamples[id.uuidString] ?? []))
            } + [.init(id: "cash", name: "现金", assetID: nil,
                       samples: completed(categorySamples["cash"] ?? []))]
        } else {
            categories = scoped.accounts.map { account in
                .init(id: account.id.uuidString, name: account.name + (account.isArchived ? " · 已归档" : ""), assetID: nil,
                      samples: completed(categorySamples[account.id.uuidString] ?? []))
            }
        }
        return .init(currency: currency, samples: completed(samples), categories: categories)
    }

    private func performanceConvert(_ amount: Decimal, from source: InvestmentCurrency, to destination: InvestmentCurrency,
                                    on day: Date, today: Date) -> Decimal? {
        if amount == 0 || source == destination { return amount }
        guard let sourceRate = rateToCNY(source, on: day, requiresDailyPrice: day < today),
              let destinationRate = rateToCNY(destination, on: day, requiresDailyPrice: day < today) else { return nil }
        return amount * sourceRate / destinationRate
    }
}

struct InvestmentProfitRectangle: Sendable {
    let id: String
    let amount: Decimal
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func layout(_ values: [(String, Decimal)], width: Double, height: Double) -> [Self] {
        let values = values.filter { $0.1 != 0 && !$0.1.isNaN }.sorted { abs($0.1) > abs($1.1) }
        func split(_ items: [(String, Decimal)], x: Double, y: Double, width: Double, height: Double) -> [Self] {
            guard !items.isEmpty, width > 0, height > 0 else { return [] }
            if items.count == 1 { return [.init(id: items[0].0, amount: items[0].1, x: x, y: y, width: width, height: height)] }
            let sum = items.reduce(Decimal.zero) { $0 + abs($1.1) }
            var cumulative: Decimal = 0
            var best = sum
            var index = 1
            for i in 1..<items.count {
                cumulative += abs(items[i - 1].1)
                if abs(cumulative - sum / 2) < best { best = abs(cumulative - sum / 2); index = i }
            }
            let first = Array(items.prefix(index)), last = Array(items.dropFirst(index))
            let share = NSDecimalNumber(decimal: first.reduce(Decimal.zero) { $0 + abs($1.1) } / sum).doubleValue
            if width >= height {
                return split(first, x: x, y: y, width: width * share, height: height)
                    + split(last, x: x + width * share, y: y, width: width * (1 - share), height: height)
            }
            return split(first, x: x, y: y, width: width, height: height * share)
                + split(last, x: x, y: y + height * share, width: width, height: height * (1 - share))
        }
        return split(values, x: 0, y: 0, width: width, height: height)
    }
}
