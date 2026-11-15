import Foundation

struct InvestmentAgentAction: Codable {
    enum Kind: String, CaseIterable, Codable {
        case addAccount = "add_account", editAccount = "edit_account", removeAccount = "remove_account"
        case archiveAccount = "archive_account", restoreAccount = "restore_account", removePosition = "remove_position"
        case addAsset = "add_asset", editAsset = "edit_asset"
        case addEvent = "add_event", editEvent = "edit_event", deleteEvent = "delete_event"
        case transfer, distribution, cashBalance = "cash_balance", spotBalance = "spot_balance", assetBalance = "asset_balance"
        case plan, removePlan = "remove_plan", watch, quote
        case balanceAccount = "balance_account", balanceRecord = "balance_record"
        case editBalanceRecord = "edit_balance_record", deleteBalanceRecord = "delete_balance_record"
        case refreshMarket = "refresh_market", rebuildSnapshots = "rebuild_snapshots"

        var title: String {
            switch self {
            case .addAccount: "新增账户"
            case .editAccount: "修改账户"
            case .removeAccount: "删除账户"
            case .archiveAccount: "归档账户"
            case .restoreAccount: "撤销账户归档"
            case .removePosition: "删除持仓"
            case .addAsset: "登记标的"
            case .editAsset: "修改标的资料"
            case .addEvent: "新增流水"
            case .editEvent: "修改流水"
            case .deleteEvent: "删除流水"
            case .transfer: "账户划转"
            case .distribution: "现金分红或送股"
            case .cashBalance: "调整现金余额"
            case .spotBalance: "调整现货数量"
            case .assetBalance: "调整标的余额"
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
        "staking_reward": .stakingReward, "spot_adjustment": .spotAdjustment,
        "derivative_margin": .marginTransfer, "derivative_settlement": .derivativeSettlement
    ]
    static let accountTypes: [String: InvestmentAccountType] = [
        "securities": .securities, "fund": .fund, "futures": .futures, "wealth": .wealth,
        "deposits": .deposits, "crypto": .crypto, "insurance": .insurance
    ]
    static let assetKinds: [String: InvestmentKind] = [
        "stock": .stock, "etf": .etf, "fund": .fund, "future": .future, "wealth": .wealth, "deposit": .deposit,
        "certificate": .certificate, "crypto": .crypto, "generic": .generic, "insurance": .insurance
    ]
    static let balanceCategories: [String: InvestmentBalanceCategory] = [
        "cash": .cash, "fixed": .fixed, "receivables": .receivables, "liabilities": .liabilities
    ]
    static let sides: [String: InvestmentContractSide] = ["long": .long, "short": .short]

    static func fields(_ kind: Kind) -> [Field] {
        let account = Field(key: "account_id", label: "投资账户 ID", required: true)
        let asset = Field(key: "asset_id", label: "标的 ID、唯一代码或唯一产品名称", required: true)
        let event = Field(key: "event_id", label: "流水 ID", required: true)
        let record = Field(key: "record_id", label: "余额记录 ID", required: true)
        let balanceAccount = Field(key: "balance_account_id", label: "资产负债账户 ID", required: true)
        let day = Field(key: "date", label: "记账日期（YYYY-MM-DD，北京时间）", required: true)
        let amount = Field(key: "amount", label: "金额（十进制字符串）", required: true)
        let name = Field(key: "name", label: "名称", required: true)
        let currency = Field(key: "currency", label: "币种", required: true, choices: ["CNY", "USD", "HKD"])
        let enabled = Field(key: "enabled", label: "启用", required: true, choices: ["true", "false"])
        let settlement = Field(key: "settled_amount", label: "港股通实际交收金额、存款操作后余额或通用标的首次录入余额")
        let terms = [Field(key: "annual_rate", label: "年利率（百分数，例如 2.5 表示 2.5%）"),
                     Field(key: "maturity_date", label: "到期日（YYYY-MM-DD）")]
        let optional: (Field) -> Field = { var field = $0; field.required = false; return field }
        let eventValues = [optional(amount), Field(key: "quantity", label: "数量（正数）"),
                           Field(key: "direction", label: "金额变动方向，变动金额填非负数", choices: ["increase", "decrease"]),
                           Field(key: "price", label: "单位价格"), Field(key: "fee", label: "手续费"),
                           Field(key: "margin", label: "期货每手保证金"), settlement]
        switch kind {
        case .addAccount: return [name, currency, .init(key: "account_type", label: "账户类型", required: true, choices: accountTypes.keys.sorted())]
        case .editAccount: return [account, optional(name), .init(key: "position", label: "账户顺序（从 1 开始）")]
        case .removeAccount, .archiveAccount, .restoreAccount: return [account]
        case .removePosition: return [account, asset]
        case .addAsset:
            return [optional(account), name, .init(key: "symbol", label: "代码（存款和通用标的不填写）"), currency,
                    .init(key: "asset_type", label: "标的类型", required: true, choices: assetKinds.keys.sorted()),
                    .init(key: "market", label: "交易所代码，港股通填 HK_CONNECT"), .init(key: "multiplier", label: "合约乘数"),
                    .init(key: "side", label: "期货方向", choices: sides.keys.sorted())] + terms
        case .editAsset: return [asset, optional(name),
                                .init(key: "symbol", label: "市场目录中的真实标的代码"),
                                .init(key: "market", label: "市场目录中的交易所")] + terms
        case .addEvent:
            return [account, day, .init(key: "event_type", label: "流水类型（通用标的投入用 buy、取出用 sell；opening 是期初资产首次录入。现金转入和提取填正数）", required: true,
                                       choices: eventKinds.keys.sorted()), optional(asset)] + eventValues +
                [.init(key: "auto_fund", label: "允许自动补入现金，仅在用户要求时启用", choices: ["true", "false"])]
        case .editEvent: return [account, event, optional(day)] + eventValues + [.init(key: "counterpart_amount", label: "跨币种对方金额（正数，沿用原流水方向）")]
        case .deleteEvent: return [account, event]
        case .transfer: return [account, .init(key: "target_id", label: "目标账户 ID", required: true), day, amount,
                                .init(key: "received", label: "跨币种实际到账金额")]
        case .distribution: return [account, asset, day, optional(amount), .init(key: "quantity", label: "送股数量")]
        case .cashBalance: return [account, day, amount]
        case .spotBalance: return [account, asset, day, amount]
        case .assetBalance: return [account, asset, day, amount]
        case .plan: return [.init(key: "plan_id", label: "编辑现有定投时填写任务 ID"),
                            .init(key: "plan_type", label: "任务类型", required: true, choices: ["deposit", "buy"]), account, optional(asset), amount,
                            .init(key: "frequency", label: "执行周期", required: true, choices: InvestmentPlanFrequency.allCases.map(\.rawValue)),
                            .init(key: "schedule_day", label: "执行日：每周或每两周为周一 1 至周日 7，每月为 1 至 31，每日为 0"), enabled]
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

    static let tool = LanguageModelTool(name: "propose_changes", description: "按页面表单生成待确认草稿。先用 inspect_entry_form 检查整笔操作，合并询问仍缺少或有歧义的必要资料。明确后提交完整操作；纠正草稿时完整替换。维护操作单独确认。",
        properties: schema(requireValues: true), required: ["actions"])

    static let inspectTool = LanguageModelTool(name: "inspect_entry_form", description: "查看对应页面表单、已知值、真实候选和全部缺项，允许不完整输入。用于组织一轮完整追问和试算，不会保存或生成待确认草稿。",
        properties: schema(requireValues: false), required: ["actions"])

    private static func schema(requireValues: Bool) -> [String: [String: Any]] {
        ["actions": ["type": "array", "minItems": 1, "maxItems": 20, "items": ["anyOf": Kind.allCases.map { kind -> [String: Any] in
            let fields = fields(kind)
            var properties = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.schema) })
            properties["action"] = ["type": "string", "enum": [kind.rawValue], "description": kind.title]
            return ["type": "object", "properties": properties, "required": ["action"] + (requireValues ? fields.filter(\.required).map(\.key) : []),
                    "additionalProperties": false]
        }]]]
    }

