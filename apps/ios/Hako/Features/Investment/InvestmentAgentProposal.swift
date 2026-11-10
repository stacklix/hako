import Foundation

struct InvestmentAgentSnapshot {
    let book: InvestmentBook
    let session: UUID
    let generation: Int64
    let revision: Int64
    let dirtyFrom: Date?
    let tables: InvestmentServerTables
}

enum InvestmentAgentCommitError: LocalizedError {
    case stale, unverified

    var errorDescription: String? {
        switch self {
        case .stale: "账本已变化，请重新生成预览并核对。"
        case .unverified: "暂时无法确认是否写入。请先查询账本核对结果，避免重复记账。"
        }
    }
}

struct InvestmentAgentProposal: Identifiable, Codable {
    struct Change: Identifiable, Codable {
        struct Field: Identifiable, Codable {
            let id: String
            let label: String
            let before: String?
            let after: String?
        }

        enum Operation: String, Codable { case add = "新增", edit = "修改", remove = "删除" }
        let id: String
        let operation: Operation
        let title: String
        let fields: [Field]
    }

    let id: UUID
    private(set) var session: UUID
    let generation: Int64
    let actions: [InvestmentAgentAction]
    let book: InvestmentBook
    let snapshotsOnly: Bool
    let changes: [Change]
    var destructive: Bool { changes.contains { $0.operation == .remove } }
    var editable: Bool { !actions.contains { $0.kind == .refreshMarket || $0.kind == .rebuildSnapshots } }

    func restored(for session: UUID) -> Self {
        var proposal = self
        proposal.session = session
        return proposal
    }

    init(base: InvestmentAgentSnapshot, actions: [InvestmentAgentAction], prepared: InvestmentBook? = nil) throws {
        id = UUID()
        session = base.session
        generation = base.generation
        self.actions = actions
        snapshotsOnly = actions.first?.kind == .rebuildSnapshots
        var candidate = prepared ?? base.book
        if prepared == nil { for action in actions { try action.apply(to: &candidate) } }
        book = candidate
        let records = InvestmentServerRecords()
        let old = try records.encode(base.book, revision: base.revision)
        let new = try records.encode(candidate, revision: base.revision)
        let before = Presentation(book: base.book)
        let after = Presentation(book: candidate)
        var result: [Change] = []
        for section in Self.sections where InvestmentServerRecords.snapshotTables.contains(section.name) == snapshotsOnly {
            try Task.checkCancellation()
            let oldRows = old[section.name] ?? []
            let newRows = new[section.name] ?? []
            let previous = Dictionary(oldRows.map { (section.key($0), $0) }, uniquingKeysWith: { first, _ in first })
            let next = Dictionary(newRows.map { (section.key($0), $0) }, uniquingKeysWith: { first, _ in first })
            for key in Set(previous.keys).union(next.keys).sorted() {
                let left = previous[key]
                let right = next[key]
                guard left != right else { continue }
                let op: Change.Operation = left == nil ? .add : right == nil ? .remove : .edit
                let beforeRow = before.fields(left, section: section.name)
                let afterRow = after.fields(right, section: section.name)
                let touched = Set(beforeRow.keys).union(afterRow.keys).filter { beforeRow[$0] != afterRow[$0] }
                guard !touched.isEmpty else { continue }
                let row = right ?? left ?? [:]
                let context = right == nil ? before : after
                let priority = ["account_id", "balance_account_id", "effective_date", "recorded_at", "snapshot_date", "asset_id",
                                "event_type", "quantity", "unit_price", "fee", "cash_change", "amount", "settled_amount"]
                let visible = touched.union(priority.filter { beforeRow[$0] != nil || afterRow[$0] != nil })
                let ordered = visible.sorted { left, right in
                    let l = priority.firstIndex(of: left) ?? priority.count
                    let r = priority.firstIndex(of: right) ?? priority.count
                    return l == r ? left < right : l < r
                }
                let fields = ordered.map { key in
                    Change.Field(id: key, label: Self.labels[key] ?? key, before: beforeRow[key], after: afterRow[key])
                }
                result.append(.init(id: section.name + ":" + key, operation: op, title: context.title(row, section: section), fields: fields))
            }
        }
        if snapshotsOnly, base.dirtyFrom != nil || base.book.dailySnapshots?.through != candidate.dailySnapshots?.through {
            let field = Change.Field(id: "through", label: "计算至", before: base.book.dailySnapshots.map { records.day.string(from: $0.through) },
                                     after: candidate.dailySnapshots.map { records.day.string(from: $0.through) })
            result.insert(.init(id: "snapshot-range", operation: .edit, title: "历史快照计算状态", fields: [field]), at: 0)
        }
        guard !result.isEmpty else { throw InvestmentError.invalid("本次操作没有可写入的变更。") }
        changes = result
    }

