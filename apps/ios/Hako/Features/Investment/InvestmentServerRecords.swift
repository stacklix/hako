import Foundation

typealias InvestmentServerRow = [String: String]
typealias InvestmentServerTables = [String: [InvestmentServerRow]]

struct InvestmentServerState: Codable {
    var generation: Int64
    var revision: Int64
    var dirtyFrom: String?
    var through: String?
    var tables: InvestmentServerTables
}

struct InvestmentServerRecords {
    let day = InvestmentBook.snapshotDateFormatter()
    private let timestamp: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
    static let snapshotTables: Set<String> = [
        "investment_daily_snapshots", "investment_account_daily_snapshots", "investment_month_snapshots"
    ]
    static let names = [
        "market_instruments", "market_derivative_specs", "investment_accounts", "investment_assets",
        "investment_events", "investment_derivative_event_details", "investment_plans", "investment_plan_runs",
        "investment_watchlist", "market_daily_prices", "market_daily_fx", "investment_manual_prices",
        "investment_daily_snapshots", "investment_account_daily_snapshots", "investment_balance_accounts",
        "investment_balance_records", "investment_month_snapshots"
    ]
    private static let accountTypes: [InvestmentAccountType: String] = [
        .securities: "securities", .fund: "fund", .futures: "futures", .wealth: "wealth",
        .deposits: "deposits", .crypto: "crypto", .insurance: "insurance"
    ]
    private static let kinds: [InvestmentKind: String] = [
        .stock: "stock", .etf: "etf", .fund: "fund", .future: "future", .crypto: "crypto",
        .cryptoContract: "crypto_contract", .insurance: "insurance", .wealth: "wealth",
        .deposit: "deposit", .certificate: "certificate"
    ]
    private static let eventTypes: [InvestmentEventKind: String] = [
        .deposit: "deposit", .withdrawal: "withdrawal", .adjustment: "adjustment", .opening: "opening",
        .buy: "buy", .sell: "sell", .transferOut: "transfer_out", .transferIn: "transfer_in", .income: "income",
        .dividend: "dividend", .bonusShares: "bonus_shares", .stakingReward: "staking_reward",
        .spotAdjustment: "spot_adjustment", .marginTransfer: "derivative_margin", .funding: "derivative_funding",
        .derivativeSettlement: "derivative_settlement"
    ]
    private static let categories: [InvestmentBalanceCategory: String] = [
        .cash: "cash", .fixed: "fixed", .receivables: "receivables", .liabilities: "liabilities"
    ]

