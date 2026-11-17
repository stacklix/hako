import SwiftUI

private struct InvestmentFieldPlaceholders: EnvironmentKey {
    static let defaultValue = true
}

private struct InvestmentEditingDraftKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var investmentEditingDraft: Bool {
        get { self[InvestmentEditingDraftKey.self] }
        set { self[InvestmentEditingDraftKey.self] = newValue }
    }
    var investmentFieldPlaceholders: Bool {
        get { self[InvestmentFieldPlaceholders.self] }
        set { self[InvestmentFieldPlaceholders.self] = newValue }
    }
}

struct InvestmentField: View {
    @Environment(\.investmentFieldPlaceholders) private var showsPlaceholder
    @FocusState private var focused: Bool
    let title: String
    @Binding var text: String
    var axis: Axis
    var keyboard: UIKeyboardType
    let help: String?
    let focusesOnRowTap: Bool

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal, keyboard: UIKeyboardType = .default,
         help: String? = nil, focusesOnRowTap: Bool = false) {
        self.title = title
        _text = text
        self.axis = axis
        self.keyboard = keyboard
        self.help = help
        self.focusesOnRowTap = focusesOnRowTap
    }

    var body: some View {
        if focusesOnRowTap {
            field
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { _ in focused = true })
                .listRowInsets(EdgeInsets())
        } else {
            field
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let help { InvestmentFieldKey(title: title, help: help) }
                else { Text(title) }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            TextField(showsPlaceholder ? title : "", text: $text, axis: axis)
                .keyboardType(keyboard)
                .accessibilityLabel(title)
                .focused($focused)
        }.investmentListRow()
    }
}

private struct InvestmentFieldHelp: View {
    let title: String
    let help: String
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title + "说明")
        .alert(title, isPresented: $showingHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(help)
        }
    }
}

private struct InvestmentFieldKey: View {
    let title: String
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InvestmentFieldHelp(title: title, help: help)
        }
    }
}

private struct InvestmentHelpRow<Content: View>: View {
    let title: String
    let help: String?
    @ViewBuilder let content: Content

    var body: some View {
        LabeledContent {
            content
        } label: {
            if let help { InvestmentFieldKey(title: title, help: help) }
            else { Text(title) }
        }
        .investmentListRow()
    }
}

private struct InvestmentSaveError: Identifiable {
    let id = UUID()
    let message: String
}

private struct InvestmentEditor<Content: View>: View {
    @Environment(\.investmentEditingDraft) private var editingDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false
    let title: String
    var inSheet = false
    var hasChanges = false
    var saveEnabled: Bool? = nil
    var inlineError: Binding<InvestmentSaveError?>?
    @ViewBuilder let content: Content
    let save: () async throws -> Void