    struct Section {
        let name: String
        let title: String
        let keys: [String]

        func key(_ row: InvestmentServerRow) -> String {
            keys.map { row[$0] ?? "" }.joined(separator: "\u{1F}")
        }
    }

    static let sections: [Section] = [
        .init(name: "investment_events", title: "交易流水", keys: ["id"]),
        .init(name: "investment_derivative_event_details", title: "合约流水明细", keys: ["event_id"]),
        .init(name: "investment_accounts", title: "投资账户", keys: ["id"]),
        .init(name: "investment_assets", title: "标的", keys: ["id"]),
        .init(name: "market_instruments", title: "行情标的", keys: ["id"]),
        .init(name: "market_derivative_specs", title: "合约规格", keys: ["instrument_id"]),
        .init(name: "investment_plans", title: "定投", keys: ["id"]),
        .init(name: "investment_plan_runs", title: "定投执行记录", keys: ["plan_id", "scheduled_date"]),
        .init(name: "investment_watchlist", title: "关注标的", keys: ["asset_id"]),
        .init(name: "investment_balance_accounts", title: "资产负债账户", keys: ["id"]),
        .init(name: "investment_balance_records", title: "资产负债记录", keys: ["id"]),
        .init(name: "investment_manual_prices", title: "手工报价", keys: ["asset_id", "valuation_date"]),
        .init(name: "market_daily_prices", title: "行情报价", keys: ["instrument_id", "session_date", "price_type", "source"]),
        .init(name: "market_daily_fx", title: "汇率", keys: ["rate_date", "base_currency", "quote_currency", "source"]),
        .init(name: "investment_daily_snapshots", title: "投资日终快照", keys: ["snapshot_date"]),
        .init(name: "investment_account_daily_snapshots", title: "账户日终快照", keys: ["account_id", "snapshot_date"]),
        .init(name: "investment_month_snapshots", title: "投资月末快照", keys: ["snapshot_date"])
    ]

    static let labels: [String: String] = [
        "account_id": "账户", "asset_id": "标的", "name": "名称", "id": "记录 ID", "event_id": "关联流水", "event_type": "类型",
        "asset_type": "标的类型", "account_type": "账户类型", "currency": "币种", "quote_currency": "报价币种", "symbol": "代码",
        "amount": "金额", "quantity": "数量", "unit_price": "单位价格", "fee": "手续费", "settled_amount": "交收金额 / 存款余额",
        "effective_date": "记账日期", "exchange": "交易所", "transfer_id": "划转编号", "transfer_account_id": "对侧账户",
        "instrument_id": "行情标的", "collateral_asset_id": "结算币", "position_side": "方向", "settlement_unit": "结算单位",
        "trade_action": "开平仓方向", "margin_delta": "保证金变动", "funding_target": "资金账户", "settlement_to_account_rate": "结算币兑美元",
        "annual_rate": "年利率", "maturity_date": "到期日", "sort_order": "顺序", "month_day": "每月执行日", "next_date": "下次执行",
        "enabled": "启用", "last_result": "最近结果", "plan_id": "定投编号", "scheduled_date": "计划日期", "executed_at": "执行时间",
        "result_detail": "执行结果", "recorded_at": "记录时间（北京时间）", "balance_account_id": "资产负债账户", "category": "分类",
        "price_type": "报价类型", "price": "价格", "value": "价格 / 估值", "session_date": "交易日", "valuation_date": "估值日",
        "closed_at_utc": "收盘时间（UTC）", "rate_date": "汇率日期", "rate": "汇率", "base_currency": "基准币种", "source": "来源",
        "is_final": "最终报价", "snapshot_date": "快照日期", "total_cny": "人民币总额", "total_usd": "美元总额", "status": "状态",
        "missing_inputs": "缺少数据", "computed_revision": "计算版本", "cash_native": "现金余额", "holdings_native": "持仓市值",
        "gain_native": "累计收益", "cumulative_gain_cny": "累计收益（CNY）", "daily_gain_cny": "当日收益（CNY）",
        "cash_change": "现金变动", "contract_multiplier": "合约乘数", "pricing_model": "定价模型", "settlement_basis": "结算本位"
    ]

