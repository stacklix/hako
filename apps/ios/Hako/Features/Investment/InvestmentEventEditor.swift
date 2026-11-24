import SwiftUI

struct InvestmentEventEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    private enum Field: Hashable { case amount, counterpart, quantity, price, fee, margin, settlement }

    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    let event: InvestmentEvent
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var values: [Field: String]
    @State private var decreases: Bool
    @State private var confirmsDeletion = false
    @State private var error: String?
    @State private var saving = false
    private let counterpart: (InvestmentAccount, InvestmentEvent)?
    private let originalValues: [Field: String]

    init(store: InvestmentStore, accountID: UUID, event: InvestmentEvent, editing: InvestmentEditorDraft? = nil) {
        self.store = store
        self.accountID = accountID
        self.event = event
        editorDraft = editing
        let counterpart = store.book.transferCounterpart(of: event, accountID: accountID)
        self.counterpart = counterpart
        func text(_ value: Decimal?) -> String {
            value?.formatted(.number.grouping(.never).precision(.fractionLength(0...38))) ?? ""
        }
        var inputs: [Field: String] = [
            .amount: text(abs(event.amount)), .counterpart: text(counterpart.map { abs($0.1.amount) }),
            .quantity: text(abs(event.quantity)), .price: text(event.price), .fee: text(event.fee),
            .margin: text(event.margin), .settlement: text(event.settledAmount)
        ]
        if editing == nil, store.book.asset(event.assetID)?.kind == .crypto,
           [.stakingReward, .spotAdjustment].contains(event.kind) {
            inputs[.settlement] = text(store.book.positionBefore(event, accountID: accountID).map { $0.quantity + event.quantity })
        }
        originalValues = inputs
        var populated = inputs
        let keys: [Field: String] = [.amount: "amount", .counterpart: "counterpart_amount", .quantity: "quantity", .price: "price",
                                    .fee: "fee", .margin: "margin", .settlement: "settled_amount"]
        for (field, key) in keys {
            if let value = editing?.action.values[key] { populated[field] = field == .amount || field == .quantity || field == .counterpart ? editing?.amount(key) : value }
        }
        if let editing, let proposed = editing.proposal.book.account(accountID)?.events.first(where: { $0.id == event.id }) {
            populated[.quantity] = text(abs(proposed.quantity))
        }
        _values = State(initialValue: populated)
        _date = State(initialValue: editing?.action.text("date").flatMap(InvestmentEditorDraft.day.date(from:)) ?? event.day)
        _decreases = State(initialValue: editing?.action.text("direction").map { $0 == "decrease" } ?? (event.amount < 0))
    }

    private var account: InvestmentAccount? { store.book.account(accountID) }
    private var asset: InvestmentAsset? { store.book.asset(event.assetID) }
    private var editsSpotBalance: Bool { editorDraft == nil && asset?.kind == .crypto && [.stakingReward, .spotAdjustment].contains(event.kind) }
    private var recordTitle: String { editsSpotBalance ? "余额调整" : (editorDraft?.proposal.book ?? store.book).eventTitle(event, accountID: accountID) }
    private var hasChanges: Bool { date != event.day || values != originalValues || decreases != (event.amount < 0) }

    var body: some View {
        SettingsSheet(title: editorDraft?.action.kind == .addEvent ? "记录交易" : "修改" + recordTitle, hasChanges: hasChanges,
                      isBusy: saving || store.saving, saveEnabled: hasChanges,
                      onSave: { Task { await save() } }, saveInProgress: saving,
                      saveAccessibilityLabel: editorDraft == nil ? "保存交易记录" : "完成修改并更新预览") {
            Form {
                Section {
                    LabeledContent("记录类型", value: event.kind == .marginTransfer ? "保证金划转" : recordTitle)
                    if let asset { LabeledContent("标的", value: asset.displayName) }
                    if let (other, _) = counterpart { LabeledContent("对方账户", value: other.name) }
                    InvestmentDatePicker(editsSpotBalance ? "调整日期" : [.dividend, .bonusShares].contains(event.kind) ? "到账日期" : "交易日期", selection: $date, latest: InvestmentBook.day())
                    fields
                } header: {
                    Text(account?.name ?? "流水")
                }
                if editorDraft == nil { Section {
                    HakoDeleteButton(title: "删除交易记录") { confirmsDeletion = true }
                        .disabled(saving || store.saving).investmentListRow()
                        .listRowBackground(Color.clear)
                } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.bar)
                        .accessibilityElement(children: .combine)
                }
            }
            .hakoDeleteConfirmation(Text("删除这笔交易记录？"), isPresented: $confirmsDeletion,
                                    message: Text(counterpart == nil ? InvestmentText.date(event.day) + " · " + recordTitle + "。删除后将重新计算持仓、盈亏和相关历史快照，此操作无法撤销。" :
                                        "两个账户中的对应划转流水会同时删除，并重新计算受影响的日终快照。"),
                                    disabled: saving || store.saving) {
                Task { await delete() }
            }
        }
        .environment(\.calendar, InvestmentBook.calendar)
        .environment(\.timeZone, InvestmentBook.calendar.timeZone)
        .environment(\.investmentFieldPlaceholders, false)
    }

    @ViewBuilder private var fields: some View {
        let currency = account?.currency.rawValue ?? ""
        switch event.kind {
        case .insuranceWithdrawal:
            field("提取金额（\(currency)）", .amount)
            field("提取后现金价值（\(currency)，选填）", .settlement)
            Text("提取金额转入本账户现金，保单继续保留。现金价值留空时按最近已知现金价值扣减；缺少可用估值时按零估值。")
                .font(.footnote).foregroundStyle(.secondary)
        case .opening, .buy, .sell:
            if asset?.kind == .generic {
                field((event.kind == .sell ? "取出金额" : "投入金额") + "（\(currency)）", .price)
                if event.settledAmount != nil { field("录入时余额（\(currency)）", .settlement) }
            } else if asset?.kind == .wealth {
                field(event.kind == .sell ? "赎回到账金额（CNY）" : "申购金额（CNY）", .price)
                field("变动后余额（CNY）", .settlement)
            } else if asset?.kind.isTermDeposit == true {
                field(event.kind == .sell ? "支取金额（CNY）" : "存入金额（CNY）", .price)
                field("变动后余额（\(currency)）", .settlement)
            } else if let asset {
                let unit = asset.historyUnit
                let priceTitle = asset.kind == .insurance ? (event.kind == .sell ? "退保到账金额" : "保费金额")
                    : asset.isStockConnect ? (event.kind == .sell ? "卖出单价" : "买入单价") : "成交价"
                let settlement = store.book.settlementUnit(for: asset)
                if asset.kind != .insurance { field("数量（\(unit)）", .quantity) }
                field("\(priceTitle)（\(store.book.quoteUnit(for: asset))）", .price)
                if asset.kind.usesMargin && event.kind != .sell { field("保证金（\(settlement)）", .margin) }
                if asset.isStockConnect {
                    field("清算金额（CNY）", .settlement)
                    Text("按券商交割单填写含费用的人民币总额，买入为实际支出，卖出为实际到账。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if event.kind != .opening && asset.kind.supportsTradeFees && !asset.isStockConnect {
                    field("交易费用（\(settlement)，选填）", .fee)
                }
            }
        case .adjustment where asset?.kind.usesBalance == true:
            field("变动后余额（\(currency)）", .settlement)
        case .income where asset?.kind.usesBalance == true:
            field(asset?.kind == .wealth ? "实收收益（CNY）" : "利息到账金额（CNY）", .amount)
            field("变动后余额（\(currency)）", .settlement)
        case .bonusShares:
            field("送股数量（股）", .quantity)
        case .stakingReward, .spotAdjustment:
            if editsSpotBalance, let asset {
                field("调整后余额（\(asset.code)）", .settlement)
                let before = store.book.positionBefore(event, accountID: accountID, on: date)
                let target = try? number(.settlement, "调整后余额", allowZero: true)
                let delta = before.flatMap { previous in target.map { $0 - previous.quantity } }
                LabeledContent("调整前余额", value: before.map { InvestmentText.number($0.quantity) + " " + asset.code } ?? "—")
                LabeledContent("数量变化", value: delta.map { ($0 > 0 ? "+" : "") + InvestmentText.number($0) + " " + asset.code } ?? "—")
                let quote = store.book.positionQuote(for: asset, on: InvestmentBook.day(date), requiresDailyPrices: InvestmentBook.day(date) < InvestmentBook.day())
                let value = delta.flatMap { change in quote.map { $0.price * change } }
                LabeledContent("估值变动", value: InvestmentText.money(value, asset.currency, signed: true))
                Text("按所选日期的账面余额计算数量增减，不产生现金收支。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                field(event.kind == .spotAdjustment ? "减少数量" : "增加数量", .quantity)
            }
        case .dividend:
            field("实际到账金额（\(currency)）", .amount)
        case .marginTransfer, .adjustment, .derivativeSettlement:
            Picker("变动方向", selection: $decreases) {
                Text("增加").tag(false)
                Text("减少").tag(true)
            }
            let unit = asset.map { store.book.settlementUnit(for: $0) } ?? currency
            field("变动金额（\(unit)）", .amount)
            if event.kind == .derivativeSettlement { field("结算价（\(currency)）", .price) }
        default:
            field("金额（\(currency)）", .amount)
            if let (other, entry) = counterpart, other.currency != account?.currency {
                let title = entry.kind == .transferIn ? "对方到账金额" : "对方划出金额"
                field("\(title)（\(other.currency.rawValue)）", .counterpart)
            }
        }
    }

    private func field(_ label: String, _ key: Field) -> some View {
        InvestmentField(label, text: Binding(get: { values[key, default: ""] }, set: { values[key] = $0 }),
                        keyboard: .decimalPad, preservesPrecision: key == .quantity || (editsSpotBalance && key == .settlement),
                        unitPrice: key == .price && asset?.kind.usesUnitPrice == true)
    }

    private func number(_ key: Field, _ label: String, allowZero: Bool = false) throws -> Decimal {
        try investmentDecimal(values[key, default: ""], label, allowZero: allowZero,
                              preservesPrecision: key == .quantity || (editsSpotBalance && key == .settlement),
                              unitPrice: key == .price && asset?.kind.usesUnitPrice == true)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            var edited = event
            edited.day = InvestmentBook.day(date)
            var otherAmount: Decimal?
            switch event.kind {
            case .insuranceWithdrawal:
                edited.amount = try number(.amount, "提取金额")
                edited.settledAmount = values[.settlement, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : try number(.settlement, "提取后现金价值", allowZero: true)
            case .opening, .buy, .sell:
                guard let asset else { throw InvestmentError.invalid("找不到流水对应的标的。") }
                if asset.kind == .generic {
                    edited.price = try number(.price, "变动金额")
                    if event.settledAmount != nil { edited.settledAmount = try number(.settlement, "录入时余额", allowZero: true) }
                    break
                }
                if asset.kind.isTermDeposit || asset.kind == .wealth {
                    edited.price = try number(.price, "变动金额")
                    edited.settledAmount = try number(.settlement, "变动后余额", allowZero: true)
                    break
                }
                if asset.kind != .insurance { edited.quantity = try number(.quantity, "数量") }
                if edited.quantity != event.quantity {
                    try asset.kind.validateTradeQuantity(edited.quantity, currency: asset.currency)
                }
                edited.price = try number(.price, "成交金额或价格", allowZero: asset.kind == .insurance && event.kind == .sell)
                if asset.kind.usesMargin && event.kind != .sell { edited.margin = try number(.margin, "保证金") }
                if asset.isStockConnect { edited.settledAmount = try number(.settlement, "清算金额") }
                if event.kind != .opening && asset.kind.supportsTradeFees && !asset.isStockConnect {
                    edited.fee = values[.fee, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
                        nil : try number(.fee, "交易费用", allowZero: true)
                }
            case .adjustment where asset?.kind.usesBalance == true:
                edited.settledAmount = try number(.settlement, "变动后余额", allowZero: true)
            case .income where asset?.kind.usesBalance == true:
                edited.amount = try number(.amount, asset?.kind == .wealth ? "实收收益" : "利息到账金额")
                edited.settledAmount = try number(.settlement, "变动后余额", allowZero: true)
            case .bonusShares, .stakingReward, .spotAdjustment:
                if editsSpotBalance {
                    edited = try store.book.spotBalanceReplacement(event, accountID: accountID,
                        balance: number(.settlement, "调整后余额", allowZero: true), on: date)
                } else {
                    edited.quantity = try number(.quantity, "变动数量") * (event.kind == .spotAdjustment ? -1 : 1)
                    if let asset, edited.quantity != event.quantity {
                        try asset.kind.validateTradeQuantity(edited.quantity, currency: asset.currency)
                    }
                }
            default:
                edited.amount = try number(.amount, "金额", allowZero: event.kind == .derivativeSettlement) * (decreases ? -1 : 1)
                if event.kind == .derivativeSettlement { edited.price = try number(.price, "结算价") }

                if let (other, entry) = counterpart, other.currency != account?.currency {
                    otherAmount = try number(.counterpart, "对方金额") * (entry.kind == .transferOut ? -1 : 1)
                }
            }
            if let editorDraft {
                var inputs = InvestmentEditorDraft.eventValues(edited)
                inputs["counterpart_amount"] = otherAmount.map { InvestmentEditorDraft.text(abs($0)) } ?? ""
                try await editorDraft.submit(inputs)
            } else {
                try await store.update { try $0.replaceEvent(event, with: edited, accountID: accountID, counterpartAmount: otherAmount) }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.update { try $0.deleteEvent(event, accountID: accountID) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
