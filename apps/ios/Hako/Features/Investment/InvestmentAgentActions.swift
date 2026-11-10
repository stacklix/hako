import Foundation

struct InvestmentAgentAction: Codable {
    enum Kind: String, CaseIterable, Codable {
        case addAccount = "add_account", editAccount = "edit_account", removeAccount = "remove_account"
        case addAsset = "add_asset", editAsset = "edit_asset"
        case addEvent = "add_event", editEvent = "edit_event", deleteEvent = "delete_event"
        case transfer, distribution, cashBalance = "cash_balance", spotBalance = "spot_balance", fundingBalance = "funding_balance"
        case plan, removePlan = "remove_plan", watch, quote
        case balanceAccount = "balance_account", balanceRecord = "balance_record"
        case editBalanceRecord = "edit_balance_record", deleteBalanceRecord = "delete_balance_record"
        case refreshMarket = "refresh_market", rebuildSnapshots = "rebuild_snapshots"

        var title: String {
            switch self {
            case .addAccount: "新增账户"
            case .editAccount: "修改账户"
            case .removeAccount: "移除空账户"
            case .addAsset: "登记标的"
            case .editAsset: "修改标的资料"
            case .addEvent: "新增流水"
            case .editEvent: "修改流水"
            case .deleteEvent: "删除流水"
            case .transfer: "账户划转"
            case .distribution: "现金分红或送股"
            case .cashBalance: "调整现金余额"
            case .spotBalance: "调整现货数量"
            case .fundingBalance: "调整合约余额"
            case .plan: "新建或修改定投"
            case .removePlan: "删除定投"
            case .watch: "调整关注"
            case .quote: "录入手工报价"
            case .balanceAccount: "添加资产负债账户"
            case .balanceRecord: "记录资产负债余额"
            case .editBalanceRecord: "修改资产负债记录"
            case .deleteBalanceRecord: "删除资产负债记录"
            case .refreshMarket: "刷新行情和汇率"
            case .rebuildSnapshots: "重算历史快照"
            }
        }
    }

    struct Field {
        let key: String
        let label: String
        var required = false
        var choices: [String] = []

        var schema: [String: Any] {
            var schema: [String: Any] = ["type": "string", "description": label]
            if !choices.isEmpty { schema["enum"] = choices }
            return schema
        }
    }

    let kind: Kind
    var values: [String: String]
    var fields: [Field] { Self.fields(kind) }

    static let eventKinds: [String: InvestmentEventKind] = [
        "deposit": .deposit, "withdrawal": .withdrawal, "adjustment": .adjustment, "opening": .opening,
        "buy": .buy, "sell": .sell, "income": .income, "dividend": .dividend, "bonus_shares": .bonusShares,
        "staking_reward": .stakingReward, "spot_adjustment": .spotAdjustment, "derivative_funding": .funding,
        "derivative_margin": .marginTransfer, "derivative_settlement": .derivativeSettlement
    ]
    static let accountTypes: [String: InvestmentAccountType] = [
        "securities": .securities, "fund": .fund, "futures": .futures, "wealth": .wealth,
        "deposits": .deposits, "crypto": .crypto, "insurance": .insurance
    ]
    static let assetKinds: [String: InvestmentKind] = [
        "stock": .stock, "etf": .etf, "fund": .fund, "future": .future, "wealth": .wealth, "deposit": .deposit,
        "certificate": .certificate, "crypto": .crypto, "crypto_contract": .cryptoContract, "insurance": .insurance
    ]
    static let balanceCategories: [String: InvestmentBalanceCategory] = [
        "cash": .cash, "fixed": .fixed, "receivables": .receivables, "liabilities": .liabilities
    ]
    static let bases: [String: InvestmentContractBasis] = ["cash": .usd, "stablecoin": .stablecoin, "coin": .coin]
    static let sides: [String: InvestmentContractSide] = ["long": .long, "short": .short]
    static let fundingTargets: [String: InvestmentFundingTarget] = ["available": .available, "margin": .margin]