    var body: some View {
        Group {
            if inSheet || editingDraft {
                SettingsSheet(title: title, hasChanges: hasChanges, isBusy: saving, saveEnabled: saveEnabled ?? hasChanges, onSave: commit,
                              saveAccessibilityLabel: editingDraft ? "完成修改并更新预览" : "保存") { form }
            } else {
                form.navigationTitle(title)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: commit) { Image(systemName: "checkmark") }
                                .accessibilityLabel("保存")
                                .disabled(saving || !(saveEnabled ?? hasChanges))
                        }
                    }
            }
        }
        .environment(\.calendar, InvestmentBook.calendar)
        .environment(\.timeZone, InvestmentBook.calendar.timeZone)
    }

    private var form: some View {
        ScrollViewReader { scroll in
            Form {
                content
                Section {
                    if editingDraft {
                        Text("完成修改后更新预览，确认预览才会写入账本。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .onChange(of: inlineError?.wrappedValue?.id) { _, id in
                guard let id else { return }
                withAnimation { scroll.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func commit() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await save(); dismiss() }
            catch {
                if let inlineError {
                    inlineError.wrappedValue = InvestmentSaveError(message: error.localizedDescription)
                } else {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private func investmentTrim(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func investmentDecimal(_ input: String, _ field: String, allowZero: Bool = false) throws -> Decimal {
    let separator = Locale.current.decimalSeparator ?? "."
    let value = investmentTrim(input).replacingOccurrences(of: separator, with: ".")
    guard value.range(of: #"^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
          let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
          decimal <= 1_000_000_000_000, allowZero ? decimal >= 0 : decimal > 0 else {
        throw InvestmentError.invalid("请输入有效的" + field + "。")
    }
    return decimal
}

struct InvestmentAccountEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    var editingAccount: InvestmentAccount? = nil
    @ObservedObject var store: InvestmentStore
    @State private var name = ""
    @State private var currency: InvestmentCurrency?
    @State private var type: InvestmentAccountType?
    @State private var position = 1

    var body: some View {
        InvestmentEditor(title: editingAccount == nil ? "添加账户" : "编辑账户", inSheet: true,
                         hasChanges: !name.isEmpty || currency != nil || type != nil) {
            Section {
                InvestmentField("账户名称", text: $name, focusesOnRowTap: true)
                if let editingAccount {
                    LabeledContent("账户币种", value: editingAccount.currency.rawValue)
                    LabeledContent("账户类型", value: editingAccount.type.rawValue)
                    Picker("账户顺序", selection: $position) {
                        ForEach(1...max(1, store.book.accounts.count), id: \.self) { Text("第 \($0) 个").tag($0) }
                    }
                } else {
                Picker("账户币种", selection: $currency) {
                    Text("请选择").tag(nil as InvestmentCurrency?)
                    ForEach(InvestmentCurrency.allCases) { item in
                        Text(item.title + " · " + item.rawValue).tag(Optional(item))
                    }
                }.onChange(of: currency) { type = nil }
                if let currency {
                    Picker("账户类型", selection: $type) {
                        Text("请选择").tag(nil as InvestmentAccountType?)
                        ForEach(InvestmentAccountType.available(in: currency)) { item in
                            Text(item.rawValue).tag(Optional(item))
                        }
                    }
                }
                }
            } footer: {
                if editingAccount == nil { Text("创建后自动添加同币种的现金账户。") }
            }
        } save: {
            let name = investmentTrim(name)
            guard !name.isEmpty, let currency, let type, InvestmentAccountType.available(in: currency).contains(type) else {
                throw InvestmentError.invalid("请填写账户名称，并选择账户币种和类型。")
            }
            if let editorDraft {
                let values = editingAccount == nil
                    ? ["name": name, "currency": currency.rawValue, "account_type": InvestmentAgentAction.accountTypes.first { $0.value == type }!.key]
                    : ["name": name, "position": String(position)]
                try await editorDraft.submit(values)
                return
            }
            if let editingAccount {
                try await store.update { book in
                    try InvestmentAgentAction(kind: .editAccount, values: ["account_id": editingAccount.id.uuidString,
                        "name": name, "position": String(position)]).apply(to: &book)
                }
                return
            }
            try await store.update { book in
                guard !book.accounts.contains(where: {
                    $0.name == name && $0.currency == currency && $0.type == type
                }) else {
                    throw InvestmentError.invalid("该账户已存在。")
                }
                book.accounts.append(InvestmentAccount(name: name, currency: currency, type: type))
            }
        }
    }
}

struct InvestmentTransferEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @State private var date = InvestmentBook.day()
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    @State private var targetID: UUID?
    @State private var amount = ""
    @State private var remaining = ""
    @State private var received = ""

    var body: some View {
        let target = targetID.flatMap { store.book.account($0) }
        let current = store.book.account(account.id).flatMap { try? store.book.ledger($0).cash }
        let code = account.currency.rawValue
        InvestmentEditor(title: "划出资金", inSheet: true,
                         hasChanges: targetID != nil || !amount.isEmpty || !remaining.isEmpty || !received.isEmpty) {
            Section(account.name) {
                InvestmentDatePicker("划转日期", selection: $date, latest: InvestmentBook.day())
                LabeledContent("当前现金余额", value: InvestmentText.money(current, account.currency))
                Picker("目标账户", selection: $targetID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(store.book.accounts.filter { $0.id != account.id && !$0.isArchived }) { item in
                        Text([item.name, item.type.rawValue, item.currency.rawValue].joined(separator: " · "))
                            .tag(Optional(item.id))
                    }
                }.onChange(of: targetID) { received = "" }
                InvestmentField("划出金额（" + code + "）", text: $amount, keyboard: .decimalPad)
                InvestmentField("划出后剩余金额（" + code + "）", text: $remaining, keyboard: .decimalPad)
                if let target, target.currency != account.currency {
                    InvestmentField("目标账户实际到账金额（" + target.currency.rawValue + "）", text: $received, keyboard: .decimalPad)
                }
            }
        } save: {
            guard let targetID, let target else { throw InvestmentError.invalid("请选择目标账户。") }
            let amount = try investmentDecimal(amount, "划出金额")
            let remaining = try investmentDecimal(remaining, "划出后剩余金额", allowZero: true)
            let received = target.currency == account.currency ? nil : try investmentDecimal(received, "实际到账金额")
            if let editorDraft {
                var trial = store.book
                try trial.transfer(from: account.id, to: targetID, amount: amount, remaining: remaining, received: received, on: date)
                try await editorDraft.submit(["target_id": targetID.uuidString, "amount": InvestmentEditorDraft.text(amount),
                    "remaining": InvestmentEditorDraft.text(remaining), "received": InvestmentEditorDraft.text(received),
                    "date": InvestmentEditorDraft.day.string(from: date)])
                return
            }
            try await store.update { try $0.transfer(from: account.id, to: targetID, amount: amount, remaining: remaining, received: received, on: date) }
        }
    }
}

struct InvestmentCashEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let kind: InvestmentEventKind
    @State private var amount = ""
    @State private var date = InvestmentBook.day()

    var body: some View {
        InvestmentEditor(title: kind == .adjustment ? "调整余额" : kind.rawValue + "资金", inSheet: true,
                         hasChanges: !amount.isEmpty || InvestmentBook.day(date) != InvestmentBook.day()) {
            Section(account.name) {
                InvestmentField((kind == .adjustment ? "调整后余额" : "金额") + "（" + account.currency.rawValue + "）",
                                text: $amount, keyboard: .decimalPad)
                InvestmentDatePicker("记账日期", selection: $date, latest: InvestmentBook.day())
                if account.type == .crypto {
                    Text("USD、USDC 和 USDT 按 1:1 计入 USD 现金余额。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .adjustment {
                    Text("调整后余额与记账日原余额的差额计入现金收益。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } save: {
            let value = try investmentDecimal(amount, "金额", allowZero: kind == .adjustment)
            let day = InvestmentBook.day(date)
            if let editorDraft {
                try await editorDraft.submit(["amount": InvestmentEditorDraft.text(value), "date": InvestmentEditorDraft.day.string(from: day)])
                return
            }
            try await store.update { book in
                guard let account = book.account(account.id) else { return }
                let delta: Decimal
                switch kind {
                case .adjustment: delta = value - (try book.ledger(account, through: day)).cash
                case .withdrawal: delta = -value
                default: delta = value
                }
                try book.post(InvestmentEvent(day: day, kind: kind, amount: delta), accountID: account.id)
            }
        }
    }
}

struct InvestmentHoldingAdjustmentEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var date = InvestmentBook.day()
    @State private var cash = ""
    @State private var shares = ""
    @State private var balance = ""

    var body: some View {
        let stock = asset.kind == .stock
        let supportsDividends = asset.kind.supportsCashDividends
        let day = InvestmentBook.day(date)
        let ledger = store.book.account(account.id).flatMap { try? store.book.ledger($0, through: day) }
        return InvestmentEditor(title: supportsDividends ? "记分红" : "调整余额", inSheet: true,
                                hasChanges: !cash.isEmpty || !shares.isEmpty || !balance.isEmpty) {
            Section(asset.kind.usesBalance ? asset.displayName : asset.displayName + " · " + asset.displayCode) {
                InvestmentDatePicker(supportsDividends ? "到账日期" : "调整日期", selection: $date, latest: InvestmentBook.day())
                if supportsDividends {
                    let suffix = stock ? "，选填）" : "）"
                    InvestmentField("实际到账金额（" + account.currency.rawValue + suffix, text: $cash, keyboard: .decimalPad)
                    if stock {
                        InvestmentField("送股股数（选填）", text: $shares, keyboard: .numberPad)
                        Text("可只填其中一项。").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if asset.kind.usesBalance {
                    if let current = ledger?.positions[asset.id]?.depositBalance {
                        LabeledContent("当前余额", value: InvestmentText.money(current, account.currency))
                    }
                    InvestmentField("变动后余额（" + account.currency.rawValue + "）", text: $balance, keyboard: .decimalPad)
                    Text("按实际余额估值，余额差额计入标的盈亏。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    if let quantity = ledger?.positions[asset.id]?.quantity {
                        LabeledContent("账面总余额", value: InvestmentText.number(quantity) + " " + asset.code)
                    }

                    InvestmentField("调整后总余额（" + asset.code + "）", text: $balance, keyboard: .decimalPad)
                    Text("增加的数量记为同币种质押奖励，减少的数量记为现货余额调整。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } save: {
            if let editorDraft {
                try await editorDraft.submit(["date": InvestmentEditorDraft.day.string(from: day),
                    "amount": supportsDividends ? cash : balance, "quantity": shares])
                return
            }
            try await store.update { book in
                if supportsDividends {
                    let cash = investmentTrim(cash).isEmpty ? 0 : try investmentDecimal(cash, "分红金额", allowZero: true)
                    let shares = investmentTrim(shares).isEmpty ? 0 : try investmentDecimal(shares, "送股股数", allowZero: true)
                    try book.recordDistribution(assetID: asset.id, accountID: account.id, cash: cash, shares: shares, on: day)
                } else {
                    let balance = try investmentDecimal(balance, "调整后余额", allowZero: true)
                    if asset.kind.usesBalance {
                        try book.adjustAssetBalance(assetID: asset.id, accountID: account.id, balance: balance, on: day)
                    } else {
                        try book.adjustSpotBalance(assetID: asset.id, accountID: account.id, balance: balance, on: day)
                    }
                }
            }
        }
    }
}

struct InvestmentFuturesSettlementEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    let store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var date = InvestmentBook.day()
    @State private var price = ""
    @State private var amount = ""
    @State private var isLoss = false

    var body: some View {
        InvestmentEditor(title: "记实际结算", inSheet: true, hasChanges: !price.isEmpty || !amount.isEmpty,
                         saveEnabled: !price.isEmpty && !amount.isEmpty) {
            Section(asset.displayName) {
                InvestmentDatePicker("结算日期", selection: $date, latest: InvestmentBook.day())
                InvestmentField("结算价（CNY）", text: $price, keyboard: .decimalPad)
                Picker("资金方向", selection: $isLoss) {
                    Text("入账").tag(false)
                    Text("扣款").tag(true)
                }
                InvestmentField("实际结算盈亏金额（CNY）", text: $amount, keyboard: .decimalPad)
            }
        } save: {
            let value = try investmentDecimal(amount, "实际结算金额", allowZero: true)
            let price = try investmentDecimal(price, "结算价")
            if let editorDraft {
                try await editorDraft.submit(["date": InvestmentEditorDraft.day.string(from: date), "price": InvestmentEditorDraft.text(price),
                    "amount": InvestmentEditorDraft.text(value), "direction": isLoss ? "decrease" : "increase"])
                return
            }
            try await store.update {
                try $0.post(.init(day: InvestmentBook.day(date), kind: .derivativeSettlement,
                    assetID: asset.id, amount: isLoss ? -value : value, price: price), accountID: account.id)
            }
        }
    }
}

struct InvestmentMarginTransferEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    private enum Direction: String {
        case increase = "增加"
        case decrease = "减少"
    }

    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var date = InvestmentBook.day()
    @State private var direction = Direction.increase
    @State private var amount = ""

    var body: some View {
        let day = InvestmentBook.day(date)
        let unit = account.currency.rawValue
        let balanceTitle = "可用现金余额"
        let ledger = store.book.account(account.id).flatMap { try? store.book.ledger($0, through: day) }
        let margin = ledger?.positions[asset.id].flatMap { $0.quantity > 0 ? $0.margin : nil }
        let available = ledger?.cash
        return InvestmentEditor(title: "调整保证金", inSheet: true, hasChanges: !amount.isEmpty) {
            Section {
                InvestmentDatePicker("划转日期", selection: $date, latest: InvestmentBook.day())
                if let margin, let available {
                    LabeledContent("已占用保证金", value: InvestmentText.number(margin) + " " + unit)
                    LabeledContent(balanceTitle, value: InvestmentText.number(available) + " " + unit)
                    Picker("划转方向", selection: $direction) {
                        Text(Direction.increase.rawValue).tag(Direction.increase)
                        Text(Direction.decrease.rawValue).tag(Direction.decrease)
                    }
                    InvestmentField("划转金额（" + unit + "）", text: $amount, keyboard: .decimalPad)
                } else {
                    Text("该日期没有可调整保证金的仓位。").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(asset.displayName + " · " + asset.kindLabel)
            } footer: {
                Text("增加时占用可用余额，减少时释放回可用余额。")
            }
        } save: {
            guard margin != nil else { throw InvestmentError.invalid("该日期没有可调整保证金的仓位。") }
            let value = try investmentDecimal(amount, "保证金划转金额")
            if let editorDraft {
                try await editorDraft.submit(["date": InvestmentEditorDraft.day.string(from: day), "amount": InvestmentEditorDraft.text(value),
                    "direction": direction == .increase ? "increase" : "decrease"])
                return
            }
            try await store.update {
                try $0.post(.init(day: day, kind: .marginTransfer, assetID: asset.id,
                                  amount: direction == .increase ? value : -value), accountID: account.id)
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
    }
}

private struct InvestmentAssetDraft: Equatable {
    init() {}
    init(_ asset: InvestmentAsset, book: InvestmentBook) {
        positionID = asset.id
        name = asset.name; code = asset.code; market = asset.market; kind = asset.kind
        multiplier = InvestmentEditorDraft.text(asset.multiplier)
        stockConnect = asset.isStockConnect
        contractSide = asset.contractSide ?? .long
        selectedAsset = asset.kind.requiresCatalog ? asset : nil
    }
    private var positionID = UUID()
    enum EntryType: Hashable {
        case standard(InvestmentKind)
        case stockConnect
    }

    var name = ""
    var code = ""
    var market = ""
    var kind = InvestmentKind.stock
    var multiplier = ""
    var contractSide = InvestmentContractSide.long
    private(set) var stockConnect = false
    private(set) var selectedAsset: InvestmentAsset?

    var entryType: EntryType {
        get {
            if stockConnect { return .stockConnect }
            return .standard(kind)
        }
        set {
            guard newValue != entryType else { return }
            clearInstrument()
            switch newValue {
            case .standard(let kind):
                stockConnect = false
                self.kind = kind
            case .stockConnect:
                stockConnect = true
                if kind != .stock && kind != .etf { kind = .stock }
            }
        }
    }

    var normalizedCode: String {
        let input = investmentTrim(code).uppercased()
        return stockConnect ? InvestmentAsset.stockConnectCode(input) ?? input : input
    }

    var venue: String { stockConnect ? InvestmentAsset.stockConnectMarket : investmentTrim(market).uppercased() }
    var assetSide: InvestmentContractSide? { kind.usesMargin ? contractSide : nil }
    var selected: Bool { selectedAsset != nil }
    var displayAsset: InvestmentAsset? {
        guard var asset = selectedAsset else { return nil }
        asset.contractSide = assetSide
        return asset
    }

    mutating func select(_ asset: InvestmentAsset) {
        code = asset.code
        name = asset.name
        market = asset.market
        selectedAsset = asset
    }

    mutating func clearInstrument() {
        positionID = UUID()
        name = ""
        code = ""
        market = ""
        multiplier = ""
        contractSide = .long
        selectedAsset = nil
    }

    func matches(_ asset: InvestmentAsset, currency: InvestmentCurrency) -> Bool {
        let entered = InvestmentAsset(name: name, code: normalizedCode, market: venue, kind: kind, currency: currency,
                                      contractSide: assetSide)
        if asset.matches(entered) { return true }
        guard asset.kind == kind, asset.currency == currency,
              !kind.usesMargin || (asset.contractSide ?? .long) == contractSide else { return false }
        guard !stockConnect, !asset.isStockConnect else { return false }
        let known = InvestmentQuoteSymbol(asset)
        let candidate = InvestmentQuoteSymbol(entered)
        if currency == .usd, !known.twelveMIC.isEmpty, !candidate.twelveMIC.isEmpty,
           known.twelveMIC != candidate.twelveMIC { return false }
        return candidate.tushareSymbol.map { $0 == known.tushareSymbol } ?? false
    }

    func asset(currency: InvestmentCurrency, reusing existing: InvestmentAsset? = nil) throws -> InvestmentAsset {
        if !kind.requiresCatalog, let existing { return existing }
        if kind.requiresCatalog, selectedAsset == nil {
            throw InvestmentError.invalid("请搜索并选择真实标的，名称和代码不能手工录入。")
        }
        let name = investmentTrim(name)
        guard !name.isEmpty else { throw InvestmentError.invalid("请选择标的或填写产品名称。") }
        let needsMultiplier = kind.derivative
        let multiplier = needsMultiplier ? try investmentDecimal(multiplier, "合约乘数") : 1
        let code = kind.usesBalance && normalizedCode.isEmpty ? UUID().uuidString : normalizedCode
        var result = InvestmentAsset(name: selectedAsset?.name ?? name, code: selectedAsset?.code ?? code,
                               market: selectedAsset?.market ?? venue, kind: kind, currency: currency, multiplier: multiplier,
                               contractSide: assetSide)
        result.id = positionID
        result.instrumentID = existing?.instrumentID ?? selectedAsset?.instrumentID ?? selectedAsset?.id
        if let existing {
            guard !kind.usesMargin || existing.multiplier == result.multiplier else {
                throw InvestmentError.invalid("目录中的合约规格与已有持仓不同，请先核对合约乘数和数量口径。")
            }
            result.id = existing.id
        }
        return result
    }
}

private struct InvestmentAssetFields: View {
    private enum SearchChoice: Identifiable {
        case instrument(InvestmentAsset)

        var asset: InvestmentAsset {
            switch self {
            case .instrument(let asset): asset
            }
        }
        var id: UUID { asset.id }
    }

    private struct SearchRequest: Equatable {
        let instrument: InvestmentInstrumentSearch
    }

    private struct SearchResponse {
        let request: SearchRequest
        let matches: [SearchChoice]?
        let message: String?
    }

    @Binding var draft: InvestmentAssetDraft
    let store: InvestmentStore
    let currency: InvestmentCurrency
    var kinds = InvestmentKind.allCases
    var allowsStockConnect = false
    var watchOnly = false
    var accountType: InvestmentAccountType?
    var existing: InvestmentAsset?
    var locksSpecifications = false
    @State private var query = ""
    @State private var searchResponse: SearchResponse?
    @State private var manualEntry = false
    @State private var showsExchange = false

    var body: some View {
        Group {
            if !locksSpecifications && (!watchOnly || currency != .hkd) {
                Picker("资产类型", selection: $draft.entryType) {
                    ForEach(kinds) { kind in
                        let title = kind == .stock ? (currency == .usd ? "美股" : "A 股") : kind.title
                        Text(title).tag(InvestmentAssetDraft.EntryType.standard(kind))
                    }
                    if allowsStockConnect { Text("港股通").tag(InvestmentAssetDraft.EntryType.stockConnect) }
                }
                .pickerStyle(.menu)
            }
            if draft.stockConnect && !locksSpecifications {
                Picker(watchOnly ? "资产类型" : "港股通标的类型", selection: $draft.kind) {
                    Text(watchOnly ? "港股通股票" : InvestmentKind.stock.rawValue).tag(InvestmentKind.stock)
                    Text(watchOnly ? "港股通 ETF" : InvestmentKind.etf.rawValue).tag(InvestmentKind.etf)
                }
                .pickerStyle(.menu)
                .onChange(of: draft.kind) { _, _ in
                    draft.clearInstrument()
                    if watchOnly { query = "" }
                }
            }
            if draft.kind == .insurance {
                InvestmentField("保单编号或自定义编号", text: $draft.code)
                    .autocorrectionDisabled()
                InvestmentField("保单名称", text: $draft.name)
            } else if draft.kind == .wealth {
                InvestmentField("理财产品编号", text: $draft.code)
                    .autocorrectionDisabled()
                InvestmentField("理财产品名称", text: $draft.name)
            } else if draft.kind == .generic {
                InvestmentField("标的名称", text: $draft.name)
            } else if draft.kind.isTermDeposit {
                InvestmentField("存款名称", text: $draft.name)
            } else if draft.selected {
                let selection = (draft.displayAsset?.displayName ?? draft.name) + " · " + (draft.displayAsset?.displayCode ?? draft.code)
                Button {
                    draft.clearInstrument()
                } label: {
                    LabeledContent("已选标的") {
                        HStack(spacing: 8) {
                            Text(selection)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                            InvestmentChevron()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .investmentListRow()
                .accessibilityLabel("已选标的，" + selection)
                .accessibilityHint("重新搜索并选择标的")

            } else {
                searchFields
                if !watchOnly && !draft.kind.requiresCatalog {
                    DisclosureGroup("手动录入", isExpanded: $manualEntry) { manualFields }
                }
            }
            if draft.kind.usesMargin, !watchOnly, !locksSpecifications {
                Picker("开仓方向", selection: $draft.contractSide) {
                    ForEach(InvestmentContractSide.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if !watchOnly, !locksSpecifications, existing == nil, draft.kind.derivative {
                InvestmentField("合约乘数", text: $draft.multiplier, keyboard: .decimalPad)
            }
        }
        .onChange(of: kinds, initial: true) { _, kinds in
            if !kinds.contains(draft.kind), let first = kinds.first { draft.entryType = .standard(first) }
        }
        .onChange(of: currency) { _, _ in
            draft.clearInstrument()
            if watchOnly { query = "" }
        }
        .onChange(of: draft.entryType) { _, _ in
            if watchOnly { query = "" }
        }
    }

    private var searchFields: some View {
        let text = investmentTrim(query)
        let searchesCash = draft.kind == .crypto && accountType == .crypto && InvestmentStablecoin.isCashCode(text)
        let instrument = InvestmentInstrumentSearch(query: text, kind: draft.kind, currency: currency,
                                                    stockConnect: draft.stockConnect, accountType: accountType)
        let request = SearchRequest(instrument: instrument)
        let searchesCrypto = draft.kind == .crypto
        return Group {
            InvestmentField(searchesCrypto ? "搜索币种代码或名称" : "搜索代码或名称",
                            text: $query, focusesOnRowTap: true)
                .autocorrectionDisabled()
                .task(id: request) { await search(request) }

            if !text.isEmpty {
                if searchesCash {
                    Text("USD、USDC 和 USDT 统一计入 USD 现金余额，请在现金管理中记账。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if searchesCrypto && currency != .usd {
                    Text("请选择美元报价币种。").font(.footnote).foregroundStyle(.secondary)
                } else if let result = searchResponse, result.request == request {
                    if let matches = result.matches {
                        if matches.isEmpty {
                            Text(searchEmptyMessage(searchesCrypto: searchesCrypto))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(matches.prefix(12)) { choice in
                            Button {
                                switch choice {
                                case .instrument(let asset): draft.select(asset)
                                }
                                manualEntry = false
                            } label: {
                                InvestmentTitle(choice.asset.displayName, subtitle: searchSubtitle(choice))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .investmentListRow()
                        }
                    } else {
                        Text(result.message ?? (watchOnly || draft.kind.requiresCatalog ? "搜索暂不可用，请稍后重试；必须选择目录中的标的。" : "搜索暂不可用，可以修改关键词重试或手动录入。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("正在搜索…").font(.footnote)
                }
            }
        }
    }

    private func searchEmptyMessage(searchesCrypto: Bool) -> String {
        if searchesCrypto || [.stock, .etf, .fund, .future, .option].contains(draft.kind) || store.configured {
            return watchOnly || draft.kind.requiresCatalog ? "没有找到匹配标的，请核对类型、市场和代码后重新搜索。" : "没有找到匹配标的，可以换个关键词或手动录入。"
        }
        return watchOnly || draft.kind.requiresCatalog ? "请先在投资记账设置中配置行情接口，再从目录选择标的。" : "配置行情源后可在线搜索，也可以手动录入。"
    }

    @ViewBuilder private var manualFields: some View {
        InvestmentField("标的代码", text: $draft.code)
            .textInputAutocapitalization(.characters).autocorrectionDisabled()
        if draft.kind == .future {
            Text("中国期货请填写带交易所后缀的完整合约代码，例如 CU1811.SHF。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if !draft.stockConnect {
            DisclosureGroup("交易所（可选）", isExpanded: $showsExchange) {
                InvestmentField("交易所代码", text: $draft.market)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
        }
        if let existing {
            LabeledContent("标的名称", value: existing.displayName)
        } else {
            InvestmentField("标的名称", text: $draft.name)
        }
    }

    private func searchSubtitle(_ choice: SearchChoice) -> String {
        let asset = choice.asset

        let market = asset.isStockConnect ? "港交所" : asset.mainlandSymbol?.venue ?? asset.market
        return [asset.code, market, asset.currency.rawValue].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func search(_ request: SearchRequest) async {
        let instrument = request.instrument
        guard !instrument.query.isEmpty,
              instrument.kind != .crypto || accountType != .crypto || !InvestmentStablecoin.isCashCode(instrument.query) else {
            searchResponse = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(400))
            let assets = try await store.searchInstruments(instrument)
            let results = assets.filter {
                accountType != .crypto || $0.kind != .crypto || !InvestmentStablecoin.isCashCode($0.code)
            }.map(SearchChoice.instrument)
            try Task.checkCancellation()
            searchResponse = SearchResponse(request: request, matches: results, message: nil)
        } catch {
            guard !Task.isCancelled else { return }
            searchResponse = SearchResponse(request: request, matches: nil, message: (error as? InvestmentError)?.localizedDescription)
        }
    }
}

private struct InvestmentTradeFields: View {
    let kind: InvestmentKind
    let currency: InvestmentCurrency
    let event: InvestmentEventKind
    let stockConnect: Bool
    @Binding var date: Date
    @Binding var quantity: String
    @Binding var price: String
    @Binding var fee: String
    @Binding var margin: String
    @Binding var settlement: String

    private var showsFee: Bool { kind.supportsTradeFees && !stockConnect && (event == .buy || event == .sell) }

    var body: some View {
        InvestmentDatePicker(event == .income || event == .insuranceWithdrawal ? "到账日期" : kind.usesBalance ? "记账日期" : "成交日期", selection: $date, latest: InvestmentBook.day())
        if event == .insuranceWithdrawal {
            InvestmentField("提取金额（" + currency.rawValue + "）", text: $price, keyboard: .decimalPad)
            InvestmentField("提取后现金价值（" + currency.rawValue + "，选填）", text: $settlement, keyboard: .decimalPad)
            Text("提取金额转入本账户现金，保单继续保留。现金价值留空时按最近已知现金价值扣减；缺少可用估值时按零估值。")
                .font(.footnote).foregroundStyle(.secondary)
        } else if kind == .insurance {
            InvestmentField((event == .sell ? "退保到账金额" : "保费金额") + "（" + currency.rawValue + "）", text: $price, keyboard: .decimalPad)
        } else if kind == .generic {
            InvestmentField((event == .sell ? "取出金额" : "投入金额") + "（" + currency.rawValue + "）", text: $price, keyboard: .decimalPad)
        } else if kind == .wealth {
            switch event {
            case .adjustment: EmptyView()
            case .income: InvestmentField("实收收益（CNY）", text: $price, keyboard: .decimalPad)
            case .sell: InvestmentField("赎回到账金额（CNY）", text: $price, keyboard: .decimalPad)
            default: InvestmentField("申购金额（CNY）", text: $price, keyboard: .decimalPad)
            }
            InvestmentField("变动后余额（CNY）", text: $settlement, keyboard: .decimalPad)
            Text("按实际金额和产品余额记账，余额差额计入盈亏。").font(.footnote).foregroundStyle(.secondary)
        } else if kind.isTermDeposit {
            switch event {
            case .adjustment: EmptyView()
            case .income: InvestmentField("利息到账金额（CNY）", text: $price, keyboard: .decimalPad)
            case .sell: InvestmentField("支取金额（CNY）", text: $price, keyboard: .decimalPad)
            default: InvestmentField("存入金额（CNY）", text: $price, keyboard: .decimalPad)
            }
            InvestmentField("变动后余额（CNY）", text: $settlement, keyboard: .decimalPad)
            if event == .adjustment {
                Text("按实际余额估值，余额差额计入存款盈亏。").font(.footnote).foregroundStyle(.secondary)
            }
        } else if event == .income {
            InvestmentField("实收收益（" + currency.rawValue + "）", text: $price, keyboard: .decimalPad)
        } else {
            InvestmentField("数量（" + kind.unit + "）", text: $quantity, keyboard: .decimalPad)
            InvestmentField("成交价（" + currency.rawValue + "）", text: $price, keyboard: .decimalPad)
        }
        if stockConnect {
            InvestmentField(event == .sell ? "实际到账金额（CNY）" : "实际成本金额（CNY）", text: $settlement, keyboard: .decimalPad)
            Text("按券商交割单填写含费用的实际人民币金额。").font(.footnote).foregroundStyle(.secondary)
        }
        if showsFee {
            InvestmentField("交易费用（" + currency.rawValue + "，选填）", text: $fee, keyboard: .decimalPad)
            Text("可合并填写佣金、手续费和税费。").font(.footnote).foregroundStyle(.secondary)
        }
        if kind.usesMargin && event != .sell {
            InvestmentField("每手初始保证金（" + currency.rawValue + "）", text: $margin, keyboard: .decimalPad)
        }
    }

    private func record(assetID: UUID, book: InvestmentBook) throws -> InvestmentEvent {
        let day = InvestmentBook.day(date)
        if event == .insuranceWithdrawal {
            return InvestmentEvent(day: day, kind: event, assetID: assetID,
                amount: try investmentDecimal(price, "提取金额"),
                settledAmount: investmentTrim(settlement).isEmpty ? nil : try investmentDecimal(settlement, "提取后现金价值", allowZero: true))
        }
        if event == .income {
            let amount = try investmentDecimal(price, "实收金额")
            let balance = kind.isTermDeposit || kind == .wealth ? try investmentDecimal(settlement, "变动后余额", allowZero: true) : nil
            return InvestmentEvent(day: day, kind: event, assetID: assetID, amount: amount, settledAmount: balance)
        }
        if kind.usesBalance {
            let change = event == .adjustment ? 0 : try investmentDecimal(price, "变动金额")
            let balance = kind == .generic && investmentTrim(settlement).isEmpty ? nil : try investmentDecimal(settlement, "变动后余额", allowZero: true)
            return InvestmentEvent(day: day, kind: event, assetID: assetID, quantity: event == .adjustment ? 0 : 1,
                                   price: change, settledAmount: balance)
        }
        let quantity = kind == .insurance ? 1 : try investmentDecimal(self.quantity, "数量")
        if ![.fund, .etf, .wealth, .crypto].contains(kind), quantity != Decimal(NSDecimalNumber(decimal: quantity).int64Value) {
            throw InvestmentError.invalid("该类型的数量必须是整数。")
        }
        return InvestmentEvent(day: day, kind: event, assetID: assetID,
            quantity: quantity, price: try investmentDecimal(price, "成交金额或价格", allowZero: kind == .insurance && event == .sell),
            margin: kind.usesMargin && event != .sell ? try investmentDecimal(margin, "保证金") : 0,
            settledAmount: stockConnect ? try investmentDecimal(settlement, "实际人民币金额") : nil,
            fee: showsFee && !investmentTrim(fee).isEmpty ? try investmentDecimal(fee, "交易费用", allowZero: true) : nil)
    }

    func entryValues(assetID: UUID, book: InvestmentBook) throws -> [String: String] {
        InvestmentEditorDraft.eventValues(try record(assetID: assetID, book: book))
    }

    @discardableResult
    func post(assetID: UUID, accountID: UUID, to book: inout InvestmentBook, autoFundCash: Bool = false) throws -> InvestmentEvent {
        let event = try record(assetID: assetID, book: book)
        try book.post(event, accountID: accountID, autoFundCash: autoFundCash)
        return event
    }
}

struct InvestmentAssetEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    var entryKind: InvestmentEventKind = .buy
    private struct WatchQuoteResult {
        let asset: InvestmentAsset
        var quotes: [InvestmentQuote] = []
        var failure: String?
    }

    @ObservedObject var store: InvestmentStore
    let accountID: UUID?
    @State private var draft = InvestmentAssetDraft()
    @State private var watchCurrency = InvestmentCurrency.cny
    @State private var watchQuoteResult: WatchQuoteResult?
    @State private var date = InvestmentBook.day()
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var margin = ""
    @State private var settlement = ""
    @State private var manualValue = ""
    @State private var annualRate = ""
    @State private var maturity = InvestmentBook.addDays(365, to: InvestmentBook.day())
    @State private var autoFundCash = false
    @State private var saveError: InvestmentSaveError?

    var body: some View {
        let watchOnly = accountID == nil
        let account = accountID.flatMap { store.book.account($0) }
        let currency: InvestmentCurrency = draft.stockConnect ? .hkd : account?.currency ?? watchCurrency
        let known = store.book.assets.values.first { draft.matches($0, currency: currency) }
        let watchOnlyDerivative: InvestmentAsset? = if !watchOnly, let known, known.kind.derivative,
            store.book.watched.contains(known.id), !store.book.accounts.contains(where: { account in
                account.events.contains { $0.assetID == known.id }
            }) { known } else { nil }
        let existing = watchOnlyDerivative == nil ? known : nil
        let hasPriorPosition = existing.flatMap { asset in
            account.flatMap { try? store.book.ledger($0, through: InvestmentBook.day(date)).positions[asset.id] }
        } != nil
        let watchAsset = watchOnly && draft.selected ? try? draft.asset(currency: currency, reusing: existing) : nil
        let watchResult = watchAsset.flatMap { watchQuoteResult?.asset == $0 ? watchQuoteResult : nil }
        let trade = InvestmentTradeFields(kind: draft.kind, currency: currency, event: entryKind,
                                          stockConnect: draft.stockConnect,
                                          date: $date, quantity: $quantity, price: $price, fee: $fee, margin: $margin,
                                          settlement: $settlement)
        let kinds = account?.kinds ?? InvestmentKind.watchKinds(in: currency)
        let initialKind = kinds.first ?? .stock
        let hasChanges = draft.code != "" || draft.name != "" || draft.market != "" || draft.kind != initialKind || draft.stockConnect
            || !quantity.isEmpty || !price.isEmpty || !fee.isEmpty || !margin.isEmpty || !manualValue.isEmpty || !draft.multiplier.isEmpty
            || !settlement.isEmpty || !annualRate.isEmpty || InvestmentBook.day(date) != InvestmentBook.day()
        return InvestmentEditor(title: watchOnly ? "添加关注" : "录入资产", inSheet: true,
                                hasChanges: hasChanges, saveEnabled: watchOnly ? watchResult?.quotes.last != nil : nil,
                                inlineError: watchOnly ? nil : $saveError) {
            Section(account?.name ?? "标的信息") {
                if watchOnly {
                    Picker("报价币种", selection: watchCurrencySelection) {
                        ForEach([InvestmentCurrency.cny, .usd, .hkd]) { Text($0.title + " · " + $0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                } else {
                    LabeledContent(draft.kind == .insurance ? "保单币种" : draft.kind == .generic ? "记账币种" : "报价币种",
                                   value: currency.title + " · " + currency.rawValue)
                }
                InvestmentAssetFields(draft: $draft, store: store, currency: currency, kinds: kinds,
                                      allowsStockConnect: account?.allowsStockConnect ?? false, watchOnly: watchOnly, accountType: account?.type,
                                      existing: existing)
                if watchAsset != nil {
                    if let quote = watchResult?.quotes.last {
                        LabeledContent("最新报价", value: InvestmentText.number(quote.price) + " " + currency.rawValue)
                        Text(InvestmentText.quoteDetail(quote)).font(.footnote).foregroundStyle(.secondary)
                    } else if let failure = watchResult?.failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ProgressView("正在查询报价…").font(.footnote)
                    }
                }
            }
            if account != nil {
                if let saveError {
                    Section {
                        Text(saveError.message).font(.footnote).foregroundStyle(.red)
                            .investmentListRow()
                            .id(saveError.id)
                    }
                }
                Section("从现金余额扣款") {
                    Group {
                        Toggle("现金不足时自动补足", isOn: $autoFundCash)
                        if autoFundCash {
                            Text("按成交日期记入一笔现金转入，补足本次扣款的差额。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    trade
                    if draft.kind.isTermDeposit {
                        InvestmentField("年利率（%）", text: $annualRate, keyboard: .decimalPad)
                        InvestmentDatePicker("到期日", selection: $maturity, earliest: date)
                    }
                    if draft.kind == .insurance {
                        InvestmentField("当前现金价值（" + currency.rawValue + "，可选）", text: $manualValue, keyboard: .decimalPad)
                    }
                    if draft.kind == .generic, !hasPriorPosition {
                        InvestmentField("当前余额（" + currency.rawValue + "，可选）", text: $settlement, keyboard: .decimalPad,
                                        help: "留空时等于投入金额；差额计入标的盈亏。")
                    }
                }
            }
        } save: {
            if watchOnly {
                guard let watchAsset, let quotes = watchResult?.quotes, !quotes.isEmpty else {
                    throw InvestmentError.invalid("请选择能够获取报价的标的。")
                }
                if let editorDraft {
                    try await editorDraft.submit(["enabled": "true"], asset: watchAsset)
                    return
                }
                try await store.update { book in
                    let id = try book.register(watchAsset)
                    book.addQuotes(quotes, assetID: id)
                    if !book.watched.contains(id) { book.watched.append(id) }
                }
                return
            }
            guard let account else { throw InvestmentError.invalid("找不到该投资账户。") }
            if let editorDraft {
                var asset = try draft.asset(currency: currency, reusing: existing)
                if asset.kind.isTermDeposit {
                    asset.depositTerms = .init(annualRate: try investmentDecimal(annualRate, "年利率", allowZero: true) / 100,
                                               maturity: InvestmentBook.day(maturity))
                }
                var trial = store.book
                let id = try trial.register(asset)
                var values = try trade.entryValues(assetID: id, book: trial)
                values["auto_fund"] = autoFundCash ? "true" : "false"
                let quote = asset.kind == .insurance && !investmentTrim(manualValue).isEmpty
                    ? try investmentDecimal(manualValue, "估值", allowZero: asset.kind == .insurance) : nil
                try await editorDraft.submit(values, asset: asset, quote: quote)
                return
            }
            try await store.update { book in
                var asset = try draft.asset(currency: currency, reusing: existing)
                if var tracked = watchOnlyDerivative {
                    tracked.multiplier = asset.multiplier
                    tracked.name = asset.name
                    tracked.code = asset.code
                    tracked.market = asset.market
                    book.assets[tracked.id] = tracked
                    asset = tracked
                }
                if asset.kind.isTermDeposit {
                    let rate = try investmentDecimal(annualRate, "年利率", allowZero: true) / 100
                    guard InvestmentBook.day(maturity) >= InvestmentBook.day(date) else {
                        throw InvestmentError.invalid("到期日不能早于首次存入日期。")
                    }
                    asset.depositTerms = .init(annualRate: rate, maturity: InvestmentBook.day(maturity))
                }
                let id = try book.register(asset)
                try trade.post(assetID: id, accountID: account.id, to: &book, autoFundCash: autoFundCash)
                if asset.kind == .insurance, !investmentTrim(manualValue).isEmpty {
                    let value = try investmentDecimal(manualValue, "估值", allowZero: asset.kind == .insurance)
                    book.addQuotes([.init(day: InvestmentBook.day(), price: value, source: "手动录入")], assetID: id)
                }
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
        .task(id: watchAsset) { await lookupWatchQuotes(watchAsset) }
    }

    private var watchCurrencySelection: Binding<InvestmentCurrency> {
        Binding(get: { watchCurrency }, set: { currency in
            guard watchCurrency != currency else { return }
            watchCurrency = currency
            let kind = InvestmentKind.watchKinds(in: currency).contains(draft.kind) ? draft.kind : .stock
            draft.entryType = currency == .hkd ? .stockConnect : .standard(kind)
            draft.clearInstrument()
        })
    }

    private func lookupWatchQuotes(_ asset: InvestmentAsset?) async {
        guard !Task.isCancelled else { return }
        watchQuoteResult = nil
        guard let asset else { return }
        do {
            let quotes = try await store.watchQuotes(for: asset)
            try Task.checkCancellation()
            watchQuoteResult = WatchQuoteResult(asset: asset, quotes: quotes)
        } catch {
            guard !Task.isCancelled else { return }
            watchQuoteResult = WatchQuoteResult(asset: asset, failure: "暂时无法获取报价。 " + error.localizedDescription)
        }
    }

}

struct InvestmentTradeEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    let kind: InvestmentEventKind
    @State private var date = InvestmentBook.day()
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var margin = ""
    @State private var settlement = ""

    var body: some View {
        let trade = InvestmentTradeFields(kind: asset.kind, currency: asset.currency, event: kind,
            stockConnect: asset.isStockConnect,
            date: $date, quantity: $quantity, price: $price, fee: $fee, margin: $margin,
            settlement: $settlement)
        let title = asset.kind.usesBalance || kind == .insuranceWithdrawal ? asset.transactionTitle(kind) : "记" + asset.transactionTitle(kind)
        let hasChanges = !price.isEmpty || !settlement.isEmpty || date != InvestmentBook.day()
        return InvestmentEditor(title: title, inSheet: asset.kind.usesBalance || kind == .insuranceWithdrawal, hasChanges: hasChanges) {
            Section(asset.displayName + " · " + account.name) {
                trade
            }
        } save: {
            if let editorDraft {
                try await editorDraft.submit(trade.entryValues(assetID: asset.id, book: store.book))
                return
            }
            try await store.update { book in
                _ = try trade.post(assetID: asset.id, accountID: account.id, to: &book)
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
    }
}

struct InvestmentDepositTermsEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    let asset: InvestmentAsset
    @State private var annualRate: String
    @State private var maturity: Date

    init(store: InvestmentStore, accountID: UUID, asset: InvestmentAsset) {
        self.store = store
        self.accountID = accountID
        self.asset = asset
        let rate = asset.depositTerms.map { ($0.annualRate * 100).formatted(.number.grouping(.never).precision(.fractionLength(0...38))) }
        _annualRate = State(initialValue: rate ?? "")
        _maturity = State(initialValue: asset.depositTerms?.maturity ?? InvestmentBook.day())
    }

    var body: some View {
        let rate = try? investmentDecimal(annualRate, "年利率", allowZero: true) / 100
        let changed = rate != asset.depositTerms?.annualRate || maturity != asset.depositTerms?.maturity
        return InvestmentEditor(title: "编辑存款信息", inSheet: true, hasChanges: changed, saveEnabled: changed && rate != nil) {
            Section(asset.displayName) {
                InvestmentField("年利率（%）", text: $annualRate, keyboard: .decimalPad)
                InvestmentDatePicker("到期日", selection: $maturity)
            }
        } save: {
            guard let rate else { throw InvestmentError.invalid("请输入有效的年利率。") }
            let day = InvestmentBook.day(maturity)
            if let editorDraft {
                try await editorDraft.submit(["annual_rate": InvestmentEditorDraft.text(rate * 100), "maturity_date": InvestmentEditorDraft.day.string(from: day)])
                return
            }
            try await store.update { book in
                guard var current = book.asset(asset.id), let account = book.account(accountID) else {
                    throw InvestmentError.invalid("找不到该存款。")
                }
                let first = account.events.filter { $0.assetID == asset.id && ($0.kind == .opening || $0.kind == .buy) }
                    .map(\.day).min()
                if let first, day < first { throw InvestmentError.invalid("到期日不能早于首次存入日期。") }
                current.depositTerms = .init(annualRate: rate, maturity: day)
                book.assets[asset.id] = current
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
    }
}

struct InvestmentQuoteEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @ObservedObject var store: InvestmentStore
    let asset: InvestmentAsset
    @State private var date = InvestmentBook.day()
    @State private var price = ""

    var body: some View {
        Group {
            if asset.kind.supportsManualQuote {
                InvestmentEditor(title: "保单现金价值", hasChanges: !price.isEmpty) {
                    quoteContent
                } save: {
                    let price = try investmentDecimal(price, asset.kind == .insurance ? "现金价值" : "报价", allowZero: asset.kind == .insurance)
                    if let editorDraft {
                        try await editorDraft.submit(["date": InvestmentEditorDraft.day.string(from: date), "price": InvestmentEditorDraft.text(price)])
                        return
                    }
                    try await store.update { book in
                        book.addQuotes([InvestmentQuote(day: InvestmentBook.day(date), price: price, source: "手动录入")], assetID: asset.id)
                        book.runPlans()
                    }
                }
            } else {
                Form { quoteContent }
                    .navigationTitle("行情")
            }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var quoteContent: some View {
        let insurance = asset.kind == .insurance
        let hasPublicQuote = asset.kind == .crypto
        let unit = store.book.quoteUnit(for: asset)
        Section(asset.displayName + " · " + asset.displayCode) {
            if let quote = store.book.quote(asset.id) {
                LabeledContent(insurance ? "最近手动现金价值" : "最新报价",
                               value: InvestmentText.number(quote.price) + " " + unit)
                LabeledContent("日期与来源", value: InvestmentText.quoteDetail(quote))
            }

            if editorDraft == nil && (hasPublicQuote || asset.usesEastmoneyMarketData || (store.configured && !asset.kind.isManual)) {
                Button(store.refreshing ? "正在刷新…" : "刷新行情") {
                    Task { await store.refresh(publicQuotesOnly: hasPublicQuote) }
                }
                .disabled(store.refreshing)
            }
            if !asset.kind.isManual, !store.quoteStatus.isEmpty {
                Text(store.quoteStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        if asset.kind.supportsManualQuote {
            Section(insurance ? "更新现金价值" : "手动报价") {
                InvestmentDatePicker(insurance ? "估值日期" : "报价日期", selection: $date, latest: InvestmentBook.day())
                let label = insurance ? "现金价值（" + unit + "）" : "价格（" + unit + "）"
                InvestmentField(label, text: $price, keyboard: .decimalPad)
                if insurance {
                    Text("部分提取当日的现金价值以交易记录为准，可在该笔交易中修改；后续日期可在这里更新。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if editorDraft == nil && store.book.watched.contains(asset.id) {
            Section {
                HakoDeleteButton(title: "移出关注") {
                    Task { await removeWatch() }
                }
                .disabled(store.saving).investmentListRow()
                .listRowBackground(Color.clear)
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private func removeWatch() async {
        do {
            try await store.update { $0.watched.removeAll { $0 == asset.id } }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct InvestmentPlanEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: InvestmentStore
    let plan: InvestmentPlan?
    private let initialAccountID: UUID
    @State private var accountID: UUID
    @State private var buy: Bool
    @State private var assetID: UUID?
    @State private var amount: String
    @State private var frequency: InvestmentPlanFrequency
    @State private var weekday: Int
    @State private var day: Int
    @State private var enabled: Bool
    @State private var draft = InvestmentAssetDraft()
    @State private var confirmDelete = false
    @State private var deleteError: String?

    init(store: InvestmentStore, accountID: UUID, plan: InvestmentPlan?) {
        self.store = store
        self.plan = plan
        initialAccountID = plan?.accountID ?? accountID
        _accountID = State(initialValue: initialAccountID)
        _buy = State(initialValue: plan?.assetID != nil)
        _assetID = State(initialValue: plan?.assetID)
        _amount = State(initialValue: plan.map { $0.amount.formatted(.number.grouping(.never)) } ?? "")
        _frequency = State(initialValue: plan?.schedule.frequency ?? .monthly)
        _weekday = State(initialValue: [.weekly, .biweekly].contains(plan?.schedule.frequency) ? plan!.schedule.day : 1)
        _day = State(initialValue: plan?.schedule.frequency == .monthly ? plan!.schedule.day : 8)
        _enabled = State(initialValue: plan?.enabled ?? true)
    }

    private var hasChanges: Bool {
        accountID != initialAccountID || buy != (plan?.assetID != nil)
            || (buy && (assetID != plan?.assetID || draft.selected || !draft.name.isEmpty || !draft.code.isEmpty))
            || amount != (plan.map { $0.amount.formatted(.number.grouping(.never)) } ?? "")
            || frequency != (plan?.schedule.frequency ?? .monthly)
            || scheduleDay != (plan?.schedule.day ?? 8) || enabled != (plan?.enabled ?? true)
    }

    private var scheduleDay: Int {
        switch frequency {
        case .daily: 0
        case .weekly, .biweekly: weekday
        case .monthly: day
        }
    }

    var body: some View {
        let account = store.book.account(accountID)
        let currency = account?.currency ?? .cny
        let kinds = (account?.kinds ?? []).filter(\.supportsPlan)
        let assets = store.book.assets.values.filter {
            guard let account, $0.supportsPlan else { return false }
            return (try? $0.validateEntry(in: account)) != nil
        }.sorted { $0.code < $1.code }
        let existing = assets.first { draft.matches($0, currency: currency) }
        return InvestmentEditor(title: plan == nil ? "新建定投任务" : "编辑定投任务", inSheet: true, hasChanges: hasChanges) {
            Section {
                Picker("任务类型", selection: $buy) {
                    Text("定期转入").tag(false)
                    if !kinds.isEmpty { Text("定期买入").tag(true) }
                }
                Picker("所属账户", selection: $accountID) {
                    ForEach(store.book.accounts) { Text($0.name + " · " + $0.currency.rawValue).tag($0.id) }
                }.onChange(of: accountID) {
                    assetID = nil
                    draft = InvestmentAssetDraft()
                    if store.book.account(accountID)?.kinds.contains(where: \.supportsPlan) != true { buy = false }
                }
                if buy && !kinds.isEmpty {
                    Picker("买入标的", selection: $assetID) {
                        Text("录入新标的").tag(nil as UUID?)
                        ForEach(assets) { Text($0.name + " · " + $0.code).tag(Optional($0.id)) }
                    }
                    if assetID == nil {
                        InvestmentAssetFields(draft: $draft, store: store, currency: currency, kinds: kinds,
                                              accountType: account?.type, existing: existing)
                    }
                }
                InvestmentField("每次金额（" + currency.rawValue + "）", text: $amount, keyboard: .decimalPad)
                Picker("执行周期", selection: $frequency) {
                    ForEach(InvestmentPlanFrequency.allCases) { Text($0.title).tag($0) }
                }
                if frequency == .weekly || frequency == .biweekly {
                    Picker("执行日", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(InvestmentPlanSchedule.weekdays[$0 - 1]).tag($0) }
                    }
                } else if frequency == .monthly {
                    Picker("每月执行日", selection: $day) {
                        ForEach(1...31, id: \.self) { Text("\($0) 日").tag($0) }
                    }
                }
                if let schedule = try? InvestmentPlanSchedule(frequency: frequency, day: scheduleDay) {
                    let unchanged = plan.map { $0.enabled && $0.schedule == schedule } ?? false
                    LabeledContent(plan == nil ? "首次执行日" : "下次执行日",
                                   value: InvestmentText.date(unchanged ? plan!.nextDay : schedule.first(after: InvestmentBook.day())))
                }
                Toggle("启用任务", isOn: $enabled)
            } footer: {
                if frequency == .biweekly { Text("从首次计划日起，每隔 14 天执行一次。") }
                if frequency == .monthly && day > 28 { Text("当月没有该日期时，按月末执行。") }
                if buy { Text("定期买入从该账户的现金余额扣款，按可用报价补记。港股通按交割单手动记账。") }
            }
            if plan != nil && editorDraft == nil {
                Section {
                    HakoDeleteButton(title: "删除任务") { confirmDelete = true }
                        .disabled(store.saving).investmentListRow()
                        .listRowBackground(Color.clear)
                }
            }
        } save: {
            let amount = try investmentDecimal(amount, "金额")
            let schedule = try InvestmentPlanSchedule(frequency: frequency, day: scheduleDay)
            if let editorDraft {
                let selected: InvestmentAsset? = buy ? try assetID.flatMap(store.book.asset) ?? draft.asset(currency: currency, reusing: existing) : nil
                try await editorDraft.submit(["account_id": accountID.uuidString, "plan_type": buy ? "buy" : "deposit",
                    "asset_id": "", "amount": InvestmentEditorDraft.text(amount), "frequency": frequency.rawValue,
                    "schedule_day": String(scheduleDay), "enabled": enabled ? "true" : "false"], asset: selected)
                return
            }
            try await store.update { book in
                var target = buy ? assetID : nil
                if buy, target == nil {
                    guard !kinds.isEmpty else { throw InvestmentError.invalid("此账户只支持定期转入。") }
                    target = try book.register(draft.asset(currency: currency, reusing: existing))
                }
                if let target {
                    guard let account, let asset = book.asset(target), asset.supportsPlan else {
                        throw InvestmentError.invalid("请选择同币种的买入标的。")
                    }
                    try asset.validateEntry(in: account)
                }
                let unchanged = plan.map { $0.enabled && $0.schedule == schedule && $0.accountID == accountID && $0.assetID == target } ?? false
                let item = InvestmentPlan(id: plan?.id ?? UUID(), accountID: accountID, assetID: target, amount: amount,
                    schedule: schedule, nextDay: unchanged ? plan!.nextDay : schedule.first(after: InvestmentBook.day()),
                    enabled: enabled, lastResult: plan?.lastResult)
                if enabled { try book.requireActive(accountID: accountID) }
                if let index = book.plans.firstIndex(where: { $0.id == item.id }) { book.plans[index] = item }
                else { book.plans.append(item) }
            }
        }
        .hakoDeleteConfirmation(Text("删除这项定投任务？"), isPresented: $confirmDelete, disabled: store.saving) {
            Task { await remove() }
        }
        .alert("无法删除", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private func remove() async {
        do {
            try await store.update { $0.plans.removeAll { $0.id == plan?.id } }
            dismiss()
        } catch { deleteError = error.localizedDescription }
    }
}

struct InvestmentAssetInfoEditor: View {
    @ObservedObject var store: InvestmentStore
    let asset: InvestmentAsset
    var editorDraft: InvestmentEditorDraft?
    @State private var draft: InvestmentAssetDraft
    @State private var annualRate: String
    @State private var maturity: Date

    init(store: InvestmentStore, asset: InvestmentAsset, editing: InvestmentEditorDraft? = nil) {
        self.store = store; self.asset = asset; editorDraft = editing
        _draft = State(initialValue: InvestmentAssetDraft(asset, book: editing?.proposal.book ?? store.book))
        _annualRate = State(initialValue: InvestmentEditorDraft.text(asset.depositTerms.map { $0.annualRate * 100 }))
        _maturity = State(initialValue: asset.depositTerms?.maturity ?? InvestmentBook.day())
    }

    var body: some View {
        let creating = editorDraft?.action.kind == .addAsset
        InvestmentEditor(title: creating ? "标的信息" : "修改标的资料", inSheet: true,
                         hasChanges: draft.name != asset.name || draft.normalizedCode != asset.code || draft.venue != asset.market
                            || annualRate != InvestmentEditorDraft.text(asset.depositTerms.map { $0.annualRate * 100 })
                            || maturity != (asset.depositTerms?.maturity ?? InvestmentBook.day())) {
            Section {
                LabeledContent("报价币种", value: asset.currency.rawValue)
                if asset.kind.requiresCatalog || creating {
                    InvestmentAssetFields(draft: $draft, store: store, currency: asset.currency, kinds: [asset.kind],
                        existing: creating ? nil : asset, locksSpecifications: !creating)
                } else {
                    InvestmentField("产品名称", text: $draft.name)
                    LabeledContent("产品代码", value: asset.code)
                }
                if asset.kind.usesMargin && !creating {
                    LabeledContent("合约规格", value: asset.kindLabel + " · " + InvestmentEditorDraft.text(asset.multiplier))
                }
                if asset.kind.isTermDeposit {
                    InvestmentField("年利率（%）", text: $annualRate, keyboard: .decimalPad)
                    InvestmentDatePicker("到期日", selection: $maturity)
                }
            }
        } save: {
            var selected = asset
            if asset.kind.requiresCatalog || creating {
                selected = try draft.asset(currency: asset.currency)
                if !creating && asset.kind.usesMargin && selected.multiplier != asset.multiplier {
                    throw InvestmentError.invalid("合约规格不同，请先核对数量口径，不能仅修改行情关联。")
                }
            } else {
                selected.name = investmentTrim(draft.name)
                guard !selected.name.isEmpty else { throw InvestmentError.invalid("请填写产品名称。") }
            }
            if asset.kind.isTermDeposit {
                selected.depositTerms = .init(annualRate: try investmentDecimal(annualRate, "年利率", allowZero: true) / 100,
                                             maturity: InvestmentBook.day(maturity))
            }
            if let editorDraft {
                try await editorDraft.submit([:], asset: selected)
            } else {
                var values = ["asset_id": asset.id.uuidString, "name": selected.name]
                if asset.kind.requiresCatalog { values["symbol"] = selected.code; values["market"] = selected.market }
                if let terms = selected.depositTerms {
                    values["annual_rate"] = InvestmentEditorDraft.text(terms.annualRate * 100)
                    values["maturity_date"] = InvestmentEditorDraft.day.string(from: terms.maturity)
                }
                try await store.update { try InvestmentAgentAction(kind: .editAsset, values: values).apply(to: &$0) }
            }
        }
    }
}

extension InvestmentAccountEditor {
    init(store: InvestmentStore, account: InvestmentAccount) {
        self.store = store
        editingAccount = account
        _name = State(initialValue: account.name)
        _currency = State(initialValue: account.currency)
        _type = State(initialValue: account.type)
        _position = State(initialValue: (store.book.accounts.firstIndex { $0.id == account.id } ?? 0) + 1)
    }
    init(store: InvestmentStore, editing: InvestmentEditorDraft) {
        self.store = store; editorDraft = editing
        editingAccount = editing.action.kind == .editAccount ? editing.account : nil
        _name = State(initialValue: editing.action.text("name") ?? editingAccount?.name ?? "")
        _currency = State(initialValue: editingAccount?.currency ?? InvestmentCurrency(rawValue: editing.value("currency")))
        _type = State(initialValue: editingAccount?.type ?? InvestmentAgentAction.accountTypes[editing.value("account_type")])
        _position = State(initialValue: Int(editing.value("position")) ?? ((store.book.accounts.firstIndex { $0.id == editingAccount?.id } ?? 0) + 1))
    }
}

extension InvestmentTransferEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount) {
        self.store = store; self.account = account; editorDraft = editing
        _date = State(initialValue: editing.date)
        _targetID = State(initialValue: UUID(uuidString: editing.value("target_id")))
        _amount = State(initialValue: editing.value("amount"))
        _received = State(initialValue: editing.value("received"))
        let balance = (try? store.book.ledger(account, through: editing.date).cash) ?? 0
        _remaining = State(initialValue: editing.action.text("remaining") ?? InvestmentEditorDraft.text(balance - (Decimal(string: editing.value("amount")) ?? 0)))
    }
}

extension InvestmentCashEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount, kind: InvestmentEventKind) {
        self.store = store; self.account = account; self.kind = kind; editorDraft = editing
        _amount = State(initialValue: editing.amount("amount")); _date = State(initialValue: editing.date)
    }
}

extension InvestmentHoldingAdjustmentEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount, asset: InvestmentAsset) {
        self.store = store; self.account = account; self.asset = asset; editorDraft = editing
        _date = State(initialValue: editing.date)
        _cash = State(initialValue: editing.value("amount")); _shares = State(initialValue: editing.value("quantity"))
        _balance = State(initialValue: editing.value("amount"))
    }
}

extension InvestmentFuturesSettlementEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount, asset: InvestmentAsset) {
        self.store = store; self.account = account; self.asset = asset; editorDraft = editing
        _date = State(initialValue: editing.date); _price = State(initialValue: editing.value("price"))
        _amount = State(initialValue: editing.amount("amount"))
        _isLoss = State(initialValue: editing.value("direction") == "decrease" || (Decimal(string: editing.value("amount")) ?? 0) < 0)
    }
}

extension InvestmentMarginTransferEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount, asset: InvestmentAsset) {
        self.store = store; self.account = account; self.asset = asset; editorDraft = editing
        _date = State(initialValue: editing.date); _amount = State(initialValue: editing.amount("amount"))
        _direction = State(initialValue: editing.value("direction") == "decrease" || (Decimal(string: editing.value("amount")) ?? 0) < 0 ? .decrease : .increase)
    }
}

extension InvestmentAssetEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, asset: InvestmentAsset) {
        self.store = store; editorDraft = editing
        entryKind = InvestmentAgentAction.eventKinds[editing.value("event_type")] ?? .buy
        accountID = editing.action.kind == .watch ? nil : editing.account?.id
        _draft = State(initialValue: InvestmentAssetDraft(asset, book: editing.proposal.book))
        _watchCurrency = State(initialValue: asset.currency)
        _date = State(initialValue: editing.date); _quantity = State(initialValue: editing.value("quantity"))
        _price = State(initialValue: editing.value("price")); _fee = State(initialValue: editing.value("fee"))
        _margin = State(initialValue: editing.value("margin")); _settlement = State(initialValue: editing.value("settled_amount"))
        _annualRate = State(initialValue: InvestmentEditorDraft.text(asset.depositTerms.map { $0.annualRate * 100 }))
        _maturity = State(initialValue: asset.depositTerms?.maturity ?? InvestmentBook.addDays(365, to: editing.date))
        _autoFundCash = State(initialValue: editing.value("auto_fund") == "true")
        _manualValue = State(initialValue: editing.quoteIndex.flatMap { editing.proposal.actions[$0].text("price") } ?? "")
    }
}

extension InvestmentTradeEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount, asset: InvestmentAsset, kind: InvestmentEventKind) {
        self.store = store; self.account = account; self.asset = asset; self.kind = kind; editorDraft = editing
        _date = State(initialValue: editing.date); _quantity = State(initialValue: editing.value("quantity"))
        _price = State(initialValue: kind == .income || kind == .insuranceWithdrawal ? editing.value("amount") : editing.value("price"))
        _fee = State(initialValue: editing.value("fee")); _margin = State(initialValue: editing.value("margin"))
        _settlement = State(initialValue: editing.value("settled_amount"))
    }
}

extension InvestmentDepositTermsEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, accountID: UUID, asset: InvestmentAsset) {
        self.init(store: store, accountID: accountID, asset: asset)
        editorDraft = editing
        _annualRate = State(initialValue: editing.action.text("annual_rate") ?? InvestmentEditorDraft.text(asset.depositTerms.map { $0.annualRate * 100 }))
        _maturity = State(initialValue: editing.action.text("maturity_date").flatMap(InvestmentEditorDraft.day.date(from:)) ?? asset.depositTerms?.maturity ?? editing.date)
    }
}

extension InvestmentQuoteEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, asset: InvestmentAsset) {
        self.store = store; self.asset = asset; editorDraft = editing
        _date = State(initialValue: editing.date); _price = State(initialValue: editing.value("price"))
    }
}

extension InvestmentPlanEditor {
    init(store: InvestmentStore, editing: InvestmentEditorDraft, account: InvestmentAccount) {
        let plan = store.book.plans.first { $0.id.uuidString == editing.action.text("plan_id") }
        self.init(store: store, accountID: account.id, plan: plan)
        editorDraft = editing
        _accountID = State(initialValue: account.id); _buy = State(initialValue: editing.value("plan_type") == "buy")
        _assetID = State(initialValue: editing.asset.flatMap { store.book.asset($0.id)?.id })
        if let asset = editing.asset, store.book.asset(asset.id) == nil { _draft = State(initialValue: InvestmentAssetDraft(asset, book: editing.proposal.book)) }
        _amount = State(initialValue: editing.value("amount"))
        let frequency = InvestmentPlanFrequency(rawValue: editing.value("frequency")) ?? .monthly
        _frequency = State(initialValue: frequency)
        _day = State(initialValue: frequency == .monthly ? Int(editing.value("schedule_day")) ?? 8 : 8)
        _weekday = State(initialValue: [.weekly, .biweekly].contains(frequency) ? Int(editing.value("schedule_day")) ?? 1 : 1)
        _enabled = State(initialValue: editing.value("enabled") == "true")
    }
}
