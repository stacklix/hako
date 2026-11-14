import SwiftUI

struct InvestmentAgentEditSheet: View {
    private struct Selection: Identifiable { let id: Int }
    let proposal: InvestmentAgentProposal
    let store: InvestmentStore
    let save: @MainActor ([InvestmentAgentAction]) async throws -> Void
    @State private var selection: Selection?

    var body: some View {
        let indices = proposal.entryEditorIndices
        Group {
            if let index = indices.first, indices.count == 1 {
                editor(index)
            } else {
                SettingsSheet(title: "选择要修改的内容") {
                    Form {
                        ForEach(indices, id: \.self) { index in
                            Button { selection = .init(id: index) } label: {
                                InvestmentTitle(proposal.actions[index].form(in: proposal.book).title,
                                    subtitle: (try? proposal.actions[index].asset(in: proposal.book))?.displayCode ?? "修改后返回预览")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).investmentListRow()
                        }
                    }
                }
            }
        }
        .sheet(item: $selection) { editor($0.id) }
    }

    private func editor(_ index: Int) -> AnyView {
        do {
            let draft = InvestmentEditorDraft(proposal: proposal, index: index, base: store.book, save: save)
            return AnyView(try InvestmentAgentNativeEditor(source: store, draft: draft))
        } catch {
            return AnyView(SettingsSheet(title: "无法修改草稿") {
                Text(error.localizedDescription).padding()
            })
        }
    }
}

private struct InvestmentAgentNativeEditor: View {
    @StateObject private var store: InvestmentStore
    let draft: InvestmentEditorDraft

    init(source: InvestmentStore, draft: InvestmentEditorDraft) throws {
        self.draft = draft
        let book = try draft.editingBook()
        _store = StateObject(wrappedValue: source.entryEditorStore(book: book))
    }

    var body: some View {
        content.environment(\.investmentEditingDraft, true)
    }

    @ViewBuilder private var content: some View {
        switch draft.action.kind {
        case .addAccount, .editAccount:
            InvestmentAccountEditor(store: store, editing: draft)
        case .transfer:
            if let account = account { InvestmentTransferEditor(store: store, editing: draft, account: account) }
            else { unavailable }
        case .cashBalance:
            if let account = account { InvestmentCashEditor(store: store, editing: draft, account: account, kind: .adjustment) }
            else { unavailable }
        case .distribution, .spotBalance:
            if let account = account, let asset = draft.asset {
                InvestmentHoldingAdjustmentEditor(store: store, editing: draft, account: account, asset: asset)
            } else { unavailable }
        case .fundingBalance:
            if let account = account, let asset = draft.asset {
                InvestmentFundingAdjustmentEditor(store: store, editing: draft, account: account, asset: asset)
            } else { unavailable }
        case .addAsset, .editAsset:
            if let asset = draft.asset {
                if draft.action.kind == .editAsset, asset.kind.isTermDeposit,
                   let account = store.book.accounts.first(where: { $0.events.contains { $0.assetID == asset.id } }) {
                    InvestmentDepositTermsEditor(store: store, editing: draft, accountID: account.id,
                                                 asset: store.book.asset(asset.id) ?? asset)
                } else {
                    InvestmentAssetInfoEditor(store: store, asset: asset, editing: draft)
                }
            } else { unavailable }
        case .watch:
            if let asset = draft.asset { InvestmentAssetEditor(store: store, editing: draft, asset: asset) }
            else { unavailable }
        case .addEvent:
            newEvent
        case .editEvent:
            if let account = account, let event = try? draft.formEvent(in: store.book) {
                InvestmentEventEditor(store: store, accountID: account.id, event: event, editing: draft)
            } else { unavailable }
        case .plan:
            if let account = account { InvestmentPlanEditor(store: store, editing: draft, account: account) }
            else { unavailable }
        case .quote:
            if let asset = draft.asset { InvestmentQuoteEditor(store: store, editing: draft, asset: asset) }
            else { unavailable }
        case .balanceAccount, .balanceRecord:
            if let account = balanceAccount {
                InvestmentBalanceAccountEditor(store: store, category: account.category, account: account,
                    hidesAmounts: false, editing: draft, onSaved: { _ in })
            } else if draft.action.kind == .balanceAccount,
                      let category = InvestmentAgentAction.balanceCategories[draft.value("category")] {
                InvestmentBalanceAccountEditor(store: store, category: category, account: nil,
                    hidesAmounts: false, editing: draft, onSaved: { _ in })
            } else { unavailable }
        case .editBalanceRecord:
            if let account = balanceAccount, let record = account.records.first(where: { $0.id.uuidString == draft.value("record_id") }) {
                InvestmentBalanceRecordEditor(store: store,
                    change: .init(id: .manual(accountID: account.id, recordID: record.id), name: account.name,
                        category: account.category, recordedAt: record.recordedAt, before: nil, after: record.amount),
                    hidesAmounts: false, editing: draft)
            } else { unavailable }
        case .removeAccount, .removePosition, .deleteEvent, .removePlan, .deleteBalanceRecord,
             .archiveAccount, .restoreAccount, .refreshMarket, .rebuildSnapshots:
            unavailable
        }
    }

    @ViewBuilder private var newEvent: some View {
        if let account = account, let kind = InvestmentAgentAction.eventKinds[draft.value("event_type")] {
            if let asset = draft.asset {
                if [.buy, .opening].contains(kind), draft.setup != nil {
                    InvestmentAssetEditor(store: store, editing: draft, asset: asset)
                } else if [.buy, .sell, .opening, .income].contains(kind) || (asset.kind.isTermDeposit && kind == .adjustment) {
                    InvestmentTradeEditor(store: store, editing: draft, account: account, asset: asset, kind: kind)
                } else if kind == .marginTransfer {
                    InvestmentMarginTransferEditor(store: store, editing: draft, account: account, asset: asset)
                } else if kind == .derivativeSettlement {
                    InvestmentFuturesSettlementEditor(store: store, editing: draft, account: account, asset: asset)
                } else { eventFields(account: account) }
            } else if kind == .deposit || kind == .withdrawal {
                InvestmentCashEditor(store: store, editing: draft, account: account, kind: kind)
            } else { eventFields(account: account) }
        } else { unavailable }
    }

    @ViewBuilder private func eventFields(account: InvestmentAccount) -> some View {
        if let event = try? draft.formEvent(in: store.book) {
            InvestmentEventEditor(store: store, accountID: account.id, event: event, editing: draft)
        } else { unavailable }
    }

    private var account: InvestmentAccount? { draft.account.flatMap { store.book.account($0.id) } }

    private var balanceAccount: InvestmentBalanceAccount? {
        store.book.balanceSheet?.accounts.first { $0.id.uuidString == draft.value("balance_account_id") }
    }

    private var unavailable: some View {
        SettingsSheet(title: "无法修改草稿") {
            Text("对应账户或标的已变化，请返回对话重新生成预览。").padding()
        }
    }
}
