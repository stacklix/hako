import Foundation

@main struct InvestmentWriteValidationTests {
    static func main() throws {
        let account: InvestmentServerRow = ["id": "account", "name": "证券", "account_type": "securities", "currency": "USD", "sort_order": "0"]
        let event: InvestmentServerRow = ["id": "event", "account_id": "account", "event_type": "deposit", "effective_date": "2026-11-23", "sequence": "0", "amount": "100"]
        let current: InvestmentServerTables = ["investment_accounts": [account], "investment_events": [event]]
        func check(_ changes: InvestmentServerTables, revision: Int64 = 3) throws {
            try InvestmentWriteValidation.validate(generation: 1, revision: revision, dirtyFrom: nil,
                through: nil, changes: changes, current: current)
        }
        func rejected(_ changes: InvestmentServerTables) {
            do { try check(changes); preconditionFailure("Invalid write passed client preflight") }
            catch { precondition(error.localizedDescription.contains("提交前校验失败")) }
        }
        try check(current)
        let fx: InvestmentServerRow = ["rate_date": "2026-11-24", "base_currency": "USD", "quote_currency": "CNY",
            "rate": "7.1", "source": "欧洲央行", "is_final": "1"]
        try check(["market_daily_fx": [fx]])
        var duplicateFX = fx; duplicateFX["source"] = "another"
        rejected(["market_daily_fx": [fx, duplicateFX]])
        let instrument: InvestmentServerRow = ["id": "ETF:US:QQQM:USD", "asset_type": "etf", "symbol": "QQQM",
            "exchange": "US", "quote_currency": "USD", "name": "QQQM", "price_type": "close"]
        let quote: InvestmentServerRow = ["instrument_id": "ETF:US:QQQM:USD", "session_date": "2026-11-20",
            "price_type": "close", "source": "first", "price": "100", "is_final": "1"]
        try check(["market_instruments": [instrument], "market_daily_prices": [quote]])
        var duplicateQuote = quote; duplicateQuote["source"] = "second"
        rejected(["market_instruments": [instrument], "market_daily_prices": [quote, duplicateQuote]])
        var wrongIdentity = instrument; wrongIdentity["symbol"] = "OTHER"
        rejected(["market_instruments": [wrongIdentity]])
        rejected(["unknown_table": []])
        rejected(["investment_accounts": [account, account]])
        for (column, value) in [("sort_order", "-1"), ("sort_order", "9223372036854775808"),
                                ("account_type", "bank"), ("id", "a\0b"), ("name", String(repeating: "中", count: 6000)),
                                ("unexpected", "value")] {
            var bad = account; bad[column] = value
            rejected(["investment_accounts": [bad]])
        }
        var missing = account; missing.removeValue(forKey: "currency")
        rejected(["investment_accounts": [missing]])
        for (column, value) in [("amount", "1e3"), ("amount", "nan"), ("effective_date", "2026-02-30"),
                                ("event_type", "unknown"), ("account_id", "absent")] {
            var bad = event; bad[column] = value
            rejected(["investment_events": [bad]])
        }
        rejected(["investment_accounts": []]) // Must check links against the merged server state.
        let snapshot: InvestmentServerRow = ["snapshot_date": "2026-11-23", "status": "complete", "computed_revision": "3"]
        try check(["investment_daily_snapshots": [snapshot]])
        rejected(["investment_accounts": [account], "investment_daily_snapshots": [snapshot]])
        var stale = snapshot; stale["computed_revision"] = "2"
        rejected(["investment_daily_snapshots": [stale]])
        var plan: InvestmentServerRow = ["id": "plan", "account_id": "account", "amount": "100", "frequency": "monthly",
            "schedule_day": "31", "next_date": "2026-02-28", "enabled": "1"]
        try check(["investment_plans": [plan]])
        plan["next_date"] = "2026-02-27"; rejected(["investment_plans": [plan]])
        plan["frequency"] = "weekly"; plan["schedule_day"] = "1"; plan["next_date"] = "2026-11-23"
        try check(["investment_plans": [plan]])
        plan["schedule_day"] = "2"; rejected(["investment_plans": [plan]])
        plan["schedule_day"] = "1"; plan["enabled"] = "2"; rejected(["investment_plans": [plan]])
        do {
            try InvestmentWriteValidation.validate(generation: -1, revision: 3, dirtyFrom: nil, through: nil, changes: [:], current: [:])
            preconditionFailure("Negative generation accepted")
        } catch is InvestmentError { }
        do {
            try InvestmentWriteValidation.validate(generation: 1, revision: 3, dirtyFrom: "2026-02-30", through: nil, changes: [:], current: [:])
            preconditionFailure("Invalid dirty date accepted")
        } catch is InvestmentError { }
        // Encoded real app records must obey the same wire contract.
        var book = InvestmentBook()
        book.accounts = [InvestmentAccount(name: "证券", currency: .usd, type: .securities)]
        let tables = try InvestmentServerRecords().encode(book, revision: 0)
            .filter { !InvestmentServerRecords.snapshotTables.contains($0.key) }
        try InvestmentWriteValidation.validate(generation: 0, revision: 0, dirtyFrom: nil, through: nil, changes: tables, current: [:])
        print("Investment write preflight: wire fields, types, dates, keys, merged references, plans and snapshot revisions passed")
    }
}
