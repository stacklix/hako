import SwiftUI

private struct InvestmentFieldPlaceholders: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var investmentFieldPlaceholders: Bool {
        get { self[InvestmentFieldPlaceholders.self] }
        set { self[InvestmentFieldPlaceholders.self] = newValue }
    }
}

struct InvestmentField: View {
    @Environment(\.investmentFieldPlaceholders) private var showsPlaceholder
    let title: String
    @Binding var text: String
    var axis: Axis
    var keyboard: UIKeyboardType
    let help: String?

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal, keyboard: UIKeyboardType = .default,
         help: String? = nil) {
        self.title = title
        _text = text
        self.axis = axis
        self.keyboard = keyboard
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let help { InvestmentFieldKey(title: title, help: help) }
                else { Text(title) }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            TextField(showsPlaceholder ? title : "", text: $text, axis: axis)
                .keyboardType(keyboard)
                .accessibilityLabel(title)
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
            if inSheet {
                SettingsSheet(title: title, hasChanges: hasChanges, isBusy: saving, saveEnabled: saveEnabled ?? hasChanges, onSave: commit) { form }
            } else {
                form.navigationTitle(title)
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
                    if !inSheet {
                        HStack(spacing: 12) {
                            Button("取消") { dismiss() }.buttonStyle(HakoActionButtonStyle(primary: false))
                            Button("保存", action: commit).buttonStyle(HakoActionButtonStyle())
                        }.disabled(saving).investmentListRow()
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
    @ObservedObject var store: InvestmentStore
    @State private var name = ""
    @State private var currency: InvestmentCurrency?
    @State private var type: InvestmentAccountType?

    var body: some View {
        InvestmentEditor(title: "添加账户", inSheet: true,
                         hasChanges: !name.isEmpty || currency != nil || type != nil) {
            Section {
                InvestmentField("账户名称", text: $name)
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
            } footer: {
                Text("创建后自动添加同币种的现金账户。")
            }
        } save: {
            let name = investmentTrim(name)
            guard !name.isEmpty, let currency, let type, InvestmentAccountType.available(in: currency).contains(type) else {
                throw InvestmentError.invalid("请填写账户名称，并选择账户币种和类型。")
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
                LabeledContent("当前现金余额", value: InvestmentText.money(current, account.currency))
                Picker("目标账户", selection: $targetID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(store.book.accounts.filter { $0.id != account.id }) { item in
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
            try await store.update { try $0.transfer(from: account.id, to: targetID, amount: amount, remaining: remaining, received: received) }
        }
    }
}

struct InvestmentCashEditor: View {
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
                DatePicker("记账日期", selection: $date, in: ...Date.now, displayedComponents: .date)
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
            Section(asset.name + " · " + asset.code) {
                DatePicker(supportsDividends ? "到账日期" : "调整日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                if supportsDividends {
                    let suffix = stock ? "，选填）" : "）"
                    InvestmentField("实际到账金额（" + account.currency.rawValue + suffix, text: $cash, keyboard: .decimalPad)
                    if stock {
                        InvestmentField("送股股数（选填）", text: $shares, keyboard: .numberPad)
                        Text("可只填其中一项。").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    if let quantity = ledger?.positions[asset.id]?.quantity {
                        LabeledContent("账面总余额", value: InvestmentText.number(quantity) + " " + asset.code)
                    }
                    if let reserved = ledger?.reservedCollateral[asset.id], reserved > 0 {
                        LabeledContent("保证金占用", value: InvestmentText.number(reserved) + " " + asset.code)
                    }
                    InvestmentField("调整后总余额（" + asset.code + "）", text: $balance, keyboard: .decimalPad)
                    Text("增加的数量记为同币种质押奖励，减少的数量记为现货余额调整。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } save: {
            try await store.update { book in
                if supportsDividends {
                    let cash = investmentTrim(cash).isEmpty ? 0 : try investmentDecimal(cash, "分红金额", allowZero: true)
                    let shares = investmentTrim(shares).isEmpty ? 0 : try investmentDecimal(shares, "送股股数", allowZero: true)
                    try book.recordDistribution(assetID: asset.id, accountID: account.id, cash: cash, shares: shares, on: day)
                } else {
                    let balance = try investmentDecimal(balance, "调整后余额", allowZero: true)
                    try book.adjustSpotBalance(assetID: asset.id, accountID: account.id, balance: balance, on: day)
                }
            }
        }
    }
}

struct InvestmentFuturesSettlementEditor: View {
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
            Section(asset.name) {
                DatePicker("结算日期", selection: $date, in: ...InvestmentBook.day(), displayedComponents: .date)
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
            try await store.update {
                try $0.post(.init(day: InvestmentBook.day(date), kind: .derivativeSettlement,
                    assetID: asset.id, amount: isLoss ? -value : value, price: price), accountID: account.id)
            }
        }
    }
}

struct InvestmentMarginTransferEditor: View {
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
        let unit = store.book.fundingUnit(for: asset, target: .available)
        let balanceTitle = asset.collateralAssetID == nil ? "可用现金余额" : "可用现货余额"
        let ledger = store.book.account(account.id).flatMap { try? store.book.ledger($0, through: day) }
        let margin = ledger?.fundingBalance(for: asset, target: .margin)
        let available = ledger?.fundingBalance(for: asset, target: .available)
        return InvestmentEditor(title: "调整保证金", inSheet: true, hasChanges: !amount.isEmpty) {
            Section {
                DatePicker("划转日期", selection: $date, in: ...Date.now, displayedComponents: .date)
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
                Text(asset.name + " · " + asset.kindLabel)
            } footer: {
                Text("增加时占用可用余额，减少时释放回可用余额。")
            }
        } save: {
            guard margin != nil else { throw InvestmentError.invalid("该日期没有可调整保证金的仓位。") }
            let value = try investmentDecimal(amount, "保证金划转金额")
            try await store.update {
                try $0.post(.init(day: day, kind: .marginTransfer, assetID: asset.id,
                                  amount: direction == .increase ? value : -value), accountID: account.id)
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
    }
}

struct InvestmentFundingAdjustmentEditor: View {
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var date = InvestmentBook.day()
    @State private var target = InvestmentFundingTarget.available
    @State private var balance = ""
    @State private var settlementRate = ""
    @State private var attributeToContract = true

    var body: some View {
        let day = InvestmentBook.day(date)
        let unit = store.book.fundingUnit(for: asset, target: target)
        let ledger = store.book.account(account.id).flatMap { try? store.book.ledger($0, through: day) }
        let current = ledger?.fundingBalance(for: asset, target: target)
        return InvestmentEditor(title: "调整余额", inSheet: true, hasChanges: !balance.isEmpty) {
            Section {
                DatePicker("对账日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                Picker("调整项目", selection: $target) {
                    ForEach(InvestmentFundingTarget.allCases) { Text($0.rawValue).tag($0) }
                }.onChange(of: target) { balance = "" }
                if let current {
                    LabeledContent("账面余额", value: InvestmentText.number(current) + " " + unit)
                } else {
                    Text("该日期没有可调整的余额。").font(.footnote).foregroundStyle(.secondary)
                }
                InvestmentField("调整后余额（" + unit + "）", text: $balance, keyboard: .decimalPad)
                if asset.collateralAssetID != nil {
                    InvestmentField(unit + " 兑美元单价（留空使用账本报价）", text: $settlementRate, keyboard: .decimalPad)
                }
                if target == .available { Toggle("计入当前合约", isOn: $attributeToContract) }
            } header: {
                Text(asset.name + " · " + asset.kindLabel)
            } footer: {
                if asset.settlementStablecoin != nil && target == .available {
                    Text("可用余额填写 USD、USDC 和 USDT 按 1:1 折算后的合计。")
                }
                Text("记齐开平仓、手续费和划转后，填写交易所已结算的余额。差额记为资金费净额。共用余额无法拆分时，可将差额计入账户。")
            }
        } save: {
            let balance = try investmentDecimal(balance, "调整后余额", allowZero: true)
            let rate = investmentTrim(settlementRate).isEmpty ? nil : try investmentDecimal(settlementRate, "结算币兑美元单价")
            try await store.update {
                try $0.adjustFundingBalance(assetID: asset.id, accountID: account.id, target: target, balance: balance,
                                            rate: rate, attributeToContract: attributeToContract, on: day)
            }
        }
    }
}

private struct InvestmentAssetDraft: Equatable {
    enum EntryType: Hashable {
        case standard(InvestmentKind)
        case contract(InvestmentContractBasis)
        case stockConnect
    }

    var name = ""
    var code = ""
    var market = ""
    var kind = InvestmentKind.stock
    var multiplier = ""
    var contractSide = InvestmentContractSide.long
    var contractBasis = InvestmentContractBasis.usd
    var collateralAssetID: UUID?
    var settlementStablecoin: InvestmentStablecoin?
    private(set) var stockConnect = false
    private(set) var selectedAsset: InvestmentAsset?
    private(set) var contractSettlementCode: String?

    var entryType: EntryType {
        get {
            if stockConnect { return .stockConnect }
            return kind == .cryptoContract ? .contract(contractBasis) : .standard(kind)
        }
        set {
            guard newValue != entryType else { return }
            clearInstrument()
            switch newValue {
            case .standard(let kind):
                stockConnect = false
                self.kind = kind
                contractBasis = .usd
            case .contract(let basis):
                stockConnect = false
                kind = .cryptoContract
                contractBasis = basis
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

    mutating func select(_ asset: InvestmentAsset) {
        code = asset.code
        name = asset.name
        market = asset.market
        selectedAsset = asset
    }

    mutating func select(_ listing: InvestmentContractListing, collateral: [InvestmentAsset]) {
        select(listing.asset)
        multiplier = NSDecimalNumber(decimal: listing.asset.multiplier).stringValue
        contractSettlementCode = listing.settlementCode
        if contractBasis == .coin {
            collateralAssetID = collateral.first { $0.code == listing.settlementCode }?.id
        } else {
            settlementStablecoin = InvestmentStablecoin(rawValue: listing.settlementCode)
        }
    }

    mutating func clearInstrument() {
        name = ""
        code = ""
        market = ""
        multiplier = ""
        contractSide = .long
        collateralAssetID = nil
        settlementStablecoin = nil
        contractSettlementCode = nil
        selectedAsset = nil
    }

    func matches(_ asset: InvestmentAsset, currency: InvestmentCurrency) -> Bool {
        let entered = InvestmentAsset(name: "", code: normalizedCode, market: venue, kind: kind, currency: currency,
                                      contractSide: assetSide, contractBasis: kind == .cryptoContract ? contractBasis : nil,
                                      collateralAssetID: collateralAssetID, settlementStablecoin: settlementStablecoin)
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

    func asset(currency: InvestmentCurrency) throws -> InvestmentAsset {
        let name = investmentTrim(name)
        guard !name.isEmpty else { throw InvestmentError.invalid("请选择搜索结果，或手动填写名称。") }
        let needsMultiplier = kind.derivative && (kind != .cryptoContract || contractBasis == .coin || !investmentTrim(multiplier).isEmpty)
        let multiplier = needsMultiplier ? try investmentDecimal(multiplier, "合约乘数") : 1
        let code = kind.isTermDeposit ? UUID().uuidString : normalizedCode
        return InvestmentAsset(name: name, code: code, market: venue, kind: kind, currency: currency, multiplier: multiplier,
                               contractSide: assetSide, contractBasis: kind == .cryptoContract ? contractBasis : nil,
                               collateralAssetID: collateralAssetID, settlementStablecoin: settlementStablecoin)
    }
}

private struct InvestmentAssetFields: View {
    private enum SearchChoice: Identifiable {
        case instrument(InvestmentAsset)
        case contract(InvestmentContractListing)

        var asset: InvestmentAsset {
            switch self {
            case .instrument(let asset): asset
            case .contract(let listing): listing.asset
            }
        }
        var id: UUID { asset.id }
    }

    private struct SearchRequest: Equatable {
        let instrument: InvestmentInstrumentSearch
        let contractBasis: InvestmentContractBasis?
    }

    private struct SearchResponse {
        let request: SearchRequest
        let matches: [SearchChoice]?
    }

    @Binding var draft: InvestmentAssetDraft
    let store: InvestmentStore
    let currency: InvestmentCurrency
    var kinds = InvestmentKind.allCases
    var allowsStockConnect = false
    var watchOnly = false
    var accountType: InvestmentAccountType?
    var collateralOptions: [InvestmentAsset] = []
    var existing: InvestmentAsset?
    @State private var query = ""
    @State private var searchResponse: SearchResponse?
    @State private var manualEntry = false
    @State private var showsExchange = false

    var body: some View {
        Group {
            if !watchOnly || currency != .hkd {
                Picker("资产类型", selection: $draft.entryType) {
                    ForEach(kinds) { kind in
                        if kind == .cryptoContract {
                            Text("U 本位合约").tag(InvestmentAssetDraft.EntryType.contract(.stablecoin))
                            Text("币本位合约").tag(InvestmentAssetDraft.EntryType.contract(.coin))
                        } else {
                            let title = kind == .stock ? (currency == .usd ? "美股" : "A 股") : kind.title
                            Text(title).tag(InvestmentAssetDraft.EntryType.standard(kind))
                        }
                    }
                    if allowsStockConnect { Text("港股通").tag(InvestmentAssetDraft.EntryType.stockConnect) }
                }
                .pickerStyle(.menu)
            }
            if draft.stockConnect {
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
            } else if draft.kind.isTermDeposit {
                InvestmentField("存款名称", text: $draft.name)
            } else if draft.selected {
                let selection = (existing?.name ?? draft.name) + " · " + draft.code
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
                if let exchange = InvestmentContractExchange(rawValue: draft.venue), draft.kind == .cryptoContract {
                    LabeledContent("报价交易所", value: exchange.title)
                }
            } else {
                searchFields
                if !watchOnly {
                    DisclosureGroup("手动录入", isExpanded: $manualEntry) { manualFields }
                }
            }
            if draft.kind == .cryptoContract {
                if let code = draft.contractSettlementCode {
                    LabeledContent("结算币种", value: code)
                    if draft.contractBasis == .coin && draft.collateralAssetID == nil {
                        Text("请先在此账户录入 \(code) 的现货余额。").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if draft.contractBasis == .stablecoin {
                    Picker("结算币种", selection: $draft.settlementStablecoin) {
                        Text("请选择").tag(nil as InvestmentStablecoin?)
                        ForEach(InvestmentStablecoin.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                } else {
                    let options = collateralOptions.filter(draft.contractBasis.accepts)
                    Picker("结算币种", selection: $draft.collateralAssetID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(options) { token in Text(token.code).tag(Optional(token.id)) }
                    }
                    .pickerStyle(.menu)
                    if options.isEmpty {
                        Text("请先在此账户录入对应币种的现货余额。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if draft.kind.usesMargin, !watchOnly {
                Picker("开仓方向", selection: $draft.contractSide) {
                    ForEach(InvestmentContractSide.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if !watchOnly, existing == nil, draft.kind.derivative {
                let title = draft.kind != .cryptoContract ? "合约乘数"
                    : (draft.contractBasis == .coin ? "每张合约面值（USD）" : "合约乘数（默认 1）")
                if draft.contractSettlementCode != nil {
                    LabeledContent(title, value: draft.multiplier)
                } else {
                    InvestmentField(title, text: $draft.multiplier, keyboard: .decimalPad)
                }
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
        let request = SearchRequest(instrument: instrument, contractBasis: draft.kind == .cryptoContract ? draft.contractBasis : nil)
        let searchesCrypto = draft.kind == .crypto || draft.kind == .cryptoContract
        return Group {
            InvestmentField(draft.kind == .cryptoContract ? "搜索合约代码" : (searchesCrypto ? "搜索币种代码或名称" : "搜索代码或名称"),
                            text: $query)
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
                                case .contract(let listing): draft.select(listing, collateral: collateralOptions)
                                }
                                manualEntry = false
                            } label: {
                                InvestmentTitle(choice.asset.name, subtitle: searchSubtitle(choice))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .investmentListRow()
                        }
                    } else {
                        Text(watchOnly ? "搜索暂不可用，请稍后重试。" : "搜索暂不可用，可以修改关键词重试或手动录入。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("正在搜索…").font(.footnote)
                }
            }
        }
    }

    private func searchEmptyMessage(searchesCrypto: Bool) -> String {
        if searchesCrypto || store.configured {
            return watchOnly ? "没有找到匹配标的，可以换个关键词。" : "没有找到匹配标的，可以换个关键词或手动录入。"
        }
        return watchOnly ? "请先在投资记账设置中配置行情接口。" : "配置行情源后可在线搜索，也可以手动录入。"
    }

    @ViewBuilder private var manualFields: some View {
        InvestmentField(draft.kind == .cryptoContract ? "合约代码" : "标的代码", text: $draft.code)
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
            LabeledContent(draft.kind == .cryptoContract ? "合约名称" : "标的名称", value: existing.name)
        } else {
            InvestmentField(draft.kind == .cryptoContract ? "合约名称" : "标的名称", text: $draft.name)
        }
    }

    private func searchSubtitle(_ choice: SearchChoice) -> String {
        let asset = choice.asset
        if case .contract(let listing) = choice {
            let exchange = InvestmentContractExchange(asset: asset)?.title ?? asset.market
            return [asset.code, exchange, listing.settlementCode + " 结算"].joined(separator: " · ")
        }
        let market = asset.isStockConnect ? "港交所" : asset.mainlandSymbol?.venue ?? asset.market
        return [asset.code, market, asset.currency.rawValue].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func search(_ request: SearchRequest) async {
        let instrument = request.instrument
        guard !instrument.query.isEmpty, request.contractBasis == nil || instrument.currency == .usd,
              instrument.kind != .crypto || accountType != .crypto || !InvestmentStablecoin.isCashCode(instrument.query) else {
            searchResponse = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(400))
            let results: [SearchChoice]
            if let basis = request.contractBasis {
                results = try await store.searchContracts(instrument.query, basis: basis).map(SearchChoice.contract)
            } else {
                let assets = try await store.searchInstruments(instrument)
                results = assets.filter {
                    accountType != .crypto || $0.kind != .crypto || !InvestmentStablecoin.isCashCode($0.code)
                }.map(SearchChoice.instrument)
            }
            try Task.checkCancellation()
            searchResponse = SearchResponse(request: request, matches: results)
        } catch {
            guard !Task.isCancelled else { return }
            searchResponse = SearchResponse(request: request, matches: nil)
        }
    }
}

private struct InvestmentCoinQuantityDraft {
    enum Mode: String, CaseIterable, Identifiable {
        case coins = "按币量"
        case notional = "按美元名义价值"
        case contracts = "按张数"
        var id: Self { self }
    }

    var mode = Mode.coins
    var coins = ""
    var referencePrice = ""
    var notional = ""
    var contracts = ""

    var hasChanges: Bool { !coins.isEmpty || !referencePrice.isEmpty || !notional.isEmpty || !contracts.isEmpty }

    func contractCount(faceValue: Decimal) throws -> Decimal {
        let quantity: InvestmentCoinContractQuantity
        switch mode {
        case .coins:
            quantity = .coins(try investmentDecimal(coins, "仓位折算量"),
                              referencePrice: try investmentDecimal(referencePrice, "折算用价格"))
        case .notional:
            quantity = .notionalUSD(try investmentDecimal(notional, "美元名义价值"))
        case .contracts:
            quantity = .contracts(try investmentDecimal(contracts, "张数"))
        }
        return try quantity.contractCount(faceValue: faceValue)
    }
}

private struct InvestmentTradeFields: View {
    let kind: InvestmentKind
    let currency: InvestmentCurrency
    let event: InvestmentEventKind
    let stockConnect: Bool
    let contractBasis: InvestmentContractBasis
    let collateral: InvestmentAsset?
    var contractExchange: InvestmentContractExchange?
    var contractSettlementCode: String?
    var contractFaceValue: Decimal?
    @Binding var coinQuantity: InvestmentCoinQuantityDraft
    @Binding var date: Date
    @Binding var quantity: String
    @Binding var price: String
    @Binding var fee: String
    @Binding var margin: String
    @Binding var settlement: String
    @Binding var settlementRate: String

    private var isCoinContract: Bool { kind == .cryptoContract && contractBasis == .coin }
    private var isStablecoinContract: Bool { kind == .cryptoContract && contractBasis == .stablecoin }
    private var settlementCode: String? { collateral?.code ?? contractSettlementCode }

    var quoteUnit: String {
        if isCoinContract { return "USD/" + (settlementCode ?? "币") }
        return kind == .cryptoContract && contractBasis == .stablecoin ? settlementUnit : currency.rawValue
    }

    private var settlementUnit: String {
        if kind == .cryptoContract, contractBasis != .usd { return settlementCode ?? "结算币" }
        return currency.rawValue
    }

    var body: some View {
        DatePicker(dateTitle, selection: $date, in: ...Date.now, displayedComponents: .date)
        if kind == .insurance {
            InvestmentField(insuranceAmountTitle + "（HKD）", text: $price, keyboard: .decimalPad)
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
            InvestmentField("实收收益（" + currency.rawValue + "）",
                            text: $price, keyboard: .decimalPad)
        } else {
            if isCoinContract {
                coinContractQuantityFields
            } else {
                let unit = kind == .cryptoContract && contractExchange == .htx ? "张" : kind.unit
                InvestmentField("数量（" + unit + "）", text: $quantity, keyboard: .decimalPad)
            }
            InvestmentField("成交价（" + quoteUnit + "）",
                            text: $price, keyboard: .decimalPad,
                            help: isCoinContract
                                ? "填写成交时每枚币的美元价格。把现有仓位一次录入时，可填交易所显示的开仓均价。"
                                : nil)
        }
        if stockConnect {
            InvestmentField(event == .sell ? "实际到账金额（CNY）" : "实际成本金额（CNY）",
                            text: $settlement, keyboard: .decimalPad)
            Text("按券商交割单填写含费用的实际人民币金额。").font(.footnote).foregroundStyle(.secondary)
        }
        if showsFee {
            InvestmentField("交易费用（" + settlementUnit + "，选填）", text: $fee, keyboard: .decimalPad,
                            help: isCoinContract ? "按结算币填写实际支付的交易费用。" : nil)
            if !isCoinContract {
                Text("可合并填写佣金、手续费和税费。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if kind.usesMargin && event != .sell {
            let title = kind == .cryptoContract ? "本次开仓保证金总额" : "每手初始保证金"
            let help = isStablecoinContract && collateral == nil
                ? "填写交易所实际占用的保证金总额。账本按 1:1 从 USD 现金余额扣除，平仓时释放。杠杆倍数无需另填。"
                : isCoinContract || isStablecoinContract
                ? "填写交易所实际占用的保证金总额。保证金占用本账户的 \(settlementUnit) 现货余额。杠杆倍数无需另填。"
                : nil
            InvestmentField(title + "（" + settlementUnit + "）", text: $margin, keyboard: .decimalPad,
                            help: help)
        }
        if let collateral {
            let suffix = isCoinContract ? "（选填）" : "（留空使用账本报价）"
            InvestmentField(collateral.code + " 兑美元单价" + suffix, text: $settlementRate, keyboard: .decimalPad,
                            help: isCoinContract ? "用于把结算币支付的手续费或已实现盈亏换算成美元。留空时使用成交日可用的账本报价。" : nil)
        }
    }

    @ViewBuilder private var coinContractQuantityFields: some View {
        Picker("数量录入方式", selection: $coinQuantity.mode) {
            ForEach(InvestmentCoinQuantityDraft.Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        switch coinQuantity.mode {
        case .coins:
            InvestmentField("仓位折算量（" + (settlementCode ?? "币") + "）", text: $coinQuantity.coins, keyboard: .decimalPad,
                            help: "填写交易所按币显示的仓位数量，例如 HTX 的持仓量（TRX）。")
            InvestmentField("折算用价格（" + quoteUnit + "）", text: $coinQuantity.referencePrice, keyboard: .decimalPad,
                            help: "填写交易所显示这笔币量时采用的价格，例如同一页面的最新价。结果取最接近的整张。")
        case .notional:
            InvestmentField("美元名义价值（USD）", text: $coinQuantity.notional, keyboard: .decimalPad,
                            help: "填写仓位的美元名义价值。它等于合约张数乘以每张美元面值。")
        case .contracts:
            InvestmentField("数量（张）", text: $coinQuantity.contracts, keyboard: .numberPad,
                            help: "填写交易所显示的实际成交张数，单位为整张。")
        }
        if coinQuantity.mode != .contracts, let contractFaceValue,
           let count = try? coinQuantity.contractCount(faceValue: contractFaceValue) {
            let prefix = coinQuantity.mode == .coins ? "约 " : ""
            InvestmentHelpRow(title: "折算张数", help: "账本按这个张数保存，并据此计算仓位和盈亏。") {
                Text(prefix + InvestmentText.number(count) + " 张")
            }
        }
    }

    private var dateTitle: String {
        if event == .income { return "到账日期" }
        if kind.isTermDeposit { return "记账日期" }
        return "成交日期"
    }

    private var showsFee: Bool {
        kind.supportsTradeFees && !stockConnect && (event == .buy || event == .sell)
    }

    private var insuranceAmountTitle: String {
        event == .sell ? "退保到账金额" : "保费金额"
    }

    private func record(assetID: UUID, book: InvestmentBook) throws -> InvestmentEvent {
        let day = InvestmentBook.day(date)
        if event == .income {
            let amount = try investmentDecimal(price, "实收金额")
            let balance = kind.isTermDeposit ? try investmentDecimal(settlement, "变动后余额", allowZero: true) : nil
            return InvestmentEvent(day: day, kind: event, assetID: assetID, amount: amount, settledAmount: balance)
        }
        if kind.isTermDeposit {
            let change = event == .adjustment ? 0 : try investmentDecimal(price, "变动金额")
            let balance = try investmentDecimal(settlement, "变动后余额", allowZero: true)
            return InvestmentEvent(day: day, kind: event, assetID: assetID, quantity: event == .adjustment ? 0 : 1,
                                   price: change, settledAmount: balance)
        }
        let quantity: Decimal
        if isCoinContract, let asset = book.asset(assetID) {
            quantity = try coinQuantity.contractCount(faceValue: asset.multiplier)
        } else {
            quantity = kind == .insurance ? 1 : try investmentDecimal(self.quantity, "数量")
        }
        if ![.fund, .etf, .wealth, .crypto, .cryptoContract].contains(kind),
           quantity != Decimal(NSDecimalNumber(decimal: quantity).int64Value) {
            throw InvestmentError.invalid("该类型的数量必须是整数。")
        }
        let rate: Decimal?
        if let collateral {
            if investmentTrim(settlementRate).isEmpty {
                rate = book.quote(collateral.id, on: day)?.price
            } else {
                rate = try investmentDecimal(settlementRate, "结算币兑美元单价")
            }
        } else {
            rate = nil
        }
        return InvestmentEvent(day: day, kind: event, assetID: assetID,
            quantity: quantity, price: try investmentDecimal(price, kind == .insurance ? insuranceAmountTitle : "价格",
                                                               allowZero: kind == .insurance && event == .sell),
            margin: kind.usesMargin && event != .sell ? try investmentDecimal(margin, "保证金") : 0,
            settledAmount: stockConnect ? try investmentDecimal(settlement, "实际人民币金额") : nil,
            fee: showsFee && !investmentTrim(fee).isEmpty ? try investmentDecimal(fee, "交易费用", allowZero: true) : nil,
            settlementRate: rate)
    }

    @discardableResult
    func post(assetID: UUID, accountID: UUID, to book: inout InvestmentBook, autoFundCash: Bool = false) throws -> InvestmentEvent {
        let event = try record(assetID: assetID, book: book)
        try book.post(event, accountID: accountID, autoFundCash: autoFundCash)
        if let collateral, let rate = event.settlementRate, book.quote(collateral.id, on: event.day) == nil {
            book.addQuotes([.init(day: event.day, price: rate, source: "结算币录入")], assetID: collateral.id)
        }
        return event
    }
}

struct InvestmentAssetEditor: View {
    private struct MarkRequest: Equatable {
        let code: String
        let market: String
        let basis: InvestmentContractBasis

        init?(_ draft: InvestmentAssetDraft) {
            guard draft.kind == .cryptoContract, !draft.normalizedCode.isEmpty,
                  InvestmentContractExchange(rawValue: draft.venue) != nil else { return nil }
            code = draft.normalizedCode
            market = draft.venue
            basis = draft.contractBasis
        }

        var asset: InvestmentAsset {
            InvestmentAsset(name: code, code: code, market: market, kind: .cryptoContract, currency: .usd, contractBasis: basis)
        }
    }

    private struct MarkResult {
        let request: MarkRequest
        let quote: InvestmentQuote?
    }

    private struct WatchQuoteResult {
        let asset: InvestmentAsset
        var quotes: [InvestmentQuote] = []
        var failure: String?
    }

    @ObservedObject var store: InvestmentStore
    let accountID: UUID?
    @State private var draft = InvestmentAssetDraft()
    @State private var coinQuantity = InvestmentCoinQuantityDraft()
    @State private var watchCurrency = InvestmentCurrency.cny
    @State private var watchQuoteResult: WatchQuoteResult?
    @State private var date = InvestmentBook.day()
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var margin = ""
    @State private var settlement = ""
    @State private var settlementRate = ""
    @State private var manualValue = ""
    @State private var markResult: MarkResult?
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
        let watchAsset = watchOnly ? draft.selectedAsset.map { existing ?? $0 } : nil
        let watchResult = watchAsset.flatMap { watchQuoteResult?.asset == $0 ? watchQuoteResult : nil }
        let collateral = store.book.asset(draft.collateralAssetID)
        let collateralOptions = Set(account?.events.compactMap(\.assetID) ?? []).compactMap { store.book.asset($0) }
            .filter { $0.kind == .crypto }.sorted { $0.code < $1.code }
        let markRequest = MarkRequest(draft)
        let currentMark = markRequest.flatMap { markResult?.request == $0 ? markResult : nil }
        let contractFaceValue = draft.contractBasis == .coin
            ? (existing?.multiplier ?? (try? investmentDecimal(draft.multiplier, "每张合约面值"))) : nil
        let trade = InvestmentTradeFields(kind: draft.kind, currency: currency, event: .buy,
                                          stockConnect: draft.stockConnect, contractBasis: draft.contractBasis, collateral: collateral,
                                          contractExchange: InvestmentContractExchange(rawValue: draft.venue),
                                          contractSettlementCode: draft.settlementStablecoin?.rawValue ?? draft.contractSettlementCode,
                                          contractFaceValue: contractFaceValue,
                                          coinQuantity: $coinQuantity,
                                          date: $date, quantity: $quantity, price: $price, fee: $fee, margin: $margin,
                                          settlement: $settlement, settlementRate: $settlementRate)
        let kinds = account?.kinds ?? InvestmentKind.watchKinds(in: currency)
        let initialKind = kinds.first ?? .stock
        let hasChanges = draft.code != "" || draft.name != "" || draft.market != "" || draft.kind != initialKind || draft.stockConnect
            || !quantity.isEmpty || coinQuantity.hasChanges || !price.isEmpty || !fee.isEmpty || !margin.isEmpty || !manualValue.isEmpty || !draft.multiplier.isEmpty
            || !settlement.isEmpty || !settlementRate.isEmpty || !annualRate.isEmpty || InvestmentBook.day(date) != InvestmentBook.day()
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
                    LabeledContent(draft.kind == .insurance ? "保单币种" : "报价币种",
                                   value: currency.title + " · " + currency.rawValue)
                }
                InvestmentAssetFields(draft: $draft, store: store, currency: currency, kinds: kinds,
                                      allowsStockConnect: account?.allowsStockConnect ?? false, watchOnly: watchOnly, accountType: account?.type,
                                      collateralOptions: collateralOptions, existing: existing)
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
                Section(draft.kind == .cryptoContract && draft.contractBasis == .coin ? "使用结算币余额" : "从现金余额扣款") {
                    if draft.kind != .cryptoContract {
                        Toggle("现金不足时自动补足", isOn: $autoFundCash)
                        if autoFundCash {
                            Text("按成交日期记入一笔现金转入，补足本次扣款的差额。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    trade
                    if draft.kind.isTermDeposit {
                        InvestmentField("年利率（%）", text: $annualRate, keyboard: .decimalPad)
                        DatePicker("到期日", selection: $maturity, in: InvestmentBook.day(date)..., displayedComponents: .date)
                    }
                    if draft.kind == .insurance {
                        InvestmentField("当前现金价值（HKD，可选）", text: $manualValue, keyboard: .decimalPad)
                    }
                    if draft.kind == .wealth {
                        InvestmentField("当前单位净值（CNY，可选）", text: $manualValue, keyboard: .decimalPad)
                    }
                    if draft.kind == .cryptoContract {
                        markField(currentMark, querying: markRequest != nil && currentMark == nil, unit: trade.quoteUnit)
                    }
                }
            }
        } save: {
            if watchOnly {
                guard let watchAsset, let quotes = watchResult?.quotes, !quotes.isEmpty else {
                    throw InvestmentError.invalid("请选择能够获取报价的标的。")
                }
                try await store.update { book in
                    let id = try book.register(watchAsset)
                    book.addQuotes(quotes, assetID: id)
                    if !book.watched.contains(id) { book.watched.append(id) }
                }
                return
            }
            guard let account else { throw InvestmentError.invalid("找不到该投资账户。") }
            try await store.update { book in
                var asset = try existing ?? draft.asset(currency: currency)
                if var tracked = watchOnlyDerivative {
                    tracked.multiplier = asset.multiplier
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
                if let quote = currentMark?.quote {
                    if book.quote(id)?.day != quote.day { book.addQuotes([quote], assetID: id) }
                } else if [.wealth, .insurance, .cryptoContract].contains(asset.kind), !investmentTrim(manualValue).isEmpty {
                    let value = try investmentDecimal(manualValue, "估值", allowZero: asset.kind == .insurance)
                    book.addQuotes([.init(day: InvestmentBook.day(), price: value, source: "手动录入")], assetID: id)
                }
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
        .onChange(of: draft.collateralAssetID) { settlementRate = "" }
        .onChange(of: markRequest) {
            if draft.kind == .cryptoContract { manualValue = "" }
        }
        .task(id: markRequest) { await lookupMark(markRequest) }
        .task(id: watchAsset) { await lookupWatchQuotes(watchAsset) }
        .task(id: draft.collateralAssetID) {
            if let collateral, InvestmentContractExchange(rawValue: draft.venue) != nil {
                await store.prepareSettlementQuote(collateral)
            }
        }
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

    @ViewBuilder private func markField(_ result: MarkResult?, querying: Bool, unit: String) -> some View {
        let help = draft.contractBasis == .coin ? "交易所发布的标记价格，用于估算当前浮动盈亏。成交价仍取实际成交记录。" : nil
        if let quote = result?.quote {
            InvestmentHelpRow(title: "当前合约报价", help: help) {
                Text(quote.price.formatted(.number.precision(.fractionLength(0...8))) + " " + unit)
                    .monospacedDigit()
            }
        } else if querying {
            InvestmentHelpRow(title: "当前合约报价", help: help) {
                ProgressView("查询中…").font(.footnote)
            }
        } else {
            InvestmentField("手动合约报价（" + unit + "，选填）", text: $manualValue, keyboard: .decimalPad,
                            help: help.map { $0 + "自动报价暂不可用时，可填写交易所显示的标记价格。" })
        }
    }

    private func lookupMark(_ request: MarkRequest?) async {
        guard let request else { markResult = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let quote = try? await InvestmentQuoteProvider().contractMark(request.asset)
            try Task.checkCancellation()
            markResult = MarkResult(request: request, quote: quote)
        } catch is CancellationError {
            return
        } catch {
            markResult = MarkResult(request: request, quote: nil)
        }
    }
}

struct InvestmentTradeEditor: View {
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    let kind: InvestmentEventKind
    @State private var coinQuantity = InvestmentCoinQuantityDraft()
    @State private var date = InvestmentBook.day()
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var margin = ""
    @State private var settlement = ""
    @State private var settlementRate = ""

    var body: some View {
        let trade = InvestmentTradeFields(kind: asset.kind, currency: asset.currency, event: kind,
            stockConnect: asset.isStockConnect, contractBasis: asset.basis, collateral: store.book.asset(asset.collateralAssetID),
            contractExchange: InvestmentContractExchange(asset: asset), contractSettlementCode: asset.settlementStablecoin?.rawValue,
            contractFaceValue: asset.multiplier, coinQuantity: $coinQuantity,
            date: $date, quantity: $quantity, price: $price, fee: $fee, margin: $margin,
            settlement: $settlement, settlementRate: $settlementRate)
        let title = asset.kind.isTermDeposit ? asset.transactionTitle(kind) : "记" + asset.transactionTitle(kind)
        let hasChanges = !price.isEmpty || !settlement.isEmpty || date != InvestmentBook.day()
        return InvestmentEditor(title: title, inSheet: asset.kind.isTermDeposit, hasChanges: hasChanges) {
            Section(asset.name + " · " + account.name) {
                trade
            }
        } save: {
            try await store.update { book in
                _ = try trade.post(assetID: asset.id, accountID: account.id, to: &book)
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
        .task(id: date) {
            if InvestmentBook.day(date) == InvestmentBook.day(), InvestmentContractExchange(asset: asset) != nil,
               let token = store.book.asset(asset.collateralAssetID) {
                await store.prepareSettlementQuote(token)
            }
        }
    }
}

struct InvestmentDepositTermsEditor: View {
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
            Section(asset.name) {
                InvestmentField("年利率（%）", text: $annualRate, keyboard: .decimalPad)
                DatePicker("到期日", selection: $maturity, displayedComponents: .date)
            }
        } save: {
            guard let rate else { throw InvestmentError.invalid("请输入有效的年利率。") }
            let day = InvestmentBook.day(maturity)
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
    @ObservedObject var store: InvestmentStore
    let asset: InvestmentAsset
    @State private var date = InvestmentBook.day()
    @State private var price = ""

    var body: some View {
        let insurance = asset.kind == .insurance
        let contractExchange = InvestmentContractExchange(asset: asset)
        let hasPublicQuote = asset.kind == .crypto || contractExchange != nil
        let unit = store.book.quoteUnit(for: asset)
        return InvestmentEditor(title: insurance ? "保单现金价值" : "行情与手动报价") {
            Section(asset.name + " · " + asset.code) {
                if let quote = store.book.quote(asset.id) {
                    LabeledContent(insurance ? "当前现金价值" : (asset.kind == .wealth ? "最新单位净值" : "最新报价"),
                                   value: InvestmentText.number(quote.price) + " " + unit)
                    LabeledContent("日期与来源", value: InvestmentText.quoteDetail(quote))
                }
                if let contractExchange {
                    LabeledContent("报价交易所", value: contractExchange.title)
                }
                if hasPublicQuote || (store.configured && !asset.kind.isManual) {
                    Button(store.refreshing ? "正在刷新…" : "刷新行情") {
                        Task { await store.refresh(publicQuotesOnly: hasPublicQuote) }
                    }
                        .disabled(store.refreshing)
                }
                if (contractExchange != nil || !asset.kind.isManual), !store.quoteStatus.isEmpty {
                    Text(store.quoteStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(insurance ? "更新现金价值" : "手动报价") {
                DatePicker(insurance ? "估值日期" : "报价日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                let label = insurance ? "现金价值（HKD）" : (asset.kind == .wealth ? "单位净值（CNY）" : "价格（" + unit + "）")
                InvestmentField(label, text: $price, keyboard: .decimalPad)
            }
            if store.book.watched.contains(asset.id) {
                Section {
                    Button("移出关注", role: .destructive) {
                        Task { await removeWatch() }
                    }
                }
            }
        } save: {
            let price = try investmentDecimal(price, insurance ? "现金价值" : "报价", allowZero: insurance)
            try await store.update { book in
                book.addQuotes([InvestmentQuote(day: InvestmentBook.day(date), price: price, source: "手动录入")], assetID: asset.id)
                book.runPlans()
            }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
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
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: InvestmentStore
    let plan: InvestmentPlan?
    private let initialAccountID: UUID
    @State private var accountID: UUID
    @State private var buy: Bool
    @State private var assetID: UUID?
    @State private var amount: String
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
        _day = State(initialValue: plan?.monthDay ?? 8)
        _enabled = State(initialValue: plan?.enabled ?? true)
    }

    private var hasChanges: Bool {
        accountID != initialAccountID || buy != (plan?.assetID != nil)
            || (buy && (assetID != plan?.assetID || draft != InvestmentAssetDraft()))
            || amount != (plan.map { $0.amount.formatted(.number.grouping(.never)) } ?? "")
            || day != (plan?.monthDay ?? 8) || enabled != (plan?.enabled ?? true)
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
                Picker("每月执行日", selection: $day) {
                    ForEach(1...28, id: \.self) { Text("\($0) 日").tag($0) }
                }
                Toggle("启用任务", isOn: $enabled)
            } footer: {
                if buy { Text("定期买入从该账户的现金余额扣款，按可用报价补记。港股通按交割单手动记账。") }
            }
            if plan != nil {
                Section { Button("删除任务", role: .destructive) { confirmDelete = true } }
            }
        } save: {
            let amount = try investmentDecimal(amount, "金额")
            try await store.update { book in
                var target = buy ? assetID : nil
                if buy, target == nil {
                    guard !kinds.isEmpty else { throw InvestmentError.invalid("此账户只支持定期转入。") }
                    target = try book.register(existing ?? draft.asset(currency: currency))
                }
                if let target {
                    guard let account, let asset = book.asset(target), asset.supportsPlan else {
                        throw InvestmentError.invalid("请选择同币种的买入标的。")
                    }
                    try asset.validateEntry(in: account)
                }
                let unchanged = plan.map { $0.enabled && $0.monthDay == day && $0.accountID == accountID && $0.assetID == target } ?? false
                let item = InvestmentPlan(id: plan?.id ?? UUID(), accountID: accountID, assetID: target, amount: amount,
                    monthDay: day, nextDay: unchanged ? (plan?.nextDay ?? .now) : InvestmentBook.nextRun(day, after: InvestmentBook.day()),
                    enabled: enabled, lastResult: plan?.lastResult)
                if let index = book.plans.firstIndex(where: { $0.id == item.id }) { book.plans[index] = item }
                else { book.plans.append(item) }
            }
        }
        .confirmationDialog("删除这项定投任务？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除任务", role: .destructive) { Task { await remove() } }
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
