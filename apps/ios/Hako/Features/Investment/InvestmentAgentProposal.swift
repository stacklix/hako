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
        var accountID: UUID?
        var assetID: UUID?
        var linkedAccountID: UUID?
    }

    let id: UUID
    private(set) var session: UUID
    let generation: Int64
    let actions: [InvestmentAgentAction]
    let book: InvestmentBook
    let snapshotsOnly: Bool
    let changes: [Change]
    var destructive: Bool { actions.contains(where: \.deletesData) }
    var editable: Bool { !entryEditorIndices.isEmpty }

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
        for section in Self.sections where snapshotsOnly || !InvestmentServerRecords.snapshotTables.contains(section.name) {
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
                var assetID = row["asset_id"].flatMap(UUID.init(uuidString:))
                if section.name == "investment_assets" { assetID = row["id"].flatMap(UUID.init(uuidString:)) }
                if op == .remove, ["market_instruments", "market_derivative_specs", "market_daily_prices"].contains(section.name),
                   let instrument = (row["instrument_id"] ?? row["id"]).flatMap(UUID.init(uuidString:)) {
                    assetID = base.book.assets.values.filter { ($0.instrumentID ?? $0.id) == instrument && candidate.assets[$0.id] == nil }
                        .map(\.id).sorted { $0.uuidString < $1.uuidString }.first
                }
                result.append(.init(id: section.name + ":" + key, operation: op, title: context.title(row, section: section), fields: fields,
                    accountID: row["account_id"].flatMap(UUID.init(uuidString:)), assetID: assetID,
                    linkedAccountID: row["transfer_account_id"].flatMap(UUID.init(uuidString:))))
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
            assets = Dictionary(entries.map { ($0.id.uuidString, $0.kind.isTermDeposit ? $0.name : "\($0.displayName) · \($0.displayCode)") }, uniquingKeysWith: { first, _ in first })
            instruments = Dictionary(entries.map { (($0.instrumentID ?? $0.id).uuidString, "\($0.displayCode) · \($0.currency.rawValue)") }, uniquingKeysWith: { first, _ in first })
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
                return [event.title(for: asset), asset.map { $0.kind.isTermDeposit ? $0.name : $0.displayCode }].compactMap { $0 }.joined(separator: " ")
            }
            let asset = section.name == "investment_assets" ? row["id"].flatMap(UUID.init(uuidString:)).flatMap(book.asset) : nil
            let named = asset?.displayName ?? row["name"] ?? row["symbol"] ?? row["asset_id"].flatMap { assets[$0] }
            let referenced = row["instrument_id"].flatMap { instruments[$0] } ?? row["balance_account_id"].flatMap { balances[$0] }
            let detail = named ?? referenced ?? row["snapshot_date"]
            return [section.title, detail].compactMap { $0 }.joined(separator: " · ")
        }

        func fields(_ source: InvestmentServerRow?, section: String) -> InvestmentServerRow {
            guard let source else { return [:] }
            var row = source
            if section == "investment_assets", let asset = source["id"].flatMap(UUID.init(uuidString:)).flatMap(book.asset) {
                row["name"] = asset.displayName
            }
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

extension InvestmentAgentProposal {
    struct Preview {
        struct Group: Identifiable {
            let title: String
            let fields: [Change.Field]
            var id: String { title }
        }

        struct Item: Identifiable {
            let id: String
            let title: String
            let operation: Change.Operation
            let transaction: Bool
            let groups: [Group]
            let sourceIDs: Set<String>
        }

        let items: [Item]
        var summary: String {
            let trades = items.filter(\.transaction).count
            let others = items.count - trades
            if trades == 0 { return "\(others) 项操作" }
            return "\(trades) 笔交易" + (others == 0 ? "" : " · \(others) 项其他操作")
        }
    }

    var preview: Preview {
        let records = recordPreview.items
        if let maintenance = actions.first, maintenance.kind == .refreshMarket || maintenance.kind == .rebuildSnapshots {
            var fields = Self.sections.compactMap { section -> Change.Field? in
                let rows = changes.filter { $0.id.hasPrefix(section.name + ":") }
                guard !rows.isEmpty else { return nil }
                let counts = [Change.Operation.add, .edit, .remove].compactMap { operation -> String? in
                    let count = rows.filter { $0.operation == operation }.count
                    return count == 0 ? nil : operation.rawValue + " \(count) 条"
                }
                return .init(id: section.name, label: section.title, before: nil, after: counts.joined(separator: "，"))
            }
            if maintenance.kind == .rebuildSnapshots, let snapshots = book.dailySnapshots {
                let report = book.dailySnapshotReport(through: snapshots.through)
                fields.insert(.init(id: "through", label: "计算至", before: nil,
                                    after: InvestmentBook.snapshotDateFormatter().string(from: snapshots.through)), at: 0)
                fields.append(.init(id: "completeness", label: "数据完整性", before: nil,
                                    after: "已计算 \(report.saved) 天，缺少快照 \(report.missing) 天，缺少美元估值 \(report.missingUSD) 天"))
            }
            let effects = records.filter(\.transaction).map { item in
                Preview.Group(title: "同时记入 · " + item.title, fields: item.groups.flatMap(\.fields))
            }
            return Preview(items: [.init(id: "maintenance", title: maintenance.kind.title, operation: .edit, transaction: false,
                                         groups: [.init(title: "更新范围", fields: fields)] + effects, sourceIDs: Set(changes.map(\.id)))])
        }
        var consumed: Set<String> = []
        var setups: [Int: [Int]] = [:]
        for (index, action) in actions.enumerated() where action.kind == .addAsset {
            guard let symbol = action.text("symbol") ?? action.text("name"), let owner = actions.indices.first(where: { candidate in
                guard candidate > index, [.addEvent, .watch, .plan].contains(actions[candidate].kind) else { return false }
                if actions[candidate].text("asset_id")?.caseInsensitiveCompare(symbol) == .orderedSame { return true }
                guard let asset = try? actions[candidate].asset(in: book) else { return false }
                return asset.code.caseInsensitiveCompare(symbol) == .orderedSame
                    && asset.market == (action.text("market")?.uppercased() ?? "")
                    && (!asset.kind.usesMargin || asset.contractSide == action.text("side").flatMap { InvestmentAgentAction.sides[$0] })
            }) else { continue }
            setups[owner, default: []].append(index)
        }
        let attached = Set(setups.values.flatMap { $0 } + actions.indices.compactMap { entryQuoteIndex(for: $0) })
        var result: [Preview.Item] = []
        for (index, action) in actions.enumerated() where !attached.contains(index) {
            let form = action.form(in: book)
            if action.kind == .removeAccount || action.kind == .removePosition,
               let accountID = action.text("account_id").flatMap(UUID.init(uuidString:)) {
                let asset = try? action.asset(in: book)
                let reference = action.text("asset_id") ?? ""
                let deletedRegistration = changes.first { change in
                    change.operation == .remove && change.id.hasPrefix("investment_assets:") &&
                        (change.assetID?.uuidString == reference || change.fields.contains { field in
                            (["symbol", "name"].contains(field.id) && field.before?.caseInsensitiveCompare(reference) == .orderedSame)
                                || (field.id == "instrument_id" && field.before?.hasPrefix(reference + " · ") == true)
                        })
                }
                let targetID = asset?.id ?? UUID(uuidString: reference) ?? deletedRegistration?.assetID
                let accountChange = changes.first { $0.id == "investment_accounts:" + accountID.uuidString }
                let accountName = book.account(accountID).map { $0.name + " · " + $0.currency.rawValue }
                    ?? accountChange?.fields.first { $0.id == "name" }?.before ?? "账户"
                var removed = changes.filter { change in
                    change.operation == .remove &&
                        ((change.accountID == accountID && (action.kind == .removeAccount || change.assetID == targetID))
                            || (action.kind == .removeAccount && change.linkedAccountID == accountID))
                }
                let involved = Set(removed.compactMap(\.assetID) + [targetID].compactMap { $0 })
                let registrations = changes.filter { $0.operation == .remove && $0.id.hasPrefix("investment_assets:")
                    && $0.assetID.map(involved.contains) == true }
                let removedAssets = Set(registrations.compactMap(\.assetID))
                removed += changes.filter { $0.operation == .remove && $0.accountID == nil && $0.assetID.map(removedAssets.contains) == true }
                let sourceIDs = Set(removed.map(\.id) + [accountChange?.id].compactMap { $0 })
                let associated = records.filter { !$0.sourceIDs.isDisjoint(with: sourceIDs) }
                consumed.formUnion(associated.map(\.id))
                let events = removed.filter { $0.id.hasPrefix("investment_events:") }
                let plans = removed.filter { $0.id.hasPrefix("investment_plans:") }
                let counterpartNames = Set(events.filter { $0.accountID != accountID }
                    .compactMap { $0.fields.first { $0.id == "account_id" }?.before }).sorted()
                var fields: [Change.Field] = [
                    .init(id: "account", label: "所属账户", before: accountName, after: nil),
                    .init(id: "records", label: "同时删除交易记录", before: "\(events.count) 条", after: nil),
                    .init(id: "plans", label: "同时删除定投及执行记录", before: "\(plans.count) 项定投", after: nil)
                ]
                if action.kind == .removePosition {
                    let label = asset.map { $0.displayName + " · " + $0.displayCode }
                        ?? events.first?.fields.first { $0.id == "asset_id" }?.before
                        ?? deletedRegistration?.fields.first { $0.id == "name" }?.before
                    fields.insert(.init(id: "asset", label: "持仓标的", before: label, after: nil), at: 1)
                }
                let removedNames = registrations.compactMap { $0.fields.first { $0.id == "name" }?.before }.sorted()
                if !removedNames.isEmpty {
                    fields.append(.init(id: "removed_assets", label: "同时删除标的登记及报价", before: removedNames.joined(separator: "、"), after: nil))
                }
                let retainedNames = involved.compactMap { book.asset($0)?.displayName }.sorted()
                if !retainedNames.isEmpty {
                    fields.append(.init(id: "retained_assets", label: "保留仍被引用的标的登记", before: retainedNames.joined(separator: "、") + "（其他流水、定投、关注或合约仍引用）", after: nil))
                }
                if !counterpartNames.isEmpty {
                    fields.append(.init(id: "transfers", label: "对应划转同时删除", before: counterpartNames.joined(separator: "、"), after: nil))
                }
                fields.append(.init(id: "consequence", label: "删除后", before: "余额和历史统计重新计算，无法撤销。", after: nil))
                result.append(.init(id: "action-\(index)", title: action.kind.title, operation: .remove, transaction: false,
                    groups: [.init(title: "删除范围", fields: fields)], sourceIDs: sourceIDs.union(associated.flatMap(\.sourceIDs))))
                continue
            }
            var related = records.filter { item in !consumed.contains(item.id) && relates(item, to: action) }
            if action.kind == .transfer, let first = related.first,
               let transferID = event(for: first)?.transferID {
                related = related.filter { event(for: $0)?.transferID == transferID }
            } else if action.kind == .distribution {
                var kinds: Set<InvestmentEventKind> = []
                related = related.filter { item in event(for: item).map { kinds.insert($0.kind).inserted } ?? false }
            } else if [.addEvent, .cashBalance, .spotBalance, .fundingBalance, .plan, .balanceRecord].contains(action.kind) {
                related = Array(related.prefix(1))
            }
            if action.kind == .balanceAccount, let row = related.first {
                let accountID = String(row.id.dropFirst("investment_balance_accounts:".count))
                let recordIDs = book.balanceSheet?.accounts.first { $0.id.uuidString == accountID }?.records.map { "investment_balance_records:" + $0.id.uuidString } ?? []
                related += records.filter { recordIDs.contains($0.id) && !consumed.contains($0.id) }
            }
            if let quote = entryQuoteIndex(for: index) {
                related += records.filter { !consumed.contains($0.id) && relates($0, to: actions[quote]) }
            }
            consumed.formUnion(related.map(\.id))
            let record = related.first
            let sourceIDs = Set(related.flatMap(\.sourceIDs))
            let operation: Change.Operation
            switch action.kind {
            case .deleteEvent, .removeAccount, .removePosition, .removePlan, .deleteBalanceRecord: operation = .remove
            case .watch: operation = action.text("enabled") == "false" ? .remove : .add
            case .editEvent, .editAccount, .archiveAccount, .restoreAccount, .editAsset, .editBalanceRecord, .cashBalance, .spotBalance, .fundingBalance: operation = .edit
            case .plan: operation = action.text("plan_id") == nil ? .add : .edit
            default: operation = record?.operation ?? .add
            }
            if action.kind == .deleteEvent, let record {
                result.append(.init(id: "action-\(index)", title: record.title, operation: .remove, transaction: true, groups: record.groups, sourceIDs: sourceIDs))
                continue
            }
            var fieldKeys = ["date": "effective_date", "price": "unit_price", "margin": "margin_delta", "settlement_rate": "settlement_to_account_rate",
                             "settled_amount": "settled_amount", "symbol": "symbol", "market": "exchange", "multiplier": "contract_multiplier", "position": "sort_order"]
            if action.kind == .quote { fieldKeys["date"] = "valuation_date"; fieldKeys["price"] = "value" }
            if [.balanceAccount, .balanceRecord, .editBalanceRecord].contains(action.kind) { fieldKeys["date"] = "recorded_at" }
            let recordFields = related.flatMap(\.groups).flatMap(\.fields)
            func present(_ field: InvestmentAgentForm.Field) -> Change.Field {
                let original = recordFields.first { $0.id == fieldKeys[field.key, default: field.key] }
                var display = field.displayValue
                if field.value == nil, action.values[field.key] == nil, let value = original?.after ?? original?.before { display = value }
                if operation == .remove, field.isReference {
                    display = original?.before ?? record?.title ?? display
                }
                var before = operation == .edit ? original?.before ?? display : operation == .remove ? display : nil
                if field.key == "amount", [.cashBalance, .spotBalance, .fundingBalance].contains(action.kind) { before = nil }
                if action.kind == .editEvent, field.key == "amount", let raw = before, let amount = Decimal(string: raw) {
                    before = NSDecimalNumber(decimal: abs(amount)).stringValue
                }
                if action.kind == .editEvent, field.key == "quantity", let raw = before, let quantity = Decimal(string: raw) {
                    before = NSDecimalNumber(decimal: abs(quantity)).stringValue
                }
                if action.kind == .editEvent, field.key == "direction", let raw = recordFields.first(where: { $0.id == "amount" })?.before,
                   let amount = Decimal(string: raw) { before = amount < 0 ? "减少 / 扣款" : "增加 / 入账" }
                if field.key == "quantity", action.text("quantity_mode") == "coins" || action.text("quantity_mode") == "notional" { before = nil }
                return .init(id: field.key, label: field.label, before: before, after: operation == .remove ? nil : display)
            }
            var groups: [Preview.Group] = []
            if [.addEvent, .editEvent].contains(action.kind), let assetGroup = record?.groups.first(where: { $0.fields.contains { $0.id == "selected_asset" } }) {
                groups.append(assetGroup)
            } else {
                for setup in setups[index] ?? [] {
                    let details = actions[setup].form(in: book)
                    groups.append(.init(title: "标的信息", fields: details.fields.map(present)))
                }
            }
            let hidden: Set<String> = groups.isEmpty ? [] : ["account_id", "asset_id"]
            for group in form.groups {
                let fields = group.fields.filter { !hidden.contains($0.key) && $0.key != "event_id" }.map(present)
                guard !fields.isEmpty else { continue }
                let groupTitle = [.addEvent, .editEvent].contains(action.kind) ?
                    ((try? action.asset(in: book))?.basis == .coin ? "使用结算币余额" : "交易信息") : group.title
                groups.append(.init(title: groupTitle, fields: fields))
            }
            if let quote = entryQuoteIndex(for: index) {
                let fields = actions[quote].form(in: book).fields.filter { $0.key != "asset_id" }.map { field in
                    Change.Field(id: "valuation-" + field.key, label: field.label, before: nil, after: field.displayValue)
                }
                groups.append(.init(title: "估值信息", fields: fields))
            }
            if action.text("quantity_mode") == "coins" || action.text("quantity_mode") == "notional",
               let quantity = recordFields.first(where: { $0.id == "quantity" }) {
                groups.append(.init(title: "数量折算", fields: [.init(id: "contract_count", label: "折算张数", before: quantity.before, after: quantity.after)]))
            }
            if action.kind == .deleteBalanceRecord || action.kind == .removePlan || action.kind == .removeAccount {
                let details = related.flatMap(\.groups).flatMap(\.fields)
                if !details.isEmpty { groups.append(.init(title: "将删除的内容", fields: details)) }
            }
            // Balance changes and linked transfer legs remain visible without becoming extra operations.
            let cash = related.flatMap(\.groups).filter { $0.title == "余额影响" }.flatMap(\.fields)
            if !cash.isEmpty {
                groups.append(.init(title: "余额影响", fields: cash.enumerated().map { index, field in
                    .init(id: "cash-\(index)", label: field.label, before: field.before, after: field.after)
                }))
            }
            let transaction = [.addEvent, .editEvent, .deleteEvent, .transfer, .distribution, .cashBalance, .spotBalance, .fundingBalance].contains(action.kind)
            let title = [.addEvent, .editEvent].contains(action.kind) ? record?.title ?? form.title : form.title
            result.append(.init(id: "action-\(index)", title: title, operation: operation, transaction: transaction, groups: groups, sourceIDs: sourceIDs))
        }
        let effects = records.filter { $0.transaction && !consumed.contains($0.id) }
        if !effects.isEmpty, let last = result.popLast() {
            let groups = effects.map { item in
                Preview.Group(title: (item.operation == .remove ? "同时删除 · " : item.operation == .edit ? "同时更新 · " : "同时记入 · ") + item.title,
                              fields: item.groups.flatMap(\.fields))
            }
            result.append(.init(id: last.id, title: last.title, operation: last.operation, transaction: last.transaction,
                                groups: last.groups + groups, sourceIDs: last.sourceIDs.union(effects.flatMap(\.sourceIDs))))
        }
        return Preview(items: result)
    }

    private func event(for item: Preview.Item) -> InvestmentEvent? {
        guard item.transaction else { return nil }
        let id = String(item.id.dropFirst("investment_events:".count))
        return book.accounts.lazy.flatMap(\.events).first { $0.id.uuidString == id }
    }

    private func relates(_ item: Preview.Item, to action: InvestmentAgentAction) -> Bool {
        let prefix: String?
        switch action.kind {
        case .addAccount, .editAccount, .removeAccount, .archiveAccount, .restoreAccount: prefix = "investment_accounts:"
        case .addAsset, .editAsset: prefix = "investment_assets:"
        case .plan, .removePlan: prefix = "investment_plans:"
        case .watch: prefix = "investment_watchlist:"
        case .quote: prefix = "investment_manual_prices:"
        case .balanceAccount: prefix = "investment_balance_accounts:"
        case .balanceRecord, .editBalanceRecord, .deleteBalanceRecord: prefix = "investment_balance_records:"
        default: prefix = nil
        }
        if let prefix {
            guard item.id.hasPrefix(prefix) else { return false }
            let key = String(item.id.dropFirst(prefix.count)).components(separatedBy: "\u{1F}").first ?? ""
            let identifiers = ["account_id", "asset_id", "plan_id", "balance_account_id", "record_id"].compactMap(action.text)
            if identifiers.contains(key) || (try? action.asset(in: book).id.uuidString) == key { return true }
            let fields = item.groups.flatMap(\.fields)
            if let name = action.text("name"), fields.contains(where: { $0.id == "name" && ($0.after ?? $0.before) == name }) { return true }
            if action.kind == .plan, let plan = book.plans.first(where: { $0.id.uuidString == key }) {
                return plan.accountID.uuidString == action.text("account_id") && plan.assetID == (try? action.asset(in: book))?.id &&
                    plan.amount == action.text("amount").flatMap { Decimal(string: $0) } && plan.monthDay == action.text("month_day").flatMap(Int.init)
            }
            if action.kind == .balanceRecord, let account = book.balanceSheet?.accounts.first(where: { $0.id.uuidString == action.text("balance_account_id") }),
               let record = account.records.first(where: { $0.id.uuidString == key }) {
                return record.amount == action.text("amount").flatMap { Decimal(string: $0) } &&
                    InvestmentBook.snapshotDateFormatter().string(from: record.recordedAt) == action.text("date")
            }
            return false
        }
        guard item.transaction else { return false }
        if let event = action.text("event_id") { return item.id == "investment_events:" + event }
        let key = String(item.id.dropFirst("investment_events:".count))
        guard let owner = book.accounts.first(where: { $0.events.contains { $0.id.uuidString == key } }),
              let event = owner.events.first(where: { $0.id.uuidString == key }) else { return false }
        if action.kind == .transfer {
            return event.transferID != nil &&
                ((owner.id.uuidString == action.text("account_id") && event.transferAccountID?.uuidString == action.text("target_id") &&
                  abs(event.amount) == action.text("amount").flatMap { Decimal(string: $0) }) ||
                 (owner.id.uuidString == action.text("target_id") && event.transferAccountID?.uuidString == action.text("account_id") &&
                  event.amount == (action.text("received") ?? action.text("amount")).flatMap { Decimal(string: $0) })) &&
                InvestmentBook.snapshotDateFormatter().string(from: event.day) == action.text("date")
        }
        guard owner.id.uuidString == action.text("account_id"),
              InvestmentBook.snapshotDateFormatter().string(from: event.day) == action.text("date") else { return false }
        let asset = try? action.asset(in: book)
        if let asset, asset.id != event.assetID { return false }
        switch action.kind {
        case .addEvent:
            guard event.kind == action.text("event_type").flatMap({ InvestmentAgentAction.eventKinds[$0] }) else { return false }
            if let price = action.text("price"), Decimal(string: price) != event.price { return false }
            if let quantity = action.text("quantity").flatMap({ Decimal(string: $0) }) {
                var expected = quantity
                if let asset, asset.kind == .cryptoContract, asset.basis == .coin {
                    let input: InvestmentCoinContractQuantity
                    if action.text("quantity_mode") == "coins" {
                        input = .coins(quantity, referencePrice: action.text("reference_price").flatMap { Decimal(string: $0) } ?? 0)
                    } else if action.text("quantity_mode") == "notional" { input = .notionalUSD(quantity) }
                    else { input = .contracts(quantity) }
                    guard let count = try? input.contractCount(faceValue: asset.multiplier) else { return false }
                    expected = count
                }
                if expected != (event.kind == .spotAdjustment ? abs(event.quantity) : event.quantity) { return false }
            }
            if let fee = action.text("fee").flatMap({ Decimal(string: $0) }), fee != (event.fee ?? 0) { return false }
            if let margin = action.text("margin").flatMap({ Decimal(string: $0) }), margin != event.margin { return false }
            if let amount = action.text("amount"), let number = Decimal(string: amount), abs(number) != abs(event.amount) { return false }
            return true
        case .distribution:
            return event.kind == .dividend && event.amount == action.text("amount").flatMap { Decimal(string: $0) } ||
                event.kind == .bonusShares && event.quantity == action.text("quantity").flatMap { Decimal(string: $0) }
        case .cashBalance: return event.kind == .adjustment && event.assetID == nil
        case .spotBalance: return event.kind == .stakingReward || event.kind == .spotAdjustment
        case .fundingBalance: return event.kind == .funding
        default: return false
        }
    }

    // The record projection supplies before/after values and automatically generated effects.
    private var recordPreview: Preview {
        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        let owners = book.accounts.flatMap { account in account.events.map { (account, $0) } }
        var consumed: Set<String> = []
        var items: [Preview.Item] = []

        func assetChanges(_ asset: InvestmentAsset) -> [Change] {
            let instrument = changes.first {
                $0.id.hasPrefix("market_instruments:") && $0.operation == .add &&
                    $0.value("symbol") == asset.code && $0.value("exchange") == asset.market
            }
            let ids = ["investment_assets:" + asset.id.uuidString, instrument?.id ?? "",
                       instrument.map { "market_derivative_specs:" + $0.recordKey } ?? ""]
            let quotePrefixes = ["investment_manual_prices:" + asset.id.uuidString + "\u{1F}",
                                 "market_daily_prices:" + (instrument?.recordKey ?? (asset.instrumentID ?? asset.id).uuidString) + "\u{1F}"]
            let quotes = changes.filter { change in quotePrefixes.contains { change.id.hasPrefix($0) } }
            return (ids.compactMap { byID[$0] } + quotes).filter { $0.operation == .add }
        }

        for change in changes where change.isEvent || change.isEventDetail {
            let key = change.recordKey
            let eventID = "investment_events:" + key
            guard !consumed.contains(eventID), !consumed.contains(change.id) else { continue }
            let eventChange = byID[eventID]
            let detail = byID["investment_derivative_event_details:" + key]
            let primary = eventChange ?? change
            let pair = owners.first { $0.1.id.uuidString == key }
            let asset = book.asset(pair?.1.assetID) ?? book.assets.values.first {
                ($0.kind.isTermDeposit ? $0.name : "\($0.displayName) · \($0.displayCode)") == primary.value("asset_id")
            }
            var fields = eventChange?.fields ?? []
            for field in detail?.fields ?? [] where !fields.contains(where: { $0.id == field.id }) { fields.append(field) }
            var sources = Set([eventChange?.id, detail?.id].compactMap { $0 })
            if let asset, primary.operation == .add { sources.formUnion(assetChanges(asset).map(\.id)) }
            consumed.formUnion(sources)
            consumed.insert(eventID)
            let groups = eventForm(fields: fields, operation: primary.operation, account: pair?.0, event: pair?.1, asset: asset)
            let title = eventChange?.title ?? pair.map { pair in
                [pair.1.title(for: asset), asset?.displayCode].compactMap { $0 }.joined(separator: " ")
            } ?? primary.title
            items.append(.init(id: eventID, title: title, operation: primary.operation, transaction: true,
                               groups: groups, sourceIDs: sources))
        }

        for change in changes where !consumed.contains(change.id) && change.id.hasPrefix("investment_assets:") {
            guard let id = UUID(uuidString: change.recordKey), let asset = book.asset(id) else { continue }
            let related = change.operation == .add ? assetChanges(asset) : []
            let sources = Set([change.id] + related.map(\.id))
            consumed.formUnion(sources)
            let fields = change.fields + related.filter { $0.id != change.id }.flatMap(\.fields)
            items.append(.init(id: change.id, title: change.title, operation: change.operation, transaction: false,
                               groups: [.init(title: "标的信息", fields: assetForm(asset, fields: fields, operation: change.operation))],
                               sourceIDs: sources))
        }

        for change in changes where !consumed.contains(change.id) {
            let fields = change.fields.filter { !Self.internalPreviewFields.contains($0.id) }.map { field in
                let labels = change.id.hasPrefix("investment_accounts:")
                    ? ["name": "账户名称", "currency": "账户币种", "account_type": "账户类型"] : [:]
                return Change.Field(id: field.id, label: labels[field.id] ?? field.label, before: field.before, after: field.after)
            }
            items.append(.init(id: change.id, title: change.title, operation: change.operation, transaction: false,
                               groups: [.init(title: "", fields: fields)], sourceIDs: [change.id]))
        }
        return Preview(items: items)
    }

    private static let internalPreviewFields: Set<String> = ["id", "event_id", "instrument_id", "trade_action", "plan_id", "computed_revision"]

    private func assetForm(_ asset: InvestmentAsset, fields: [Change.Field], operation: Change.Operation) -> [Change.Field] {
        let form = FormFields(fields: fields, operation: operation)
        let contract = asset.kind == .cryptoContract
        let selected = fields.first { $0.id == "asset_id" }.map {
            Change.Field(id: "selected_asset", label: "已选标的", before: $0.before, after: $0.after)
        } ?? form.context("selected_asset", "已选标的", asset.kind.isTermDeposit ? asset.name : asset.displayName + " · " + asset.displayCode)
        var result = [
            form.context("quote_currency", "报价币种", asset.currency.title + " · " + asset.currency.rawValue),
            form.context("asset_type", "资产类型", contract ? asset.basis.rawValue + "合约" : asset.kind.title),
            selected
        ]
        if !asset.kind.isTermDeposit && asset.kind != .insurance && asset.kind != .wealth {
            result.append(form.field("exchange", contract ? "报价交易所" : "交易所", asset.market))
        }
        if contract {
            result.append(form.field("settlement_unit", "结算币种", book.settlementUnit(for: asset)))
            let quote = book.quote(asset.id)
            let state: String
            if let quote {
                let unit = asset.basis == .coin ? "USD/" + book.settlementUnit(for: asset) : book.quoteUnit(for: asset)
                state = [quote.source ?? "报价", NSDecimalNumber(decimal: quote.price).stringValue + " " + unit,
                         InvestmentBook.snapshotDateFormatter().string(from: quote.day)].joined(separator: " · ")
            } else { state = "暂未取得报价，可在行情恢复后刷新" }
            result.append(form.context("quote_state", "行情报价", state))
        }
        if asset.kind.usesMargin {
            result.append(form.context("position_side", "开仓方向", (asset.contractSide ?? .long).rawValue))
            result.append(form.field("contract_multiplier", asset.basis == .coin ? "每张合约面值（USD）" : "合约乘数",
                                     NSDecimalNumber(decimal: asset.multiplier).stringValue))
        }
        // Existing asset edits must retain their before/after values, especially a renamed instrument.
        for key in ["name", "symbol", "annual_rate", "maturity_date"] {
            if let field = fields.first(where: { $0.id == key && (operation != .add || key != "name") }) {
                if key == "symbol", operation != .edit { continue }
                result.append(field)
            }
        }
        return result
    }

    private func eventForm(fields: [Change.Field], operation: Change.Operation, account: InvestmentAccount?,
                           event: InvestmentEvent?, asset: InvestmentAsset?) -> [Preview.Group] {
        let form = FormFields(fields: fields, operation: operation)
        let title = event?.title(for: asset) ?? fields.first { $0.id == "event_type" }.map { $0.after ?? $0.before ?? "" } ?? "流水"
        let trade = event.map { [.buy, .sell, .opening].contains($0.kind) } ??
            ["买入", "卖出", "开多", "开空", "平多", "平空", "首次录入"].contains(title)
        var groups: [Preview.Group] = []
        if let asset {
            groups.append(.init(title: account?.name ?? fields.first { $0.id == "account_id" }.flatMap { $0.after ?? $0.before } ?? "标的信息",
                                fields: assetForm(asset, fields: fields, operation: operation)))
        }
        var values: [Change.Field] = []
        if asset == nil {
            values.append(form.field("account_id", "账户", account.map { $0.name + " · " + $0.currency.rawValue }))
        }
        values.append(form.field("event_type", "流水类型", title))
        let day = event.map { InvestmentBook.snapshotDateFormatter().string(from: $0.day) }
        values.append(form.field("effective_date", trade && operation == .add ? "成交日期" : "记账日期", day))
        let currency = account?.currency.rawValue ?? ""
        if trade, let asset {
            let settlement = book.settlementUnit(for: asset)
            let coin = asset.kind == .cryptoContract && asset.basis == .coin
            let unit = coin || (asset.kind == .cryptoContract && asset.market == "HTX") ? "张" : asset.kind.unit
            if coin { values.append(form.context("quantity_mode", "数量录入方式", "按张数")) }
            if asset.kind != .insurance && !asset.kind.isTermDeposit {
                values.append(form.field("quantity", "数量（\(unit)）", event.map { NSDecimalNumber(decimal: $0.quantity).stringValue }))
            }
            let quote = coin ? "USD/" + settlement : book.quoteUnit(for: asset)
            let priceLabel = asset.kind.isTermDeposit ? (event?.kind == .sell ? "支取金额（CNY）" : "存入金额（CNY）")
                : asset.kind == .insurance ? (event?.kind == .sell ? "退保到账金额（HKD）" : "保费金额（HKD）") : "成交价（\(quote)）"
            values.append(form.field("unit_price", priceLabel, event.map { NSDecimalNumber(decimal: $0.price).stringValue }))
            if asset.isStockConnect || asset.kind.isTermDeposit {
                values.append(form.field("settled_amount", asset.kind.isTermDeposit ? "变动后余额（CNY）" :
                    (event?.kind == .sell ? "实际到账金额（CNY）" : "实际成本金额（CNY）")))
            }
            if asset.kind.supportsTradeFees && !asset.isStockConnect && event?.kind != .opening {
                values.append(form.field("fee", "交易费用（\(settlement)，选填）", event?.fee.map { NSDecimalNumber(decimal: $0).stringValue } ?? "未填写"))
            }
            if asset.kind.usesMargin && event?.kind != .sell && !["平多", "平空"].contains(title) {
                var margin = form.field("margin_delta", asset.kind == .cryptoContract ? "本次开仓保证金总额（\(settlement)）" : "每手初始保证金（\(settlement)）",
                                        event.map { NSDecimalNumber(decimal: $0.margin).stringValue })
                if asset.kind == .future, let raw = fields.first(where: { $0.id == "margin_delta" }) {
                    let quantity = fields.first { $0.id == "quantity" }
                    func perContract(_ value: String?, _ count: String?) -> String? {
                        guard let value, let total = Decimal(string: value), let count, let quantity = Decimal(string: count), quantity != 0 else { return value }
                        return NSDecimalNumber(decimal: total / quantity).stringValue
                    }
                    margin = .init(id: margin.id, label: margin.label, before: perContract(raw.before, quantity?.before), after: perContract(raw.after, quantity?.after))
                }
                values.append(margin)
            }
            if asset.collateralAssetID != nil {
                values.append(form.field("settlement_to_account_rate", settlement + " 兑美元单价",
                                         event?.settlementRate.map { NSDecimalNumber(decimal: $0).stringValue } ?? "未填写"))
            }
        } else {
            values += fields.filter { !Self.internalPreviewFields.contains($0.id) && !["account_id", "asset_id", "event_type", "effective_date", "cash_change"].contains($0.id) }.map { field in
                let labels = ["amount": "金额（\(asset.map { book.settlementUnit(for: $0) } ?? currency)）", "unit_price": "成交价（\(currency)）"]
                return Change.Field(id: field.id, label: labels[field.id] ?? field.label, before: field.before, after: field.after)
            }
        }
        let groupTitle = trade && asset?.basis == .coin ? "使用结算币余额" : trade ? "交易信息" : "流水信息"
        groups.append(.init(title: groupTitle, fields: values))
        if let cash = fields.first(where: { $0.id == "cash_change" }) { groups.append(.init(title: "余额影响", fields: [cash])) }
        return groups
    }

    private struct FormFields {
        let fields: [Change.Field]
        let operation: Change.Operation

        func field(_ id: String, _ label: String, _ value: String? = nil) -> Change.Field {
            if let field = fields.first(where: { $0.id == id }) {
                return .init(id: id, label: label, before: field.before, after: field.after)
            }
            return context(id, label, value ?? "—")
        }

        func context(_ id: String, _ label: String, _ value: String) -> Change.Field {
            .init(id: id, label: label, before: operation == .add ? nil : value, after: operation == .remove ? nil : value)
        }
    }
}

private extension InvestmentAgentProposal.Change {
    var recordKey: String { String(id.drop { $0 != ":" }.dropFirst()) }
    var isEvent: Bool { id.hasPrefix("investment_events:") }
    var isEventDetail: Bool { id.hasPrefix("investment_derivative_event_details:") }
    func value(_ key: String) -> String? { fields.first { $0.id == key }.flatMap { $0.after ?? $0.before } }
}
