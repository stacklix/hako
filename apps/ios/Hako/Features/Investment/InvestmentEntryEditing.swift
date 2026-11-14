import Foundation

extension InvestmentAgentAction {
    var hasEntryEditor: Bool {
        switch kind {
        case .removeAccount, .removePosition, .deleteEvent, .removePlan, .deleteBalanceRecord,
             .archiveAccount, .restoreAccount, .refreshMarket, .rebuildSnapshots: false
        case .watch: text("enabled") != "false"
        default: true
        }
    }

    var deletesData: Bool {
        [.removeAccount, .removePosition, .deleteEvent, .removePlan, .deleteBalanceRecord].contains(kind)
    }
}

extension InvestmentAgentProposal {
    func assetSetupIndex(for index: Int) -> Int? {
        guard actions.indices.contains(index), [.addEvent, .watch, .plan].contains(actions[index].kind),
              let asset = try? actions[index].asset(in: book) else { return nil }
        let setup = actions.indices.first { candidate in
            guard candidate < index, actions[candidate].kind == .addAsset else { return false }
            let setup = actions[candidate]
            return asset.kind.isTermDeposit ? setup.text("name") == asset.name :
                setup.text("symbol")?.uppercased() == asset.code && (setup.text("market")?.uppercased() ?? "") == asset.market
                    && (!asset.kind.usesMargin || asset.contractSide == setup.text("side").flatMap { InvestmentAgentAction.sides[$0] })
        }
        guard let setup else { return nil }
        // A shared registration belongs to its first entry; later entries use the registered asset.
        guard !(setup + 1..<index).contains(where: { position in
            [.addEvent, .watch, .plan].contains(actions[position].kind)
                && (try? actions[position].resolvingPlan(in: book).asset(in: book).id) == asset.id
        }) else { return nil }
        return setup
    }

    var entryEditorIndices: [Int] {
        let attached = Set(actions.indices.flatMap { [assetSetupIndex(for: $0), entryQuoteIndex(for: $0)].compactMap { $0 } })
        return actions.indices.filter { actions[$0].hasEntryEditor && !attached.contains($0) }
    }

    func entryQuoteIndex(for index: Int) -> Int? {
        let next = index + 1
        guard actions.indices.contains(next), actions[index].kind == .addEvent,
              ["buy", "opening"].contains(actions[index].text("event_type")), assetSetupIndex(for: index) != nil,
              let asset = try? actions[index].asset(in: book), [.wealth, .insurance].contains(asset.kind),
              actions[next].kind == .quote, (try? actions[next].asset(in: book).id) == asset.id,
              actions[next].text("date") == InvestmentEditorDraft.day.string(from: InvestmentBook.day()) else { return nil }
        return next
    }
}

/// A native editor changes this pending operation. Only the preview's confirmation writes the ledger.
struct InvestmentEditorDraft {
    let proposal: InvestmentAgentProposal
    let index: Int
    let base: InvestmentBook
    let save: @MainActor ([InvestmentAgentAction]) async throws -> Void

