import SwiftUI
import UniformTypeIdentifiers

struct InvestmentLink<Label: View>: View {
    let route: InvestmentRoute
    @ViewBuilder let label: Label

    var body: some View {
        // Hako's shared stack is bound to an array of its own route type.
        NavigationLink {
            InvestmentDestination(store: .shared, route: route)
        } label: { label }
    }
}

struct InvestmentDestination: View {
    @ObservedObject var store: InvestmentStore
    let route: InvestmentRoute

    var body: some View {
        Group {
            switch route {
            case .settings: InvestmentSettings(store: store)
            case .asset(let id, let assetID):
                if let account = store.book.account(id), let asset = store.book.asset(assetID) {
                    InvestmentHoldingView(store: store, account: account, asset: asset)
                }
            case .trade(let id, let assetID, let kind):
                if let account = store.book.account(id), let asset = store.book.asset(assetID) {
                    InvestmentTradeEditor(store: store, account: account, asset: asset, kind: kind)
                }
            case .quote(let id):
                if let asset = store.book.asset(id) { InvestmentQuoteEditor(store: store, asset: asset) }
            }
        }.navigationBarTitleDisplayMode(.inline)
    }
}

struct InvestmentCashHistory: View {
    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    @State private var editing: InvestmentEvent?

    var body: some View {
        SettingsSheet(title: "现金流水") {
            if let account = store.book.account(accountID) { history(account) }
        }
        .sheet(item: $editing) { event in
            InvestmentEventEditor(store: store, accountID: accountID, event: event)
        }
    }

    private func history(_ account: InvestmentAccount) -> some View {
        let book = store.book
        let rows = (try? book.ledger(account, includeRows: true))?.cashRows ?? []
        let cashIDs = Set(rows.map(\.id))
        let otherEvents = book.orderedEvents(account, through: InvestmentBook.day()).filter { !cashIDs.contains($0.id) }
        return List {
            Section(account.name + " · " + account.currency.rawValue) {
                ForEach(rows.reversed()) { row in
                    Button { editing = row.event } label: {
                        HStack(alignment: .top) {
                            let asset = book.asset(row.event.assetID)
                            let otherAccount = row.event.transferAccountID.flatMap { book.account($0)?.name }
                            let name = otherAccount ?? asset?.displayName
                            let title = store.book.eventTitle(row.event, accountID: account.id) + (name.map { " · " + $0 } ?? "")
                            InvestmentTitle(title, subtitle: InvestmentText.date(row.event.day))
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(InvestmentText.money(row.change, account.currency, signed: true))
                                    .foregroundStyle(InvestmentText.tint(row.change))
                                Text("余额 " + InvestmentText.money(row.balance, account.currency))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.monospacedDigit()
                            InvestmentChevron()
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).investmentListRow()
                }
                if rows.isEmpty { Text("暂无现金流水").foregroundStyle(.secondary) }
            }
            if !otherEvents.isEmpty {
                Section("其他流水") {
                    ForEach(otherEvents.reversed()) { event in
                        let asset = book.asset(event.assetID)
                        let name = asset.map { " · " + $0.displayName } ?? ""
                        Button { editing = event } label: {
                            HStack {
                                InvestmentTitle(store.book.eventTitle(event, accountID: account.id) + name, subtitle: InvestmentText.date(event.day))
                                Spacer()
                                if let asset, event.amount != 0 {
                                    Text((event.amount > 0 ? "+" : "") + InvestmentText.number(event.amount)
                                         + " " + book.settlementUnit(for: asset)).monospacedDigit()
                                }
                                InvestmentChevron()
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).investmentListRow()
                    }
                }
            }
        }.listStyle(.insetGrouped)
    }
}

struct InvestmentPlansView: View {
    private struct EditorRequest: Identifiable {
        let id = UUID()
        let accountID: UUID
        var plan: InvestmentPlan?
    }

    @ObservedObject var store: InvestmentStore
    let selectedAccount: UUID
    @State private var editing: EditorRequest?

    var body: some View {
        SettingsSheet(title: "定投管理") {
            List {
                ForEach(store.book.accounts) { account in
                    let plans = store.book.plans.filter { $0.accountID == account.id }
                    if !plans.isEmpty {
                        Section(account.name + " · " + account.currency.rawValue) {
                            ForEach(plans) { plan in
                                Button { editing = EditorRequest(accountID: account.id, plan: plan) } label: {
                                    planRow(plan, account: account)
                                }
                                .buttonStyle(.plain)
                                .investmentListRow()
                            }
                        }
                    }
                }
                if store.book.plans.isEmpty {
                    ContentUnavailableView("暂无定投任务", systemImage: "calendar.badge.clock",
                        description: Text("可以定期转入现金，或用账户现金定期买入。"))
                }
                Section {
                    Text("定投在打开投资记账时补记。余额不足时跳过当期，买入等待可用日线报价。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = EditorRequest(accountID: selectedAccount) } label: {
                        Image(systemName: "plus")
                    }.accessibilityLabel("新建定投任务")
                }
            }
        }
        .sheet(item: $editing) { request in
            InvestmentPlanEditor(store: store, accountID: request.accountID, plan: request.plan)
        }
    }

    private func planRow(_ plan: InvestmentPlan, account: InvestmentAccount) -> some View {
        let label = store.book.asset(plan.assetID).map { "定期买入 · " + $0.name } ?? "定期转入"
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                InvestmentTitle(label, subtitle: plan.schedule.summary)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(InvestmentText.money(plan.amount, account.currency)).monospacedDigit()
                    Text(plan.enabled ? "计划日 " + InvestmentText.date(plan.nextDay) : "已暂停")
                        .font(.caption).foregroundStyle(.secondary)
                }
                InvestmentChevron()
            }
            if let result = plan.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }.contentShape(Rectangle())
    }
}