    static func parse(_ arguments: [String: Any], requireComplete: Bool = true) throws -> [Self] {
        guard arguments.count == 1, let rows = arguments["actions"] as? [[String: String]], (1...20).contains(rows.count) else {
            throw InvestmentError.invalid("请提供 1 至 20 项结构化操作，金额和日期用字符串填写。")
        }
        return try rows.map { row in
            var values = row
            guard let code = values.removeValue(forKey: "action"), let kind = Kind(rawValue: code) else {
                throw InvestmentError.invalid("不支持该记账操作。")
            }
            let action = Self(kind: kind, values: values)
            if requireComplete { try action.validate() }
            else if !Set(values.keys).isSubset(of: Set(action.fields.map(\.key))) { throw InvestmentError.invalid("操作包含未知字段。") }
            return action
        }
    }

    private func validate() throws {
        let fields = fields
        guard Set(values.keys).isSubset(of: Set(fields.map(\.key))) else { throw InvestmentError.invalid("操作包含未知字段。") }
        var missing: [String] = []
        for field in fields {
            let value = text(field.key)
            guard let value else {
                if field.required && !(kind == .plan && text("plan_id") != nil) { missing.append(field.label) }
                continue
            }
            guard value.count <= 180, field.choices.isEmpty || field.choices.contains(value) else {
                throw InvestmentError.invalid("请检查\(field.label)。")
            }
        }

        if kind == .addAsset, let assetKind = text("asset_type").flatMap({ Self.assetKinds[$0] }), !assetKind.usesBalance, text("symbol") == nil {
            missing.append("代码")
        }
        guard missing.isEmpty else { throw InvestmentError.invalid("资料不完整，请先向用户询问：" + missing.joined(separator: "、") + "。") }
    }

