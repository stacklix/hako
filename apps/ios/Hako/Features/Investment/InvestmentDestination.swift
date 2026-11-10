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
                            let name = row.event.unallocatedFunding == true ? nil : otherAccount ?? asset?.name
                            let title = row.event.title(for: asset) + (name.map { " · " + $0 } ?? "")
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
                        let name = event.unallocatedFunding == true ? "" : asset.map { " · " + $0.name } ?? ""
                        Button { editing = event } label: {
                            HStack {
                                InvestmentTitle(event.title(for: asset) + name, subtitle: InvestmentText.date(event.day))
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
                InvestmentTitle(label, subtitle: "每月 \(plan.monthDay) 日")
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
    @State private var editing: InvestmentEvent?
    @State private var depositAction: DepositAction?
    @State private var showsDepositTerms = false

    private var offersAdjustment: Bool { asset.kind.supportsCashDividends || [.crypto, .cryptoContract].contains(asset.kind) }

    var body: some View {
        InvestmentScroll {
            if let current = store.book.account(account.id),
               let ledger = try? store.book.ledger(current, includeRows: true),
               let position = ledger.positions[asset.id] {
                positionCard(position, reserved: ledger.reservedCollateral[asset.id, default: 0])
                InvestmentCard {
                    Text(asset.kind.isManual || offersAdjustment ? "资产流水" : "买卖记录").font(.headline)
                    ForEach(store.book.orderedEvents(current, through: InvestmentBook.day()).filter {
                        $0.assetID == asset.id && $0.unallocatedFunding != true
                    }.reversed()) { event in
                        Button { editing = event } label: {
                        HStack {
                            let target = event.fundingTarget.map { " · " + $0.rawValue } ?? ""
                            InvestmentTitle(event.title(for: asset), subtitle: InvestmentText.date(event.day) + target)
                            Spacer()
                            VStack(alignment: .trailing) {
                                switch event.kind {
                                case .income, .dividend:
                                    Text(InvestmentText.money(event.amount, account.currency, signed: true))
                                case .funding:
                                    let unit = event.fundingTarget.map { store.book.fundingUnit(for: asset, target: $0) }
                                        ?? store.book.settlementUnit(for: asset)
                                    Text((event.amount > 0 ? "+" : "") + InvestmentText.number(event.amount)
                                         + " " + unit)
                                        .foregroundStyle(InvestmentText.tint(event.amount))
                                case .marginTransfer, .derivativeSettlement:
                                    let unit = store.book.fundingUnit(for: asset, target: .available)
                                    Text((event.amount > 0 ? "+" : "") + InvestmentText.number(event.amount) + " " + unit)
                                case .bonusShares, .stakingReward, .spotAdjustment:
                                    let unit = asset.kind == .crypto ? asset.code : asset.kind.unit
                                    Text((event.quantity > 0 ? "+" : "") + InvestmentText.number(event.quantity) + " " + unit)
                                case .opening where asset.kind.isTermDeposit,
                                     .buy where asset.kind.isTermDeposit,
                                     .sell where asset.kind.isTermDeposit:
                                    Text(InvestmentText.money(event.kind == .sell ? -event.price : event.price,
                                                              account.currency, signed: true))
                                case .adjustment where asset.kind.isTermDeposit:
                                    EmptyView()
                                default:
                                    if asset.kind != .insurance {
                                        Text(InvestmentText.number(event.quantity) + " " + asset.kind.unit)
                                    }
                                    Text(InvestmentText.number(event.price) + " " + store.book.quoteUnit(for: asset))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let fee = event.fee, fee > 0 {
                                    Text("交易费用 " + InvestmentText.number(fee) + " " + store.book.settlementUnit(for: asset))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let change = ledger.collateralChanges[event.id], change != 0 {
                                    Text("净结算 " + (change > 0 ? "+" : "") + InvestmentText.number(change) + " " + store.book.settlementUnit(for: asset))
                                        .font(.caption).foregroundStyle(InvestmentText.tint(change))
                                }
                                if let amount = event.settledAmount {
                                    Text((asset.kind.isTermDeposit ? "余额 " : "") + InvestmentText.money(amount, account.currency))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.monospacedDigit()
                            InvestmentChevron()
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .navigationTitle(asset.name)
        .sheet(item: $editing) { event in
            InvestmentEventEditor(store: store, accountID: account.id, event: event)
        }
        .sheet(item: $depositAction) { action in
            InvestmentTradeEditor(store: store, account: account, asset: asset, kind: action.kind)
        }
        .sheet(isPresented: $showsDepositTerms) {
            InvestmentDepositTermsEditor(store: store, accountID: account.id, asset: asset)
        }
        .sheet(isPresented: $showsAdjustment) {
            if asset.kind == .cryptoContract {
                InvestmentFundingAdjustmentEditor(store: store, account: account, asset: asset)
            } else {
                InvestmentHoldingAdjustmentEditor(store: store, account: account, asset: asset)
            }
        }
        .sheet(isPresented: $showsMarginTransfer) {
            InvestmentMarginTransferEditor(store: store, account: account, asset: asset)
        }
        .sheet(isPresented: $showsFuturesSettlement) {
            InvestmentFuturesSettlementEditor(store: store, account: account, asset: asset)
        }
    }

    private func positionCard(_ position: InvestmentPosition, reserved: Decimal) -> some View {
        let insurance = asset.kind == .insurance
        let termDeposit = asset.kind.isTermDeposit
        let nativeContract = asset.collateralAssetID != nil
        let cashContract = asset.settlementStablecoin != nil
        let quote = store.book.quote(asset.id)
        let value = store.book.positionValue(position, asset: asset)
        let gain = value.map { $0 - position.netCost + position.realized }
        let unrealized = cashContract ? value.map { $0 - position.margin } : value
        let collateralPrice: Decimal? = cashContract ? 1 : asset.collateralAssetID.flatMap { store.book.quote($0)?.price }
        let marginUSD = collateralPrice.map { position.margin * $0 }
        let rate: Decimal? = if nativeContract || cashContract, let marginUSD, marginUSD > 0 {
            unrealized.map { $0 / marginUSD }
        } else {
            position.netCost > 0 ? value.map { ($0 - position.netCost) / position.netCost } : nil
        }
        let sinceEntry = position.lastEntry.flatMap { entry in quote.map { ($0.price / entry - 1) * asset.priceDirection } }
        return InvestmentCard {
            let description = "\(asset.kindLabel) · \(InvestmentText.number(position.quantity)) \(asset.kind.unit)"
            InvestmentTitle("持仓概况", subtitle: termDeposit ? asset.kindLabel : asset.code + " · " + description)
            InvestmentMetric(title: nativeContract || cashContract ? "未实现盈亏" : (termDeposit ? "存款余额" : (insurance ? "保单现金价值" : "持仓估值")),
                             value: InvestmentText.money(unrealized, account.currency), prominent: true)
            HStack(alignment: .top) {
                InvestmentMetric(title: "累计盈亏", value: InvestmentText.money(gain, account.currency, signed: true), color: InvestmentText.tint(gain))
                Spacer(minLength: 6)
                InvestmentMetric(title: "盈亏比例", value: InvestmentText.percent(rate), color: InvestmentText.tint(rate))
                if !insurance && !termDeposit {
                    Spacer(minLength: 6)
                    InvestmentMetric(title: asset.kind == .cryptoContract ? "较上次开仓" : "较上次买入",
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
            if position.quantity > 0, asset.kind == .cryptoContract {
                Text("占用保证金 " + InvestmentText.number(position.margin) + " " + store.book.settlementUnit(for: asset))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if reserved > 0 {
                Text("可用 " + InvestmentText.number(position.quantity - reserved) + " · 保证金占用 " + InvestmentText.number(reserved))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if position.quantity > 0, !asset.kind.usesMargin, !termDeposit {
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
                if nativeContract, value == nil {
                    Text("缺少结算币兑美元报价。").font(.caption).foregroundStyle(.secondary)
                }
            } else if !termDeposit {
                Text(insurance ? "待录入现金价值。" : "缺少报价。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if termDeposit {
                    Button("存入") { depositAction = .init(kind: .buy) }.buttonStyle(HakoActionButtonStyle())
                    if position.quantity > 0 {
                        Button("支取") { depositAction = .init(kind: .sell) }.buttonStyle(HakoActionButtonStyle(primary: false))
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
                InvestmentPageLink(title: "记录实收收益", symbol: "plus.circle",
                                   route: .trade(account.id, asset.id, .income))
            }
            Divider()
            if termDeposit {
                Button { depositAction = .init(kind: .income) } label: {
                    InvestmentPageRow(title: "支取利息", symbol: "banknote")
                }.buttonStyle(.plain)
                Divider()
                Button { depositAction = .init(kind: .adjustment) } label: {
                    InvestmentPageRow(title: "调整余额", symbol: "slider.horizontal.3")
                }.buttonStyle(.plain)
            } else {
                InvestmentPageLink(title: insurance ? "更新现金价值" : (asset.kind == .wealth ? "更新单位净值" : "行情与手动报价"),
                                   symbol: "chart.xyaxis.line", route: .quote(asset.id))
            }
        }
    }

    @ViewBuilder private var adjustmentAction: some View {
        if offersAdjustment {
            let title = asset.kind.supportsCashDividends ? "记分红" : "调整余额"
            let symbol = asset.kind.supportsCashDividends ? "banknote" : "slider.horizontal.3"
            let subtitle = asset.kind == .cryptoContract ? "资金费" : ""
            Divider()
            Button { showsAdjustment = true } label: {
                InvestmentPageRow(title: title, symbol: symbol, subtitle: subtitle)
            }.buttonStyle(.plain)
        }
    }
}

private struct InvestmentSettings: View {
    private enum Sheet: Hashable, Identifiable {
        case addAccount, credential(InvestmentQuoteSource)
        var id: Self { self }
    }

    @ObservedObject var store: InvestmentStore
    @State private var error: String?
    @State private var sheet: Sheet?
    @State private var recalculatingSnapshots = false
    @State private var snapshotReport: InvestmentDailySnapshotReport?
    @State private var preparingExport = false
    @State private var showingExporter = false
    @State private var exportDocument: InvestmentExportDocument?

    var body: some View {
        Form {
            Section("账户管理") {
                ForEach(store.book.accounts) { account in
                    let subtitle = account.currency.rawValue + " · " + account.type.rawValue
                    InvestmentTitle(account.name, subtitle: subtitle).investmentListRow()
                }
                .onMove { offsets, destination in
                    Task { await perform { try await store.update { $0.accounts.move(fromOffsets: offsets, toOffset: destination) } } }
                }
                Button { sheet = .addAccount } label: {
                    Label("添加账户", systemImage: "plus")
                }
                .investmentListRow()
            }
            Section("行情与汇率") {
                Text("A 股与中国基金、期货优先使用 Tushare Pro，港股通与美股优先使用 Twelve Data。加密现货使用 Binance 公开报价，加密合约使用所选交易所的标记价格。汇率可由欧洲央行补充。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(store.refreshing ? "正在刷新…" : "刷新行情与汇率") { Task { await store.refresh() } }
                    .disabled(!store.canRefresh || store.refreshing)
                if !store.quoteStatus.isEmpty { Text(store.quoteStatus).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("行情接口") {
                ForEach(InvestmentQuoteSource.allCases) { source in credentialLink(source) }
            }
            Section {
                Button(recalculatingSnapshots ? "正在查询并重算…" : "重新计算历史快照") {
                    Task { await rebuildSnapshots() }
                }
                .disabled(recalculatingSnapshots || store.book.earliest == nil)
                if let snapshotReport {
                    Text(snapshotReport.message).font(.footnote).foregroundStyle(.secondary)
                    SectionReportTotals(report: snapshotReport)
                }
                if let snapshotSaveError = store.snapshotSaveError {
                    Text(snapshotSaveError).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("日终快照")
            } footer: {
                Text("按北京时间截日，快照保存到服务端。重算复用已保存的历史行情和汇率，仅补查缺失数据。自动化可使用「同步 Hako 数据」快捷指令。")
            }
            Section {
                Button { preparingExport = true } label: {
                    Label(preparingExport ? "正在准备导出…" : "导出账本", systemImage: "square.and.arrow.up")
                }
                .disabled(preparingExport || showingExporter)
                .investmentListRow()
            } header: {
                Text("数据导出")
            } footer: {
                Text("将服务端已保存的全部记账数据导出为 CSV 压缩包，内含 SQLite 建表语句。")
            }
        }
        .navigationTitle("投资记账设置")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton().accessibilityLabel("调整账户顺序") } }
        .sheet(item: $sheet) { item in
            switch item {
            case .addAccount: InvestmentAccountEditor(store: store)
            case .credential(let source): InvestmentQuoteCredentialEditor(store: store, source: source)
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

    private func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch { self.error = error.localizedDescription }
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

    private func rebuildSnapshots() async {
        guard !recalculatingSnapshots else { return }
        recalculatingSnapshots = true
        snapshotReport = nil
        defer { recalculatingSnapshots = false }
        do {
            try await store.refreshSnapshotHistory()
            snapshotReport = try await store.saveDailySnapshots(rebuild: true)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
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

    private var hasChanges: Bool { savedKey.map { key != $0 } ?? false }

    var body: some View {
        SettingsSheet(title: source.title, hasChanges: hasChanges, saveEnabled: hasChanges, onSave: save) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.credential).font(.subheadline).foregroundStyle(.secondary)
                        SecureField("输入 " + source.credential, text: $key)
                            .accessibilityLabel(source.credential)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .investmentListRow()
                    .disabled(savedKey == nil)
                } footer: {
                    Text("清空后保存可移除此行情源的凭据。")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if savedKey == nil { Button("重试读取", action: load) }
            }
        }
        .task { load() }
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