    static func fields(_ kind: Kind) -> [Field] {
        let account = Field(key: "account_id", label: "投资账户 ID", required: true)
        let asset = Field(key: "asset_id", label: "标的 ID 或同一草稿中已登记的唯一代码", required: true)
        let event = Field(key: "event_id", label: "流水 ID", required: true)
        let record = Field(key: "record_id", label: "余额记录 ID", required: true)
        let balanceAccount = Field(key: "balance_account_id", label: "资产负债账户 ID", required: true)
        let day = Field(key: "date", label: "记账日期（YYYY-MM-DD，北京时间）", required: true)
        let amount = Field(key: "amount", label: "金额（十进制字符串）", required: true)
        let name = Field(key: "name", label: "名称", required: true)
        let currency = Field(key: "currency", label: "币种", required: true, choices: ["CNY", "USD", "HKD"])
        let target = Field(key: "funding_target", label: "合约资金账户", choices: ["available", "margin"])
        let enabled = Field(key: "enabled", label: "启用", required: true, choices: ["true", "false"])
        let settlement = Field(key: "settled_amount", label: "港股通实际交收金额或操作后存款余额")
        let rate = Field(key: "settlement_rate", label: "结算币兑美元单价")
        let terms = [Field(key: "annual_rate", label: "年利率（百分数，例如 2.5 表示 2.5%）"),
                     Field(key: "maturity_date", label: "到期日（YYYY-MM-DD）")]
        let optional: (Field) -> Field = { var field = $0; field.required = false; return field }
        let eventValues = [optional(amount), Field(key: "quantity", label: "数量（合约按张，现货减少填负数）"),
                           Field(key: "price", label: "单位价格"), Field(key: "fee", label: "手续费"),
                           Field(key: "margin", label: "保证金（期货每手，合约为整笔）"), settlement, rate, target,
                           Field(key: "unallocated", label: "账户资金费", choices: ["true", "false"])]
        switch kind {
        case .addAccount: return [name, currency, .init(key: "account_type", label: "账户类型", required: true, choices: accountTypes.keys.sorted())]
        case .editAccount: return [account, optional(name), .init(key: "position", label: "账户顺序（从 1 开始）")]
        case .removeAccount: return [account]
        case .addAsset:
            return [optional(account), name, .init(key: "symbol", label: "代码", required: true), currency,
                    .init(key: "asset_type", label: "标的类型", required: true, choices: assetKinds.keys.sorted()),
                    .init(key: "market", label: "交易所代码，港股通填 HK_CONNECT"), .init(key: "multiplier", label: "合约乘数"),
                    .init(key: "side", label: "合约方向", choices: sides.keys.sorted()),
                    .init(key: "basis", label: "合约本位", choices: bases.keys.sorted()),
                    .init(key: "collateral_id", label: "结算币标的 ID"),
                    .init(key: "stablecoin", label: "稳定币结算单位", choices: ["USDT", "USDC"])] + terms
        case .editAsset: return [asset, optional(name)] + terms
        case .addEvent:
            return [account, day, .init(key: "event_type", label: "流水类型（现金转入和提取的金额填正数）", required: true,
                                       choices: eventKinds.keys.sorted()), optional(asset)] + eventValues +
                [.init(key: "auto_fund", label: "允许自动补入现金，仅在用户要求时启用", choices: ["true", "false"])]
        case .editEvent: return [account, event, optional(day)] + eventValues + [.init(key: "counterpart_amount", label: "跨币种对侧带符号金额")]
        case .deleteEvent: return [account, event]
        case .transfer: return [account, .init(key: "target_id", label: "目标账户 ID", required: true), day, amount,
                                .init(key: "received", label: "跨币种实际到账金额")]
        case .distribution: return [account, asset, day, optional(amount), .init(key: "quantity", label: "送股数量")]
        case .cashBalance: return [account, day, amount]
        case .spotBalance: return [account, asset, day, amount]
        case .fundingBalance: return [account, asset, day, amount, target, rate,
                                      .init(key: "attribute_to_contract", label: "计入该合约的资金费", choices: ["true", "false"])]
        case .plan: return [.init(key: "plan_id", label: "编辑现有定投时填写任务 ID"), account, optional(asset), amount,
                            .init(key: "month_day", label: "每月执行日（1 至 28）", required: true), enabled]
        case .removePlan: return [.init(key: "plan_id", label: "定投任务 ID", required: true)]
        case .watch: return [asset, enabled]
        case .quote: return [asset, day, .init(key: "price", label: "手工报价或估值", required: true)]
        case .balanceAccount:
            return [name, .init(key: "category", label: "资产负债分类", required: true, choices: balanceCategories.keys.sorted()), day, amount]
        case .balanceRecord: return [balanceAccount, day, amount]
        case .editBalanceRecord: return [balanceAccount, record, day, amount]
        case .deleteBalanceRecord: return [balanceAccount, record]
        case .refreshMarket, .rebuildSnapshots: return []
        }
    }