    func apply(to book: inout InvestmentBook, today: Date = InvestmentBook.day()) throws {
        let resolved = resolvingPlan(in: book)
        if resolved.values != values { try resolved.apply(to: &book, today: today); return }
        try validate()
        let missingFields = form(in: book).missing
        guard missingFields.isEmpty else { throw InvestmentError.invalid("资料不完整，请一次询问：" + missingFields.joined(separator: "、") + "。") }
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
                try book.deleteInvestment(accountID: id, today: today)
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
        case .archiveAccount, .restoreAccount:
            try book.setArchived(kind == .archiveAccount, accountID: uuid("account_id"))
        case .removePosition:
            try book.deleteInvestment(accountID: uuid("account_id"), assetID: asset(in: book).id, today: today)
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
            try book.post(.init(day: day, kind: .adjustment, amount: delta), accountID: account.id, today: today)
        case .spotBalance:
            try book.adjustSpotBalance(assetID: asset(in: book).id, accountID: owner(in: book).id,
                                       balance: decimal("amount", fallback: 0), on: date("date", through: today))
        case .assetBalance:
            try book.adjustAssetBalance(assetID: asset(in: book).id, accountID: owner(in: book).id,
                                        balance: decimal("amount", fallback: 0), on: date("date", through: today))
        case .plan, .removePlan:
            try applyPlan(to: &book, today: today)
        case .watch:
            let item = try asset(in: book)
            if text("enabled") == "true" {
                guard InvestmentKind.watchKinds(in: item.settlementCurrency).contains(item.kind) else {
                    throw InvestmentError.invalid("该标的类型不支持关注。")
                }
                if !book.watched.contains(item.id) { book.watched.append(item.id) }
            } else { book.watched.removeAll { $0 == item.id } }
        case .quote:
            let item = try asset(in: book)
            guard item.kind.supportsManualQuote else {
                throw InvestmentError.invalid(item.kind == .crypto ? "加密货币现货使用自动行情，不支持手动报价。" : "该标的类型不支持手动报价。")
            }
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

    func resolvingPlan(in book: InvestmentBook) -> Self {
        guard kind == .plan, let plan = book.plans.first(where: { $0.id.uuidString == text("plan_id") }) else { return self }
        var action = self
        let existing = ["account_id": plan.accountID.uuidString, "asset_id": text("plan_type") == "deposit" ? nil : plan.assetID?.uuidString,
                        "plan_type": plan.assetID == nil ? "deposit" : "buy",
                        "amount": NSDecimalNumber(decimal: plan.amount).stringValue, "frequency": plan.schedule.frequency.rawValue,
                        "enabled": plan.enabled ? "true" : "false"]
        for (key, value) in existing where values[key] == nil { action.values[key] = value }
        if action.text("schedule_day") == nil {
            if action.text("frequency") == "daily" { action.values["schedule_day"] = "0" }
            else if action.text("frequency") == plan.schedule.frequency.rawValue {
                action.values["schedule_day"] = String(plan.schedule.day)
            }
        }
        return action
    }

    func planSchedule() throws -> InvestmentPlanSchedule {
        guard let frequency = InvestmentPlanFrequency(rawValue: try required("frequency")) else { throw missing("执行周期") }
        let day = frequency == .daily && text("schedule_day") == nil ? 0 : Int(try required("schedule_day"))
        guard let day else { throw missing("执行日") }
        return try InvestmentPlanSchedule(frequency: frequency, day: day)
    }

    private func applyAsset(to book: inout InvestmentBook) throws {
        var item: InvestmentAsset
        if kind == .editAsset {
            item = try asset(in: book)
            if let name = text("name") { item.name = name }
            if text("symbol") != nil || text("market") != nil {
                guard item.kind.requiresCatalog else {
                    throw InvestmentError.invalid("请从对应市场目录重新选择标的。")
                }
                let symbol = text("symbol")?.uppercased() ?? item.code
                let market = text("market")?.uppercased() ?? item.market
                if symbol != item.code || market != item.market {
                    item.code = symbol
                    item.market = market
                    item.instrumentID = UUID()
                    book.quotes.removeValue(forKey: item.id)
                    if let first = book.accounts.flatMap(\.events).filter({ $0.assetID == item.id }).map(\.day).min() {
                        book.invalidateDailySnapshots(from: first)
                    }
                }
            }
        } else {
            guard let kind = Self.assetKinds[try required("asset_type")],
                  let currency = InvestmentCurrency(rawValue: try required("currency")) else { throw missing("标的类别或币种") }
            let market = text("market")?.uppercased() ?? ""
            let symbol = kind.usesBalance ? UUID().uuidString : try required("symbol").uppercased()
            item = .init(name: try required("name"), code: market == InvestmentAsset.stockConnectMarket
                ? InvestmentAsset.stockConnectCode(symbol) ?? symbol : symbol, market: market, kind: kind, currency: currency,
                multiplier: try decimal("multiplier", fallback: 1))
            item.contractSide = text("side").flatMap { Self.sides[$0] }

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
        if let amount = try number("amount") {
            if let direction = text("direction") {
                guard amount >= 0 else { throw missing("非负的变动金额") }
                event.amount = direction == "decrease" ? -amount : amount
            } else { event.amount = type == .withdrawal || type == .transferOut ? -abs(amount) : amount }
        } else if let direction = text("direction") { event.amount = abs(event.amount) * (direction == "decrease" ? -1 : 1) }
        event.quantity = try decimal("quantity", fallback: event.quantity)
        if type == .spotAdjustment, let quantity = try number("quantity") {
            guard quantity > 0 else { throw missing("减少数量（正数）") }
            event.quantity = -quantity
        }
        if let asset = book.asset(event.assetID), asset.kind.usesBalance || asset.kind == .insurance,
           [.buy, .sell, .opening].contains(type) { event.quantity = 1 }
        event.price = try decimal("price", fallback: event.price)
        event.margin = try decimal("margin", fallback: event.margin)
        if values["fee"] != nil { event.fee = try number("fee") }
        event.settledAmount = try number("settled_amount") ?? event.settledAmount
        if let maturity = book.asset(event.assetID)?.depositTerms?.maturity, type == .opening || type == .buy, day > maturity {
            throw InvestmentError.invalid("到期日不能早于存入日期。")
        }
        if let original {
            guard event != original || text("counterpart_amount") != nil else { return }
            var counterpartAmount = try number("counterpart_amount")
            if let amount = counterpartAmount, let pair = book.transferCounterpart(of: original, accountID: account.id) {
                guard amount > 0 else { throw missing("对方金额（正数）") }
                counterpartAmount = pair.1.kind == .transferOut ? -amount : amount
            }
            try book.replaceEvent(original, with: event, accountID: account.id, counterpartAmount: counterpartAmount, today: today)
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
        if text("enabled") == "true" { try book.requireActive(accountID: account.id) }
        guard (text("plan_type") == "buy") == (target != nil) else {
            throw InvestmentError.invalid("定期买入需要选择标的，定期转入不指定买入标的。")
        }
        if let target {
            guard target.supportsPlan else { throw missing("支持定投的标的") }
            try target.validateEntry(in: account)
        }
        let amount = try decimal("amount", fallback: 0)
        guard amount > 0 else { throw missing("定投金额") }
        let schedule = try planSchedule()
        let current = index.map { book.plans[$0] }
        let unchanged = current.map { $0.enabled && $0.schedule == schedule && $0.accountID == account.id && $0.assetID == target?.id } ?? false
        let next = (unchanged ? current?.nextDay : nil) ?? schedule.first(after: today)
        let plan = InvestmentPlan(id: id ?? UUID(), accountID: account.id, assetID: target?.id, amount: amount, schedule: schedule,
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



    func asset(in book: InvestmentBook, key: String = "asset_id") throws -> InvestmentAsset {
        let value = try required(key)
        if let id = UUID(uuidString: value), let asset = book.asset(id) { return asset }
        let matches = book.assets.values.filter {
            $0.code.caseInsensitiveCompare(value) == .orderedSame || $0.displayCode.caseInsensitiveCompare(value) == .orderedSame
                || ($0.kind.usesBalance && $0.name == value)
        }
        guard matches.count == 1, let asset = matches.first else { throw missing("唯一标的，请使用标的 ID") }
        return asset
    }

    func text(_ key: String) -> String? {
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
