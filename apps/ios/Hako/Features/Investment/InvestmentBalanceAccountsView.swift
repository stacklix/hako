import SwiftUI

struct InvestmentBalanceAccountsView: View {
    @ObservedObject var store: InvestmentStore
    let hidesAmounts: Bool
    @State private var edit: Edit?
    @State private var feedback = ""

    private struct Edit: Identifiable {
        let id = UUID()
        let category: InvestmentBalanceCategory
        let account: InvestmentBalanceAccount?
    }

    var body: some View {
        let book = store.book
        let today = InvestmentBook.day()
        let snapshot = book.balanceSnapshot(on: today, today: today)
        let accounts = book.balanceSheet?.accounts ?? []
        InvestmentScroll {
            HStack(alignment: .top) {
                Text("账户余额（CNY）").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !feedback.isEmpty { Text(feedback).foregroundStyle(InvestmentBalanceStyle.accent) }
            }.font(.caption)
            ForEach(InvestmentBalanceCategory.allCases) { category in
                if category == .investments {
                    investments(book, total: snapshot.investment, today: today)
                } else {
                    manual(category, accounts: accounts.filter { $0.category == category },
                           total: snapshot.manual[category, default: 0], today: today)
                }
            }
        }
        .navigationTitle("更新余额")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $edit) { route in
            InvestmentBalanceAccountEditor(store: store, category: route.category, account: route.account,
                                           hidesAmounts: hidesAmounts) { feedback = $0 }
        }
    }

    private func investments(_ book: InvestmentBook, total: Decimal?, today: Date) -> some View {
        InvestmentCard {
            HStack {
                Text("投资理财").font(.headline)
                Spacer(minLength: 4)
                Text("来自投资记账 · 只读").font(.caption).foregroundStyle(.secondary)
            }
            totalText(total)
            if book.accounts.isEmpty {
                Text("暂无投资账户。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(book.accounts) { account in
                Divider()
                accountRow(account.name, amount: book.investmentBalance(account, on: today))
                    .accessibilityElement(children: .combine)
            }
            if total == nil {
                Text("部分持仓缺少报价或汇率。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func manual(_ category: InvestmentBalanceCategory, accounts: [InvestmentBalanceAccount],
                        total: Decimal, today: Date) -> some View {
        InvestmentCard {
            HStack {
                Text(category.rawValue).font(.headline)
                Spacer(minLength: 4)
                Button {
                    edit = Edit(category: category, account: nil)
                } label: {
                    Label("添加账户", systemImage: "plus").font(.caption.weight(.medium)).frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
                .accessibilityLabel("添加" + category.rawValue + "账户")
            }
            totalText(total)
            if accounts.isEmpty {
                Text("暂无账户。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                Divider()
                HStack(spacing: 8) {
                    accountRow(account.name, amount: account.latest(on: today)?.amount)
                    Button {
                        edit = Edit(category: category, account: account)
                    } label: {
                        Text("更新").font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
                    .accessibilityLabel("更新" + account.name + "余额")
                }
            }
        }
    }

    private func totalText(_ value: Decimal?) -> some View {
        Text("合计 " + InvestmentBalanceStyle.amount(value, hidden: hidesAmounts))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func accountRow(_ name: String, amount: Decimal?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.subheadline)
            Spacer(minLength: 0)
            Text(InvestmentBalanceStyle.amount(amount, hidden: hidesAmounts))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(minHeight: 32)
    }
}

private struct InvestmentBalanceAccountEditor: View {
    @ObservedObject var store: InvestmentStore
    @Environment(\.dismiss) private var dismiss
    let category: InvestmentBalanceCategory
    let account: InvestmentBalanceAccount?
    let hidesAmounts: Bool
    let onSaved: (String) -> Void
    private let initialAmount: String
    private let initialDay: Date
    @State private var name = ""
    @State private var amount: String
    @State private var recordDay: Date
    @State private var error: String?

    init(store: InvestmentStore, category: InvestmentBalanceCategory, account: InvestmentBalanceAccount?,
         hidesAmounts: Bool, onSaved: @escaping (String) -> Void) {
        self.store = store
        self.category = category
        self.account = account
        self.hidesAmounts = hidesAmounts
        self.onSaved = onSaved
        let previous = account?.records.last?.amount
        let initial = hidesAmounts ? "" : previous?.formatted(.number.grouping(.never)) ?? ""
        initialAmount = initial
        _amount = State(initialValue: initial)
        let day = InvestmentBook.day()
        initialDay = day
        _recordDay = State(initialValue: day)
    }

    var body: some View {
        let editing = account != nil
        let title = editing ? "更新余额" : "添加账户"
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasChanges = !name.isEmpty || amount != initialAmount || (!editing && recordDay != initialDay)
        SettingsSheet(title: title, hasChanges: hasChanges,
                      isBusy: store.saving, saveEnabled: !amount.isEmpty && (editing || hasName), onSave: { Task { await save() } },
                      detents: [.medium, .large], saveAccessibilityLabel: editing ? "保存余额" : "添加账户") {
            Form {
                Section {
                    if !editing {
                        InvestmentField("账户名称", text: $name, focusesOnRowTap: true)
                            .listRowBackground(HakoStyle.card)
                    }
                    InvestmentField(editing ? "更新后余额（元）" : "初始余额（元）", text: $amount,
                                    keyboard: .decimalPad, focusesOnRowTap: true)
                        .listRowBackground(HakoStyle.card)
                    if !editing {
                        DatePicker("记账日期", selection: $recordDay, in: ...InvestmentBook.day(), displayedComponents: .date)
                            .investmentListRow()
                            .listRowBackground(HakoStyle.card)
                    }
                    if editing {
                        let previous = account?.records.last?.amount
                        let next = try? investmentDecimal(amount, "余额", allowZero: true)
                        let change = previous.flatMap { old in next.map { $0 - old } }
                        LabeledContent("原余额", value: InvestmentBalanceStyle.amount(previous, hidden: hidesAmounts))
                            .monospacedDigit().investmentListRow()
                            .listRowBackground(HakoStyle.card)
                        LabeledContent("本次变动") {
                            Text(InvestmentBalanceStyle.amount(change, hidden: hidesAmounts, signed: true))
                                .monospacedDigit()
                                .foregroundStyle(InvestmentBalanceStyle.changeColor(change, liability: category == .liabilities, hidden: hidesAmounts))
                        }.investmentListRow()
                            .listRowBackground(HakoStyle.card)
                    }
                } header: {
                    Text(account?.name ?? category.rawValue)
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red).investmentListRow()
                            .listRowBackground(HakoStyle.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HakoStyle.background)
        }
        .presentationBackground(HakoStyle.background)
        .environment(\.calendar, InvestmentBook.calendar)
        .environment(\.timeZone, InvestmentBook.calendar.timeZone)
    }

    private func save() async {
        do {
            let value = try investmentDecimal(amount, "余额", allowZero: true)
            var message = "已添加账户"
            try await store.update { book in
                var sheet = book.balanceSheet ?? InvestmentBalanceLedger()
                if let account {
                    let previous = sheet.accounts.first { $0.id == account.id }?.records.last?.amount
                    try sheet.update(account.id, amount: value)
                    message = previous == value ? "余额无变化" : "已更新余额"
                } else {
                    let now = Date.now
                    let day = InvestmentBook.day(recordDay)
                    let recordedAt = day == InvestmentBook.day(now) ? now : day
                    try sheet.add(name, category: category, amount: value, at: recordedAt)
                }
                book.balanceSheet = sheet
            }
            onSaved(message)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct InvestmentBalanceChangeRow: View {
    let change: InvestmentBalanceChange
    let showsDate: Bool
    let hidesAmounts: Bool

    var body: some View {
        let source = change.category == .investments ? "月末快照" : change.category.rawValue
        let label = showsDate ? InvestmentBalanceStyle.shortDay(change.day) + " · " + source : source
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Text(change.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 2)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            if let before = change.before {
                let difference = change.after - before
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(InvestmentBalanceStyle.amount(before, hidden: hidesAmounts) + " → " +
                         InvestmentBalanceStyle.amount(change.after, hidden: hidesAmounts))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(InvestmentBalanceStyle.amount(difference, hidden: hidesAmounts, signed: true))
                        .fontWeight(.semibold)
                        .foregroundStyle(InvestmentBalanceStyle.changeColor(difference, liability: change.category == .liabilities,
                                                                            hidden: hidesAmounts))
                }
            } else {
                let prefix = change.category == .investments ? "月末余额 " : "初始余额 "
                Text(prefix + InvestmentBalanceStyle.amount(change.after, hidden: hidesAmounts)).foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

struct InvestmentBalanceHistory: View {
    @ObservedObject var store: InvestmentStore
    let hidesAmounts: Bool
    @State private var limit = 30

    var body: some View {
        let changes = store.book.balanceChanges(through: InvestmentBook.day(), limit: limit + 1)
        let groups = Dictionary(grouping: changes.prefix(limit), by: \.day)
        InvestmentScroll {
            if groups.isEmpty {
                ContentUnavailableView("暂无更新记录", systemImage: "clock")
            }
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                InvestmentCard {
                    Text(InvestmentText.date(day)).font(.subheadline.weight(.semibold))
                    ForEach(groups[day] ?? []) { change in
                        Divider()
                        InvestmentBalanceChangeRow(change: change, showsDate: false, hidesAmounts: hidesAmounts)
                    }
                }
            }
            if changes.count > limit {
                Button("显示更早记录") { limit += 30 }.buttonStyle(HakoActionButtonStyle(primary: false))
            }
        }
        .navigationTitle("更新历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}