    var action: InvestmentAgentAction { proposal.actions[index].resolvingPlan(in: proposal.book) }
    var setupIndex: Int? { proposal.assetSetupIndex(for: index) }
    var setup: InvestmentAgentAction? { setupIndex.map { proposal.actions[$0] } }
    var quoteIndex: Int? { proposal.entryQuoteIndex(for: index) }
    var asset: InvestmentAsset? {
        if action.kind != .addAsset { return try? action.asset(in: proposal.book) }
        return proposal.book.assets.values.first {
            $0.name == action.text("name") && ($0.kind.isTermDeposit ||
                ($0.code == action.text("symbol")?.uppercased() && $0.market == (action.text("market")?.uppercased() ?? "")))
        }
    }
    var account: InvestmentAccount? { action.text("account_id").flatMap(UUID.init(uuidString:)).flatMap(proposal.book.account) }
    var date: Date { action.text("date").flatMap(Self.day.date(from:)) ?? InvestmentBook.day() }
    static var day: DateFormatter { InvestmentBook.snapshotDateFormatter() }
    static func text(_ value: Decimal?) -> String { value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" }
    func value(_ key: String) -> String { action.values[key] ?? "" }
    func amount(_ key: String) -> String { Decimal(string: value(key)).map { Self.text(abs($0)) } ?? value(key) }

    /// Include preceding pending operations for field choices and balance calculations.
    func editingBook() throws -> InvestmentBook {
        var book = base
        for position in proposal.actions.indices where position < index && position != setupIndex {
            try proposal.actions[position].apply(to: &book)
        }
        var identifiers: [UUID: UUID] = [:]
        for asset in book.assets.values where base.asset(asset.id) == nil {
            let matches = proposal.book.assets.values.filter {
                ($0.kind.isTermDeposit ? $0.name == asset.name : $0.code == asset.code) && $0.market == asset.market && $0.kind == asset.kind && $0.currency == asset.currency
                    && $0.basis == asset.basis && $0.contractSide == asset.contractSide
                    && ($0.kind.isTermDeposit ? $0.name == asset.name : true)
            }
            if matches.count == 1, let match = matches.first { identifiers[asset.id] = match.id }
        }
        let oldAssets = book.assets
        for (old, new) in identifiers {
            book.assets.removeValue(forKey: old)
            var asset = oldAssets[old]
            asset?.id = new
            book.assets[new] = asset
            if let quotes = book.quotes.removeValue(forKey: old) { book.quotes[new] = quotes }
        }
        for id in book.assets.keys {
            if let collateral = book.assets[id]?.collateralAssetID, let new = identifiers[collateral] { book.assets[id]?.collateralAssetID = new }
        }
        for owner in book.accounts.indices {
            for event in book.accounts[owner].events.indices {
                if let id = book.accounts[owner].events[event].assetID, let new = identifiers[id] { book.accounts[owner].events[event].assetID = new }
            }
        }
        for plan in book.plans.indices {
            if let id = book.plans[plan].assetID, let new = identifiers[id] { book.plans[plan].assetID = new }
        }
        book.watched = book.watched.map { identifiers[$0] ?? $0 }
        return book
    }

    func reference(_ asset: InvestmentAsset) -> String {
        base.asset(asset.id) != nil ? asset.id.uuidString : asset.kind.isTermDeposit ? asset.name : asset.displayCode
    }

    func formEvent(in book: InvestmentBook) throws -> InvestmentEvent? {
        guard let account else { return nil }
        if action.kind == .editEvent {
            return book.account(account.id)?.events.first { $0.id.uuidString == action.text("event_id") }
        }
        guard action.kind == .addEvent else { return nil }
        let previous = Set(book.account(account.id)?.events.map(\.id) ?? [])
        var projected = book
        try action.apply(to: &projected)
        let kind = InvestmentAgentAction.eventKinds[value("event_type")]
        return projected.account(account.id)?.events.last { !previous.contains($0.id) && $0.kind == kind }
    }

    static func assetValues(_ asset: InvestmentAsset, in book: InvestmentBook) -> [String: String] {
        var values = ["name": asset.name, "symbol": asset.code, "market": asset.market, "currency": asset.currency.rawValue,
                      "asset_type": InvestmentAgentAction.assetKinds.first { $0.value == asset.kind }!.key,
                      "multiplier": text(asset.multiplier)]
        if let side = asset.contractSide { values["side"] = InvestmentAgentAction.sides.first { $0.value == side }?.key }
        if asset.kind == .cryptoContract { values["basis"] = InvestmentAgentAction.bases.first { $0.value == asset.basis }?.key }
        if let id = asset.collateralAssetID, let token = book.asset(id) { values["collateral_id"] = token.id.uuidString }
        if let token = asset.settlementStablecoin { values["stablecoin"] = token.rawValue }
        if let terms = asset.depositTerms {
            values["annual_rate"] = text(terms.annualRate * 100)
            values["maturity_date"] = day.string(from: terms.maturity)
        }
        return values
    }

    static func eventValues(_ event: InvestmentEvent) -> [String: String] {
        var values = ["date": day.string(from: event.day), "amount": text(abs(event.amount)),
                      "direction": event.amount < 0 ? "decrease" : "increase", "quantity": text(abs(event.quantity)),
                      "quantity_mode": "contracts", "price": text(event.price), "margin": text(event.margin),
                      "fee": text(event.fee), "settled_amount": text(event.settledAmount), "settlement_rate": text(event.settlementRate)]
        if let target = event.fundingTarget { values["funding_target"] = InvestmentAgentAction.fundingTargets.first { $0.value == target }?.key }
        if let flag = event.unallocatedFunding { values["unallocated"] = flag ? "true" : "false" }
        return values
    }

    func replacing(values: [String: String], selectedAsset: InvestmentAsset? = nil,
                   quote: Decimal? = nil) throws -> [InvestmentAgentAction] {
        guard action.hasEntryEditor else { throw InvestmentError.invalid("此操作不提供编辑表单，请在预览中确认或取消。") }
        var updated = action
        let allowed = Set(action.fields.map(\.key))
        updated.values.merge(values.filter { allowed.contains($0.key) }) { _, new in new }
        var replacement: [InvestmentAgentAction] = []
        let clearsPlanAsset = action.kind == .plan && updated.text("asset_id") == nil
        let keepsSetup: Bool
        if let original = asset,
           clearsPlanAsset || selectedAsset.map({ !original.matches($0) || (original.kind.isTermDeposit && original.name != $0.name) }) == true {
            keepsSetup = proposal.actions.indices.contains { position in
                position != index && position != setupIndex && position != quoteIndex && ["asset_id", "collateral_id"].contains { key in
                    (try? proposal.actions[position].asset(in: proposal.book, key: key).id) == original.id
                }
            }
        } else { keepsSetup = false }
        if let selectedAsset {
            var identity = Self.assetValues(selectedAsset, in: proposal.book)
            if let id = selectedAsset.collateralAssetID, let token = proposal.book.asset(id) { identity["collateral_id"] = reference(token) }
            if action.kind == .addAsset {
                updated.values = identity
            } else if action.kind == .editAsset {
                updated.values["name"] = selectedAsset.name
                if selectedAsset.kind.requiresCatalog {
                    updated.values["symbol"] = selectedAsset.code
                    updated.values["market"] = selectedAsset.market
                }
                if selectedAsset.kind.isTermDeposit {
                    updated.values["annual_rate"] = identity["annual_rate"]
                    updated.values["maturity_date"] = identity["maturity_date"]
                }
            } else {
                updated.values["asset_id"] = reference(selectedAsset)
                if try editingBook().asset(selectedAsset.id) == nil {
                    replacement.append(.init(kind: .addAsset, values: identity))
                }
            }
        }
        replacement.append(updated)
        if let quote, let selectedAsset {
            replacement.append(.init(kind: .quote, values: ["asset_id": reference(selectedAsset),
                "date": Self.day.string(from: InvestmentBook.day()), "price": Self.text(quote)]))
        }
        var actions: [InvestmentAgentAction] = []
        for position in proposal.actions.indices {
            if position == setupIndex, selectedAsset != nil || clearsPlanAsset, !keepsSetup { continue }
            if position == quoteIndex, selectedAsset != nil { continue }
            if position == index { actions += replacement }
            else { actions.append(proposal.actions[position]) }
        }
        return actions
    }

    @MainActor func submit(_ values: [String: String], asset: InvestmentAsset? = nil, quote: Decimal? = nil) async throws {
        try await save(replacing(values: values, selectedAsset: asset, quote: quote))
    }
}
