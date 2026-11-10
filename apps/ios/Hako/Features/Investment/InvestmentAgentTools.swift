import Foundation

enum InvestmentAgentTools {
    static let read = LanguageModelTool(name: "read_ledger",
        description: "查询投资账簿。先读账户和标的获取真实 ID，可分页读取。金额用精确十进制字符串返回。",
        properties: [
            "section": ["type": "string", "enum": ["overview", "holdings", "balance"] + InvestmentAgentProposal.sections.map(\.name)],
            "id": ["type": "string", "description": "精确记录 ID"],
            "account_id": ["type": "string", "description": "投资账户 ID 或资产负债账户 ID"],
            "asset_id": ["type": "string", "description": "精确标的 ID"],
            "from": ["type": "string", "description": "起始日期 YYYY-MM-DD"],
            "through": ["type": "string", "description": "截止日期 YYYY-MM-DD；汇总以此日为准，默认今天"],
            "offset": ["type": "integer", "minimum": 0],
            "limit": ["type": "integer", "minimum": 1, "maximum": 40]
        ], required: ["section"])
    static let searchTool = LanguageModelTool(name: "search_instruments", description: "按名称或代码查找行情标的。非美元线性的加密合约需指定本位。搜索结果可以用于登记新标的；结果 ID 只有已登记时才能直接引用。",
        properties: ["query": ["type": "string"],
                     "asset_type": ["type": "string", "enum": InvestmentAgentAction.assetKinds.keys.sorted()],
                     "currency": ["type": "string", "enum": ["CNY", "USD", "HKD"]],
                     "stock_connect": ["type": "boolean"],
                     "basis": ["type": "string", "enum": ["coin", "stablecoin"]]], required: ["query", "asset_type", "currency"])
    static let export = LanguageModelTool(name: "offer_ledger_export", description: "在应用内显示导出账本按钮，用户点击后保存服务端 ZIP。ZIP 内容不会返回给模型。",
                                          properties: [:], required: [])
    static let all = [read, searchTool, InvestmentAgentAction.tool, export]

