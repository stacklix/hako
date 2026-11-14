import SwiftUI

struct InvestmentEventEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    private enum Field: Hashable { case amount, counterpart, quantity, price, fee, margin, settlement, rate }

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
    @State private var settlementQuote = InvestmentEntryQuoteState()
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
        let inputs: [Field: String] = [
            .amount: text(abs(event.amount)), .counterpart: text(counterpart.map { abs($0.1.amount) }),
            .quantity: text(abs(event.quantity)), .price: text(event.price), .fee: text(event.fee),
            .margin: text(event.margin), .settlement: text(event.settledAmount), .rate: text(event.settlementRate)
        ]
        originalValues = inputs
        var populated = inputs
        let keys: [Field: String] = [.amount: "amount", .counterpart: "counterpart_amount", .quantity: "quantity", .price: "price",
                                    .fee: "fee", .margin: "margin", .settlement: "settled_amount", .rate: "settlement_rate"]
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
    private var hasChanges: Bool { date != event.day || values != originalValues || decreases != (event.amount < 0) }

    var body: some View {
        SettingsSheet(title: editorDraft?.action.kind == .addEvent ? "记录流水" : "编辑流水", hasChanges: hasChanges,
                      isBusy: saving || store.saving, saveEnabled: hasChanges,
                      onSave: { Task { await save() } }, saveAccessibilityLabel: editorDraft == nil ? "保存流水" : "完成修改并更新预览") {
            Form {
                Section {
                    LabeledContent("流水类型", value: event.kind == .marginTransfer ? "保证金划转" : event.title(for: asset))
                    if let asset { LabeledContent("标的", value: asset.displayName) }
                    if let (other, _) = counterpart { LabeledContent("对方账户", value: other.name) }
                    InvestmentDatePicker("记账日期", selection: $date, latest: InvestmentBook.day())
                    fields
                } header: {
                    Text(account?.name ?? "流水")
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                if editorDraft == nil { Section {
                    HakoDeleteButton(title: "删除流水") { confirmsDeletion = true }
                        .disabled(store.saving).investmentListRow()
                        .listRowBackground(Color.clear)
                } }
            }
            .hakoDeleteConfirmation(Text("删除这笔流水？"), isPresented: $confirmsDeletion,
                                    message: Text(counterpart == nil ? "删除后将重新计算受影响的日终快照。" :
                                        "两个账户中的对应划转流水会同时删除，并重新计算受影响的日终快照。"),
                                    disabled: store.saving) {
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
        case .opening, .buy, .sell:
            if asset?.kind.isTermDeposit == true {
                field(event.kind == .sell ? "支取金额（CNY）" : "存入金额（CNY）", .price)
                field("变动后余额（CNY）", .settlement)
            } else if let asset {
                let unit = asset.basis == .coin ? "张" : asset.kind.unit
                let priceTitle = asset.kind == .insurance ? (event.kind == .sell ? "退保到账金额" : "保费金额") : "成交价"
                let settlement = store.book.settlementUnit(for: asset)
                if asset.kind != .insurance { field("数量（\(unit)）", .quantity) }
                field("\(priceTitle)（\(store.book.quoteUnit(for: asset))）", .price)
                if asset.kind.usesMargin && event.kind != .sell { field("保证金（\(settlement)）", .margin) }
                if asset.isStockConnect { field("实际交收金额（CNY）", .settlement) }
                if event.kind != .opening && asset.kind.supportsTradeFees && !asset.isStockConnect {
                    field("交易费用（\(settlement)，选填）", .fee)
                }
                if asset.collateralAssetID != nil { settlementPriceField }
            }
        case .adjustment where asset?.kind.isTermDeposit == true:
            field("变动后余额（CNY）", .settlement)
        case .income where asset?.kind.isTermDeposit == true:
            field("利息到账金额（CNY）", .amount)
            field("变动后余额（CNY）", .settlement)
        case .bonusShares, .stakingReward, .spotAdjustment:
            field(event.kind == .spotAdjustment ? "减少数量" : "增加数量", .quantity)
        case .funding, .marginTransfer, .adjustment, .derivativeSettlement:
            if let target = event.fundingTarget { LabeledContent("调整余额", value: target.rawValue) }
            Picker("变动方向", selection: $decreases) {
                Text("增加").tag(false)
                Text("减少").tag(true)
            }
            let unit = asset.map { store.book.settlementUnit(for: $0) } ?? currency
            field("变动金额（\(unit)）", .amount)
            if event.kind == .derivativeSettlement { field("结算价（\(currency)）", .price) }
            if event.kind == .funding, asset?.collateralAssetID != nil { settlementPriceField }
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
                        keyboard: .decimalPad)
    }

    private func number(_ key: Field, _ label: String, allowZero: Bool = false) throws -> Decimal {
        try investmentDecimal(values[key, default: ""], label, allowZero: allowZero)
    }

    private var settlementRequest: InvestmentEntryQuoteRequest? {
        store.book.asset(asset?.collateralAssetID).map {
            .settlement(code: $0.code, day: InvestmentBook.day(date))
        }
    }

    private var settlementPriceField: some View {
        let unit = asset.map { store.book.settlementUnit(for: $0) } ?? "结算币"
        return InvestmentAutomaticPriceField(title: unit + " 兑美元单价", unit: "USD/" + unit,
            request: settlementRequest,
            help: "保留流水已记录的价格；清空手动价格后自动查询所选日期的美元报价。历史报价采用 UTC 日价。",
            state: $settlementQuote,
            manualPrice: Binding(get: { values[.rate, default: ""] }, set: { values[.rate] = $0 }))
    }

    private func settlementRate() throws -> Decimal? {
        if values[.rate, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return settlementQuote.quote(for: settlementRequest)?.price
        }
        return try number(.rate, "结算币兑美元单价")
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
            case .opening, .buy, .sell:
                guard let asset else { throw InvestmentError.invalid("找不到流水对应的标的。") }
                if asset.kind.isTermDeposit {
                    edited.price = try number(.price, "变动金额")
                    edited.settledAmount = try number(.settlement, "变动后余额", allowZero: true)
                    break
                }
                if asset.kind != .insurance { edited.quantity = try number(.quantity, "数量") }
                if asset.basis == .coin {
                    _ = try InvestmentCoinContractQuantity.contracts(edited.quantity).contractCount(faceValue: asset.multiplier)
                } else if [.stock, .option, .future].contains(asset.kind),
                          edited.quantity != Decimal(NSDecimalNumber(decimal: edited.quantity).int64Value) {
                    throw InvestmentError.invalid("该类型的数量必须是整数。")
                }
                edited.price = try number(.price, "成交金额或价格", allowZero: asset.kind == .insurance && event.kind == .sell)
                if asset.kind.usesMargin && event.kind != .sell { edited.margin = try number(.margin, "保证金") }
                if asset.isStockConnect { edited.settledAmount = try number(.settlement, "实际交收金额") }
                if event.kind != .opening && asset.kind.supportsTradeFees && !asset.isStockConnect {
                    edited.fee = values[.fee, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
                        nil : try number(.fee, "交易费用", allowZero: true)
                }
                if asset.collateralAssetID != nil { edited.settlementRate = try settlementRate() }
            case .adjustment where asset?.kind.isTermDeposit == true:
                edited.settledAmount = try number(.settlement, "变动后余额", allowZero: true)
            case .income where asset?.kind.isTermDeposit == true:
                edited.amount = try number(.amount, "利息到账金额")
                edited.settledAmount = try number(.settlement, "变动后余额", allowZero: true)
            case .bonusShares, .stakingReward, .spotAdjustment:
                edited.quantity = try number(.quantity, "变动数量") * (event.kind == .spotAdjustment ? -1 : 1)
            default:
                edited.amount = try number(.amount, "金额", allowZero: event.kind == .derivativeSettlement) * (decreases ? -1 : 1)
                if event.kind == .derivativeSettlement { edited.price = try number(.price, "结算价") }
                if event.kind == .funding, asset?.collateralAssetID != nil {
                    edited.settlementRate = try settlementRate()
                }
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
        do {
            try await store.update { try $0.deleteEvent(event, accountID: accountID) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
