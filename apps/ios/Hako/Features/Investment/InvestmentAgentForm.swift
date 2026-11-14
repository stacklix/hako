import Foundation

struct InvestmentAgentForm {
    struct Choice: Identifiable {
        let id: String
        let title: String
    }
    struct Field: Identifiable {
        let key: String
        let label: String
        let value: String?
        let required: Bool
        let choices: [Choice]
        var editable = true
        var id: String { key }
        var isReference: Bool {
            ["account_id", "target_id", "asset_id", "collateral_id", "event_id", "plan_id", "balance_account_id", "record_id"].contains(key)
        }
        var unresolved: Bool {
            required && (value == nil || ((isReference || !choices.isEmpty) && !choices.contains { $0.id == value }))
        }
        var displayValue: String {
            guard let value else { return required ? "待补充" : "未填写" }
            return choices.isEmpty && !isReference ? value : choices.first { $0.id == value }?.title ?? "未找到对应选项"
        }
    }
    struct Group: Identifiable {
        let title: String
        let fields: [Field]
        var id: String { title }
    }
    let title: String
    let groups: [Group]
    var fields: [Field] { groups.flatMap(\.fields) }
    var missing: [String] { fields.filter(\.unresolved).map(\.label) }

    func persistentReferences(in context: InvestmentBook, base: InvestmentBook) -> Self {
        let assets = Dictionary(uniqueKeysWithValues: context.assets.values.filter { base.assets[$0.id] == nil }.map { ($0.id.uuidString, $0.kind.isTermDeposit ? $0.name : $0.displayCode) })
        let existing: [String: Set<String>] = [
            "account_id": Set(base.accounts.map { $0.id.uuidString }), "target_id": Set(base.accounts.map { $0.id.uuidString }),
            "event_id": Set(base.accounts.flatMap(\.events).map { $0.id.uuidString }), "plan_id": Set(base.plans.map { $0.id.uuidString }),
            "balance_account_id": Set((base.balanceSheet?.accounts ?? []).map { $0.id.uuidString }),
            "record_id": Set((base.balanceSheet?.accounts ?? []).flatMap(\.records).map { $0.id.uuidString })]
        let groups = groups.map { group in
            Group(title: group.title, fields: group.fields.map { field in
                var choices = field.choices
                var value = field.value
                if field.key == "asset_id" || field.key == "collateral_id" {
                    var seen: Set<String> = []
                    choices = choices.compactMap { choice in
                        let id = assets[choice.id] ?? choice.id
                        return seen.insert(id).inserted ? Choice(id: id, title: choice.title) : nil
                    }
                    value = value.map { assets[$0] ?? $0 }
                } else if let ids = existing[field.key] { choices = choices.filter { ids.contains($0.id) } }
                return Field(key: field.key, label: field.label, value: value, required: field.required, choices: choices, editable: field.editable)
            })
        }
        return .init(title: title, groups: groups)
    }
}

extension InvestmentAgentAction {
    static func inspect(_ actions: [Self], in book: InvestmentBook) -> [[String: Any]] {
        var context = book
        return actions.map { action in
            let form = action.form(in: context).persistentReferences(in: context, base: book)
            var result: [String: Any] = ["operation": form.title, "missing": form.missing,
                "groups": form.groups.map { group in
                    ["title": group.title, "fields": group.fields.map { field -> [String: Any] in
                        var row: [String: Any] = ["key": field.key, "label": field.label, "required": field.required,
                            "editable": field.editable,
                            "choices": field.choices.map { ["value": $0.id, "label": $0.title] }]
                        row["value"] = field.value
                        return row
                    }] as [String: Any]
                }]
            do { try action.validateTransactionType(in: context) }
            catch { result["validation_error"] = error.localizedDescription }
            if result["validation_error"] == nil && form.missing.isEmpty && action.kind != .refreshMarket && action.kind != .rebuildSnapshots {
                do {
                    var trial = context
                    try action.apply(to: &trial)
                    context = trial
                } catch { result["validation_error"] = error.localizedDescription }
            }
            return result
        }
    }

