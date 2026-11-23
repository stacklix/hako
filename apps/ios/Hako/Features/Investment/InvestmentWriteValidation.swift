import Foundation

// Wire rules mirror server/investment.go; server authentication and commit stay authoritative.
enum InvestmentWriteValidation {
    struct Rule { let keys: String; let fields: String; let required: String; let output: Bool }
    static let schema: [String: Rule] = [
        "market_instruments": .init(keys: "id", fields: "asset_type symbol exchange name quote_currency price_type", required: "asset_type symbol exchange name quote_currency price_type", output: false),
        "market_derivative_specs": .init(keys: "instrument_id", fields: "contract_multiplier expiry_date", required: "contract_multiplier", output: false),
        "investment_accounts": .init(keys: "id", fields: "name account_type currency sort_order archived_at", required: "name account_type currency sort_order", output: false),
        "investment_assets": .init(keys: "id", fields: "instrument_id name asset_type settlement_unit annual_rate maturity_date position_side symbol quote_currency", required: "name asset_type quote_currency settlement_unit", output: false),
        "investment_events": .init(keys: "id", fields: "account_id asset_id event_type effective_date sequence amount quantity unit_price fee settled_amount transfer_id transfer_account_id version created_at updated_at deleted_at", required: "account_id effective_date sequence event_type", output: false),
        "investment_derivative_event_details": .init(keys: "event_id", fields: "trade_action position_side margin_delta", required: "", output: false),
        "investment_plans": .init(keys: "id", fields: "account_id asset_id amount frequency schedule_day next_date enabled last_result sort_order", required: "account_id amount frequency schedule_day next_date enabled", output: false),
        "investment_plan_runs": .init(keys: "plan_id scheduled_date", fields: "status event_id executed_at result_detail", required: "", output: false),
        "investment_watchlist": .init(keys: "asset_id", fields: "instrument_id sort_order", required: "sort_order", output: false),
        "market_daily_prices": .init(keys: "instrument_id session_date price_type source", fields: "closed_at_utc valuation_date price is_final revision", required: "price", output: false),
        "market_daily_fx": .init(keys: "rate_date base_currency quote_currency source", fields: "rate available_at_utc is_final revision", required: "rate", output: false),
        "investment_manual_prices": .init(keys: "asset_id valuation_date", fields: "value source is_final", required: "value", output: false),
        "investment_daily_snapshots": .init(keys: "snapshot_date", fields: "total_cny total_usd cumulative_gain_cny daily_gain_cny status missing_inputs computed_revision", required: "status computed_revision", output: true),
        "investment_account_daily_snapshots": .init(keys: "account_id snapshot_date", fields: "cash_native holdings_native gain_native status", required: "status", output: true),
        "investment_balance_accounts": .init(keys: "id", fields: "name category currency sort_order", required: "name category currency", output: false),
        "investment_balance_records": .init(keys: "id", fields: "balance_account_id recorded_at amount", required: "balance_account_id recorded_at amount", output: false)
    ]
    static let links: [(String, String, String, String)] = [
        ("investment_events", "account_id", "investment_accounts", "id"),
        ("investment_events", "asset_id", "investment_assets", "id"),
        ("investment_events", "transfer_account_id", "investment_accounts", "id"),
        ("investment_derivative_event_details", "event_id", "investment_events", "id"),
        ("investment_assets", "instrument_id", "market_instruments", "id"),
        ("market_derivative_specs", "instrument_id", "market_instruments", "id"),
        ("market_daily_prices", "instrument_id", "market_instruments", "id"),
        ("investment_manual_prices", "asset_id", "investment_assets", "id"),
        ("investment_watchlist", "asset_id", "investment_assets", "id"),
        ("investment_plans", "account_id", "investment_accounts", "id"),
        ("investment_plans", "asset_id", "investment_assets", "id"),
        ("investment_plan_runs", "plan_id", "investment_plans", "id"),
        ("investment_account_daily_snapshots", "account_id", "investment_accounts", "id"),
        ("investment_balance_records", "balance_account_id", "investment_balance_accounts", "id")
    ]
    static let numbers = Set(" amount quantity unit_price fee settled_amount annual_rate margin_delta price rate value contract_multiplier total_cny total_usd cumulative_gain_cny daily_gain_cny cash_native holdings_native gain_native ".split(separator: " ").map(String.init))
    static let integers = Set(" sequence sort_order enabled schedule_day is_final version revision computed_revision ".split(separator: " ").map(String.init))
    private static let formatter = InvestmentBook.snapshotDateFormatter()
    private static func date(_ value: String) -> Date? {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
    private static func reject(_ table: String, _ field: String) -> InvestmentError {
        .invalid("提交前校验失败（" + table + " · " + field + "）。")
    }
    static func validate(generation: Int64, revision: Int64, dirtyFrom: String?, through: String?,
                         changes: InvestmentServerTables, current: InvestmentServerTables) throws {
        guard generation >= 0, changes.count <= schema.count else { throw reject("账本", "版本或表数量") }
        for value in [dirtyFrom, through].compactMap({ $0 }) where date(value) == nil {
            throw reject("账本", "日期")
        }
        var inputs = false, outputs = false
        for (table, rows) in changes {
            guard let rule = schema[table], rows.count <= 500_000 else { throw reject(table, "未知表或记录数量") }
            inputs = inputs || !rule.output; outputs = outputs || rule.output
            let keys = rule.keys.split(separator: " ").map(String.init)
            let allowed = Set((rule.keys + " " + rule.fields).split(separator: " ").map(String.init))
            var seen = Set<String>()
            for row in rows {
                for column in keys {
                    guard let value = row[column], (column == "source" || !value.isEmpty), !value.contains("\0") else {
                        throw reject(table, column)
                    }
                }
                let key = keys.map { row[$0]! }.joined(separator: "\0")
                guard seen.insert(key).inserted else { throw reject(table, "重复主键") }
                for field in rule.required.split(separator: " ") where row[String(field)] == nil {
                    throw reject(table, String(field))
                }
                for (column, value) in row {
                    guard allowed.contains(column), value.utf8.count <= 16_384 else { throw reject(table, column) }
                    if numbers.contains(column), value.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) == nil {
                        throw reject(table, column)
                    }
                    if integers.contains(column) {
                        guard let number = Int64(value), number >= 0,
                              !["enabled", "is_final"].contains(column) || number <= 1 else { throw reject(table, column) }
                    }
                    if column.hasSuffix("_date") || column == "effective_date" {
                        guard date(value) != nil else { throw reject(table, column) }
                    }
                }
                if let kind = row["asset_type"], !Set("stock etf fund future crypto generic insurance wealth deposit certificate".split(separator: " ").map(String.init)).contains(kind) {
                    throw reject(table, "asset_type")
                }
                if table == "investment_accounts", !Set("securities fund_wealth futures deposits crypto insurance".split(separator: " ").map(String.init)).contains(row["account_type"] ?? "") {
                    throw reject(table, "account_type")
                }
                if let kind = row["event_type"], !Set("deposit withdrawal adjustment opening buy sell transfer_out transfer_in income dividend bonus_shares staking_reward spot_adjustment derivative_margin derivative_settlement derivative_trade insurance_withdrawal".split(separator: " ").map(String.init)).contains(kind) {
                    throw reject(table, "event_type")
                }
                if table == "investment_plans" { try validatePlan(row) }
                if table == "investment_daily_snapshots", row["computed_revision"] != String(revision) {
                    throw reject(table, "快照版本已过期")
                }
            }
        }
        guard !(inputs && outputs) else { throw reject("账本", "源数据与派生快照必须分开提交") }
        var merged = current
        merged.merge(changes) { _, replacement in replacement }
        for (from, column, to, target) in links {
            let ids = Set((merged[to] ?? []).compactMap { $0[target] })
            for row in merged[from] ?? [] {
                if let id = row[column], !ids.contains(id) { throw reject(from, column + " 引用了不存在的记录") }
            }
        }
    }
    private static func validatePlan(_ row: InvestmentServerRow) throws {
        guard let amount = Decimal(string: row["amount"] ?? ""), InvestmentPrecision.rounded(amount) > 0,
              let day = Int(row["schedule_day"] ?? ""), let next = date(row["next_date"] ?? "") else {
            throw reject("investment_plans", "金额或执行日期")
        }
        let calendar = InvestmentBook.calendar
        let valid: Bool
        switch row["frequency"] {
        case "daily": valid = day == 0
        case "weekly", "biweekly": valid = (1...7).contains(day) && day == (calendar.component(.weekday, from: next) + 5) % 7 + 1
        case "monthly": valid = (1...31).contains(day) && calendar.component(.day, from: next) == min(day, calendar.range(of: .day, in: .month, for: next)!.count)
        default: valid = false
        }
        guard valid else { throw reject("investment_plans", "周期与下次执行日期不一致") }
    }
}