    static func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func rows(_ args: [String: Any], base: InvestmentAgentSnapshot) throws -> String {
        guard let section = args["section"] as? String else { throw InvestmentError.invalid("请选择查询范围。") }
        let account = try id(args, key: "account_id")
        let asset = try id(args, key: "asset_id")
        let record = try id(args, key: "id")
        let from = try day(args, key: "from")
        let through = try day(args, key: "through")
        if let from, let through, from > through { throw InvestmentError.invalid("起始日期不能晚于截止日期。") }
        let formatter = InvestmentBook.snapshotDateFormatter()
        let asOf = through ?? InvestmentBook.day()
        var values: [InvestmentServerRow]
        switch section {
        case "overview":
            var row = ["date": formatter.string(from: asOf)]
            for currency in [InvestmentCurrency.cny, .usd] {
                let valuation = base.book.portfolio(on: asOf, currency: currency)
                row["value_" + currency.rawValue] = decimal(valuation?.value)
                row["gain_" + currency.rawValue] = decimal(valuation?.gain)
            }
            row["status"] = row["value_CNY"] == nil ? "missing_valuation" : "available"
            values = [row]
        case "balance":
            let balance = base.book.balanceSnapshot(on: asOf)
            var row = ["date": formatter.string(from: asOf), "currency": "CNY"]
            row["assets"] = decimal(balance.assets)
            row["liabilities"] = decimal(balance.liabilities)
            row["net"] = decimal(balance.net)
            row["debt_ratio"] = decimal(balance.debtRatio)
            for category in InvestmentBalanceCategory.allCases { row[category.rawValue] = decimal(balance.amount(category)) }
            values = [row]
        case "holdings":
            values = []
            for item in base.book.accounts where account == nil || item.id.uuidString == account {
                let ledger = try base.book.ledger(item, through: asOf)
                values.append(["account_id": item.id.uuidString, "account": item.name, "cash": decimal(ledger.cash) ?? "0",
                               "currency": item.currency.rawValue])
                for id in ledger.positions.keys.sorted(by: { $0.uuidString < $1.uuidString }) where asset == nil || id.uuidString == asset {
                    guard let position = ledger.positions[id], let holding = base.book.asset(id), position.quantity != 0 else { continue }
                    var row = assetRow(holding)
                    row["account_id"] = item.id.uuidString
                    row["account"] = item.name
                    row["quantity"] = decimal(position.quantity)
                    row["net_cost"] = decimal(position.netCost)
                    row["realized_gain"] = decimal(position.realized)
                    row["margin"] = decimal(position.margin)
                    row["latest_quote"] = decimal(base.book.quote(id, on: asOf)?.price)
                    values.append(row)
                }
            }
        default:
            guard let table = InvestmentAgentProposal.sections.first(where: { $0.name == section }) else {
                throw InvestmentError.invalid("未知的账簿查询范围。")
            }
            let dates = ["effective_date", "recorded_at", "snapshot_date", "valuation_date", "rate_date", "scheduled_date", "next_date"]
            let first = from.map(formatter.string(from:))
            let last = through.map(formatter.string(from:))
            let lower = first ?? ""
            let upper = last ?? "9999-12-31"
            func rowDay(_ row: InvestmentServerRow) -> String {
                for key in dates {
                    if let value = row[key] {
                        if key == "recorded_at" {
                            let timestamp = ISO8601DateFormatter()
                            timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            if let date = timestamp.date(from: value) { return formatter.string(from: date) }
                        }
                        return String(value.prefix(10))
                    }
                }
                return ""
            }
            let filtered = (base.tables[section] ?? []).compactMap { row -> (InvestmentServerRow, String)? in
                let owner = row["account_id"] ?? row["balance_account_id"]
                    ?? (section == "investment_accounts" || section == "investment_balance_accounts" ? row["id"] : nil)
                let target = row["asset_id"] ?? (section == "investment_assets" ? row["id"] : nil)
                let key = row["id"] ?? row["event_id"] ?? row["instrument_id"]
                guard (account == nil || account == owner), (asset == nil || asset == target), (record == nil || record == key) else { return nil }
                let date = rowDay(row)
                guard (first == nil && last == nil) || (!date.isEmpty && date >= lower && date <= upper) else { return nil }
                return (row, date)
            }
            values = filtered.sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                if section == "investment_events", let l = Int(left.0["sequence"] ?? ""), let r = Int(right.0["sequence"] ?? ""), l != r { return l > r }
                return table.key(left.0) < table.key(right.0)
            }.map { $0.0 }
        }
        let offset = min(max(args["offset"] as? Int ?? 0, 0), values.count)
        let limit = min(max(args["limit"] as? Int ?? 20, 1), 40)
        let end = min(offset + limit, values.count)
        var result: [String: Any] = ["section": section, "total": values.count, "rows": Array(values[offset..<end])]
        if end < values.count { result["next_offset"] = end }
        return try json(result)
    }

    @MainActor
    static func search(_ args: [String: Any], store: InvestmentStore, base: InvestmentAgentSnapshot) async throws -> String {
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...100).contains(query.count),
              let kind = (args["asset_type"] as? String).flatMap({ InvestmentAgentAction.assetKinds[$0] }),
              let currency = (args["currency"] as? String).flatMap(InvestmentCurrency.init(rawValue:)) else {
            throw InvestmentError.invalid("请提供标的代码或名称、类型和币种。")
        }
        var values: [InvestmentServerRow]
        if kind == .cryptoContract, let basis = (args["basis"] as? String).flatMap({ InvestmentAgentAction.bases[$0] }), basis != .usd {
            values = try await store.searchContracts(query, basis: basis).prefix(20).map { listing in
                var row = assetRow(listing.asset)
                row["settlement_unit"] = listing.settlementCode
                row["basis"] = args["basis"] as? String
                return row
            }
        } else {
            let search = InvestmentInstrumentSearch(query: query, kind: kind, currency: currency, stockConnect: args["stock_connect"] as? Bool ?? false)
            values = try await store.searchInstruments(search).prefix(20).map(assetRow)
        }
        for index in values.indices {
            if let id = values[index]["id"], base.book.asset(UUID(uuidString: id)) == nil { values[index].removeValue(forKey: "id") }
        }
        return try json(["rows": values])
    }

    private static func assetRow(_ asset: InvestmentAsset) -> InvestmentServerRow {
        ["id": asset.id.uuidString, "name": asset.name, "symbol": asset.code, "market": asset.market,
         "currency": asset.currency.rawValue, "asset_type": InvestmentAgentAction.assetKinds.first { $0.value == asset.kind }?.key ?? asset.kind.title,
         "multiplier": decimal(asset.multiplier) ?? "1"]
    }

    private static func decimal(_ value: Decimal?) -> String? { value.map { NSDecimalNumber(decimal: $0).stringValue } }

    private static func id(_ args: [String: Any], key: String) throws -> String? {
        guard let value = args[key] else { return nil }
        guard let text = value as? String, let id = UUID(uuidString: text) else { throw InvestmentError.invalid("请使用有效的记录 ID。") }
        return id.uuidString
    }

    private static func day(_ args: [String: Any], key: String) throws -> Date? {
        guard let value = args[key] else { return nil }
        let formatter = InvestmentBook.snapshotDateFormatter()
        guard let text = value as? String, let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw InvestmentError.invalid("日期应使用 YYYY-MM-DD 格式。")
        }
        return date
    }
}