    func form(in book: InvestmentBook) -> InvestmentAgentForm {
        let resolved = resolvingPlan(in: book)
        if resolved.values != values { return resolved.form(in: book) }
        typealias Form = InvestmentAgentForm
        let account = text("account_id").flatMap(UUID.init(uuidString:)).flatMap(book.account)
        let original = account?.events.first { $0.id.uuidString == text("event_id") }
        let selected = (try? asset(in: book)) ?? book.asset(original?.assetID)
        let target = text("target_id").flatMap(UUID.init(uuidString:)).flatMap(book.account)
        let balance = book.balanceSheet?.accounts.first { $0.id.uuidString == text("balance_account_id") }
        let record = balance?.records.first { $0.id.uuidString == text("record_id") }
        let plan = book.plans.first { $0.id.uuidString == text("plan_id") }
        let eventKind = original?.kind ?? text("event_type").flatMap { Self.eventKinds[$0] }
        let day = InvestmentBook.snapshotDateFormatter()
        let currency = account?.currency.rawValue ?? selected?.currency.rawValue ?? "币种"
        let settlement = selected.map { book.settlementUnit(for: $0) } ?? currency
        func decimal(_ value: Decimal?) -> String? { value.map { NSDecimalNumber(decimal: $0).stringValue } }
        let boolean: [Form.Choice] = [.init(id: "true", title: "是"), .init(id: "false", title: "否")]
        func options(_ key: String) -> [Form.Choice] {
            switch key {
            case "market" where selected?.kind == .cryptoContract || text("asset_type") == "crypto_contract":
                return InvestmentContractExchange.allCases.map { .init(id: $0.rawValue, title: $0.title) }
            case "account_id", "target_id":
                return book.accounts.filter { key != "target_id" || $0.id != account?.id }.map {
                    .init(id: $0.id.uuidString, title: $0.name + " · " + $0.currency.rawValue + ($0.isArchived ? " · 已归档" : ""))
                }
            case "asset_id", "collateral_id":
                let candidates = book.assets.values.filter { asset in
                    if key == "collateral_id" { return text("basis").flatMap { Self.bases[$0] }?.accepts(asset) ?? false }
                    return true
                }.sorted { $0.code < $1.code }
                func label(_ asset: InvestmentAsset) -> String {
                    (asset.kind.isTermDeposit ? asset.name : asset.displayName + " · " + asset.displayCode) + " · " + asset.kindLabel
                }
                var result = candidates.map { Form.Choice(id: $0.id.uuidString, title: label($0)) }
                if let value = text(key), let match = try? asset(in: book, key: key), value != match.id.uuidString {
                    result.append(.init(id: value, title: label(match)))
                }
                return result
            case "event_id":
                return (account?.events ?? []).map { event in
                    let asset = book.asset(event.assetID)
                    return .init(id: event.id.uuidString, title: [day.string(from: event.day), event.title(for: asset), asset.map { $0.kind.isTermDeposit ? $0.name : $0.displayCode },
                        decimal(event.quantity != 0 ? event.quantity : event.amount)].compactMap { $0 }.joined(separator: " · "))
                }
            case "plan_id":
                return book.plans.map { .init(id: $0.id.uuidString, title:
                    [book.account($0.accountID)?.name, book.asset($0.assetID)?.name ?? "定期转入", "每月 \($0.monthDay) 日"].compactMap { $0 }.joined(separator: " · ")) }
            case "balance_account_id": return (book.balanceSheet?.accounts ?? []).map { .init(id: $0.id.uuidString, title: $0.name + " · " + $0.category.rawValue) }
            case "record_id": return (balance?.records ?? []).map { .init(id: $0.id.uuidString, title: day.string(from: $0.recordedAt) + " · " + (decimal($0.amount) ?? "") + " 元") }
            case "event_type" where selected?.kind == .cryptoContract && selected?.basis != .usd:
                let kinds: [InvestmentEventKind] = [.buy, .sell, .funding, .marginTransfer, .derivativeSettlement]
                return kinds.compactMap { kind in
                    Self.eventKinds.first { $0.value == kind }.map { .init(id: $0.key, title: selected!.transactionTitle(kind)) }
                }
            default:
                return (fields.first { $0.key == key }?.choices ?? []).map { value in
                    let label: String
                    switch key {
                    case "account_type": label = Self.accountTypes[value]?.rawValue ?? value
                    case "asset_type": label = Self.assetKinds[value]?.title ?? value
                    case "event_type": label = Self.eventKinds[value].map { selected?.transactionTitle($0) ?? $0.rawValue } ?? value
                    case "basis": label = Self.bases[value]?.rawValue ?? value
                    case "side": label = Self.sides[value]?.rawValue ?? value
                    case "funding_target": label = Self.fundingTargets[value]?.rawValue ?? value
                    case "category": label = Self.balanceCategories[value]?.rawValue ?? value
                    case "quantity_mode": label = ["coins": "按币量", "notional": "按美元名义价值", "contracts": "按张数"][value] ?? value
                    case "direction": label = value == "increase" ? "增加 / 入账" : "减少 / 扣款"
                    case "plan_type": label = value == "buy" ? "定期买入" : "定期转入"
                    default: label = boolean.first { $0.id == value }?.title ?? value
                    }
                    return .init(id: value, title: label)
                }
            }
        }
        func field(_ key: String, _ label: String, required: Bool = false, value: String? = nil) -> Form.Field {
            .init(key: key, label: label, value: values[key] == nil ? value : text(key), required: required, choices: options(key))
        }
        func readOnly(_ key: String, _ label: String, _ value: String?) -> Form.Field {
            .init(key: key, label: label, value: value, required: false, choices: [], editable: false)
        }
        let owner = field("account_id", "所属账户", required: true)
        let instrument = field("asset_id", "已选标的", required: true, value: selected?.id.uuidString)
        func date(_ title: String = "记账日期", _ value: Date? = nil) -> Form.Field {
            field("date", title, required: true, value: value.map(day.string(from:)))
        }
        var title = kind.title
        var groups: [Form.Group] = []
        var inputs: [Form.Field] = []
        switch kind {
        case .addAccount:
            inputs = [field("name", "账户名称", required: true), field("currency", "账户币种", required: true), field("account_type", "账户类型", required: true)]
        case .editAccount:
            inputs = [owner, field("name", "账户名称", value: account?.name), field("position", "账户顺序（从 1 开始）")]
        case .removeAccount, .removePosition:
            inputs = kind == .removeAccount ? [owner] : [owner, instrument]
            if let account {
                inputs.append(readOnly("deletion_effect", "删除影响", book.deletionMessage(accountID: account.id,
                    assetID: kind == .removePosition ? selected?.id : nil)))
            }
        case .archiveAccount, .restoreAccount:
            inputs = [owner, readOnly("archive_effect", "数据处理", kind == .archiveAccount
                ? "仅余额为零的账户可归档。保留全部数据、暂停定投，默认隐藏，可在设置中显示并撤销归档。"
                : "保留原数据并重新显示账户，定投需手动启用。")]
        case .addAsset, .editAsset:
            let assetKind = selected?.kind ?? text("asset_type").flatMap { Self.assetKinds[$0] }
            let basis = selected?.basis ?? text("basis").flatMap { Self.bases[$0] }
            if kind == .addAsset {
                inputs = [field("currency", "报价币种", required: true), field("asset_type", "资产类型", required: true),
                          field("name", assetKind?.isTermDeposit == true ? "存款名称" : "标的名称", required: true)]
                if assetKind?.isTermDeposit != true { inputs.append(field("symbol", "代码", required: true)) }
                if assetKind?.isTermDeposit != true && ![.insurance, .wealth].contains(assetKind) {
                    inputs.append(field("market", assetKind == .cryptoContract ? "报价交易所" : "交易所", required: assetKind?.derivative == true))
                }
                if assetKind == .cryptoContract {
                    inputs.append(field("basis", "合约本位", required: true))
                    if basis == .coin { inputs.append(field("collateral_id", "结算币种", required: true)) }
                    if basis == .stablecoin { inputs.append(field("stablecoin", "结算币种", required: true)) }
                }
                if assetKind?.usesMargin == true {
                    inputs += [field("side", "开仓方向", required: true),
                               field("multiplier", basis == .coin ? "每张合约面值（USD）" : "合约乘数", required: true)]
                }
            } else {
                inputs = [instrument, field("name", "标的名称", value: selected?.name)]
                title = assetKind?.isTermDeposit == true ? "编辑存款信息" : "修改标的资料"
                if assetKind == .cryptoContract, basis != .usd {
                    inputs += [field("market", "报价交易所", required: true, value: selected?.market),
                               field("symbol", "交易所合约代码", required: true, value: selected?.code),
                               readOnly("contract_terms", "合约规格", (basis?.rawValue ?? "") + " · " + settlement + " · 面值 / 乘数 " + (decimal(selected?.multiplier) ?? ""))]
                    if text("market") != nil || text("symbol") != nil {
                        inputs.append(readOnly("quote_effect", "行情关联更新", "更换合约代码或交易所时，清除原报价并重新获取所选合约的标记价格；交易数量、本位和结算币不变。"))
                    }
                    if let selected, let quote = book.quote(selected.id) {
                        inputs.append(readOnly("quote_state", "行情报价", (quote.source ?? "报价") + " · " + (decimal(quote.price) ?? "") + " · " + day.string(from: quote.day)))
                    }
                }
                if assetKind?.requiresCatalog == true, assetKind != .cryptoContract {
                    inputs += [field("market", "市场", value: selected?.market), field("symbol", "市场代码", required: true, value: selected?.code)]
                }
            }
            if assetKind?.requiresCatalog == true {
                inputs = inputs.map { input in
                    var output = input
                    if ["name", "symbol", "market", "multiplier"].contains(input.key) { output.editable = false }
                    return output
                }
                inputs.append(readOnly("catalog_rule", "标的来源", "名称、代码及交易所由市场目录提供；需要更换时继续对话，重新搜索并选择。"))
                if assetKind == .cryptoContract {
                    let code = text("symbol") ?? selected?.code ?? ""
                    let market = text("market") ?? selected?.market ?? ""
                    let display = InvestmentAsset(name: text("name") ?? selected?.name ?? "", code: code, market: market,
                        kind: .cryptoContract, currency: .usd,
                        contractSide: text("side").flatMap { Self.sides[$0] } ?? selected?.contractSide, contractBasis: basis)
                    inputs = inputs.map { input in
                        guard input.key == "name", let value = input.value else { return input }
                        return Form.Field(key: input.key, label: input.label, value: value, required: input.required,
                            choices: [.init(id: value, title: display.displayName)], editable: false)
                    }
                    if !code.isEmpty { inputs.insert(readOnly("display_code", "合约代号", display.displayCode), at: 0) }
                }
            }
            if assetKind?.isTermDeposit == true {
                inputs += [field("annual_rate", "年利率（%）", required: true, value: selected?.depositTerms.flatMap { decimal($0.annualRate * 100) }),
                           field("maturity_date", "到期日", required: true, value: selected?.depositTerms.map { day.string(from: $0.maturity) })]
            }
        case .addEvent, .editEvent, .deleteEvent:
            title = kind == .deleteEvent ? "删除流水" : kind == .editEvent ? "编辑流水" : eventKind.map { selected?.transactionTitle($0) ?? $0.rawValue } ?? "新增流水"
            inputs = [owner]
            if kind != .addEvent { inputs.append(field("event_id", "交易流水", required: true)) }
            if kind == .deleteEvent { break }
            if kind == .addEvent { inputs.append(field("event_type", "流水类型", required: true)) }
            else { inputs.append(readOnly("event_type", "流水类型", eventKind.map { selected?.transactionTitle($0) ?? $0.rawValue })) }
            if let eventKind, ![.deposit, .withdrawal, .transferIn, .transferOut].contains(eventKind),
               eventKind != .adjustment || selected != nil {
                var selectedInstrument = instrument
                selectedInstrument.editable = kind == .addEvent
                inputs.append(selectedInstrument)
            }
            inputs.append(date(kind == .addEvent && [.buy, .sell, .opening].contains(eventKind) && selected?.kind.isTermDeposit != true ? "成交日期" : "记账日期", original?.day))
            if let eventKind, [.buy, .sell, .opening].contains(eventKind), let selected {
                let coin = selected.kind == .cryptoContract && selected.basis == .coin
                let quote = coin ? "USD/" + settlement : book.quoteUnit(for: selected)
                if selected.kind.isTermDeposit {
                    inputs += [field("price", eventKind == .sell ? "支取金额（CNY）" : "存入金额（CNY）", required: true, value: decimal(original?.price)),
                               field("settled_amount", "变动后余额（CNY）", required: true, value: decimal(original?.settledAmount))]
                } else {
                    if selected.kind != .insurance {
                        if coin {
                            let mode = text("quantity_mode") ?? (original != nil && text("quantity") == nil ? "contracts" : nil)
                            inputs.append(field("quantity_mode", "数量录入方式", required: true, value: mode))
                            let label = mode == "coins" ? "仓位折算量（\(settlement)）" : mode == "notional" ? "美元名义价值（USD）" : "数量（张）"
                            inputs.append(field("quantity", label, required: true, value: mode == "contracts" ? decimal(original?.quantity) : nil))
                            if mode == "coins" { inputs.append(field("reference_price", "折算用价格（\(quote)）", required: true)) }
                        } else {
                            let unit = selected.kind == .cryptoContract && selected.market == "HTX" ? "张" : selected.kind.unit
                            inputs.append(field("quantity", "数量（\(unit)）", required: true, value: decimal(original?.quantity)))
                        }
                    }
                    inputs.append(field("price", selected.kind == .insurance ? (eventKind == .sell ? "退保到账金额（HKD）" : "保费金额（HKD）") : "成交价（\(quote)）",
                                        required: true, value: decimal(original?.price)))
                    if selected.isStockConnect { inputs.append(field("settled_amount", eventKind == .sell ? "实际到账金额（CNY）" : "实际成本金额（CNY）", required: true, value: decimal(original?.settledAmount))) }
                    if selected.kind.supportsTradeFees && !selected.isStockConnect && eventKind != .opening {
                        inputs.append(field("fee", "交易费用（\(settlement)，选填）", value: decimal(original?.fee)))
                    }
                    if selected.kind.usesMargin && eventKind != .sell {
                        inputs.append(field("margin", (selected.kind == .cryptoContract ? "本次开仓保证金总额" : "每手初始保证金") + "（\(settlement)）", required: true, value: decimal(original?.margin)))
                    }
                    if selected.collateralAssetID != nil { inputs.append(field("settlement_rate", settlement + " 兑美元单价", value: decimal(original?.settlementRate))) }
                }
                if kind == .addEvent && selected.kind != .cryptoContract { inputs.append(field("auto_fund", "现金不足时自动补足")) }
            } else if let eventKind {
                if selected?.kind.isTermDeposit == true {
                    if eventKind == .income { inputs.append(field("amount", "利息到账金额（CNY）", required: true, value: decimal(original?.amount))) }
                    inputs.append(field("settled_amount", "变动后余额（CNY）", required: true, value: decimal(original?.settledAmount)))
                } else if [.bonusShares, .stakingReward, .spotAdjustment].contains(eventKind) {
                    inputs.append(field("quantity", eventKind == .spotAdjustment ? "减少数量" : "增加数量", required: true, value: decimal(original.map { abs($0.quantity) })))
                } else {
                    let signed = [.adjustment, .funding, .marginTransfer, .derivativeSettlement].contains(eventKind)
                    if signed {
                        let direction = original.map { $0.amount < 0 ? "decrease" : "increase" }
                        inputs.append(field("direction", eventKind == .marginTransfer ? "划转方向" : "变动方向", required: true, value: text("amount") == nil ? direction : nil))
                    }
                    let amount = original.map { abs($0.amount) }
                    inputs.append(field("amount", (eventKind == .income ? "实收收益" : signed ? "变动金额" : "金额") + "（\(settlement)）", required: true, value: decimal(amount)))
                    if eventKind == .derivativeSettlement { inputs.append(field("price", "结算价（\(currency)）", required: true, value: decimal(original?.price))) }
                    if eventKind == .funding {
                        inputs.append(field("funding_target", "调整项目", required: true, value: original?.fundingTarget == .margin ? "margin" : original?.fundingTarget == .available ? "available" : nil))
                        if selected?.collateralAssetID != nil { inputs.append(field("settlement_rate", settlement + " 兑美元单价", value: decimal(original?.settlementRate))) }
                        inputs.append(field("unallocated", "计入账户资金费", value: original.map { $0.unallocatedFunding == true ? "true" : "false" }))
                    }
                    if let original, let pair = book.transferCounterpart(of: original, accountID: account?.id ?? UUID()), pair.0.currency != account?.currency {
                        let label = pair.1.kind == .transferIn ? "对方到账金额" : "对方划出金额"
                        inputs.append(field("counterpart_amount", "\(label)（\(pair.0.currency.rawValue)）", value: decimal(abs(pair.1.amount))))
                    }
                }
            }
        case .transfer:
            title = "划出资金"
            inputs = [owner, field("target_id", "目标账户", required: true), date(), field("amount", "划出金额（\(currency)）", required: true)]
            if let target, target.currency != account?.currency { inputs.append(field("received", "目标账户实际到账金额（\(target.currency.rawValue)）", required: true)) }
        case .cashBalance:
            title = "调整现金余额"
            inputs = [owner, field("amount", "调整后余额（\(currency)）", required: true), date()]
        case .distribution:
            title = "记分红"
            inputs = [owner, instrument, date("到账日期"), field("amount", "实际到账金额（\(currency)）")]
            if selected?.kind == .stock { inputs.append(field("quantity", "送股股数（选填）")) }
        case .spotBalance:
            title = "调整现货余额"
            inputs = [owner, instrument, date("调整日期"), field("amount", "调整后总余额（\(selected?.code ?? "币种")）", required: true)]
        case .fundingBalance:
            inputs = [owner, instrument, date("对账日期"), field("funding_target", "调整项目", required: true),
                      field("amount", "调整后余额（\(settlement)）", required: true)]
            if selected?.collateralAssetID != nil { inputs.append(field("settlement_rate", settlement + " 兑美元单价（留空使用账本报价）")) }
            if text("funding_target") == "available" { inputs.append(field("attribute_to_contract", "计入当前合约", required: true)) }
        case .plan:
            title = plan == nil ? "新建定投任务" : "编辑定投任务"
            if plan != nil { inputs.append(field("plan_id", "定投任务", required: true)) }
            inputs += [field("plan_type", "任务类型", required: true), owner]
            if text("plan_type") == "buy" { inputs.append(field("asset_id", "买入标的", required: true)) }
            inputs += [field("amount", "每次金额（\(currency)）", required: true),
                       field("month_day", "每月执行日", required: true), field("enabled", "启用任务", required: true)]
        case .removePlan: inputs = [field("plan_id", "定投任务", required: true)]
        case .watch:
            title = text("enabled") == "false" ? "移出关注" : "添加关注"
            inputs = [instrument, field("enabled", "关注此标的", required: true)]
        case .quote:
            let insurance = selected?.kind == .insurance
            title = insurance ? "更新现金价值" : selected?.kind == .wealth ? "更新单位净值" : "手动报价"
            inputs = [instrument, date(insurance ? "估值日期" : "报价日期"),
                      field("price", insurance ? "现金价值（HKD）" : selected?.kind == .wealth ? "单位净值（CNY）" : "价格（\(selected.map { book.quoteUnit(for: $0) } ?? currency)）", required: true)]
        case .balanceAccount:
            inputs = [field("category", "账户分类", required: true), field("name", "账户名称", required: true), field("amount", "初始余额（元）", required: true), date()]
        case .balanceRecord:
            title = "更新余额"
            inputs = [field("balance_account_id", "资产负债账户", required: true), field("amount", "更新后余额（元）", required: true), date()]
        case .editBalanceRecord, .deleteBalanceRecord:
            inputs = [field("balance_account_id", "资产负债账户", required: true), field("record_id", "余额记录", required: true)]
            if kind == .editBalanceRecord { inputs += [date("记账日期", record?.recordedAt), field("amount", "变动后余额（元）", required: true, value: decimal(record?.amount))] }
        case .refreshMarket, .rebuildSnapshots: break
        }
        groups.append(.init(title: account?.name ?? "", fields: inputs))
        return .init(title: title, groups: groups)
    }
}