    private func invalid(_ field: String) -> InvestmentError { .invalid("投资服务端记录无效（\(field)）。") }
    private func required(_ row: InvestmentServerRow, _ key: String) throws -> String {
        guard let value = row[key] else { throw invalid(key) }
        return value
    }
    private func uuid(_ row: InvestmentServerRow, _ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try required(row, key)) else { throw invalid(key) }
        return value
    }
    private func date(_ row: InvestmentServerRow, _ key: String) throws -> Date {
        guard let value = day.date(from: try required(row, key)) else { throw invalid(key) }
        return value
    }
    private func decimal(_ value: String?) -> Decimal? {
        value.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }
    private func string(_ value: Decimal?) -> String? { value.map { NSDecimalNumber(decimal: $0).stringValue } }
    private func currency(_ row: InvestmentServerRow, _ key: String) throws -> InvestmentCurrency {
        guard let value = InvestmentCurrency(rawValue: try required(row, key)) else { throw invalid(key) }
        return value
    }
    private func ordering(_ row: InvestmentServerRow, _ key: String = "sort_order") -> Int { Int(row[key] ?? "") ?? 0 }

    private struct InstrumentKey: Hashable {
        let kind: InvestmentKind
        let currency: InvestmentCurrency
        let code, market: String
        let multiplier: Decimal
        let basis: InvestmentContractBasis
        let settlement: String
    }

    func encode(_ book: InvestmentBook, revision: Int64) throws -> InvestmentServerTables {
        var result = Dictionary(uniqueKeysWithValues: Self.names.map { ($0, [InvestmentServerRow]()) })
        let assets = book.assets.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let quotedAssets = assets.filter { ![.insurance, .wealth, .deposit, .certificate].contains($0.kind) }
        let byInstrument = Dictionary(grouping: quotedAssets) { asset in
            InstrumentKey(kind: asset.kind, currency: asset.currency, code: asset.code, market: asset.market,
                          multiplier: asset.multiplier, basis: asset.basis, settlement: book.settlementUnit(for: asset))
        }
        var instrumentIDs: [UUID: String] = [:]
        var priceTypes: [UUID: String] = [:]
        for (key, group) in byInstrument {
            guard let asset = group.first, let kind = Self.kinds[key.kind] else { throw invalid("asset_type") }
            let id = (group.compactMap(\.instrumentID).first ?? asset.id).uuidString
            let priceType = asset.kind == .cryptoContract ? "mark" : (asset.kind == .fund ? "nav" : "close")
            for item in group {
                instrumentIDs[item.id] = id
                priceTypes[item.id] = priceType
            }
            result["market_instruments", default: []].append([
                "id": id, "asset_type": kind, "symbol": key.code, "exchange": key.market, "name": asset.name,
                "quote_currency": key.currency.rawValue, "price_type": priceType
            ])
            if asset.kind.usesMargin {
                result["market_derivative_specs", default: []].append([
                    "instrument_id": id, "pricing_model": key.basis == .coin ? "inverse" : "linear",
                    "contract_multiplier": string(key.multiplier)!, "settlement_unit": key.settlement,
                    "settlement_basis": key.basis == .usd ? "cash" : (key.basis == .coin ? "coin" : "stablecoin")
                ])
            }
        }
        var publicPrices: [String: InvestmentServerRow] = [:]
        for asset in assets {
            guard let kind = Self.kinds[asset.kind] else { throw invalid("asset_type") }
            var row = ["id": asset.id.uuidString, "asset_type": kind, "name": asset.name, "symbol": asset.code,
                       "quote_currency": asset.currency.rawValue, "settlement_unit": book.settlementUnit(for: asset)]
            row["instrument_id"] = instrumentIDs[asset.id]
            row["collateral_asset_id"] = asset.collateralAssetID?.uuidString
            row["position_side"] = asset.contractSide.map { $0 == .short ? "short" : "long" }
            row["annual_rate"] = string(asset.depositTerms?.annualRate)
            row["maturity_date"] = asset.depositTerms.map { day.string(from: $0.maturity) }
            result["investment_assets", default: []].append(row)
            for quote in book.quotes[asset.id] ?? [] {
                let date = day.string(from: quote.day)
                let source = quote.source ?? ""
                if let instrument = instrumentIDs[asset.id], source != "手动录入" && source != "结算币录入" {
                    let priceType = priceTypes[asset.id] ?? "close"
                    let key = [instrument, date, priceType, source].joined(separator: "|")
                    var price = ["instrument_id": instrument, "session_date": date, "source": source,
                                 "price_type": priceType, "price": string(quote.price)!]
                    let close = asset.usesUSEquityClose ? InvestmentBook.usEquityClose(on: quote.day) : quote.day
                    price["valuation_date"] = day.string(from: close)
                    if asset.usesUSEquityClose { price["closed_at_utc"] = timestamp.string(from: close) }
                    price["is_final"] = quote.isDailyClose.map { $0 ? "1" : "0" }
                    publicPrices[key] = price
                } else {
                    var manual = ["asset_id": asset.id.uuidString, "valuation_date": date,
                                  "value": string(quote.price)!, "source": source]
                    manual["is_final"] = quote.isDailyClose.map { $0 ? "1" : "0" }
                    result["investment_manual_prices", default: []].append(manual)
                }
            }
        }
        result["market_daily_prices"] = publicPrices.keys.sorted().compactMap { publicPrices[$0] }
        for (offset, account) in book.accounts.enumerated() {
            result["investment_accounts", default: []].append([
                "id": account.id.uuidString, "name": account.name, "currency": account.currency.rawValue,
                "account_type": Self.accountTypes[account.type]!, "sort_order": String(offset)
            ])
            for (index, event) in account.events.enumerated() {
                let (row, details) = encode(event, accountID: account.id, offset: index, asset: book.asset(event.assetID))
                result["investment_events", default: []].append(row)
                if let details { result["investment_derivative_event_details", default: []].append(details) }
            }
        }
        for (offset, plan) in book.plans.enumerated() {
            var row = ["id": plan.id.uuidString, "account_id": plan.accountID.uuidString,
                       "amount": string(plan.amount)!, "month_day": String(plan.monthDay),
                       "next_date": day.string(from: plan.nextDay), "enabled": plan.enabled ? "1" : "0", "sort_order": String(offset)]
            row["asset_id"] = plan.assetID?.uuidString
            row["last_result"] = plan.lastResult
            result["investment_plans", default: []].append(row)
        }
        for run in book.planRuns where book.plans.contains(where: { $0.id == run.planID }) {
            var row = ["plan_id": run.planID.uuidString, "scheduled_date": day.string(from: run.day), "status": run.status]
            row["event_id"] = run.eventID?.uuidString
            row["result_detail"] = run.detail
            row["executed_at"] = run.executedAt.map(timestamp.string(from:))
            result["investment_plan_runs", default: []].append(row)
        }
        for (offset, id) in book.watched.enumerated() {
            var row = ["asset_id": id.uuidString, "sort_order": String(offset)]
            row["instrument_id"] = instrumentIDs[id]
            result["investment_watchlist", default: []].append(row)
        }
        for (currency, quotes) in book.fx.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for quote in quotes {
                var row = ["rate_date": day.string(from: quote.day), "base_currency": currency.rawValue,
                           "quote_currency": "CNY", "rate": string(quote.price)!, "source": quote.source ?? ""]
                row["is_final"] = quote.isDailyClose.map { $0 ? "1" : "0" }
                result["market_daily_fx", default: []].append(row)
            }
        }
        encodeSnapshots(book, revision: revision, into: &result)
        for (offset, account) in (book.balanceSheet?.accounts ?? []).enumerated() {
            guard let category = Self.categories[account.category] else { throw invalid("category") }
            result["investment_balance_accounts", default: []].append([
                "id": account.id.uuidString, "name": account.name, "category": category, "currency": "CNY", "sort_order": String(offset)
            ])
            for record in account.records {
                result["investment_balance_records", default: []].append([
                    "id": record.id.uuidString, "balance_account_id": account.id.uuidString,
                    "recorded_at": timestamp.string(from: record.recordedAt), "amount": string(record.amount)!
                ])
            }
        }
        for (date, value) in (book.balanceSheet?.investmentSnapshots ?? [:]).sorted(by: { $0.key < $1.key }) {
            result["investment_month_snapshots", default: []].append(["snapshot_date": day.string(from: date), "total_cny": string(value)!])
        }
        return result.mapValues(Self.ordered)
    }

    static func ordered(_ rows: [InvestmentServerRow]) -> [InvestmentServerRow] {
        rows.sorted { first, second in
            let lhs = first.sorted { $0.key < $1.key }.map { $0.key + "\0" + $0.value }
            let rhs = second.sorted { $0.key < $1.key }.map { $0.key + "\0" + $0.value }
            return lhs.lexicographicallyPrecedes(rhs)
        }
    }

    private func encode(_ event: InvestmentEvent, accountID: UUID, offset: Int, asset: InvestmentAsset?)
        -> (InvestmentServerRow, InvestmentServerRow?) {
        let derivative = asset?.kind.usesMargin == true
        let trade = derivative && (event.kind == .buy || event.kind == .sell)
        var row = ["id": event.id.uuidString, "account_id": accountID.uuidString, "sequence": String(offset),
                   "effective_date": day.string(from: event.day),
                   "event_type": trade ? "derivative_trade" : Self.eventTypes[event.kind]!]
        row["asset_id"] = event.assetID?.uuidString
        row["amount"] = string(event.amount)
        row["quantity"] = string(event.quantity)
        row["unit_price"] = string(event.price)
        row["fee"] = string(event.fee)
        row["settled_amount"] = string(event.settledAmount)
        row["transfer_id"] = event.transferID?.uuidString
        row["transfer_account_id"] = event.transferAccountID?.uuidString
        row["version"] = String(event.version ?? 1)
        row["created_at"] = event.createdAt.map(timestamp.string(from:))
        row["updated_at"] = event.updatedAt.map(timestamp.string(from:))
        guard derivative else { return (row, nil) }
        var detail = ["event_id": event.id.uuidString]
        let side = asset?.contractSide == .short ? "short" : "long"
        if trade { detail["trade_action"] = (event.kind == .buy ? "open_" : "close_") + side }
        else if event.unallocatedFunding != true { detail["position_side"] = side }
        let margin = asset?.kind == .future && event.kind == .buy ? event.margin * event.quantity : event.margin
        detail["margin_delta"] = string(event.kind == .marginTransfer ? event.amount : margin)
        detail["settlement_to_account_rate"] = string(event.settlementRate)
        detail["funding_target"] = event.fundingTarget.map {
            $0 == .margin ? "position_margin" : (event.unallocatedFunding == true ? "account_available" : "position_available")
        }
        return (row, detail)
    }

    private func encodeSnapshots(_ book: InvestmentBook, revision: Int64, into result: inout InvestmentServerTables) {
        guard let snapshots = book.dailySnapshots, let first = book.earliest, first <= snapshots.through else { return }
        var date = first
        while date <= snapshots.through {
            let value = snapshots.values[date]
            var row = ["snapshot_date": day.string(from: date), "computed_revision": String(revision),
                       "status": value == nil ? "missing" : (value?.valueUSD == nil ? "partial" : "complete")]
            row["total_cny"] = string(value?.value)
            row["total_usd"] = string(value?.valueUSD)
            row["cumulative_gain_cny"] = string(value?.gain)
            if let current = value?.gain,
               let previous = snapshots.values[InvestmentBook.addDays(-1, to: date)]?.gain {
                row["daily_gain_cny"] = string(current - previous)
            }
            result["investment_daily_snapshots", default: []].append(row)
            date = InvestmentBook.addDays(1, to: date)
        }
        for (id, history) in (snapshots.accountValues ?? [:]).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for (date, value) in history.sorted(by: { $0.key < $1.key }) {
                var row = ["account_id": id.uuidString, "snapshot_date": day.string(from: date),
                           "cash_native": string(value.cash)!, "status": value.holdings == nil ? "partial" : "complete"]
                row["holdings_native"] = string(value.holdings)
                row["gain_native"] = string(value.gain)
                result["investment_account_daily_snapshots", default: []].append(row)
            }
        }
    }

    func decode(_ state: InvestmentServerState) throws -> InvestmentBook {
        func records(_ table: String) -> [InvestmentServerRow] { state.tables[table] ?? [] }
        var book = InvestmentBook()
        book.usesServerSnapshots = true
        let instruments = Dictionary(grouping: records("market_instruments")) { $0["id"] ?? "" }
        let specs = Dictionary(grouping: records("market_derivative_specs")) { $0["instrument_id"] ?? "" }
        let prices = Dictionary(grouping: records("market_daily_prices")) { $0["instrument_id"] ?? "" }
        let manual = Dictionary(grouping: records("investment_manual_prices")) { $0["asset_id"] ?? "" }
        for row in records("investment_assets") {
            let id = try uuid(row, "id")
            let kind = try mapped(Self.kinds, row, "asset_type")
            let instrument = row["instrument_id"].flatMap { instruments[$0]?.first }
            let spec = row["instrument_id"].flatMap { specs[$0]?.first }
            let basis: InvestmentContractBasis? = if kind == .cryptoContract {
                spec?["settlement_basis"] == "coin" ? .coin : (spec?["settlement_basis"] == "stablecoin" ? .stablecoin : .usd)
            } else { nil }
            var asset = try InvestmentAsset(id: id, name: required(row, "name"),
                code: row["symbol"] ?? instrument?["symbol"] ?? "", market: instrument?["exchange"] ?? "",
                kind: kind, currency: currency(row, "quote_currency"), multiplier: decimal(spec?["contract_multiplier"]) ?? 1,
                contractSide: row["position_side"].map { $0 == "short" ? .short : .long },
                contractBasis: basis, collateralAssetID: row["collateral_asset_id"].flatMap(UUID.init(uuidString:)))
            asset.instrumentID = row["instrument_id"].flatMap(UUID.init(uuidString:))
            if basis == .stablecoin, asset.collateralAssetID == nil {
                asset.settlementStablecoin = row["settlement_unit"].flatMap(InvestmentStablecoin.init(rawValue:))
            }
            if let rate = decimal(row["annual_rate"]), let maturity = row["maturity_date"].flatMap(day.date(from:)) {
                asset.depositTerms = InvestmentDepositTerms(annualRate: rate, maturity: maturity)
            }
            book.assets[id] = asset
            let quoted = try (prices[row["instrument_id"] ?? ""] ?? []).map { try quote($0, day: "session_date", value: "price") }
            let edited = try (manual[id.uuidString] ?? []).map { try quote($0, day: "valuation_date", value: "value") }
            if !quoted.isEmpty || !edited.isEmpty {
                book.quotes[id] = InvestmentBook.merge(quoted, edited, allowZero: kind == .insurance)
            }
        }

        let events = Dictionary(grouping: records("investment_events")) { $0["account_id"] ?? "" }
        let details = Dictionary(grouping: records("investment_derivative_event_details")) { $0["event_id"] ?? "" }
        for row in records("investment_accounts").sorted(by: { ordering($0) < ordering($1) }) {
            let id = try uuid(row, "id")
            let entries = try (events[id.uuidString] ?? []).sorted { ordering($0, "sequence") < ordering($1, "sequence") }
                .map { try event($0, detail: details[$0["id"] ?? ""]?.first, book: book) }
            let account = try InvestmentAccount(id: id, name: required(row, "name"), currency: currency(row, "currency"),
                                                events: entries, type: mapped(Self.accountTypes, row, "account_type"))
            book.accounts.append(account)
        }
        for row in records("investment_plans").sorted(by: { ordering($0) < ordering($1) }) {
            book.plans.append(try InvestmentPlan(id: uuid(row, "id"), accountID: uuid(row, "account_id"),
                assetID: row["asset_id"].flatMap(UUID.init(uuidString:)), amount: decimal(row["amount"]) ?? 0,
                monthDay: ordering(row, "month_day"), nextDay: date(row, "next_date"),
                enabled: row["enabled"] == "1", lastResult: row["last_result"]))
        }
        book.planRuns = try records("investment_plan_runs").map { row in
            try InvestmentPlanRun(planID: uuid(row, "plan_id"), day: date(row, "scheduled_date"),
                status: required(row, "status"), eventID: row["event_id"].flatMap(UUID.init(uuidString:)),
                executedAt: row["executed_at"].flatMap(timestamp.date(from:)), detail: row["result_detail"])
        }
        book.watched = try records("investment_watchlist").sorted { ordering($0) < ordering($1) }.map { try uuid($0, "asset_id") }
        for row in records("market_daily_fx") {
            let base = try currency(row, "base_currency")
            book.fx[base, default: []].append(try quote(row, day: "rate_date", value: "rate"))
        }
        book.fx = book.fx.mapValues { InvestmentBook.merge([], $0) }

        if let through = state.through.flatMap(day.date(from:)) {
            var values: [Date: InvestmentValuation] = [:]
            var accountValues: [UUID: [Date: InvestmentAccountDay]] = [:]
            for row in records("investment_daily_snapshots") {
                guard let total = decimal(row["total_cny"]), let gain = decimal(row["cumulative_gain_cny"]) else { continue }
                values[try date(row, "snapshot_date")] = InvestmentValuation(value: total, gain: gain, valueUSD: decimal(row["total_usd"]))
            }
            for row in records("investment_account_daily_snapshots") {
                guard let cash = decimal(row["cash_native"]) else { continue }
                let id = try uuid(row, "account_id")
                accountValues[id, default: [:]][try date(row, "snapshot_date")] = InvestmentAccountDay(
                    cash: cash, holdings: decimal(row["holdings_native"]), gain: decimal(row["gain_native"]))
            }
            book.dailySnapshots = InvestmentDailySnapshots(through: through, values: values, hasUSD: true, accountValues: accountValues)
        }
        let balance = Dictionary(grouping: records("investment_balance_records")) { $0["balance_account_id"] ?? "" }
        let balanceAccounts = try records("investment_balance_accounts").sorted { ordering($0) < ordering($1) }.map { row in
            let id = try uuid(row, "id")
            let entries = try (balance[id.uuidString] ?? []).sorted { ($0["recorded_at"] ?? "") < ($1["recorded_at"] ?? "") }.map {
                guard let stamp = $0["recorded_at"].flatMap(timestamp.date(from:)), let amount = decimal($0["amount"]) else {
                    throw invalid("recorded_at")
                }
                return try InvestmentBalanceRecord(id: uuid($0, "id"), recordedAt: stamp, amount: amount)
            }
            return try InvestmentBalanceAccount(id: id, name: required(row, "name"), category: mapped(Self.categories, row, "category"), records: entries)
        }
        var months: [Date: Decimal] = [:]
        for row in records("investment_month_snapshots") { months[try date(row, "snapshot_date")] = decimal(row["total_cny"]) }
        if !balanceAccounts.isEmpty || !months.isEmpty {
            book.balanceSheet = InvestmentBalanceLedger(accounts: balanceAccounts, investmentMonthEnds: months)
        }
        return book
    }

    private func mapped<T>(_ map: [T: String], _ row: InvestmentServerRow, _ field: String) throws -> T {
        let value = try required(row, field)
        guard let key = map.first(where: { $0.value == value })?.key else { throw invalid(field) }
        return key
    }

    private func quote(_ row: InvestmentServerRow, day key: String, value: String) throws -> InvestmentQuote {
        guard let amount = decimal(row[value]) else { throw invalid(value) }
        let source = row["source"].flatMap { $0.isEmpty ? nil : $0 }
        return try InvestmentQuote(day: date(row, key), price: amount, source: source,
                                   isDailyClose: row["is_final"].map { $0 == "1" })
    }

    private func event(_ row: InvestmentServerRow, detail: InvestmentServerRow?, book: InvestmentBook) throws -> InvestmentEvent {
        let kind: InvestmentEventKind
        if row["event_type"] == "derivative_trade" {
            switch detail?["trade_action"] {
            case "open_long", "open_short": kind = .buy
            case "close_long", "close_short": kind = .sell
            default: throw invalid("trade_action")
            }
        } else { kind = try mapped(Self.eventTypes, row, "event_type") }
        let id = row["asset_id"].flatMap(UUID.init(uuidString:))
        let quantity = decimal(row["quantity"]) ?? 0
        var margin = decimal(detail?["margin_delta"]) ?? 0
        if kind == .buy, book.asset(id)?.kind == .future, quantity > 0 { margin /= quantity }
        var value = try InvestmentEvent(id: uuid(row, "id"), day: date(row, "effective_date"), kind: kind, assetID: id,
            amount: decimal(row["amount"]) ?? 0, quantity: quantity, price: decimal(row["unit_price"]) ?? 0,
            margin: margin, settledAmount: decimal(row["settled_amount"]), fee: decimal(row["fee"]),
            settlementRate: decimal(detail?["settlement_to_account_rate"]),
            fundingTarget: detail?["funding_target"].map { $0 == "position_margin" ? .margin : .available },
            unallocatedFunding: detail?["funding_target"].map { $0 == "account_available" },
            transferAccountID: row["transfer_account_id"].flatMap(UUID.init(uuidString:)),
            transferID: row["transfer_id"].flatMap(UUID.init(uuidString:)))
        value.version = Int(row["version"] ?? "")
        value.createdAt = row["created_at"].flatMap(timestamp.date(from:))
        value.updatedAt = row["updated_at"].flatMap(timestamp.date(from:))
        return value
    }
}
