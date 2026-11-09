import SwiftUI

private let investmentCardInset: CGFloat = 15
private let investmentCardRadius: CGFloat = 14

enum InvestmentRoute {
    case settings
    case asset(UUID, UUID), trade(UUID, UUID, InvestmentEventKind), quote(UUID)
}

struct InvestmentView: View {
    private enum Tab: String, CaseIterable {
        case overview = "总览", accounts = "账户", watch = "关注", balance = "资产负债"

        var symbol: String {
            switch self {
            case .overview: "chart.line.uptrend.xyaxis"
            case .accounts: "wallet.bifold"
            case .watch: "star"
            case .balance: "scalemass"
            }
        }
    }

    @StateObject private var store = InvestmentStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.overview
    @State private var selectedAccount: UUID?
    @State private var showsSettings = false
    @State private var showsWatchEditor = false
    @State private var showsBalanceAccounts = false
    @State private var hidesBalances = false

    var body: some View {
        VStack(spacing: 0) {
            if tab == .balance { balanceHeader }
            else { header }
            if let error = store.loadError {
                InvestmentScroll {
                    Text(error)
                    Button("重试") { store.load() }.buttonStyle(HakoActionButtonStyle())
                    Button("打开设置") { showsSettings = true }.buttonStyle(HakoActionButtonStyle(primary: false))
                }
            } else {
                switch tab {
                case .overview:
                    InvestmentOverview(book: store.book) { id in selectedAccount = id; tab = .accounts }
                        .refreshable { await store.refresh() }
                case .accounts: accounts
                case .watch: watch
                case .balance:
                    InvestmentBalanceView(store: store, hidesAmounts: $hidesBalances)
                        .refreshable { await store.refresh() }
                }
            }
        }
        .background(HakoStyle.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HakoStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }.accessibilityLabel("投资记账设置")
            }
        }
        .navigationDestination(isPresented: $showsSettings) {
            InvestmentDestination(store: store, route: .settings)
        }
        .navigationDestination(isPresented: $showsBalanceAccounts) {
            InvestmentBalanceAccountsView(store: store, hidesAmounts: hidesBalances)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            store.load()
            store.settleDuePlans()
            await store.refreshIfNeeded()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                await store.refreshIfNeeded()
            }
        }
        .onChange(of: store.refreshing ? nil : store.rateCurrencies) { _, currencies in
            guard scenePhase == .active, currencies != nil else { return }
            Task { await store.refreshIfNeeded() }
        }
        .onChange(of: store.refreshing ? nil : store.publicQuoteIDs) { _, assets in
            guard scenePhase == .active, let assets, !assets.isEmpty else { return }
            Task { await store.refreshIfNeeded() }
        }
        .onChange(of: store.book.accounts.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selectedAccount }) { selectedAccount = ids.first }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("投资记账").font(.system(size: 28, weight: .bold)).tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(store.configured ? Color.teal : HakoStyle.muted).frame(width: 5, height: 5).padding(.top, 5)
                Text(store.quoteStatus.isEmpty ? (store.configured ? "日线与基金净值 · 自动切换行情源" : "行情未配置 · 支持手动报价") : store.quoteStatus)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 21))
                        Text(item.rawValue).font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                    }
                    .foregroundStyle(tab == item ? HakoStyle.text : HakoStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12).padding(.top, 5)
        .background(HakoStyle.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider() }
    }

    private var balanceHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("投资记账").font(.caption).foregroundStyle(.secondary)
                Text("资产负债").font(.title.bold()).tracking(-0.7)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            Button {
                showsBalanceAccounts = true
            } label: {
                Label("更新余额", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(InvestmentBalanceStyle.accent)
            .disabled(store.loadError != nil)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 2)
    }

    @ViewBuilder private var accounts: some View {
        if let selectedAccount, let account = store.book.account(selectedAccount) {
            accountTabs(selectedAccount)
            InvestmentAccountView(store: store, account: account).id(account.id)
                .refreshable { await store.refresh() }
        } else {
            InvestmentScroll {
                ContentUnavailableView("暂无投资账户", systemImage: "wallet.bifold",
                                       description: Text("在投资记账设置中添加账户。"))
            }
        }
    }

    private func accountTabs(_ selected: UUID) -> some View {
        let accounts = store.book.accounts
        let tabs = HakoUnderlineTabs(title: "资产账户", options: accounts.map(\.id),
                                    selection: Binding(get: { selected }, set: { selectedAccount = $0 })) { id in
            guard let item = store.book.account(id) else { return "" }
            var name = item.name
            if item.currency == .hkd {
                name += " " + item.currency.rawValue
            } else if item.currency == .cny && accounts.contains(where: { $0.name == item.name && $0.currency == .usd }) {
                name += " " + item.currency.title
            }
            if accounts.contains(where: { $0.id != id && $0.name == item.name && $0.currency == item.currency }) {
                return name + " " + item.type.rawValue
            }
            return name
        }
        return Group {
            if accounts.count > 3 {
                ScrollView(.horizontal) { tabs.frame(minWidth: CGFloat(accounts.count) * 96) }
                    .scrollIndicators(.hidden)
            } else { tabs }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 20) }
    }

    private var watch: some View {
        InvestmentScroll {
            HStack {
                Text("关注列表").font(.headline)
                Spacer()
                Button { showsWatchEditor = true } label: { Label("添加关注", systemImage: "plus") }
                    .font(.subheadline)
            }
            ForEach(store.book.watched, id: \.self) { id in
                if let asset = store.book.asset(id) {
                    InvestmentLink(route: .quote(id)) {
                        watchRow(asset)
                    }.buttonStyle(.plain)
                }
            }
            if store.book.watched.isEmpty {
                ContentUnavailableView("暂无关注标的", systemImage: "star",
                                       description: Text("搜索标的并添加关注后，可查看报价和各周期涨跌幅。"))
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showsWatchEditor) {
            InvestmentAssetEditor(store: store, accountID: nil)
        }
    }

    private func watchRow(_ asset: InvestmentAsset) -> some View {
        let latest = store.book.quote(asset.id)
        return InvestmentCard {
            HStack {
                InvestmentTitle(asset.name, subtitle: asset.code + " · " + asset.kindLabel)
                Spacer()
                if let latest {
                    VStack(alignment: .trailing) {
                        Text(InvestmentText.price(latest.price, asset.currency)).monospacedDigit()
                        Text(InvestmentText.quoteDetail(latest)).font(.caption2).foregroundStyle(.secondary)
                    }
                } else { Text("待报价").font(.caption).foregroundStyle(.secondary) }
                InvestmentChevron()
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(InvestmentRange.watch) { range in
                    let base = latest.flatMap { quote in
                        store.book.quote(asset.id, on: range.start(from: quote.day, earliest: nil))
                    }
                    let change = latest.flatMap { quote in base.map { quote.price / $0.price - 1 } }
                    VStack(spacing: 4) {
                        Text(range.rawValue).foregroundStyle(.secondary)
                        Text(InvestmentText.percent(change)).foregroundStyle(InvestmentText.tint(change))
                            .monospacedDigit().minimumScaleFactor(0.72)
                    }.font(.caption2).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct InvestmentAccountView: View {
    private enum AccountSheet: Hashable, Identifiable {
        case cash(InvestmentEventKind), transfer, history, plans, addAsset
        var id: Self { self }
    }

    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    @State private var sheet: AccountSheet?
    @State private var cashExpanded = false
    private var book: InvestmentBook { store.book }

    var body: some View {
        InvestmentScroll {
            if let ledger = try? book.ledger(account) {
                summary(ledger)
                cash(ledger)
                holdings(ledger)
            } else {
                Text("无法读取该账户的流水。").foregroundStyle(.secondary)
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .cash(let kind): InvestmentCashEditor(store: store, account: account, kind: kind)
            case .transfer: InvestmentTransferEditor(store: store, account: account)
            case .history: InvestmentCashHistory(book: store.book, account: account)
            case .plans: InvestmentPlansView(store: store, selectedAccount: account.id)
            case .addAsset: InvestmentAssetEditor(store: store, accountID: account.id)
            }
        }
    }

    private func summary(_ ledger: InvestmentLedger) -> some View {
        let valuation = book.value(account)
        let currencies: [InvestmentCurrency] = switch account.currency {
        case .cny: [.usd]
        case .usd: [.cny]
        case .hkd: [.cny, .usd]
        }
        return InvestmentCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text("账户总资产")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, investmentCardInset)
                    Spacer(minLength: 0)
                    Text(account.type.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12),
                                    in: UnevenRoundedRectangle(bottomLeadingRadius: 10, topTrailingRadius: investmentCardRadius))
                }
                .padding(.top, -investmentCardInset)
                .padding(.trailing, -investmentCardInset)
                Text(InvestmentText.money(valuation?.value, account.currency))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                ForEach(currencies) { currency in
                    let amount = valuation.flatMap { book.convert($0.value, from: account.currency, to: currency) }
                    Text("折合" + currency.title + " · " + InvestmentText.money(amount, currency))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }.accessibilityElement(children: .combine)
            HStack {
                InvestmentMetric(title: "历史总盈亏", value: InvestmentText.money(valuation?.gain, account.currency, signed: true),
                                 color: InvestmentText.tint(valuation?.gain))
                Spacer(minLength: 10)
                InvestmentMetric(title: "持仓估值", value: InvestmentText.money(valuation.map { $0.value - ledger.cash }, account.currency))
            }
        }
    }

    private func cash(_ ledger: InvestmentLedger) -> some View {
        let plans = book.plans.filter { $0.accountID == account.id && $0.enabled }
        let balance = InvestmentText.money(ledger.cash, account.currency)
        return InvestmentCard {
            DisclosureGroup(isExpanded: $cashExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("累计余额调整收益 " + InvestmentText.money(ledger.cashIncome, account.currency, signed: true))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        cashAction(.deposit, primary: true)
                        cashAction(.withdrawal)
                        cashAction(.adjustment)
                    }
                    Divider()
                    Button { sheet = .transfer } label: {
                        InvestmentPageRow(title: "划出资金", symbol: "arrow.left.arrow.right")
                    }.buttonStyle(.plain).disabled(book.accounts.count < 2)
                    Divider()
                    Button { sheet = .history } label: {
                        InvestmentPageRow(title: "现金流水", symbol: "list.bullet.rectangle")
                    }.buttonStyle(.plain)
                    Divider()
                    Button { sheet = .plans } label: {
                        InvestmentPageRow(title: "定投管理", symbol: "calendar.badge.clock",
                            subtitle: "当前账户 · 转入 \(plans.filter { $0.assetID == nil }.count) 项 · 买入 \(plans.filter { $0.assetID != nil }.count) 项")
                    }.buttonStyle(.plain)
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text("现金管理").font(.headline)
                    Spacer(minLength: 0)
                    Text(balance)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityLabel("现金余额 \(balance)")
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func cashAction(_ kind: InvestmentEventKind, primary: Bool = false) -> some View {
        Button { sheet = .cash(kind) } label: {
            Text(kind == .adjustment ? "调整余额" : kind.rawValue)
        }.buttonStyle(HakoActionButtonStyle(primary: primary))
    }

    private func holdings(_ ledger: InvestmentLedger) -> some View {
        let assets = ledger.positions.keys.compactMap { book.asset($0) }.sorted { $0.code < $1.code }
        return InvestmentCard {
            HStack {
                Text("持仓").font(.headline)
                Spacer()
                Button { sheet = .addAsset } label: { Label("录入资产", systemImage: "plus") }
                    .font(.subheadline)
            }
            if assets.isEmpty {
                Text("这个账户目前只有现金。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(assets) { asset in
                if let position = ledger.positions[asset.id] {
                    let value = book.positionValue(position, asset: asset)
                    let gain = value.map { $0 - position.netCost + position.realized }
                    InvestmentLink(route: .asset(account.id, asset.id)) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                let details = "\(asset.kindLabel) · \(InvestmentText.number(position.quantity)) \(asset.kind.unit)"
                                InvestmentTitle(asset.name, subtitle: asset.kind.isTermDeposit ? details : asset.code + " · " + details)
                                if let note = account.notes[asset.id], !note.isEmpty {
                                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(InvestmentText.money(value, account.currency)).font(.subheadline.weight(.semibold))
                                Text(InvestmentText.money(gain, account.currency, signed: true))
                                    .font(.caption).foregroundStyle(InvestmentText.tint(gain))
                            }.monospacedDigit()
                            InvestmentChevron()
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if asset.id != assets.last?.id { Divider() }
                }
            }
        }
    }
}

enum InvestmentText {
    static func number(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
    static func money(_ value: Decimal?, _ currency: InvestmentCurrency, signed: Bool = false) -> String {
        guard let value else { return "—" }
        let prefix = signed && value > 0 ? "+" : ""
        return prefix + value.formatted(.currency(code: currency.rawValue))
    }
    static func price(_ value: Decimal, _ currency: InvestmentCurrency) -> String {
        number(value) + " " + currency.rawValue
    }
    static func percent(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return (value > 0 ? "+" : "") + value.formatted(.percent.precision(.fractionLength(2)))
    }
    static func tint(_ value: Decimal?) -> Color {
        guard let value, value != 0 else { return .primary }
        return value > 0 ? HakoStyle.adaptive(0xac4841, 0xf6a199) : HakoStyle.adaptive(0x267669, 0x82c7b7)
    }
    static func date(_ date: Date) -> String {
        var format = Date.FormatStyle(date: .numeric, time: .omitted)
        format.timeZone = InvestmentBook.calendar.timeZone
        return date.formatted(format)
    }
    static func quoteDetail(_ quote: InvestmentQuote) -> String {
        [date(quote.day), quote.source].compactMap { $0 }.joined(separator: " · ")
    }
}

struct InvestmentScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(HakoStyle.background)
    }
}

struct InvestmentCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(investmentCardInset)
            .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: investmentCardRadius))
    }
}

struct InvestmentTitle: View {
    let title: String
    let subtitle: String
    init(_ title: String, subtitle: String = "") { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct InvestmentMetric: View {
    let title: String
    let value: String
    var color: Color = .primary
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(prominent ? .title2.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(color).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

struct InvestmentChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

struct InvestmentPageLink: View {
    let title: String
    let symbol: String
    var subtitle = ""
    let route: InvestmentRoute

    var body: some View {
        InvestmentLink(route: route) {
            InvestmentPageRow(title: title, symbol: symbol, subtitle: subtitle)
        }.buttonStyle(.plain)
    }
}

struct InvestmentPageRow: View {
    let title: String
    let symbol: String
    var subtitle = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).accessibilityHidden(true)
            InvestmentTitle(title, subtitle: subtitle)
            Spacer(minLength: 0)
            InvestmentChevron()
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}
