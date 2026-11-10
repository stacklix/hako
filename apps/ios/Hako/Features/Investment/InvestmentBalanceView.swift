import SwiftUI

enum InvestmentBalanceStyle {
    static let accent = HakoStyle.adaptive(0x514298, 0xc5b7ff)
    static let summary = HakoStyle.adaptive(0xf0eef8, 0x2b2936)
    static let asset = HakoStyle.adaptive(0x307c69, 0x82cbb8)
    static let debt = HakoStyle.adaptive(0x737689, 0xa5a8bb)
    static let equity = HakoStyle.adaptive(0x4765ae, 0x9eafff)
    static let assetBackground = HakoStyle.adaptive(0xeaf4f1, 0x253a35)
    static let debtBackground = HakoStyle.adaptive(0xfaf0e6, 0x3b3029)
    static let equityBackground = HakoStyle.adaptive(0xefedfa, 0x333047)

    static func amount(_ value: Decimal?, hidden: Bool, signed: Bool = false) -> String {
        guard let value else { return "—" }
        guard !hidden else { return "••••" }
        let prefix = signed && value > 0 ? "+" : ""
        return prefix + value.formatted(.number.precision(.fractionLength(2)))
    }

    static func changeColor(_ change: Decimal?, liability: Bool, hidden: Bool) -> Color {
        guard let change, change != 0, !hidden else { return .secondary }
        let favorable = liability ? change < 0 : change > 0
        return favorable ? HakoStyle.adaptive(0x147557, 0x76cbae) : HakoStyle.adaptive(0xaa3846, 0xf78891)
    }

    static func compact(_ change: Decimal?, hidden: Bool) -> String {
        guard let change, !hidden else { return amount(change, hidden: hidden) }
        if change == 0 { return "无变化" }
        let sign = change > 0 ? "+" : "−"
        let magnitude = abs(change)
        if magnitude >= 10_000 {
            return sign + (magnitude / 10_000).formatted(.number.precision(.fractionLength(1))) + "万"
        }
        return sign + magnitude.formatted(.number.precision(.fractionLength(magnitude >= 1 ? 0 : 2)))
    }

    static func shortDay(_ day: Date) -> String {
        let parts = InvestmentBook.calendar.dateComponents([.month, .day], from: day)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }
}

extension InvestmentBalanceCategory {
    var color: Color {
        switch self {
        case .cash: InvestmentBalanceStyle.asset
        case .investments: HakoStyle.adaptive(0x7861c4, 0xb5a0ff)
        case .fixed: HakoStyle.adaptive(0x3978a2, 0x86bce0)
        case .receivables: HakoStyle.adaptive(0x9b681e, 0xd7a65e)
        case .liabilities: InvestmentBalanceStyle.debt
        }
    }
}

struct InvestmentBalanceView: View {
    @ObservedObject var store: InvestmentStore
    @Binding var hidesAmounts: Bool
    @State private var excludesFixed = false
    @State private var showsCalendar = false
    @State private var showsHistory = false
    @State private var editingBalanceRecord: InvestmentBalanceChange?

    var body: some View {
        let book = store.book
        let today = InvestmentBook.day()
        let changes = book.balanceChanges(through: today, limit: 5)
        let snapshot = book.balanceSnapshot(on: today, today: today, updatedAt: changes.first?.recordedAt)
        let debts = (book.balanceSheet?.accounts ?? []).filter {
            $0.category == .liabilities && ($0.latest(on: today)?.amount ?? 0) > 0
        }
        InvestmentScroll {
            summary(snapshot)
            comparisonPanel(snapshot, comparison: previousMonth(book, today: today))
            structure(snapshot, debts: debts)
            InvestmentBalanceTrend(book: book, today: today, hidesAmounts: hidesAmounts)
            history(changes)
        }
        .navigationDestination(isPresented: $showsCalendar) {
            InvestmentBalanceCalendar(store: store, hidesAmounts: hidesAmounts)
        }
        .navigationDestination(isPresented: $showsHistory) {
            InvestmentBalanceHistory(store: store, hidesAmounts: hidesAmounts)
        }
        .sheet(item: $editingBalanceRecord) { change in
            InvestmentBalanceRecordEditor(store: store, change: change, hidesAmounts: hidesAmounts)
        }
    }

    private func previousMonth(_ book: InvestmentBook, today: Date) -> (day: Date, snapshot: InvestmentBalanceSnapshot?) {
        let day = InvestmentBook.previousMonthEnd(before: today)
        let snapshot = book.balanceEarliest.flatMap { $0 <= day ? book.balanceSnapshot(on: day, today: today) : nil }
        return (day, snapshot)
    }

