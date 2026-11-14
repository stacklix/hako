import SwiftUI

struct InvestmentBalanceAccountsView: View {
    enum Mode: Equatable { case update, composition }

    @ObservedObject var store: InvestmentStore
    let hidesAmounts: Bool
    var mode: Mode = .update
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
        let categories = InvestmentBalanceCategory.allCases.filter { category in
            mode == .update || (category == .investments ? !book.accounts.isEmpty : accounts.contains { $0.category == category })
        }
        InvestmentScroll {
            HStack(alignment: .top) {
                Text("账户余额（CNY）").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !feedback.isEmpty { Text(feedback).foregroundStyle(InvestmentBalanceStyle.accent) }
            }.font(.caption)
            if categories.isEmpty {
                ContentUnavailableView("暂无账户", systemImage: "list.bullet.rectangle")
            }
            ForEach(categories) { category in
                if category == .investments {
                    investments(book, total: snapshot.investment, today: today)
                } else {
                    manual(category, accounts: accounts.filter { $0.category == category },
                           total: snapshot.manual[category, default: 0], today: today)
                }
            }
        }
        .navigationTitle(mode == .update ? "更新余额" : "资产构成详情")
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
                if mode == .update {
                    Button {
                        edit = Edit(category: category, account: nil)
                    } label: {
                        Label("添加账户", systemImage: "plus").font(.caption.weight(.medium)).frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
                    .accessibilityLabel("添加" + category.rawValue + "账户")
                }
            }
            totalText(total)
            if accounts.isEmpty {
                Text("暂无账户。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                Divider()
                let amount = account.latest(on: today)?.amount
                if mode == .composition {
                    NavigationLink {
                        InvestmentBalanceAccountDetail(store: store, accountID: account.id, hidesAmounts: hidesAmounts)
                    } label: {
                        HStack(spacing: 8) {
                            accountRow(account.name, amount: amount)
                            InvestmentChevron()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        accountRow(account.name, amount: amount)
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

struct InvestmentBalanceAccountDetail: View {
    @ObservedObject var store: InvestmentStore
    let accountID: UUID
    let hidesAmounts: Bool
    @State private var showsUpdate = false
    @State private var editing: InvestmentBalanceChange?
    @State private var feedback = ""
    @State private var limit = 30

    var body: some View {
        let book = store.book
        let today = InvestmentBook.day()
        let account = book.balanceSheet?.accounts.first { $0.id == accountID }
        let changes = book.balanceChanges(through: today, limit: limit + 1, filter: .account(accountID))
        InvestmentScroll {
            if let account {
                summary(account, balance: account.latest(on: today))
                InvestmentBalanceAccountTrend(account: account, today: today, hidesAmounts: hidesAmounts)
                InvestmentCard {
                    Text("更新历史").font(.headline)
                    if changes.isEmpty {
                        Text("暂无余额记录。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(changes.prefix(limit)) { change in
                        Divider()
                        InvestmentBalanceChangeRow(change: change, showsDate: false, hidesAmounts: hidesAmounts,
                                                   showsAccount: false) { editing = change }
                    }
                    if changes.count > limit {
                        Button("显示更早记录") { limit += 30 }.buttonStyle(HakoActionButtonStyle(primary: false))
                    }
                }
            } else {
                ContentUnavailableView("找不到账户", systemImage: "wallet.bifold")
            }
        }
        .navigationTitle(account?.name ?? "账户详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsUpdate) {
            if let account {
                InvestmentBalanceAccountEditor(store: store, category: account.category, account: account,
                                               hidesAmounts: hidesAmounts) { feedback = $0 }
            }
        }
        .sheet(item: $editing) { change in
            InvestmentBalanceRecordEditor(store: store, change: change, hidesAmounts: hidesAmounts)
        }
    }

    private func summary(_ account: InvestmentBalanceAccount, balance: InvestmentBalanceRecord?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.category.rawValue)
                    Text("当前余额（元）")
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    showsUpdate = true
                } label: {
                    Label("更新余额", systemImage: "square.and.pencil")
                        .font(.caption.weight(.medium)).frame(minHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(InvestmentBalanceStyle.accent)
            }
            Text(InvestmentBalanceStyle.amount(balance?.amount, hidden: hidesAmounts))
                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55)
            if let balance {
                Text("记账日期 · " + InvestmentText.date(balance.recordedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(InvestmentBalanceStyle.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(InvestmentBalanceStyle.summary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct InvestmentBalanceAccountEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @State private var saving = false
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
         hidesAmounts: Bool, editing: InvestmentEditorDraft? = nil, onSaved: @escaping (String) -> Void) {
        self.store = store
        self.category = category
        self.account = account
        self.hidesAmounts = hidesAmounts
        self.onSaved = onSaved
        editorDraft = editing
        let previous = account?.records.last?.amount
        let initial = hidesAmounts ? "" : previous?.formatted(.number.grouping(.never)) ?? ""
        initialAmount = initial
        _amount = State(initialValue: editing?.action.text("amount") ?? initial)
        _name = State(initialValue: editing?.value("name") ?? "")
        let day = InvestmentBook.day()
        initialDay = day
        _recordDay = State(initialValue: editing?.date ?? day)
    }

    var body: some View {
        let editing = account != nil
        let title = editing ? "更新余额" : "添加账户"
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasChanges = !name.isEmpty || amount != initialAmount || recordDay != initialDay
        SettingsSheet(title: title, hasChanges: hasChanges,
                      isBusy: saving || store.saving, saveEnabled: !amount.isEmpty && (editing || hasName), onSave: { Task { await save() } },
                      detents: [.medium, .large], saveAccessibilityLabel: editorDraft != nil ? "完成修改并更新预览" : editing ? "保存余额" : "添加账户") {
            Form {
                Section {
                    if !editing {
                        InvestmentField("账户名称", text: $name, focusesOnRowTap: true)
                            .listRowBackground(HakoStyle.card)
                    }
                    InvestmentField(editing ? "更新后余额（元）" : "初始余额（元）", text: $amount,
                                    keyboard: .decimalPad, focusesOnRowTap: true)
                        .listRowBackground(HakoStyle.card)
                    InvestmentDatePicker("记账日期", selection: $recordDay, latest: InvestmentBook.day())
                        .listRowBackground(HakoStyle.card)
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
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let value = try investmentDecimal(amount, "余额", allowZero: true)
            if let editorDraft {
                try await editorDraft.submit(["name": name, "amount": InvestmentEditorDraft.text(value), "date": InvestmentEditorDraft.day.string(from: recordDay)])
                dismiss()
                return
            }
            var message = "已添加账户"
            try await store.update { book in
                var sheet = book.balanceSheet ?? InvestmentBalanceLedger()
                if let account {
                    let previous = sheet.accounts.first { $0.id == account.id }?.records.last?.amount
                    let day = InvestmentBook.day(recordDay)
                    try sheet.update(account.id, amount: value, at: day == InvestmentBook.day() ? .now : day)
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
    var showsAccount = true
    var onEdit: (() -> Void)? = nil

    var body: some View {
        if let onEdit, change.manualRecord != nil {
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InvestmentChevron()
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("编辑余额记录")
        } else {
            content
        }
    }

    private var content: some View {
        let source = change.category == .investments ? "月末快照" : change.category.rawValue
        let showsDateBelow = showsAccount && showsDate
        let difference = change.before.map { change.after - $0 }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Text(showsAccount ? change.name : InvestmentText.date(change.day)).font(.subheadline.weight(.medium))
                if showsAccount {
                    Spacer(minLength: 2)
                    if showsDateBelow {
                        if let difference { changeAmount(difference) }
                    } else {
                        Text(source).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(balanceDescription).foregroundStyle(.secondary)
                if showsDateBelow {
                    Spacer(minLength: 2)
                    Text(InvestmentBalanceStyle.shortDay(change.day) + " · " + source)
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let difference {
                    Spacer(minLength: 2)
                    changeAmount(difference)
                }
            }
        }
        .font(.caption).monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private var balanceDescription: String {
        let after = InvestmentBalanceStyle.amount(change.after, hidden: hidesAmounts)
        if let before = change.before {
            return InvestmentBalanceStyle.amount(before, hidden: hidesAmounts) + " → " + after
        }
        return (change.category == .investments ? "月末余额 " : "初始余额 ") + after
    }

    private func changeAmount(_ difference: Decimal) -> some View {
        Text(InvestmentBalanceStyle.amount(difference, hidden: hidesAmounts, signed: true))
            .fontWeight(.semibold)
            .foregroundStyle(InvestmentBalanceStyle.changeColor(difference, liability: change.category == .liabilities,
                                                                hidden: hidesAmounts))
    }
}

struct InvestmentBalanceHistory: View {
    @ObservedObject var store: InvestmentStore
    let hidesAmounts: Bool
    @State private var limit = 30
    @State private var filter = InvestmentBalanceHistoryFilter.all
    @State private var editing: InvestmentBalanceChange?

    var body: some View {
        let book = store.book
        let changes = book.balanceChanges(through: InvestmentBook.day(), limit: limit + 1, filter: filter)
        let groups = Dictionary(grouping: changes.prefix(limit), by: \.day)
        InvestmentScroll {
            InvestmentCard {
                Picker("账户筛选", selection: $filter) {
                    Text("全部账户").tag(InvestmentBalanceHistoryFilter.all)
                    ForEach(book.balanceSheet?.accounts ?? []) { account in
                        Text(account.name + " · " + account.category.rawValue)
                            .tag(InvestmentBalanceHistoryFilter.account(account.id))
                    }
                    if book.balanceSheet?.investmentSnapshots.isEmpty == false {
                        Text("投资理财 · 月末快照").tag(InvestmentBalanceHistoryFilter.investment)
                    }
                }
                .pickerStyle(.menu)
            }
            if groups.isEmpty {
                ContentUnavailableView("暂无更新记录", systemImage: "clock")
            }
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                InvestmentCard {
                    Text(InvestmentText.date(day)).font(.subheadline.weight(.semibold))
                    ForEach(groups[day] ?? []) { change in
                        Divider()
                        InvestmentBalanceChangeRow(change: change, showsDate: false, hidesAmounts: hidesAmounts) { editing = change }
                    }
                }
            }
            if changes.count > limit {
                Button("显示更早记录") { limit += 30 }.buttonStyle(HakoActionButtonStyle(primary: false))
            }
        }
        .navigationTitle("更新历史")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: filter) { limit = 30 }
        .sheet(item: $editing) { change in
            InvestmentBalanceRecordEditor(store: store, change: change, hidesAmounts: hidesAmounts)
        }
    }
}

struct InvestmentBalanceRecordEditor: View {
    var editorDraft: InvestmentEditorDraft? = nil
    @ObservedObject var store: InvestmentStore
    @Environment(\.dismiss) private var dismiss
    let change: InvestmentBalanceChange
    let hidesAmounts: Bool
    private let initialAmount: String
    @State private var date: Date
    @State private var amount: String
    @State private var saving = false
    @State private var confirmsDeletion = false
    @State private var error: String?

    init(store: InvestmentStore, change: InvestmentBalanceChange, hidesAmounts: Bool, editing: InvestmentEditorDraft? = nil) {
        self.store = store
        self.change = change
        self.hidesAmounts = hidesAmounts
        editorDraft = editing
        let initial = hidesAmounts ? "" : change.after.formatted(.number.grouping(.never))
        initialAmount = initial
        _amount = State(initialValue: editing?.action.text("amount") ?? initial)
        _date = State(initialValue: editing?.date ?? change.day)
    }

    var body: some View {
        let hasChanges = date != change.day || amount != initialAmount
        let hasAmount = !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        SettingsSheet(title: "编辑余额记录", hasChanges: hasChanges, isBusy: saving || store.saving,
                      saveEnabled: hasChanges && (hidesAmounts || hasAmount), onSave: {
            Task {
                await persist { ledger, accountID, original in
                    let value = hasAmount ? try investmentDecimal(amount, "余额", allowZero: true) : original.amount
                    try ledger.replaceRecord(original, accountID: accountID, amount: value, on: date)
                }
            }
        }, saveAccessibilityLabel: editorDraft == nil ? "保存余额记录" : "完成修改并更新预览") {
            Form {
                Section(change.name + " · " + change.category.rawValue) {
                    InvestmentDatePicker("记账日期", selection: $date, latest: InvestmentBook.day())
                    InvestmentField("变动后余额（元）", text: $amount, keyboard: .decimalPad, focusesOnRowTap: true)
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                if editorDraft == nil { Section {
                    HakoDeleteButton(title: "删除余额记录") { confirmsDeletion = true }
                        .investmentListRow()
                        .listRowBackground(Color.clear)
                } }
            }
            .disabled(saving || store.saving)
            .hakoDeleteConfirmation(Text("删除这笔余额记录？"), isPresented: $confirmsDeletion,
                                    message: Text("删除后，历史余额会按剩余记录重新显示。"),
                                    disabled: saving || store.saving) {
                Task {
                    await persist { ledger, accountID, original in
                        try ledger.deleteRecord(original, accountID: accountID)
                    }
                }
            }
        }
        .environment(\.investmentFieldPlaceholders, false)
    }

    private func persist(_ operation: (inout InvestmentBalanceLedger, UUID, InvestmentBalanceRecord) throws -> Void) async {
        guard !saving, let (accountID, record) = change.manualRecord else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let editorDraft {
                guard var ledger = store.book.balanceSheet else { throw InvestmentError.invalid("找不到资产负债账本。") }
                try operation(&ledger, accountID, record)
                guard let edited = ledger.accounts.first(where: { $0.id == accountID })?.records.first(where: { $0.id == record.id }) else {
                    throw InvestmentError.invalid("请通过删除预览确认删除记录。")
                }
                try await editorDraft.submit(["amount": InvestmentEditorDraft.text(edited.amount), "date": InvestmentEditorDraft.day.string(from: edited.recordedAt)])
                dismiss()
                return
            }
            try await store.update { book in
                guard var ledger = book.balanceSheet else { throw InvestmentError.invalid("找不到资产负债账本。") }
                try operation(&ledger, accountID, record)
                book.balanceSheet = ledger
            }
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