    static let tool = LanguageModelTool(name: "propose_changes", description: "创建待确认的写入预览。所有动作按顺序试算。读取已有账户、标的和记录 ID。用户未提供必填资料时先询问。行情刷新和快照重算分别单独提案。",
        properties: ["actions": ["type": "array", "minItems": 1, "maxItems": 20, "items": ["anyOf": Kind.allCases.map { kind -> [String: Any] in
            let fields = fields(kind)
            var properties = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.schema) })
            properties["action"] = ["type": "string", "enum": [kind.rawValue], "description": kind.title]
            return ["type": "object", "properties": properties, "required": ["action"] + fields.filter(\.required).map(\.key),
                    "additionalProperties": false]
        }]]], required: ["actions"])

    static func parse(_ arguments: [String: Any]) throws -> [Self] {
        guard arguments.count == 1, let rows = arguments["actions"] as? [[String: String]], (1...20).contains(rows.count) else {
            throw InvestmentError.invalid("请提供 1 至 20 项结构化操作，金额和日期用字符串填写。")
        }
        return try rows.map { row in
            var values = row
            guard let code = values.removeValue(forKey: "action"), let kind = Kind(rawValue: code) else {
                throw InvestmentError.invalid("不支持该记账操作。")
            }
            let action = Self(kind: kind, values: values)
            try action.validate()
            return action
        }
    }

    private func validate() throws {
        let fields = fields
        guard Set(values.keys).isSubset(of: Set(fields.map(\.key))) else { throw InvestmentError.invalid("操作包含未知字段。") }
        for field in fields {
            let value = text(field.key)
            guard let value else {
                if field.required { throw InvestmentError.invalid("请填写\(field.label)。") }
                continue
            }
            guard value.count <= 180, field.choices.isEmpty || field.choices.contains(value) else {
                throw InvestmentError.invalid("请检查\(field.label)。")
            }
        }
    }

    func apply(to book: inout InvestmentBook, today: Date = InvestmentBook.day()) throws {
        try validate()
        switch kind {
        case .addAccount:
            let name = try required("name")
            guard let currency = InvestmentCurrency(rawValue: try required("currency")),
                  let type = Self.accountTypes[try required("account_type")], InvestmentAccountType.available(in: currency).contains(type),
                  !book.accounts.contains(where: { $0.name == name && $0.currency == currency && $0.type == type }) else {
                throw InvestmentError.invalid("账户已存在或该币种不支持所选账户类型。")
            }
            book.accounts.append(.init(name: name, currency: currency, type: type))
        case .editAccount, .removeAccount:
            let id = try uuid("account_id")
            guard let index = book.accounts.firstIndex(where: { $0.id == id }) else { throw missing("投资账户") }
            if kind == .removeAccount {
                guard book.accounts[index].events.isEmpty, !book.plans.contains(where: { $0.accountID == id }),
                      !book.accounts.contains(where: { $0.events.contains { $0.transferAccountID == id } }) else {
                    throw InvestmentError.invalid("仍有流水或定投的账户不能移除。")
                }
                book.accounts.remove(at: index)
            } else {
                if let name = text("name") {
                    let current = book.accounts[index]
                    guard !book.accounts.contains(where: { $0.id != id && $0.name == name && $0.currency == current.currency && $0.type == current.type }) else {
                        throw InvestmentError.invalid("该账户已存在。")
                    }
                    book.accounts[index].name = name
                }
                if let order = text("position") {
                    guard let position = Int(order), (1...book.accounts.count).contains(position) else { throw missing("账户顺序") }
                    let account = book.accounts.remove(at: index)
                    book.accounts.insert(account, at: position - 1)
                }
            }
        case .addAsset, .editAsset:
            try applyAsset(to: &book)
        case .addEvent, .editEvent, .deleteEvent:
            try applyEvent(to: &book, today: today)
        case .transfer:
            let account = try owner(in: book)
            let day = try date("date", through: today)
            let amount = try decimal("amount", fallback: 0)
            let remaining = try book.ledger(account, through: day).cash - amount
            try book.transfer(from: account.id, to: uuid("target_id"), amount: amount, remaining: remaining,
                              received: number("received"), on: day)
        case .distribution:
            try book.recordDistribution(assetID: asset(in: book).id, accountID: owner(in: book).id,
                                        cash: decimal("amount", fallback: 0), shares: decimal("quantity", fallback: 0), on: date("date", through: today))
        case .cashBalance:
            let account = try owner(in: book)
            let day = try date("date", through: today)
            let balance = try decimal("amount", fallback: 0)
            guard balance >= 0 else { throw missing("现金余额") }
            let delta = try balance - book.ledger(account, through: day).cash
            let kind: InvestmentEventKind = account.type == .crypto ? .adjustment : delta > 0 ? .deposit : .withdrawal
            try book.post(.init(day: day, kind: kind, amount: delta), accountID: account.id, today: today)
        case .spotBalance:
            try book.adjustSpotBalance(assetID: asset(in: book).id, accountID: owner(in: book).id,
                                       balance: decimal("amount", fallback: 0), on: date("date", through: today))
        case .fundingBalance:
            guard let target = Self.fundingTargets[try required("funding_target")] else { throw missing("合约资金账户") }
            try book.adjustFundingBalance(assetID: asset(in: book).id, accountID: owner(in: book).id, target: target,
                                          balance: decimal("amount", fallback: 0), rate: number("settlement_rate"),
                                          attributeToContract: text("attribute_to_contract") == "true", on: date("date", through: today))
        case .plan, .removePlan:
            try applyPlan(to: &book, today: today)
        case .watch:
            let item = try asset(in: book)
            if text("enabled") == "true" {
                guard InvestmentKind.watchKinds(in: item.settlementCurrency).contains(item.kind) || item.kind == .cryptoContract else {
                    throw InvestmentError.invalid("该标的类型不支持关注。")
                }
                if !book.watched.contains(item.id) { book.watched.append(item.id) }
            } else { book.watched.removeAll { $0 == item.id } }
        case .quote:
            let item = try asset(in: book)
            let price = try decimal("price", fallback: 0)
            guard price > 0 || (item.kind == .insurance && price == 0) else { throw missing("有效报价") }
            book.addQuotes([.init(day: try date("date", through: today), price: price, source: "手动录入")], assetID: item.id)
            book.runPlans(through: today)
        case .balanceAccount, .balanceRecord, .editBalanceRecord, .deleteBalanceRecord:
            try applyBalance(to: &book, today: today)
        case .refreshMarket, .rebuildSnapshots:
            throw InvestmentError.invalid("请单独提交行情刷新或快照重算。")
        }
    }

    private func applyAsset(to book: inout InvestmentBook) throws {
        var item: InvestmentAsset
        if kind == .editAsset {
            item = try asset(in: book)
            if let name = text("name") { item.name = name }
        } else {
            guard let kind = Self.assetKinds[try required("asset_type")],
                  let currency = InvestmentCurrency(rawValue: try required("currency")) else { throw missing("标的类别或币种") }
            let market = text("market")?.uppercased() ?? ""
            let symbol = try required("symbol").uppercased()
            item = .init(name: try required("name"), code: market == InvestmentAsset.stockConnectMarket
                ? InvestmentAsset.stockConnectCode(symbol) ?? symbol : symbol, market: market, kind: kind, currency: currency,
                multiplier: try decimal("multiplier", fallback: 1))
            item.contractSide = text("side").flatMap { Self.sides[$0] }
            item.contractBasis = text("basis").flatMap { Self.bases[$0] }
            item.settlementStablecoin = text("stablecoin").flatMap(InvestmentStablecoin.init(rawValue:))
            if text("collateral_id") != nil {
                let collateral = try asset(in: book, key: "collateral_id")
                guard item.basis.accepts(collateral) else { throw missing("有效结算币") }
                item.collateralAssetID = collateral.id
            }
            if text("account_id") != nil { try item.validateEntry(in: owner(in: book)) }
            else { try item.validateMarket(settlingIn: item.settlementCurrency) }
        }
        if item.kind.isTermDeposit, item.depositTerms == nil || text("annual_rate") != nil || text("maturity_date") != nil {
            let annual = try number("annual_rate").map { $0 / 100 } ?? item.depositTerms?.annualRate
            let maturity = try text("maturity_date").map { _ in try date("maturity_date") } ?? item.depositTerms?.maturity
            guard let annual, annual >= 0, let maturity else { throw missing("存款年利率或到期日") }
            let assetID = item.id
            let events: [InvestmentEvent] = book.accounts.flatMap(\.events)
            let depositDates = events.compactMap { event -> Date? in
                guard event.assetID == assetID, event.kind == .opening || event.kind == .buy else { return nil }
                return event.day
            }
            if let first = depositDates.min(), maturity < first {
                throw InvestmentError.invalid("到期日不能早于首次存入日期。")
            }
            item.depositTerms = .init(annualRate: annual, maturity: maturity)
        }
        if kind == .editAsset { book.assets[item.id] = item }
        else { _ = try book.register(item) }
    }

    private func applyEvent(to book: inout InvestmentBook, today: Date) throws {
        let account = try owner(in: book)
        let original: InvestmentEvent?
        if kind == .addEvent { original = nil }
        else {
            let id = try uuid("event_id")
            guard let event = account.events.first(where: { $0.id == id }) else { throw missing("原流水") }
            if kind == .deleteEvent { try book.deleteEvent(event, accountID: account.id, today: today); return }
            original = event
        }
        guard let type = original?.kind ?? text("event_type").flatMap({ Self.eventKinds[$0] }) else { throw missing("流水类型") }
        let day = try text("date").map { _ in try date("date", through: today) } ?? original?.day ?? today
        var event = original ?? .init(day: day, kind: type)
        event.day = day
        if text("asset_id") != nil { event.assetID = try asset(in: book).id }
        if let amount = try number("amount") { event.amount = type == .withdrawal ? -abs(amount) : amount }
        event.quantity = try decimal("quantity", fallback: event.quantity)
        event.price = try decimal("price", fallback: event.price)
        event.margin = try decimal("margin", fallback: event.margin)
        event.fee = try number("fee") ?? event.fee
        event.settledAmount = try number("settled_amount") ?? event.settledAmount
        event.settlementRate = try number("settlement_rate") ?? event.settlementRate
        event.fundingTarget = text("funding_target").flatMap { Self.fundingTargets[$0] } ?? event.fundingTarget
        if let flag = text("unallocated") { event.unallocatedFunding = flag == "true" }
        if let maturity = book.asset(event.assetID)?.depositTerms?.maturity, type == .opening || type == .buy, day > maturity {
            throw InvestmentError.invalid("到期日不能早于存入日期。")
        }
        if let original {
            guard event != original || text("counterpart_amount") != nil else { return }
            try book.replaceEvent(original, with: event, accountID: account.id, counterpartAmount: number("counterpart_amount"), today: today)
        } else {
            try book.post(event, accountID: account.id, today: today, autoFundCash: text("auto_fund") == "true")
        }
    }

    private func applyPlan(to book: inout InvestmentBook, today: Date) throws {
        let id = try text("plan_id").map { _ in try uuid("plan_id") }
        let index = book.plans.firstIndex { $0.id == id }
        if id != nil, index == nil { throw missing("定投任务") }
        if kind == .removePlan {
            guard let index else { throw missing("定投任务") }
            book.plans.remove(at: index)
            book.planRuns.removeAll { $0.planID == id }
            return
        }
        let account = try owner(in: book)
        let target = try text("asset_id").map { _ in try asset(in: book) }
        if let target {
            guard target.supportsPlan else { throw missing("支持定投的标的") }
            try target.validateEntry(in: account)
        }
        let amount = try decimal("amount", fallback: 0)
        guard amount > 0, let day = Int(try required("month_day")), (1...28).contains(day) else { throw missing("定投金额或执行日") }
        let current = index.map { book.plans[$0] }
        let unchanged = current.map { $0.enabled && $0.monthDay == day && $0.accountID == account.id && $0.assetID == target?.id } ?? false
        let next = (unchanged ? current?.nextDay : nil) ?? InvestmentBook.nextRun(day, after: today)
        let plan = InvestmentPlan(id: id ?? UUID(), accountID: account.id, assetID: target?.id, amount: amount, monthDay: day,
                                  nextDay: next, enabled: text("enabled") == "true", lastResult: current?.lastResult)
        if let index { book.plans[index] = plan } else { book.plans.append(plan) }
    }

    private func applyBalance(to book: inout InvestmentBook, today: Date) throws {
        var ledger = book.balanceSheet ?? .init()
        let now = Date.now
        if kind == .balanceAccount {
            guard let category = Self.balanceCategories[try required("category")] else { throw missing("资产负债分类") }
            let day = try date("date", through: today)
            try ledger.add(required("name"), category: category, amount: decimal("amount", fallback: 0), at: day == today ? now : day)
        } else {
            let id = try uuid("balance_account_id")
            if kind == .balanceRecord {
                let day = try date("date", through: today)
                try ledger.update(id, amount: decimal("amount", fallback: 0), at: day == today ? now : day)
            } else {
                let recordID = try uuid("record_id")
                guard let account = ledger.accounts.first(where: { $0.id == id }),
                      let record = account.records.first(where: { $0.id == recordID }) else { throw missing("余额记录") }
                if kind == .deleteBalanceRecord { try ledger.deleteRecord(record, accountID: id) }
                else { try ledger.replaceRecord(record, accountID: id, amount: decimal("amount", fallback: 0), on: date("date", through: today)) }
            }
        }
        book.balanceSheet = ledger
    }

    private func owner(in book: InvestmentBook) throws -> InvestmentAccount {
        guard let account = book.account(try uuid("account_id")) else { throw missing("投资账户") }
        return account
    }

    private func asset(in book: InvestmentBook, key: String = "asset_id") throws -> InvestmentAsset {
        let value = try required(key)
        if let id = UUID(uuidString: value), let asset = book.asset(id) { return asset }
        let matches = book.assets.values.filter { $0.code.caseInsensitiveCompare(value) == .orderedSame }
        guard matches.count == 1, let asset = matches.first else { throw missing("唯一标的，请使用标的 ID") }
        return asset
    }

    private func text(_ key: String) -> String? {
        guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func required(_ key: String) throws -> String {
        guard let value = text(key) else { throw missing(fields.first { $0.key == key }?.label ?? key) }
        return value
    }

    private func uuid(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try required(key)) else { throw missing(fields.first { $0.key == key }?.label ?? key) }
        return id
    }

    private func number(_ key: String) throws -> Decimal? {
        guard let value = text(key) else { return nil }
        guard value.range(of: #"^-?[0-9]{1,18}(\.[0-9]{1,18})?$"#, options: .regularExpression) != nil,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else {
            throw missing(fields.first { $0.key == key }?.label ?? key)
        }
        return number
    }

    private func decimal(_ key: String, fallback: Decimal) throws -> Decimal { try number(key) ?? fallback }

    private func date(_ key: String, through end: Date? = nil) throws -> Date {
        let value = try required(key)
        let formatter = InvestmentBook.snapshotDateFormatter()
        guard let day = formatter.date(from: value), formatter.string(from: day) == value,
              end.map({ day <= $0 }) ?? true else { throw missing("有效日期") }
        return day
    }

    private func missing(_ field: String) -> InvestmentError { .invalid("请核对\(field)。") }
}