    private func summary(_ snapshot: InvestmentBalanceSnapshot) -> some View {
        let mainAmount = snapshot.assets.map { $0 - (excludesFixed ? snapshot.manual[.fixed, default: 0] : 0) }
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { summaryHeading; Spacer(minLength: 4); fixedToggle }
                VStack(alignment: .leading, spacing: 0) { summaryHeading; fixedToggle }
            }
            Text(InvestmentBalanceStyle.amount(mainAmount, hidden: hidesAmounts))
                .font(.largeTitle.weight(.semibold)).tracking(-0.8).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55)
            Group {
                if let updated = snapshot.updatedAt {
                    Text(InvestmentText.date(updated) + " 更新")
                } else {
                    Text("暂无更新")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                metric("净资产", snapshot.net)
                metric("总负债", snapshot.liabilities)
                InvestmentMetric(title: "负债率", value: ratio(snapshot.debtRatio), alignment: .trailing)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if snapshot.investment == nil {
                Text("部分持仓缺少报价或汇率，暂无法汇总全部资产。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(InvestmentBalanceStyle.summary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var summaryHeading: some View {
        HStack(spacing: 6) {
            Text("资产汇总").font(.headline)
            Text("元").font(.caption).foregroundStyle(.secondary)
            Button {
                hidesAmounts.toggle()
            } label: {
                Image(systemName: hidesAmounts ? "eye.slash" : "eye")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(InvestmentBalanceStyle.accent)
            .accessibilityLabel(hidesAmounts ? "显示金额" : "隐藏金额")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var fixedToggle: some View {
        Toggle(isOn: $excludesFixed) {
            Text("排除固定资产").font(.caption).foregroundStyle(.secondary)
        }
        .tint(InvestmentBalanceStyle.accent)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func metric(_ title: String, _ amount: Decimal?) -> some View {
        InvestmentMetric(title: title, value: InvestmentBalanceStyle.amount(amount, hidden: hidesAmounts))
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ratio(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return hidesAmounts ? "••••" : value.formatted(.percent.precision(.fractionLength(2)))
    }

    private func comparisonPanel(_ snapshot: InvestmentBalanceSnapshot,
                                 comparison: (day: Date, snapshot: InvestmentBalanceSnapshot?)) -> some View {
        let previous = comparison.snapshot
        let changes = InvestmentBalanceCategory.allCases.map { category in
            difference(snapshot.amount(category), previous?.amount(category))
        }
        let maximum = changes.compactMap { $0.map(abs) }.max() ?? 0
        return InvestmentCard {
            HStack {
                Text("较上月底").font(.headline)
                Text(InvestmentBalanceStyle.shortDay(comparison.day))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    showsCalendar = true
                } label: {
                    HStack(spacing: 4) { Text("资产月历"); InvestmentChevron() }
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 34)
                }
                .buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
            }
            HStack {
                changeMetric("总资产", difference(snapshot.assets, previous?.assets), liability: false)
                changeMetric("总负债", difference(snapshot.liabilities, previous?.liabilities), liability: true)
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(InvestmentBalanceCategory.allCases.enumerated()), id: \.element) { index, category in
                    changeCell(category, change: changes[index], maximum: maximum)
                }
            }
        }
    }

    private func difference(_ lhs: Decimal?, _ rhs: Decimal?) -> Decimal? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }

    private func changeMetric(_ title: String, _ change: Decimal?, liability: Bool) -> some View {
        InvestmentMetric(title: title, value: InvestmentBalanceStyle.amount(change, hidden: hidesAmounts, signed: true),
                         color: InvestmentBalanceStyle.changeColor(change, liability: liability, hidden: hidesAmounts))
            .lineLimit(1).minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeCell(_ category: InvestmentBalanceCategory, change: Decimal?, maximum: Decimal) -> some View {
        let proportion = hidesAmounts || maximum == 0 ? 0 : NSDecimalNumber(decimal: abs(change ?? 0) / maximum).doubleValue
        return VStack(spacing: 4) {
            Text(InvestmentBalanceStyle.compact(change, hidden: hidesAmounts))
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(InvestmentBalanceStyle.changeColor(change, liability: category == .liabilities, hidden: hidesAmounts))
            GeometryReader { proxy in
                Capsule().fill(HakoStyle.line)
                    .overlay(alignment: .leading) { Capsule().fill(category.color).frame(width: proxy.size.width * proportion) }
            }.frame(height: 3).accessibilityHidden(true)
            Text(category.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.rawValue + "变动 " + InvestmentBalanceStyle.amount(change, hidden: hidesAmounts, signed: true))
    }

    private func structure(_ snapshot: InvestmentBalanceSnapshot, debts: [InvestmentBalanceAccount]) -> some View {
        let activeDebtCount = debts.count + (snapshot.investmentDeficit > 0 ? 1 : 0)
        let hasDebt = activeDebtCount > 0
        let hasEquity = snapshot.net.map { $0 != 0 } ?? false
        let assets = InvestmentBalanceCategory.assets.filter { category in
            snapshot.amount(category).map { $0 != 0 } ?? false
        }
        let manualAccounts = Dictionary(grouping: store.book.balanceSheet?.accounts ?? [], by: \.category)
        return InvestmentCard {
            HStack {
                Text("资产构成").font(.headline)
                Spacer(minLength: 4)
                NavigationLink {
                    InvestmentBalanceAccountsView(store: store, hidesAmounts: hidesAmounts, mode: .composition)
                } label: {
                    HStack(spacing: 4) { Text("查看详情"); InvestmentChevron() }
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
                .accessibilityLabel("查看资产构成详情")
            }
            HStack(spacing: 5) {
                equationMetric("总资产", snapshot.assets, background: InvestmentBalanceStyle.assetBackground)
                Text("=").foregroundStyle(.secondary)
                if hasDebt {
                    equationMetric("总负债", snapshot.liabilities, background: InvestmentBalanceStyle.debtBackground)
                }
                if hasEquity || !hasDebt || snapshot.net == nil {
                    if hasDebt { Text("+").foregroundStyle(.secondary) }
                    equationMetric("净资产", snapshot.net, background: InvestmentBalanceStyle.equityBackground)
                }
            }
            if let assets = snapshot.assets, assets > 0 || snapshot.liabilities > 0 {
                InvestmentBalanceSankey(snapshot: snapshot, debtCount: activeDebtCount)
            } else {
                Text(snapshot.assets == nil ? "估值完整后可查看资产构成。" : "记录余额后可查看资产构成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                if !assets.isEmpty {
                    bucket("资产（元）", background: InvestmentBalanceStyle.assetBackground) {
                        ForEach(assets) { category in
                            let hint = category == .investments
                                ? (snapshot.investmentDeficit > 0 ? "负值计入负债" : "来自投资记账 · 只读") : nil
                            if let accounts = manualAccounts[category], accounts.count == 1, let account = accounts.first {
                                accountLink(account, name: category.rawValue, amount: snapshot.amount(category))
                            } else {
                                detail(category.rawValue, snapshot.amount(category), color: category.color, hint: hint)
                            }
                        }
                    }
                }
                if hasDebt || hasEquity {
                    VStack(spacing: 8) {
                        if hasDebt {
                            bucket("负债（元）", background: InvestmentBalanceStyle.debtBackground) {
                                ForEach(debts) { account in
                                    accountLink(account, name: account.name, amount: account.latest(on: snapshot.day)?.amount)
                                }
                                if snapshot.investmentDeficit > 0 {
                                    detail("投资账户缺口", snapshot.investmentDeficit, color: InvestmentBalanceStyle.debt)
                                }
                            }
                        }
                        if hasEquity {
                            bucket("所有者权益（元）", background: InvestmentBalanceStyle.equityBackground) {
                                detail("净资产", snapshot.net, color: InvestmentBalanceStyle.equity)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func accountLink(_ account: InvestmentBalanceAccount, name: String, amount: Decimal?) -> some View {
        NavigationLink {
            InvestmentBalanceAccountDetail(store: store, accountID: account.id, hidesAmounts: hidesAmounts)
        } label: {
            detail(name, amount, color: account.category.color, showsChevron: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看" + account.name + "详情")
    }

    private func equationMetric(_ title: String, _ amount: Decimal?, background: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(InvestmentBalanceStyle.amount(amount, hidden: hidesAmounts))
                .font(.caption.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7).padding(.horizontal, 3)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func bucket<Content: View>(_ title: String, background: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 9))
    }

    private func detail(_ name: String, _ amount: Decimal?, color: Color, hint: String? = nil, showsChevron: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(name).font(.caption)
                    }
                    Text(InvestmentBalanceStyle.amount(amount, hidden: hidesAmounts))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    if let hint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron { InvestmentChevron() }
            }
        }.accessibilityElement(children: .combine)
    }

    private func history(_ changes: [InvestmentBalanceChange]) -> some View {
        InvestmentCard {
            HStack {
                Text("更新历史").font(.headline)
                Spacer()
                Button {
                    showsHistory = true
                } label: {
                    HStack(spacing: 4) { Text("查看全部"); InvestmentChevron() }
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 34)
                }
                .buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
            }
            if changes.isEmpty {
                Text("暂无更新记录。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(changes) { change in
                Divider()
                InvestmentBalanceChangeRow(change: change, showsDate: true, hidesAmounts: hidesAmounts) { editingBalanceRecord = change }
            }
        }
    }
}