struct InvestmentHoldingView: View {
    private struct DepositAction: Identifiable {
        let kind: InvestmentEventKind
        var id: String { kind.rawValue }
    }

    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var showsAdjustment = false
    @State private var showsMarginTransfer = false
    @State private var showsFuturesSettlement = false
    @State private var depositAction: DepositAction?
    @State private var showsDepositTerms = false
    @Environment(\.dismiss) private var dismiss

    private var offersAdjustment: Bool { asset.kind.supportsCashDividends || [.crypto, .generic].contains(asset.kind) }

    var body: some View {
        InvestmentScroll {
            if let current = store.book.account(account.id),
               let ledger = try? store.book.ledger(current, includeRows: true) {
                let position = ledger.positions[asset.id] ?? InvestmentPosition()
                positionCard(position)
                    .disabled(current.isArchived)
                if current.isArchived {
                    Text("账户已归档；如需修改交易，请先在账户管理中撤销归档。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                InvestmentHoldingChart(store: store, account: current, asset: asset)
                InvestmentTransactionRecords(store: store, account: current, asset: asset)
            }
        }
        .navigationTitle(asset.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                InvestmentLifecycleActions(store: store, accountID: account.id, assetID: asset.id) { dismiss() }
            }
        }
        .sheet(item: $depositAction) { action in
            InvestmentTradeEditor(store: store, account: account, asset: asset, kind: action.kind)
        }
        .sheet(isPresented: $showsDepositTerms) {
            InvestmentDepositTermsEditor(store: store, accountID: account.id, asset: asset)
        }
        .sheet(isPresented: $showsAdjustment) {
            InvestmentHoldingAdjustmentEditor(store: store, account: account, asset: asset)
        }
        .sheet(isPresented: $showsMarginTransfer) {
            InvestmentMarginTransferEditor(store: store, account: account, asset: asset)
        }
        .sheet(isPresented: $showsFuturesSettlement) {
            InvestmentFuturesSettlementEditor(store: store, account: account, asset: asset)
        }
    }

    private func positionCard(_ position: InvestmentPosition) -> some View {
        let insurance = asset.kind == .insurance
        let termDeposit = asset.kind.isTermDeposit
        let quote = store.book.positionQuote(for: asset, on: InvestmentBook.day(), requiresDailyPrices: false, position: position)
        let value = store.book.positionValue(position, asset: asset)
        let gain = value.map { $0 - position.netCost + position.realized }
        let rate = position.netCost > 0 ? value.map { ($0 - position.netCost + (insurance ? position.realized : 0)) / position.netCost } : nil
        let sinceEntry = position.lastEntry.flatMap { entry in quote.map { ($0.price / entry - 1) * asset.priceDirection } }
        return InvestmentCard {
            let description = "\(asset.kindLabel) · \(InvestmentText.number(position.quantity)) \(asset.historyUnit)"
            InvestmentTitle("持仓概况", subtitle: asset.kind.usesBalance ? asset.kindLabel : asset.displayCode + " · " + description)
            InvestmentMetric(title: asset.kind == .wealth ? "理财余额" : asset.kind == .generic ? "标的余额" : (termDeposit ? "存款余额" : (insurance ? "保单现金价值" : "持仓估值")),
                             value: InvestmentText.money(value, account.currency), prominent: true)
            HStack(alignment: .top) {
                InvestmentMetric(title: "累计盈亏", value: InvestmentText.money(gain, account.currency, signed: true), color: InvestmentText.tint(gain))
                Spacer(minLength: 6)
                InvestmentMetric(title: "盈亏比例", value: InvestmentText.percent(rate), color: InvestmentText.tint(rate))
                if !insurance && !asset.kind.usesBalance {
                    Spacer(minLength: 6)
                    InvestmentMetric(title: "较上次买入",
                                     value: InvestmentText.percent(sinceEntry), color: InvestmentText.tint(sinceEntry))
                }
            }
            if termDeposit {
                Button { showsDepositTerms = true } label: {
                    HStack {
                        if let terms = asset.depositTerms {
                            let annualRate = terms.annualRate.formatted(.percent)
                            Text("年利率 \(annualRate) · 到期日 \(InvestmentText.date(terms.maturity))")
                        } else {
                            Text("填写年利率和到期日")
                        }
                        Spacer(minLength: 4)
                        InvestmentChevron()
                    }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint("编辑存款信息")
                Text("存款本金 " + InvestmentText.money(max(0, position.netCost), account.currency))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if asset.kind == .generic {
                Text("净投入 " + InvestmentText.money(position.netCost - position.realized, account.currency))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if position.quantity > 0, !asset.kind.usesMargin, !asset.kind.usesBalance {
                Text((insurance ? "累计保费 " : "摊薄成本价 ")
                     + InvestmentText.price(position.netCost / (position.quantity * asset.multiplier), account.currency))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let quote {
                Text((insurance ? "估值" : "报价") + " " + InvestmentText.number(quote.price)
                     + " " + store.book.quoteUnit(for: asset) + " · " + InvestmentText.quoteDetail(quote))
                    .font(.caption).foregroundStyle(.secondary)
                if asset.isStockConnect, value == nil {
                    Text("缺少港币兑人民币汇率。").font(.caption).foregroundStyle(.secondary)
                }

            } else if !asset.kind.usesBalance {
                Text(insurance ? "待录入现金价值。" : "缺少报价。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if asset.kind.usesBalance {
                    Button(asset.transactionTitle(.buy)) { depositAction = .init(kind: .buy) }.buttonStyle(HakoActionButtonStyle())
                    if position.quantity > 0 {
                        Button(asset.transactionTitle(.sell)) { depositAction = .init(kind: .sell) }.buttonStyle(HakoActionButtonStyle(primary: false))
                    }
                } else {
                    if !insurance || position.quantity > 0 {
                        InvestmentLink(route: .trade(account.id, asset.id, .buy)) { Text(asset.transactionTitle(.buy)) }
                            .buttonStyle(HakoActionButtonStyle())
                    }
                    if position.quantity > 0 {
                        InvestmentLink(route: .trade(account.id, asset.id, .sell)) { Text(asset.transactionTitle(.sell)) }
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                    }
                }
            }
            if asset.kind.usesMargin, position.quantity > 0 {
                Divider()
                Button { showsMarginTransfer = true } label: {
                    InvestmentPageRow(title: "调整保证金", symbol: "arrow.left.arrow.right")
                }.buttonStyle(.plain)
            }
            if asset.kind == .future, position.quantity > 0 {
                Divider()
                Button { showsFuturesSettlement = true } label: {
                    InvestmentPageRow(title: "记实际结算", symbol: "calendar.badge.checkmark")
                }.buttonStyle(.plain)
            }
            adjustmentAction
            if asset.kind == .wealth {
                Divider()
                Button { depositAction = .init(kind: .income) } label: {
                    InvestmentPageRow(title: "记录实收收益", symbol: "plus.circle")
                }.buttonStyle(.plain)
                Divider()
                Button { depositAction = .init(kind: .adjustment) } label: {
                    InvestmentPageRow(title: "更新理财余额", symbol: "slider.horizontal.3")
                }.buttonStyle(.plain)
            }
            if termDeposit || asset.kind == .insurance { Divider() }
            if termDeposit {
                Button { depositAction = .init(kind: .income) } label: {
                    InvestmentPageRow(title: "支取利息", symbol: "banknote")
                }.buttonStyle(.plain)
                Divider()
                Button { depositAction = .init(kind: .adjustment) } label: {
                    InvestmentPageRow(title: "调整余额", symbol: "slider.horizontal.3")
                }.buttonStyle(.plain)
            } else if asset.kind == .insurance {
                if position.quantity > 0 {
                    Button { depositAction = .init(kind: .insuranceWithdrawal) } label: {
                        InvestmentPageRow(title: "部分提取", symbol: "banknote")
                    }.buttonStyle(.plain)
                    Divider()
                }
                InvestmentPageLink(title: "更新现金价值",
                                   symbol: "chart.xyaxis.line", route: .quote(asset.id))
            }
        }
    }

    @ViewBuilder private var adjustmentAction: some View {
        if offersAdjustment {
            let title = asset.kind.supportsCashDividends ? "记分红" : "调整余额"
            let symbol = asset.kind.supportsCashDividends ? "banknote" : "slider.horizontal.3"
            Divider()
            Button { showsAdjustment = true } label: {
                InvestmentPageRow(title: title, symbol: symbol)
            }.buttonStyle(.plain)
        }
    }
}

struct InvestmentAccountManagement: View {
    @State private var editingAccount = false
    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SettingsSheet(title: "管理账户") {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let account = store.book.account(accountID) {
                        InvestmentAccountManagementCard {
                            Group {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 10) {
                                        accountName(account)
                                        accountStatus(account)
                                    }
                                } else {
                                    HStack(spacing: 12) {
                                        accountName(account)
                                        Spacer(minLength: 8)
                                        accountStatus(account)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.top, 20)
                            .padding(.bottom, 15)

                            accountDetail("账户类型", value: account.type.rawValue)
                            accountDivider
                            accountDetail("账户币种", value: account.currency.title + " · " + account.currency.rawValue)
                            accountDivider
                            Button { editingAccount = true } label: {
                                InvestmentAccountManagementRow(title: "编辑账户")
                            }
                            .buttonStyle(.plain)
                            .disabled(store.saving)
                        }
                        InvestmentLifecycleActions(store: store, accountID: accountID) { dismiss() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            .background(InvestmentAccountManagementStyle.background)
            .toolbarBackground(InvestmentAccountManagementStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $editingAccount) {
            if let account = store.book.account(accountID) { InvestmentAccountEditor(store: store, account: account) }
        }
    }

    private func accountName(_ account: InvestmentAccount) -> some View {
        Text(account.name).font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("账户名称，" + account.name)
    }

    private func accountStatus(_ account: InvestmentAccount) -> some View {
        HStack(spacing: 5) {
            Circle().frame(width: 5, height: 5).accessibilityHidden(true)
            Text(account.isArchived ? "已归档" : "使用中")
        }
        .font(.caption)
        .foregroundStyle(account.isArchived ? Color.secondary : Color.green)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background((account.isArchived ? Color.secondary : Color.green).opacity(0.12), in: Capsule())
        .fixedSize()
    }

    private func accountDetail(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } label: {
            Text(title)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .frame(minHeight: 51)
        .padding(.horizontal, 18)
    }

    private var accountDivider: some View {
        Divider().padding(.horizontal, 18)
    }
}

private enum InvestmentAccountManagementStyle {
    static let background = HakoStyle.adaptive(0xf2f2f7, 0x1c1c1e)
    static let card = HakoStyle.adaptive(0xffffff, 0x2b2b2e)
}

private struct InvestmentAccountManagementCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InvestmentAccountManagementStyle.card, in: RoundedRectangle(cornerRadius: 19))
    }
}

private struct InvestmentAccountManagementRow: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct InvestmentLifecycleActions: View {
    @State private var editingAsset = false
    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    var assetID: UUID?
    let onDelete: () -> Void
    @State private var confirmsDeletion = false
    @State private var confirmsArchival = false
    @State private var archivesAccount = true
    @State private var deletionVersion: UUID?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Group {
            if assetID != nil {
                Menu {
                    Button("修改标的资料") { editingAsset = true }
                    Button(role: .destructive, action: requestDeletion) {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多持仓操作")
                .disabled(working || store.saving)
            } else {
                accountActions
            }
        }
        .hakoDeleteConfirmation(Text(assetID == nil ? "删除账户？" : "删除持仓？"), isPresented: $confirmsDeletion,
                                message: Text(store.book.deletionMessage(accountID: accountID, assetID: assetID)), disabled: working || store.saving) {
            Task {
                await perform {
                    try await store.update { book in
                        guard deletionVersion == store.bookVersion else {
                            throw InvestmentError.invalid("账本已更新，请重新核对删除范围。")
                        }
                        try book.deleteInvestment(accountID: accountID, assetID: assetID)
                    }
                    onDelete()
                }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(archivesAccount ? "归档此账户？" : "恢复此账户？", isPresented: $confirmsArchival, titleVisibility: .visible) {
            Button(archivesAccount ? "确认归档" : "确认恢复") {
                Task {
                    await perform {
                        try await store.update { book in
                            guard let account = book.account(accountID), account.isArchived != archivesAccount else {
                                throw InvestmentError.invalid("账户状态已更新，请重新核对。")
                            }
                            try book.setArchived(archivesAccount, accountID: accountID)
                        }
                    }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(archivesAccount ? "全部数据会保留，定投将暂停，账户默认隐藏。之后可随时恢复。"
                 : "账户将重新显示，已暂停的定投不会自动恢复。")
        }
        .sheet(isPresented: $editingAsset) {
            if let assetID, let asset = store.book.asset(assetID) {
                if asset.kind.isTermDeposit {
                    InvestmentDepositTermsEditor(store: store, accountID: accountID, asset: asset)
                } else {
                    InvestmentAssetInfoEditor(store: store, asset: asset)
                }
            }
        }
    }

    private var accountActions: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let account = store.book.account(accountID) {
                let blocker = store.book.archiveBlocker(accountID: accountID)
                VStack(alignment: .leading, spacing: 9) {
                    Button {
                        archivesAccount = !account.isArchived
                        confirmsArchival = true
                    } label: {
                        Text(account.isArchived ? "恢复账户" : "归档账户")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(HakoActionButtonStyle(backgroundColor: .orange))
                    .disabled(working || store.saving || (!account.isArchived && blocker != nil))
                    Text(account.isArchived ? "账户已隐藏，交易记录和历史盈亏完整保留。恢复后可重新使用，定投需手动启用。"
                         : blocker ?? "保留全部数据，暂停定投并隐藏账户。可在设置中显示归档账户，随时恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                HakoDeleteButton(title: "删除账户", action: requestDeletion)
                    .font(.subheadline.weight(.medium))
                    .disabled(working || store.saving)
                Text("同时删除该账户的全部交易记录，无法撤销。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 11)
        }
    }

    private func requestDeletion() {
        deletionVersion = store.bookVersion
        confirmsDeletion = true
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }
}

private struct InvestmentSettings: View {
    private enum Sheet: Hashable, Identifiable {
        case credential(InvestmentQuoteSource), dataBackup
        var id: Self { self }
    }

    @ObservedObject var store: InvestmentStore
    @State private var error: String?
    @State private var sheet: Sheet?
    @State private var preparingExport = false
    @State private var showingExporter = false
    @State private var exportDocument: InvestmentExportDocument?

    var body: some View {
        SettingsSheet(title: "投资记账设置") { settings }
    }

    private var settings: some View {
        Form {
            Section {
                NavigationLink {
                    InvestmentAccountSettings(store: store)
                } label: {
                    HStack {
                        Text("账户管理")
                        Spacer()
                        Text("\(store.visibleAccounts.count)个账户")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }.investmentListRow()
            }
            Section("显示选项") {
                Toggle("显示归档账户", isOn: $store.showsArchived)
                Toggle("显示零余额持仓", isOn: $store.showsZeroPositions)
                Text("隐藏只影响列表显示，历史流水和统计仍保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                InvestmentQuoteChannels()
                ForEach(InvestmentQuoteSource.allCases) { source in
                    credentialLink(source)
                }
            } header: {
                Text("行情接口")
            } footer: {
                Text("进入各接口页面配置密钥，查看最近24小时的成功与失败调用量。")
                if !store.quoteStatus.isEmpty { Text(store.quoteStatus) }
            }
            Section {
                NavigationLink {
                    InvestmentDataManagement(store: store)
                } label: {
                    Label("数据管理", systemImage: "internaldrive")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.investmentListRow()
                NavigationLink {
                    InvestmentDataInspection(store: store)
                } label: {
                    Label("数据检验", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.investmentListRow()
                NavigationLink {
                    InvestmentSnapshotSettings(store: store)
                } label: {
                    Label("重新计算历史快照", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.investmentListRow()
                Button { preparingExport = true } label: {
                    Label(preparingExport ? "正在准备导出…" : "导出账本", systemImage: "square.and.arrow.up")
                }
                .disabled(preparingExport || showingExporter)
                .investmentListRow()
                Button { sheet = .dataBackup } label: {
                    Label("数据备份", systemImage: "externaldrive.badge.icloud")
                }.investmentListRow()
            } header: {
                Text("数据")
            }
        }
        .navigationTitle("投资记账设置")
        .sheet(item: $sheet) { item in
            switch item {
            case .credential(let source): InvestmentQuoteCredentialEditor(store: store, source: source)
            case .dataBackup: InvestmentDataBackupSettings()
            }
        }
        .task(id: preparingExport) {
            if preparingExport { await prepareExport() }
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentTypes: [.zip],
                      defaultFilename: "投资记账-" + InvestmentBook.snapshotDateFormatter().string(from: InvestmentBook.day())) { result in
            exportDocument = nil
            if case .failure(let failure) = result { error = failure.localizedDescription }
        } onCancellation: {
            exportDocument = nil
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func credentialLink(_ source: InvestmentQuoteSource) -> some View {
        let configured = store.configuredSources.contains(source)
        return Button { sheet = .credential(source) } label: {
            HStack {
                Text(source.title)
                Spacer()
                if configured {
                    Label("已配置", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                InvestmentChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .investmentListRow()
        .accessibilityValue(configured ? "已配置" : "未配置")
    }

    private func prepareExport() async {
        defer { preparingExport = false }
        do {
            let data = try await store.exportLedger()
            exportDocument = InvestmentExportDocument(data: data)
            showingExporter = true
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

}

private struct InvestmentSnapshotSettings: View {
    @ObservedObject var store: InvestmentStore
    @State private var recalculating = false
    @State private var report: InvestmentDailySnapshotReport?
    @State private var error: String?

    private var end: Date { InvestmentBook.addDays(-1, to: InvestmentBook.day()) }
    private var hasHistory: Bool { store.book.earliest.map { $0 <= end } ?? false }

    var body: some View {
        Form {
            Section("这个操作做什么") {
                Text("根据现有交易流水、估值和汇率，重新计算每天收盘后的账户余额、持仓市值、总资产和盈亏，用于历史趋势与盈亏日历。")
                Text("重算会更新服务端的日终快照，不修改原始交易流水。")
            }
            Section("何时使用") {
                Text("修改历史交易、补齐历史行情或汇率后，或数据检验提示快照缺失、与账本不一致时，可以重新计算。")
            }
            Section("计算范围") {
                if let first = store.book.earliest, hasHistory {
                    LabeledContent("日期", value: InvestmentText.date(first) + " 至 " + InvestmentText.date(end))
                } else {
                    Text("暂无已结束的记账日。").foregroundStyle(.secondary)
                }
                Text("按北京时间截日，覆盖全部账户，包括已归档账户；今天尚未结束，不生成今天的日终快照。")
                Text("复用本机与服务端已有的历史行情和汇率，仅补查两处都缺少的数据。未能补齐的数据会保留为缺失，不用零值替代。")
            }
            Section {
                Button { recalculating = true } label: {
                    HStack(spacing: 8) {
                        if recalculating { ProgressView() }
                        Text(recalculating ? "正在查询并重算…" : "开始重新计算")
                    }
                }
                .buttonStyle(HakoActionButtonStyle())
                .disabled(recalculating || !hasHistory)
            } footer: {
                Text("自动化可使用「同步 Hako 数据」快捷指令。")
            }
            if let report {
                Section("重算结果") {
                    Text(report.message)
                    SectionReportTotals(report: report)
                }
            }
            if let failure = error ?? store.snapshotSaveError {
                Section("未能完成") {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("重新计算历史快照")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recalculating) {
            if recalculating { await rebuild() }
        }
    }

    private func rebuild() async {
        report = nil
        error = nil
        defer { recalculating = false }
        do {
            try await store.refreshSnapshotHistory()
            report = try await store.saveDailySnapshots(rebuild: true)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct InvestmentAccountSettings: View {
    private enum Sheet: Hashable, Identifiable {
        case addAccount, account(UUID)
        var id: Self { self }
    }

    @ObservedObject var store: InvestmentStore
    @State private var sheet: Sheet?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.visibleAccounts) { account in
                    let subtitle = account.currency.rawValue + " · " + account.type.rawValue + (account.isArchived ? " · 已归档" : "")
                    Button { sheet = .account(account.id) } label: {
                        HStack {
                            InvestmentTitle(account.name, subtitle: subtitle)
                            Spacer()
                            InvestmentChevron()
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).investmentListRow().hakoReorderRow()
                }
                .onMove(perform: moveAccounts)
                Button { sheet = .addAccount } label: {
                    Label("添加账户", systemImage: "plus")
                }.investmentListRow()
            }
        }
        .navigationTitle("账户管理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { item in
            switch item {
            case .addAccount: InvestmentAccountEditor(store: store)
            case .account(let id): InvestmentAccountManagement(store: store, accountID: id)
            }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func moveAccounts(from offsets: IndexSet, to destination: Int) {
        var reordered = store.visibleAccounts.map(\.id)
        reordered.move(fromOffsets: offsets, toOffset: destination)
        Task {
            do {
                try await store.update { book in
                    let ids = Set(reordered)
                    var ordered = reordered.compactMap { book.account($0) }.makeIterator()
                    for i in book.accounts.indices where ids.contains(book.accounts[i].id) {
                        if let account = ordered.next() { book.accounts[i] = account }
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct InvestmentDataInspection: View {
    @ObservedObject var store: InvestmentStore
    @State private var checking = false
    @State private var report: InvestmentDataReport?
    @State private var error: String?
    @State private var changedSinceCheck = false

    var body: some View {
        Form {
            Section {
                Text("读取服务端最新保存的完整账本，检查全部账户（包括归档账户）的交易、历史估值、汇率和日终快照。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(checking ? "正在检验…" : report == nil ? "开始检验" : "重新检验") { checking = true }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(checking || store.saving)
                if checking { ProgressView("正在读取并检验数据") }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("仅检验，不修改交易、补查行情或重算快照。保险未录入现金价值时按零估值，并显示提醒。")
            }
            if let report {
                Section("检验结果") {
                    LabeledContent("影响计算", value: "\(report.errors) 项")
                    LabeledContent("请留意", value: "\(report.notices) 项")
                    LabeledContent("检查数据", value: "\(report.accounts) 个账户 · \(report.events) 笔交易")
                    if let first = report.firstDay {
                        Text("检查范围：" + InvestmentText.date(first) + " 至 " + InvestmentText.date(report.lastDay))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("检验时间：" + report.checkedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.footnote).foregroundStyle(.secondary)
                    if changedSinceCheck {
                        Text("账本已更新，请重新检验以获取最新结果。").foregroundStyle(.orange)
                    } else if report.issues.isEmpty {
                        Label("未发现问题", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
                issueSection(report.issues.filter { $0.level == .error }, title: "影响计算的问题")
                issueSection(report.issues.filter { $0.level == .notice }, title: "需要留意的情况")
            }
        }
        .navigationTitle("数据检验")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: checking) {
            guard checking else { return }
            report = nil
            error = nil
            changedSinceCheck = false
            defer { checking = false }
            do { report = try await store.inspectData() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: store.bookVersion) { _, _ in
            if report != nil { changedSinceCheck = true }
        }
    }

    @ViewBuilder private func issueSection(_ issues: [InvestmentDataIssue], title: String) -> some View {
        if !issues.isEmpty {
            Section(title) {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(issue.title, systemImage: issue.level == .error ? "exclamationmark.circle" : "info.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(issue.level == .error ? Color.red : Color.orange)
                        Text(issue.location).font(.subheadline)
                        Text(issue.dateRanges).font(.caption).foregroundStyle(.secondary)
                        Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                    }.textSelection(.enabled).investmentListRow()
                }
            }
        }
    }
}

struct InvestmentExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SectionReportTotals: View {
    let report: InvestmentDailySnapshotReport

    var body: some View {
        LabeledContent("快照日期", value: InvestmentText.date(report.day)).investmentListRow()
        LabeledContent("折算人民币总额", value: InvestmentText.money(report.latest?.value, .cny)).investmentListRow()
        LabeledContent("折算美元总额", value: InvestmentText.money(report.latest?.valueUSD, .usd)).investmentListRow()
    }
}

private struct InvestmentQuoteCredentialEditor: View {
    let store: InvestmentStore
    let source: InvestmentQuoteSource
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var savedKey: String?
    @State private var error: String?
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var showsKey = false

    private var hasChanges: Bool { savedKey.map { key != $0 } ?? false }

    var body: some View {
        SettingsSheet(title: source.title, hasChanges: hasChanges, saveEnabled: hasChanges, onSave: save) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(source.credential).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button { showsKey.toggle() } label: {
                                Image(systemName: showsKey ? "eye" : "eye.slash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel((showsKey ? "隐藏" : "显示") + source.credential)
                            .accessibilityValue(showsKey ? "已显示" : "已隐藏")
                        }
                        HakoSecureTextEditor(text: $key, isSecure: !showsKey, label: source.credential)
                            .frame(minHeight: 88, alignment: .topLeading)
                            .overlay(alignment: .topLeading) {
                                if key.isEmpty {
                                    Text("输入 " + source.credential)
                                        .font(.body.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                    .investmentListRow()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .listRowInsets(EdgeInsets())
                    .disabled(savedKey == nil)
                } footer: {
                    Text("清空后保存可移除此行情源的凭据。")
                }
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { testing = true } label: {
                            HStack(spacing: 8) {
                                if testing { ProgressView() }
                                Text(testing ? "正在测试…" : "测试连接")
                            }
                        }
                        .buttonStyle(HakoActionButtonStyle(primary: false, outlined: true))
                        .disabled(testing || savedKey == nil || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if source == .tushare {
                            Text("通过读取交易日历测试，需要该接口的访问权限。测试失败不一定表示 Token 无效。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let testMessage { connectionResult(testMessage) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Keep both outlines inside the grouped Form's rounded clipping boundary.
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if savedKey == nil { Button("重试读取", action: load) }
                InvestmentAPIUsageChart(source: source)
            }
        }
        .task { load() }
        .task(id: testing) {
            if testing { await testConnection() }
        }
        .onChange(of: key) { _, _ in testMessage = nil }
    }

    private func connectionResult(_ message: String) -> some View {
        let tint = testSucceeded ? Color.green : Color.red
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.body)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(testSucceeded ? "连接成功" : "连接失败")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }

    private func testConnection() async {
        let value = key
        testMessage = nil
        defer { testing = false }
        do {
            try await InvestmentQuoteProvider().testCredential(value, for: source)
            guard !Task.isCancelled, key == value else { return }
            testSucceeded = true
            testMessage = source == .tushare
                ? "Token 可用，交易日历读取正常。其他行情接口仍受各自权限与频率限制。"
                : "凭据可用，行情接口响应正常。"
        } catch {
            guard !Task.isCancelled, key == value else { return }
            testSucceeded = false
            testMessage = error.localizedDescription
        }
    }

    private func load() {
        do {
            key = try store.loadKey(for: source)
            savedKey = key
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            try store.saveKey(key, for: source)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    func investmentListRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