    private struct Presentation {
        let book: InvestmentBook
        let accounts: [String: String]
        let balances: [String: String]
        let assets: [String: String]
        let instruments: [String: String]
        let events: [String: InvestmentEvent]
        let cashChanges: [String: String]

        init(book: InvestmentBook) {
            self.book = book
            accounts = Dictionary(book.accounts.map { ($0.id.uuidString, "\($0.name) · \($0.currency.rawValue)") }, uniquingKeysWith: { first, _ in first })
            balances = Dictionary((book.balanceSheet?.accounts ?? []).map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { first, _ in first })
            let entries = book.assets.values.sorted { $0.id.uuidString < $1.id.uuidString }
            assets = Dictionary(entries.map { ($0.id.uuidString, "\($0.name) · \($0.code)") }, uniquingKeysWith: { first, _ in first })
            instruments = Dictionary(entries.map { (($0.instrumentID ?? $0.id).uuidString, "\($0.code) · \($0.currency.rawValue)") }, uniquingKeysWith: { first, _ in first })
            events = Dictionary(book.accounts.flatMap(\.events).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
            var cash: [String: String] = [:]
            for account in book.accounts {
                guard let ledger = try? book.ledger(account, includeRows: true) else { continue }
                for row in ledger.cashRows where row.change != 0 {
                    cash[row.id.uuidString] = "\(account.currency.rawValue) \(NSDecimalNumber(decimal: row.change).stringValue)"
                }
            }
            cashChanges = cash
        }

        func title(_ row: InvestmentServerRow, section: Section) -> String {
            if section.name == "investment_events", let id = row["id"], let event = events[id] {
                let asset = book.asset(event.assetID)
                return [event.title(for: asset), asset?.code].compactMap { $0 }.joined(separator: " ")
            }
            let named = row["name"] ?? row["symbol"] ?? row["asset_id"].flatMap { assets[$0] }
            let referenced = row["instrument_id"].flatMap { instruments[$0] } ?? row["balance_account_id"].flatMap { balances[$0] }
            let detail = named ?? referenced ?? row["snapshot_date"]
            return [section.title, detail].compactMap { $0 }.joined(separator: " · ")
        }

        func fields(_ source: InvestmentServerRow?, section: String) -> InvestmentServerRow {
            guard let source else { return [:] }
            var row = source
            for metadata in ["id", "created_at", "updated_at", "version", "sequence", "transfer_id"] { row.removeValue(forKey: metadata) }
            if let id = source["id"], let event = events[id], section == "investment_events" {
                row["event_type"] = event.title(for: book.asset(event.assetID))
                for key in ["amount", "quantity", "unit_price"] where row[key] == "0" { row.removeValue(forKey: key) }
                row["cash_change"] = cashChanges[id]
                if event.kind == .buy || event.kind == .sell { row["fee"] = row["fee"] ?? "0" }
            }
            let references = ["account_id": accounts, "transfer_account_id": accounts, "asset_id": assets,
                              "collateral_asset_id": assets, "instrument_id": instruments, "balance_account_id": balances]
            for (key, names) in references { if let value = row[key], let label = names[value] { row[key] = label } }
            if let value = row["account_type"] { row["account_type"] = InvestmentAgentAction.accountTypes[value]?.rawValue ?? value }
            if let value = row["asset_type"] { row["asset_type"] = InvestmentAgentAction.assetKinds[value]?.title ?? value }
            if let value = row["category"] { row["category"] = InvestmentAgentAction.balanceCategories[value]?.rawValue ?? value }
            for key in ["enabled", "is_final"] { if let value = row[key] { row[key] = value == "1" ? "是" : "否" } }
            if let value = row["sort_order"], let offset = Int(value) { row["sort_order"] = String(offset + 1) }
            if let value = row["annual_rate"], let rate = Decimal(string: value) {
                row["annual_rate"] = NSDecimalNumber(decimal: rate * 100).stringValue + "%"
            }
            if let value = row["recorded_at"] {
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = format.date(from: value) {
                    let local = InvestmentBook.snapshotDateFormatter()
                    local.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    row["recorded_at"] = local.string(from: date)
                }
            }
            return row
        }
    }
}
