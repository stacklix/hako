import Foundation

@main
struct InvestmentBookTests {
    static func main() throws {
        try globalInstrumentIDsAndPrices()
        try finalizedExchangeRatesAreReused()
        try numericStoragePrecision()
        holdingsSortByMarketValue()
        try accountOrderSurvivesSaving()
        try fourPlacePricesSurviveStorage()
        try fractionalCryptoTradesSurviveStorage()
        try threePlaceQuantitiesSurviveStorage()
        try threePlaceSpotBalancesPreserveHistoricalPrecision()
        try serializedLedgerValidationBlocksInvalidWrites()
        cumulativePortfolioGainRate()
        try ledgerAndDilutedCost()
        try firstPurchaseRequiresCash()
        try purchasesCanAutomaticallyFundFullCashAmount()
        try insurancePurchasesPreserveExistingCashWhenAutomaticallyFunded()
        try tradingFeesAffectCashAndDilutedCost()
        try futuresFeesStaySeparateFromMargin()

        try stockDistributionsKeepPurchaseCost()
        try fundsAndETFsRecordCashDividends()
        try genericBalancesSeparateValuationFromCashFlows()
        try genericBalancesValidateAndReplayHistory()
        try spotBalanceAdjustmentsUseTokenQuantity()
        try plansUseCashInExecutionOrder()
        try planSchedulesRespectCalendarDays()
        try planPeriodsCatchUpOnceAndRoundTrip()
        try historicalPlansUseClosedPricesAndKeepCashFlows()
        try historicalShortcutRequestsStayWithinTenClosedDays()
        try shortcutIncludesSessionsAsSoonAsTheyClose()
        try currencyConversionRequiresQuote()
        try accountCurrencyRestrictsEntries()
        try stockConnectSettlesInRenminbi()
        try insuranceKeepsOnePolicyPosition()
        try insurancePremiumTitlesFollowPaymentOrder()
        try increasingPremiumUsesOnlyAdditionalCash()
        try renminbiInsuranceCountsCashValueAndRoundTrips()
        try insuranceWithdrawalsKeepPolicyAndMoveCash()
        try insuranceWithdrawalsAllowMissingValues()
        try insuranceDefaultsToZeroAndAuditsAllProblems()
        try typedAccountsFilterAssets()
        try fundWealthAccountsKeepBothKindsAndRoundTrip()
        try transfersMoveCashAsOneOperation()
        try depositsUseRecordedBalancesAndCashMovements()
        try balanceSheetKeepsDatedBalancesAndUsesInvestmentValuation()
        try balanceHistoryFiltersAndReplaysEditedRecords()
        try investmentHistoryRecordsOneFrozenSnapshotPerClosedMonth()
        try balanceTrendUsesEveryDailySnapshotBeforeFirstMonthClose()
        try balanceTrendKeepsMissingDaysAndManualBalances()
        try balanceTrendCarriesSnapshotsFromNovemberFirst()
        try balanceTrendStopsCarryAtNovemberFirst()
        try fundAndWealthHistoryTracksNetInvestment()
        try wealthUsesAmountsAndReportedBalances()
        try manualQuotesAreLimitedToInsurance()
        try holdingHistoryTracksQuantitiesAndAmounts()
        try dailyGainsCarryForwardMarketPrices()
        try firstServerSnapshotUsesZeroOpeningGain()
        try allAssetPricesCarryAcrossConsecutiveGaps()
        try portfolioHistoryMatchesIndividualValuations()
        try dailySnapshotsUseBeijingCloseAndDatedRates()
        try accountSnapshotsStartWithEachAccountsFirstEvent()
        try dailyExchangeRatesCarryForwardAcrossMissingDays()
        try deletedAndRecreatedHoldingsInvalidateSnapshotsWithoutCache()
        try changingHistoricalEntriesInvalidatesOnlyTheAffectedDays()
        try changingTransfersIsAtomic()
        try dailyQuotesReuseCachedMarketCloses()
        try serverRoundTripPreservesShortFuturesAndSnapshots()
        try archivesOnlyEmptyAccountsAndPreservesHistory()
        try deletesOnlyTheSelectedHoldingAndItsRecords()
        try deletesAccountsAndPairedTransfersAtomically()
        try deletesUnreferencedRegistrationsAndTheirQuotes()
        try deletionPreservesPlanReferences()
        print("Investment ledger checks passed")
    }

    static func holdingsSortByMarketValue() {
        var book = InvestmentBook()
        var ledger = InvestmentLedger()
        func holding(_ code: String, quantity: Decimal, price: Decimal?, market: String = "", currency: InvestmentCurrency = .cny) -> UUID {
            let asset = InvestmentAsset(name: code, code: code, market: market, kind: .stock, currency: currency)
            book.assets[asset.id] = asset
            ledger.positions[asset.id] = InvestmentPosition(quantity: quantity)
            if let price { book.addQuotes([.init(day: date(1), price: price)], assetID: asset.id) }
            return asset.id
        }
        let low = holding("159525.SZ", quantity: 100, price: 161)
        let medium = holding("159941.SZ", quantity: 100, price: 238)
        let high = holding("513500.SH", quantity: 100, price: 292)
        let connect = holding("00700.HK", quantity: 100, price: 320,
                              market: InvestmentAsset.stockConnectMarket, currency: .hkd)
        let missing = holding("000001.SZ", quantity: 100, price: nil)
        let zero = holding("000002.SZ", quantity: 0, price: nil)
        book.addExchangeRates([.init(day: date(1), price: Decimal(string: "0.9")!)], for: .hkd)
        precondition(book.sortedHoldingAssets(in: ledger, showsZeroPositions: false, on: date(1)).map(\.id)
            == [high, connect, medium, low, missing], "Sort by displayed value, including Stock Connect FX conversion; unknown values last")
        precondition(book.sortedHoldingAssets(in: ledger, showsZeroPositions: true, on: date(1)).map(\.id)
            == [high, connect, medium, low, zero, missing], "Known zero values precede missing values")
        book.addQuotes([.init(day: date(2), price: 400)], assetID: low)
        precondition(book.sortedHoldingAssets(in: ledger, showsZeroPositions: false, on: date(2)).first?.id == low,
                     "New quotes must update the ordering")
        let tied = holding("159524.SZ", quantity: 100, price: 238)
        precondition(book.sortedHoldingAssets(in: ledger, showsZeroPositions: false, on: date(1)).map(\.id)
            == [high, connect, tied, medium, low, missing], "Equal values have a stable code order")
    }

    static func cumulativePortfolioGainRate() {
        precondition(InvestmentValuation(value: 1200, gain: 200).gainRate == Decimal(string: "0.2"))
        precondition(InvestmentValuation(value: 800, gain: -200).gainRate == Decimal(string: "-0.2"))
        precondition(InvestmentValuation(value: 1000, gain: 0).gainRate == 0)
        precondition(InvestmentValuation(value: 0, gain: -1000).gainRate == -1)
        precondition(InvestmentValuation(value: 0, gain: 0).gainRate == nil)
        precondition(InvestmentValuation(value: 200, gain: 200).gainRate == nil)
        precondition(InvestmentValuation(value: 100, gain: 200).gainRate == nil)
    }

    static func numericStoragePrecision() throws {
        let cases: [(String, String, Bool)] = [
            ("461884.88406188735462735462735462735462", "461884.88", false),
            ("460997.5774186740512075540221536266206", "460997.58", false),
            ("7.123456789012345678", "7.1235", true),
            ("0.00123456", "0.0012", false), ("1.00123456", "1", false),
            ("-1.00123456", "-1", false), ("1.00496", "1", false),
            ("1.00999", "1.01", false), ("9.99999", "10", false),
            ("-12.345", "-12.35", false), ("0.00005", "0.0001", false),
            ("-0.000049", "0", false), ("9007199254740993.0001", "9007199254740993", false)
        ]
        for (raw, expected, fx) in cases {
            let input = Decimal(string: raw)!
            precondition(InvestmentPrecision.string(input, exchangeRate: fx) == expected, raw)
            let output = InvestmentPrecision.rounded(input, exchangeRate: fx)
            precondition(InvestmentPrecision.rounded(output, exchangeRate: fx) == output, "Rounding must be idempotent")
        }
        precondition(InvestmentPrecision.display(330000) == "330000.00")
        precondition(InvestmentPrecision.display(0) == "0.0000")
        precondition(InvestmentPrecision.display(Decimal(string: "0.00123456")!) == "0.0012")
        precondition(InvestmentPrecision.display(Decimal(string: "1.005")!) == "1.01")
        precondition(InvestmentPrecision.display(Decimal(string: "123.0012")!) == "123.00")
        precondition(InvestmentPrecision.display(7, exchangeRate: true) == "7.0000")
        let account = InvestmentAccount(name: "精度测试", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
        book.addExchangeRates([.init(day: date(1), price: Decimal(string: "7.1235")!, isDailyClose: true)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(2), rebuild: true)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let restored = try records.decode(.init(generation: 1, revision: 1, through: records.day.string(from: date(2)), tables: tables))
        precondition(!restored.inspectData(through: date(3)).issues.contains { $0.title == "快照与当前账本不一致" })
        var draft = book
        try draft.post(.init(day: date(2), kind: .adjustment, amount: Decimal(string: "12.3456")!), accountID: account.id)
        draft.addExchangeRates([.init(day: date(2), price: Decimal(string: "7.123456")!, isDailyClose: true)], for: .usd)
        let encoded = try records.encode(draft, revision: 1)
        precondition(encoded["investment_events"]?.first(where: { $0["effective_date"] == records.day.string(from: date(2)) })?["amount"] == "12.35")
        precondition(encoded["market_daily_fx"]?.last?["rate"] == "7.1235")
    }

    static func fourPlacePricesSurviveStorage() throws {
        let records = InvestmentServerRecords()
        for kind in [InvestmentKind.stock, .etf, .fund, .crypto, .future] {
            for text in ["12.3456", "1.005", "0.0123", "0.0001", "71504.1234"] {
                let price = Decimal(string: text)!
                try InvestmentPrecision.validateInput(price, field: "单价", unitPrice: true)
                let asset = InvestmentAsset(name: "精度测试", code: "TEST", market: "", kind: kind, currency: .usd)
                let event = InvestmentEvent(day: date(1), kind: .opening, assetID: asset.id, quantity: 1, price: price)
                let account = InvestmentAccount(name: "精度测试", currency: .usd, events: [event], type: .securities)
                var book = InvestmentBook(accounts: [account])
                book.assets[asset.id] = asset
                book.quotes[asset.id] = [.init(day: date(1), price: price, isDailyClose: true)]
                try records.validateEventInputs(book, comparedTo: InvestmentBook())
                let encoded = try records.encode(book, revision: 1)
                precondition(encoded["investment_events"]?.first?["unit_price"] == text)
                precondition(encoded["market_daily_prices"]?.first?["price"] == text)
                let restored = try records.decode(.init(generation: 1, revision: 1, tables: encoded))
                precondition(restored.accounts[0].events[0].price == price)
            }
        }
        do { try InvestmentPrecision.validateInput(Decimal(string: "12.34567")!, field: "单价", unitPrice: true); preconditionFailure("Reject fifth decimal") }
        catch InvestmentError.invalid {}
        do { try InvestmentPrecision.validateInput(Decimal(string: "12.3456")!, field: "金额"); preconditionFailure("Amounts still use amount precision") }
        catch InvestmentError.invalid {}
    }

    static func fractionalCryptoTradesSurviveStorage() throws {
        precondition(InvestmentPrecision.exactInput("000.05800") == Decimal(string: "0.058"))
        precondition(InvestmentPrecision.exactInput("0.1234567890123456789012345678901234567890123456789") == nil,
                     "Unsupported input precision must be rejected rather than truncated")
        let account = InvestmentAccount(name: "加密投机", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let btc = try book.register(.init(name: "Bitcoin", code: "BTC", market: "", kind: .crypto, currency: .usd))
        let quantity = Decimal(string: "0.058")!
        let purchase = InvestmentEvent(day: date(1), kind: .buy, assetID: btc, quantity: quantity, price: 71504)
        try book.post(purchase, accountID: account.id, autoFundCash: true)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        precondition(tables["investment_events"]?.first { $0["event_type"] == "buy" }?["quantity"] == "0.058")
        precondition(tables["investment_events"]?.first { $0["event_type"] == "deposit" }?["amount"] == "4147.23")
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        let ledger = try restored.ledger(restored.accounts[0])
        precondition(ledger.cash == 0 && ledger.positions[btc]?.quantity == quantity)
        precondition(ledger.positions[btc]?.netCost == Decimal(string: "4147.23")!)
        try records.validateLedgers(tables, comparedTo: try records.encode(InvestmentBook(), revision: 1))
        var sold = restored
        try sold.post(.init(day: date(2), kind: .sell, assetID: btc, quantity: quantity, price: 71504), accountID: account.id)
        let soldLedger = try sold.ledger(sold.accounts[0])
        precondition(soldLedger.cash == Decimal(string: "4147.23")!)
        // A historical malformed quantity can be corrected through the normal editor.
        var broken = restored
        let offset = broken.accounts[0].events.firstIndex { $0.kind == .buy }!
        broken.accounts[0].events[offset].quantity = Decimal(string: "0.06")!
        let displayed = try broken.ledger(broken.accounts[0], includeRows: true)
        precondition(displayed.cash == Decimal(string: "-143.01")! && displayed.cashRows.count == 2, "Display must not hide an overdrawn account")
        do { _ = try broken.ledger(broken.accounts[0], validatingBalances: true); preconditionFailure("The stored 0.06 BTC must overdraw cash") }
        catch InvestmentError.insufficientCash {}
        var corrected = broken.accounts[0].events[offset]
        corrected.quantity = quantity
        try broken.replaceEvent(broken.accounts[0].events[offset], with: corrected, accountID: account.id)
        let correctedLedger = try broken.ledger(broken.accounts[0])
        precondition(correctedLedger.cash == 0)
        // Historical token quantities must retain their original precision on serialization.
        for value in ["0.00000001", "0.0012345678", "1.123456789012345678"] {
            var draft = InvestmentBook(accounts: [account])
            draft.assets[btc] = book.asset(btc)
            let units = Decimal(string: value)!
            draft.accounts[0].events = [.init(day: date(1), kind: .opening, assetID: btc, quantity: units, price: 100)]
            let encoded = try records.encode(draft, revision: 1)
            let reopened = try records.decode(.init(generation: 1, revision: 1, tables: encoded))
            precondition(reopened.accounts[0].events[0].quantity == units)
            var editedHistory = reopened
            let original = reopened.accounts[0].events[0]
            var updated = original
            updated.price = 101
            try editedHistory.replaceEvent(original, with: updated, accountID: account.id)
            try records.validateEventInputs(editedHistory, comparedTo: reopened)
            precondition(editedHistory.accounts[0].events[0].quantity == units,
                         "Editing another field must preserve an unchanged historical quantity")
        }
        var insufficient = InvestmentBook(accounts: [account])
        insufficient.assets[btc] = book.asset(btc)
        try insufficient.post(.init(day: date(1), kind: .deposit, amount: 4000), accountID: account.id)
        do { try insufficient.post(purchase, accountID: account.id); preconditionFailure("An actual cash shortfall must be rejected") }
        catch InvestmentError.insufficientCash {}
        precondition(insufficient.accounts[0].events.count == 1)
    }

    static func threePlaceQuantitiesSurviveStorage() throws {
        let records = InvestmentServerRecords()
        for (kind, currency, code, market) in [
            (InvestmentKind.stock, InvestmentCurrency.usd, "SPCX", "XNMS"),
            (.etf, .usd, "SPYM", "ARCX"),
            (.etf, .cny, "159941.SZ", "XSHE"),
            (.fund, .cny, "110022.OF", "OF"),
            (.crypto, .usd, "BTC", "BINANCE")
        ] {
            let account = InvestmentAccount(name: "小数股数", currency: currency, type: kind == .crypto ? .crypto : kind == .fund ? .fundWealth : .securities)
            var book = InvestmentBook(accounts: [account])
            let id = try book.register(.init(name: code, code: code, market: market, kind: kind, currency: currency))
            let price = Decimal(string: "137.36")!
            try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: Decimal(string: "5.711")!, price: price),
                          accountID: account.id, autoFundCash: true)
            let bought = try book.ledger(book.accounts[0], validatingBalances: true)
            precondition(bought.cash == 0 && bought.positions[id]?.quantity == Decimal(string: "5.711"))
            precondition(bought.positions[id]?.netCost == Decimal(string: "784.46"))
            let sale = InvestmentEvent(day: date(2), kind: .sell, assetID: id, quantity: Decimal(string: "0.711")!, price: price)
            try book.post(sale, accountID: account.id)
            let recordedSale = book.accounts[0].events.last!
            var edited = recordedSale
            edited.quantity = Decimal(string: "0.712")!
            try book.replaceEvent(recordedSale, with: edited, accountID: account.id)
            let confirmedEdit = book.accounts[0].events.last!
            let ledger = try book.ledger(book.accounts[0], validatingBalances: true)
            precondition(ledger.positions[id]?.quantity == Decimal(string: "4.999") && ledger.cash == Decimal(string: "97.80"))

            let encoded = try records.encode(book, revision: 1)
            let saved = try records.decode(.init(generation: 1, revision: 1, tables: encoded))
            precondition(saved.accounts[0].events.first(where: { $0.kind == .buy })?.quantity == Decimal(string: "5.711"))
            precondition(saved.accounts[0].events.last?.quantity == Decimal(string: "0.712"))
            let savedLedger = try saved.ledger(saved.accounts[0])
            precondition(savedLedger.positions[id]?.quantity == Decimal(string: "4.999"))

            for input in ["5.7111", "0.0001"] {
                let invalid = Decimal(string: input)!
                for eventKind in [InvestmentEventKind.opening, .buy, .sell] {
                    let before = book.accounts[0].events
                    do {
                        try book.post(.init(day: date(3), kind: eventKind, assetID: id, quantity: invalid, price: price),
                                      accountID: account.id, autoFundCash: true)
                        preconditionFailure("Excess quantity precision must not be rounded or posted")
                    } catch InvestmentError.invalid(let message) { precondition(message.contains("3 位小数")) }
                    precondition(book.accounts[0].events == before, "Invalid trades must not add an automatic cash top-up")
                }
                var invalidEdit = confirmedEdit
                invalidEdit.quantity = invalid
                do {
                    try book.replaceEvent(confirmedEdit, with: invalidEdit, accountID: account.id)
                    preconditionFailure("Editing must enforce the same quantity precision")
                } catch InvestmentError.invalid(let message) { precondition(message.contains("3 位小数")) }
                var direct = book
                direct.accounts[0].events[1].quantity = invalid
                do {
                    try records.validateEventInputs(direct, comparedTo: book)
                    preconditionFailure("Server-bound input validation must reject excess quantity precision")
                } catch InvestmentError.invalid { }
            }
            var opening = InvestmentBook(accounts: [account], assets: book.assets)
            try opening.post(.init(day: date(1), kind: .opening, assetID: id, quantity: Decimal(string: "0.001")!, price: price),
                             accountID: account.id)
            let openingLedger = try opening.ledger(opening.accounts[0])
            precondition(openingLedger.positions[id]?.quantity == Decimal(string: "0.001"))
        }
        for currency in [InvestmentCurrency.cny, .hkd] {
            do {
                try InvestmentKind.stock.validateTradeQuantity(Decimal(string: "5.711")!, currency: currency)
                preconditionFailure("Non-US stocks must still require integer quantities")
            } catch InvestmentError.invalid { }
        }
        try InvestmentKind.fund.validateTradeQuantity(Decimal(string: "5.711")!, currency: .cny)
        try InvestmentKind.crypto.validateTradeQuantity(Decimal(string: "0.001")!, currency: .usd)

        let account = InvestmentAccount(name: "美股定投", currency: .usd, type: .securities)
        var planned = InvestmentBook(accounts: [account])
        let id = try planned.register(.init(name: "SPCX", code: "SPCX", market: "XNMS", kind: .stock, currency: .usd))
        let amount: Decimal = 100
        try planned.post(.init(day: date(1), kind: .deposit, amount: amount), accountID: account.id)
        planned.addQuotes([.init(day: date(1), price: 3)], assetID: id)
        planned.plans = [.init(accountID: account.id, assetID: id, amount: amount,
                               schedule: try .init(frequency: .monthly, day: 1), nextDay: date(1))]
        planned.runPlans(through: date(1))
        let plannedLedger = try planned.ledger(planned.accounts[0], validatingBalances: true)
        precondition(plannedLedger.positions[id]?.quantity == Decimal(string: "33.333") && plannedLedger.cash == 0,
                     "US stock plans must round quantity down to thousandths without overdrawing cash")
    }

    static func threePlaceSpotBalancesPreserveHistoricalPrecision() throws {
        let account = InvestmentAccount(name: "历史现货", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "Bitcoin", code: "BTC", market: "BINANCE", kind: .crypto, currency: .usd))
        let original = InvestmentEvent(day: date(1), kind: .opening, assetID: id,
                                       quantity: Decimal(string: "0.12345678")!, price: 1)
        book.accounts[0].events = [original]
        try book.adjustSpotBalance(assetID: id, accountID: account.id, balance: Decimal(string: "0.125")!, on: date(2))
        let reward = book.accounts[0].events.last!
        precondition(reward.quantity == Decimal(string: "0.00154322"), "A computed balance delta must remain exact")
        let replacement = try book.spotBalanceReplacement(reward, accountID: account.id,
                                                          balance: Decimal(string: "0.126")!, on: date(2))
        try book.replaceEvent(reward, with: replacement, accountID: account.id)
        let ledger = try book.ledger(book.accounts[0])
        precondition(ledger.positions[id]?.quantity == Decimal(string: "0.126"))
        for input in ["0.1261", "0.0001"] {
            let before = book.accounts[0].events
            do {
                try book.adjustSpotBalance(assetID: id, accountID: account.id, balance: Decimal(string: input)!, on: date(3))
                preconditionFailure("Balance input must reject more than three places")
            } catch InvestmentError.invalid(let message) { precondition(message.contains("3 位小数")) }
            precondition(book.accounts[0].events == before)
            do {
                _ = try book.spotBalanceReplacement(book.accounts[0].events.last!, accountID: account.id,
                                                    balance: Decimal(string: input)!, on: date(2))
                preconditionFailure("Balance editing must reject more than three places")
            } catch InvestmentError.invalid(let message) { precondition(message.contains("3 位小数")) }
        }
        let records = InvestmentServerRecords()
        let saved = try records.decode(.init(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
        let savedLedger = try saved.ledger(saved.accounts[0])
        precondition(saved.accounts[0].events[0].quantity == original.quantity && savedLedger.positions[id]?.quantity == Decimal(string: "0.126"))
    }

    static func serializedLedgerValidationBlocksInvalidWrites() throws {
        let account = InvestmentAccount(name: "现金校验", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let btc = try book.register(.init(name: "Bitcoin", code: "BTC", market: "", kind: .crypto, currency: .usd))
        try book.post(.init(day: date(1), kind: .deposit, amount: Decimal(string: "1000.05")!), accountID: account.id)
        let records = InvestmentServerRecords()
        let previous = try records.encode(book, revision: 1)
        // The input price is rounded on write: validate the serialized price, not only the form draft.
        try book.post(.init(day: date(1), kind: .buy, assetID: btc, quantity: 1000, price: Decimal(string: "1.00005")!), accountID: account.id)
        do { try records.validateEventInputs(book, comparedTo: try records.decode(.init(generation: 1, revision: 1, tables: previous))); preconditionFailure("User price precision must be rejected without rounding") }
        catch InvestmentError.invalid {}
        let next = try records.encode(book, revision: 1)
        do { try records.validateLedgers(next, comparedTo: previous); preconditionFailure("The normalized price would overdraw cash") }
        catch InvestmentError.insufficientCash {}
        // Unrelated writes remain possible while an existing invalid account is being corrected.
        try records.validateLedgers(next, comparedTo: next)
    }

    static func ledgerAndDilutedCost() throws {
        let account = InvestmentAccount(name: "银河证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(InvestmentAsset(name: "测试", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        let first = date(1), second = date(2), third = date(3)
        try book.post(.init(day: first, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: first, kind: .opening, assetID: asset, quantity: 10, price: 10), accountID: account.id)
        try book.post(.init(day: second, kind: .buy, assetID: asset, quantity: 10, price: 20), accountID: account.id)
        try book.post(.init(day: third, kind: .sell, assetID: asset, quantity: 5, price: 24), accountID: account.id)
        try book.post(.init(day: third, kind: .adjustment, amount: 5), accountID: account.id)
        book.addQuotes([.init(day: third, price: 25)], assetID: asset)
        let recorded = book.accounts[0]
        let ledger = try book.ledger(recorded, through: third, includeRows: true)
        let position = try require(ledger.positions[asset])
        precondition(ledger.cash == 925 && ledger.flows == 1100 && ledger.cashIncome == 5)
        precondition(position.quantity == 15 && position.netCost == 180 && position.lastEntry == 20)
        precondition(ledger.cashRows.map(\.change) == [1000, -200, 120, 5])
        precondition(book.value(recorded, on: third)?.gain == 200)
        do {
            try book.post(.init(day: second, kind: .withdrawal, amount: -850), accountID: account.id)
            preconditionFailure("A backdated overdraft must be rejected")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.count == 5)
    }

    static func firstPurchaseRequiresCash() throws {
        let account = InvestmentAccount(name: "证券账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        let day = date(1)
        let purchase = InvestmentEvent(day: day, kind: .buy, assetID: id, quantity: 10, price: 10)
        do {
            try book.post(purchase, accountID: account.id)
            preconditionFailure("A first purchase must have enough cash")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.isEmpty)
        try book.post(.init(day: day, kind: .deposit, amount: 130), accountID: account.id)
        try book.post(purchase, accountID: account.id)
        let ledger = try book.ledger(book.accounts[0], through: day, includeRows: true)
        precondition(ledger.cash == 30 && ledger.flows == 130 && ledger.cashRows.map(\.change) == [130, -100])
        precondition(ledger.positions[id]?.netCost == 100 && ledger.positions[id]?.lastEntry == 10)
    }

    static func purchasesCanAutomaticallyFundFullCashAmount() throws {
        let account = InvestmentAccount(name: "证券账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "600000", market: "", kind: .stock, currency: .cny))
        let day = date(1)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 10, price: 10, fee: 5),
                      accountID: account.id, autoFundCash: true)
        try book.post(.init(day: day, kind: .deposit, amount: 30), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 4, price: 10, fee: 5),
                      accountID: account.id, autoFundCash: true)
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 4, price: 10, fee: 5),
                      accountID: account.id, autoFundCash: true)
        let ledger = try book.ledger(book.accounts[0], through: day, includeRows: true)
        precondition(ledger.cashRows.map(\.change) == [105, 30, 45, 100, 45, -105, -45, -45])
        precondition(ledger.cash == 130 && ledger.flows == 325 && ledger.positions[id]?.netCost == 195,
                     "Fully fund first and additional purchases, including fees, without using any existing cash")

        try book.post(.init(day: date(2), kind: .withdrawal, amount: -130), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 6, price: 10),
                      accountID: account.id, autoFundCash: true)
        let backdated = try book.ledger(book.accounts[0], through: date(2))
        precondition(backdated.cash == 0 && backdated.positions[id]?.netCost == 255,
                     "A backdated funded purchase must leave cash available for later recorded withdrawals")
        let records = InvestmentServerRecords()
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
        let restoredLedger = try restored.ledger(restored.accounts[0], through: date(2))
        precondition(restoredLedger.cash == 0)

        // Even when the input book is invalid, a failed write cannot retain the new deposit.
        book.accounts[0].events.append(.init(day: date(3), kind: .withdrawal, amount: -1))
        let previousEvents = book.accounts[0].events.map(\.id)
        do {
            try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 6, price: 10),
                          accountID: account.id, autoFundCash: true)
            preconditionFailure("A purchase and its automatic deposit must both roll back if ledger validation fails")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.map(\.id) == previousEvents)
    }

    static func insurancePurchasesPreserveExistingCashWhenAutomaticallyFunded() throws {
        for currency in [InvestmentCurrency.cny, .hkd] {
            let owner = InvestmentAccount(name: "保险", currency: currency, type: .insurance)
            var book = InvestmentBook(accounts: [owner])
            let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: currency))
            try book.post(.init(day: date(1), kind: .deposit, amount: 5_000), accountID: owner.id)
            for premium in [Decimal(1_000), Decimal(2_000)] {
                try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: premium),
                              accountID: owner.id, autoFundCash: true)
                let ledger = try book.ledger(book.accounts[0], through: date(1))
                precondition(ledger.cash == 5_000, "Initial and renewal premiums must preserve existing cash")
            }
            let deposits = book.accounts[0].events.filter { $0.kind == .deposit }.map(\.amount)
            precondition(deposits == [5_000, 1_000, 2_000])
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 1, price: 3_000), accountID: owner.id)
            let ordinary = try book.ledger(book.accounts[0], through: date(2))
            precondition(ordinary.cash == 2_000 && ordinary.positions[id]?.netCost == 6_000,
                         "When automatic funding is off, purchases still use existing cash")
        }
    }

    static func tradingFeesAffectCashAndDilutedCost() throws {
        let account = InvestmentAccount(name: "证券账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "600000", market: "", kind: .stock, currency: .cny))
        let day = date(1)
        let buy = InvestmentEvent(day: day, kind: .buy, assetID: id, quantity: 100, price: 10, fee: 5)
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        do {
            try book.post(buy, accountID: account.id)
            preconditionFailure("The purchase must also cover its fee")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.count == 1)
        try book.post(.init(day: day, kind: .deposit, amount: 5), accountID: account.id)
        try book.post(buy, accountID: account.id)
        let purchased = try book.ledger(book.accounts[0], through: day)
        precondition(purchased.cash == 0 && purchased.positions[id]?.netCost == 1005)

        try book.post(.init(day: date(2), kind: .sell, assetID: id, quantity: 40, price: 12, fee: 3), accountID: account.id)
        let partial = try book.ledger(book.accounts[0], through: date(2))
        precondition(partial.cash == 477 && partial.positions[id]?.netCost == 528)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 60, price: 12, fee: 3), accountID: account.id)
        let restored = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))
        let sold = try restored.ledger(restored.accounts[0], through: date(3), includeRows: true)
        precondition(sold.cashRows.map(\.change) == [1000, 5, -1005, 477, 717])
        precondition(sold.positions[id]?.realized == 189 && restored.portfolio(on: date(3))?.gain == 189)
    }

    static func futuresFeesStaySeparateFromMargin() throws {
        let account = InvestmentAccount(name: "期货账户", currency: .cny, type: .futures)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试合约", code: "CU1811.SHF", market: "", kind: .future, currency: .cny, multiplier: 10))
        let day = date(1)
        try book.post(.init(day: day, kind: .deposit, amount: 200), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 1, price: 100, margin: 100, fee: 5), accountID: account.id)
        let opened = try book.ledger(book.accounts[0], through: day)
        precondition(opened.cash == 95 && opened.positions[id]?.margin == 100 && opened.positions[id]?.netCost == 105)
        try book.post(.init(day: date(2), kind: .sell, assetID: id, quantity: 1, price: 105, fee: 6), accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: date(2))
        precondition(closed.cash == 239 && closed.positions[id]?.realized == 39)
    }















    static func stockDistributionsKeepPurchaseCost() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let stock = try book.register(.init(name: "股票", code: "600000", market: "", kind: .stock, currency: .cny))
        let purchase = date(1), distribution = date(2)
        try book.post(.init(day: purchase, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: purchase, kind: .buy, assetID: stock, quantity: 10, price: 10), accountID: account.id)
        do {
            try book.recordDistribution(assetID: stock, accountID: account.id, cash: 10, shares: Decimal(string: "0.5")!,
                                        on: distribution)
            preconditionFailure("Invalid bonus shares must also reject the cash entry")
        } catch InvestmentError.invalid {}
        precondition(book.accounts[0].events.count == 2)
        try book.recordDistribution(assetID: stock, accountID: account.id, cash: 10, shares: 2, on: distribution)
        book.addQuotes([.init(day: distribution, price: Decimal(string: "9.5")!)], assetID: stock)
        let ledger = try book.ledger(book.accounts[0], through: distribution, includeRows: true)
        precondition(ledger.cash == 10 && ledger.flows == 100 && ledger.cashRows.map(\.change) == [100, -100, 10])
        precondition(ledger.positions[stock]?.quantity == 12 && ledger.positions[stock]?.netCost == 100)
        precondition(ledger.positions[stock]?.realized == 10 && book.value(book.accounts[0], on: distribution)?.gain == 24)
    }

    static func fundsAndETFsRecordCashDividends() throws {
        let cases: [(InvestmentAccount, InvestmentAsset)] = [
            (.init(name: "基金账户", currency: .cny, type: .fundWealth),
             .init(name: "测试基金", code: "110022.OF", market: "", kind: .fund, currency: .cny)),
            (.init(name: "美元证券账户", currency: .usd, type: .securities),
             .init(name: "QQQ", code: "QQQ", market: "", kind: .etf, currency: .usd)),
        ]
        for (account, asset) in cases {
            var book = InvestmentBook(accounts: [account])
            let assetID = try book.register(asset)
            let purchase = date(1), distribution = date(2)
            try book.post(.init(day: purchase, kind: .deposit, amount: 100), accountID: account.id)
            try book.post(.init(day: purchase, kind: .buy, assetID: assetID, quantity: 10, price: 5), accountID: account.id)
            try book.recordDistribution(assetID: assetID, accountID: account.id, cash: 8, on: distribution)
            do {
                try book.recordDistribution(assetID: assetID, accountID: account.id, cash: 8, shares: 1, on: distribution)
                preconditionFailure("An unsupported distribution must not post its cash portion")
            } catch InvestmentError.invalid {}
            let ledger = try book.ledger(book.accounts[0], through: distribution, includeRows: true)
            precondition(ledger.cash == 58 && ledger.flows == 100)
            precondition(ledger.positions[assetID]?.quantity == 10 && ledger.positions[assetID]?.netCost == 50)
            precondition(ledger.positions[assetID]?.realized == 8)
            precondition(ledger.cashRows.last?.event.kind == .dividend && ledger.cashRows.last?.event.assetID == assetID)
        }
    }

    static func spotBalanceAdjustmentsUseTokenQuantity() throws {
        let account = InvestmentAccount(name: "加密货币", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let token = try book.register(.init(name: "Ether", code: "ETH", market: "", kind: .crypto, currency: .usd))
        let purchase = date(1), reward = date(2)
        try book.post(.init(day: purchase, kind: .deposit, amount: 2000), accountID: account.id)
        try book.post(.init(day: purchase, kind: .buy, assetID: token, quantity: 1, price: 2000), accountID: account.id)
        let total = Decimal(string: "1.01")!
        try book.adjustSpotBalance(assetID: token, accountID: account.id, balance: total, on: reward)
        let ledger = try book.ledger(book.accounts[0], through: reward, includeRows: true)
        precondition(ledger.positions[token]?.quantity == total && ledger.positions[token]?.netCost == 2000)
        precondition(ledger.cash == 0 && ledger.cashRows.count == 2 && book.accounts[0].events.last?.kind == .stakingReward)
        try book.adjustSpotBalance(assetID: token, accountID: account.id, balance: 1, on: reward)
        let corrected = try book.ledger(book.accounts[0], through: reward)
        precondition(corrected.positions[token]?.quantity == 1 && corrected.positions[token]?.netCost == 2000)
        precondition(book.accounts[0].events.last?.kind == .spotAdjustment)
    }

    static func historicalShortcutRequestsStayWithinTenClosedDays() throws {
        let end = date(7), first = InvestmentBook.addDays(-9, to: end)
        let old = InvestmentBook.addDays(-30, to: end)
        let account = InvestmentAccount(name: "长期定投", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "Bitcoin", code: "BTC", market: "BINANCE", kind: .crypto, currency: .usd))
        try book.post(.init(day: old, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: old, kind: .buy, assetID: id, quantity: 1, price: 50), accountID: account.id)
        book.plans = [.init(accountID: account.id, amount: 10,
                            schedule: try .init(frequency: .daily, day: 0), nextDay: old)]
        let requests = book.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true, notBefore: first)
        precondition(requests.assets[id] == [first...end], "Crypto must retain all ten closed calendar days, including weekends")
        for ranges in Array(requests.assets.values) + Array(requests.rates.values) {
            precondition(ranges.allSatisfy { $0.lowerBound >= first && $0.upperBound <= end },
                         "Snapshot and plan requests cannot escape the ten-day boundary")
        }
        precondition(requests.rates[.usd]?.allSatisfy {
            ![1, 7].contains(InvestmentBook.calendar.component(.weekday, from: $0.lowerBound))
        } == true, "FX must not expand a weekend lower bound back before the limit")
        let complete = book.historicalMarketDataRequests(through: end, fullHistory: true)
        precondition(complete.assets[id]?.first?.lowerBound == old, "Manual full-history work must retain its range")
        let empty = book.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true,
                                                     notBefore: InvestmentBook.addDays(1, to: end))
        precondition(empty.assets.isEmpty && empty.rates.isEmpty)
        precondition(book.planRuns.isEmpty && book.accounts[0].events.count == 2, "Preparing data must not execute plans")
    }

    static func shortcutIncludesSessionsAsSoonAsTheyClose() throws {
        let format = ISO8601DateFormatter()
        func instant(_ text: String) -> Date { format.date(from: text)! }
        let mainland = InvestmentAsset(name: "沪深300", code: "510300.SH", market: "XSHG", kind: .etf, currency: .cny)
        let hongKong = InvestmentAsset(name: "盈富", code: "02800.HK", market: InvestmentAsset.stockConnectMarket, kind: .etf, currency: .hkd)
        let us = InvestmentAsset(name: "Apple", code: "AAPL", market: "NASDAQ", kind: .stock, currency: .usd)
        let crypto = InvestmentAsset(name: "Bitcoin", code: "BTC", market: "BINANCE", kind: .crypto, currency: .usd)
        let today = InvestmentBook.day(instant("2026-11-25T15:00:00+08:00"))
        let yesterday = InvestmentBook.addDays(-1, to: today)
        let first = InvestmentBook.addDays(-10, to: today)
        let account = InvestmentAccount(name: "收盘补数", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        for asset in [mainland, hongKong, us, crypto] {
            book.assets[asset.id] = asset
            // A pending first purchase also needs its just-closed session, without executing the plan.
            book.plans.append(.init(accountID: account.id, assetID: asset.id, amount: 50,
                schedule: try .init(frequency: .daily, day: 0), nextDay: today))
        }
        func requests(_ time: String, _ source: InvestmentBook) -> InvestmentSnapshotQuoteRequests {
            source.historicalMarketDataRequests(through: yesterday, fullHistory: false, includePlans: true,
                notBefore: first, closedMarketsAt: instant(time))
        }
        let before = requests("2026-11-25T14:59:59+08:00", book)
        precondition(before.assets[mainland.id] == [yesterday...yesterday])
        let closed = requests("2026-11-25T15:00:00+08:00", book)
        precondition(closed.assets[mainland.id] == [today...today])
        precondition(closed.assets[hongKong.id] == [yesterday...yesterday])
        precondition(requests("2026-11-25T16:00:00+08:00", book).assets[hongKong.id] == [today...today])
        precondition(closed.assets[crypto.id] == [yesterday...yesterday], "An unfinished crypto day is never a daily close")
        precondition(requests("2026-11-25T04:59:59+08:00", book).assets[us.id] == [InvestmentBook.addDays(-1, to: yesterday)...InvestmentBook.addDays(-1, to: yesterday)])
        precondition(requests("2026-11-25T05:00:00+08:00", book).assets[us.id] == [yesterday...yesterday])
        precondition(us.lastClosedMarketDay(at: instant("2026-07-15T04:00:00+08:00"))
            == InvestmentBook.day(instant("2026-07-14T00:00:00+08:00")), "New York daylight time closes at Beijing 04:00")
        precondition(mainland.lastClosedMarketDay(at: instant("2026-11-28T17:00:00+08:00"))
            == InvestmentBook.day(instant("2026-11-27T00:00:00+08:00")), "Weekends do not invent a trading session")
        var held = book
        held.plans = []
        held.accounts[0].events = [.init(day: first, kind: .opening, assetID: mainland.id, quantity: 1, price: 1)]
        held.addQuotes([.init(day: yesterday, price: 1, isDailyClose: true)], assetID: mainland.id)
        precondition(requests("2026-11-25T15:00:00+08:00", held).assets[mainland.id]?.contains(today...today) == true,
                     "Carrying yesterday's value must not suppress the held asset's newly closed session")
        book.addQuotes([.init(day: today, price: 1, isDailyClose: false)], assetID: mainland.id)
        precondition(requests("2026-11-25T15:00:00+08:00", book).assets[mainland.id] != nil,
                     "An intraday cached quote must be replaced by a closing quote")
        book.addQuotes([.init(day: today, price: 2, isDailyClose: true)], assetID: mainland.id)
        precondition(requests("2026-11-25T15:00:00+08:00", book).assets[mainland.id] == nil)
        precondition(closed.rates.isEmpty && book.planRuns.isEmpty && book.dailySnapshots == nil,
                     "Closing-price preparation does not advance plans, snapshots or provisional daily FX")
        var archived = book
        archived.accounts[0].archivedAt = first
        precondition(requests("2026-11-25T17:00:00+08:00", archived).assets.isEmpty)
    }

    static func historicalPlansUseClosedPricesAndKeepCashFlows() throws {
        let first = date(1), end = date(2), today = date(3)
        let account = InvestmentAccount(name: "历史定投", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "ETF", code: "510300", market: "XSHG", kind: .etf, currency: .cny))
        let daily = try InvestmentPlanSchedule(frequency: .daily, day: 0)
        book.plans = [
            .init(accountID: account.id, amount: 100, schedule: daily, nextDay: first),
            .init(accountID: account.id, assetID: id, amount: 50, schedule: daily, nextDay: first)
        ]
        precondition(book.earliest == nil)
        let requests = book.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true)
        precondition(requests.assets[id] == [first...end], "First purchases need quotes before a position exists")
        precondition(requests.rates[.usd] == [first...end], "Snapshot FX for future plan flows must be fetched before settlement")
        var fundingOnly = book
        fundingOnly.plans.removeLast()
        let fundingRequests = fundingOnly.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true)
        precondition(fundingRequests.assets.isEmpty && fundingRequests.rates[.usd] == [first...end],
                     "A first deposit needs snapshot FX even without positions or prior transactions")
        let usAccount = InvestmentAccount(name: "美股定投", currency: .usd, type: .securities)
        var usBook = InvestmentBook(accounts: [usAccount])
        let usID = try usBook.register(.init(name: "Apple", code: "AAPL", market: "NASDAQ", kind: .stock, currency: .usd))
        usBook.plans = [.init(accountID: usAccount.id, assetID: usID, amount: 50, schedule: daily, nextDay: first)]
        let usRequests = usBook.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true)
        precondition(usRequests.assets[usID] == [InvestmentBook.addDays(-1, to: first)...end],
                     "US session prices needed for the first Beijing valuation date must precede settlement")
        precondition(book.historicalMarketDataRequests(through: end, fullHistory: false).assets.isEmpty)
        var excluded = book
        excluded.plans[1].nextDay = today
        precondition(excluded.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true).assets.isEmpty)
        excluded = book; excluded.plans[1].enabled = false
        precondition(excluded.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true).assets.isEmpty)
        excluded = book; excluded.accounts[0].archivedAt = first
        precondition(excluded.historicalMarketDataRequests(through: end, fullHistory: false, includePlans: true).assets.isEmpty)

        book.addQuotes([.init(day: first, price: 5, isDailyClose: false),
                        .init(day: end, price: 10, isDailyClose: true),
                        .init(day: today, price: 20, isDailyClose: false)], assetID: id)
        precondition(book.runPlans(through: end))
        let events = book.accounts[0].events
        precondition(events.filter { $0.kind == .deposit }.count == 2, "Historical funding must still create cash flows")
        let buys = events.filter { $0.kind == .buy }
        precondition(buys.count == 1 && buys[0].day == end && buys[0].price == 10 && buys[0].quantity == 5)
        precondition(events.allSatisfy { $0.day <= end } && book.plans.allSatisfy { $0.nextDay == today })
        precondition(book.planRuns.filter { $0.status == "skipped" }.count == 1, "Provisional historical prices cannot execute a buy")
        precondition(!book.runPlans(through: end), "Reruns cannot duplicate flows")
        var current = InvestmentBook(accounts: [account])
        current.plans = [.init(accountID: account.id, amount: 100, schedule: daily, nextDay: InvestmentBook.day())]
        precondition(!current.runPlans() && current.accounts[0].events.isEmpty, "Default execution must defer today's plans")
    }

    static func plansUseCashInExecutionOrder() throws {
        let account = InvestmentAccount(name: "定投账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(InvestmentAsset(name: "测试ETF", code: "510300", market: "XSHG", kind: .etf, currency: .cny))
        let first = date(1), second = date(2), third = date(3)
        book.plans = [
            InvestmentPlan(accountID: account.id, assetID: asset, amount: 100, schedule: try .init(frequency: .monthly, day: 1), nextDay: first),
            InvestmentPlan(accountID: account.id, amount: 105, schedule: try .init(frequency: .monthly, day: 2), nextDay: second)
        ]
        book.runPlans(through: first)
        precondition(book.plans[0].nextDay == first && book.accounts[0].events.isEmpty)
        let priorRuns = book.planRuns
        book.addQuotes([.init(day: third, price: 6)], assetID: asset)
        book.runPlans(through: third)
        book.runPlans(through: third)
        let ledger = try book.ledger(book.accounts[0], through: third)
        precondition(ledger.cash == 5 && ledger.positions[asset]?.quantity == Decimal(string: "16.666"))
        precondition(book.accounts[0].events.map(\.kind) == [.deposit, .buy])
        precondition(book.plans.allSatisfy { $0.nextDay > third })
        let report = book.planReport(since: priorRuns)
        precondition(report.executed == 2 && report.skipped == 0 && report.waiting == 0)
    }

    static func planSchedulesRespectCalendarDays() throws {
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            InvestmentBook.calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let daily = try InvestmentPlanSchedule(frequency: .daily, day: 0)
        precondition(daily.first(after: date(2026, 11, 1)) == date(2026, 11, 2))
        precondition(daily.next(after: date(2026, 12, 31)) == date(2027, 1, 1))
        let weekly = try InvestmentPlanSchedule(frequency: .weekly, day: 1)
        precondition(weekly.first(after: date(2026, 11, 1)) == date(2026, 11, 2))
        precondition(weekly.next(after: date(2026, 11, 2)) == date(2026, 11, 9))
        precondition(weekly.summary == "每周一")
        let biweekly = try InvestmentPlanSchedule(frequency: .biweekly, day: 1)
        precondition(biweekly.first(after: date(2026, 11, 1)) == date(2026, 11, 2))
        precondition(biweekly.next(after: date(2026, 11, 2)) == date(2026, 11, 16))
        precondition(biweekly.next(after: date(2026, 11, 16)) == date(2026, 11, 30))
        let monthly = try InvestmentPlanSchedule(frequency: .monthly, day: 31)
        precondition(monthly.next(after: date(2026, 1, 31)) == date(2026, 2, 28))
        precondition(monthly.next(after: date(2026, 2, 28)) == date(2026, 3, 31))
        precondition(monthly.first(after: date(2028, 2, 1)) == date(2028, 2, 29))
        let restored = try JSONDecoder().decode(InvestmentPlanSchedule.self, from: JSONEncoder().encode(monthly))
        precondition(restored == monthly)
        let invalidSchedules: [(InvestmentPlanFrequency, Int)] = [
            (.daily, 1), (.weekly, 0), (.weekly, 8), (.biweekly, 0), (.biweekly, 8), (.monthly, 0), (.monthly, 32)
        ]
        for (frequency, day) in invalidSchedules {
            do { _ = try InvestmentPlanSchedule(frequency: frequency, day: day); preconditionFailure("invalid plan schedule") }
            catch is InvestmentError { }
        }
    }

    static func planPeriodsCatchUpOnceAndRoundTrip() throws {
        let monday = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let account = InvestmentAccount(name: "周期测试", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let daily = InvestmentPlan(accountID: account.id, amount: 10, schedule: try .init(frequency: .daily, day: 0), nextDay: monday)
        let weekly = InvestmentPlan(accountID: account.id, amount: 100, schedule: try .init(frequency: .weekly, day: 1), nextDay: monday)
        let biweekly = InvestmentPlan(accountID: account.id, amount: 1000, schedule: try .init(frequency: .biweekly, day: 1), nextDay: monday)
        let monthly = InvestmentPlan(accountID: account.id, amount: 10000, schedule: try .init(frequency: .monthly, day: 2), nextDay: monday)
        book.plans = [daily, weekly, biweekly, monthly]
        precondition(!book.runPlans(through: InvestmentBook.addDays(-1, to: monday)))
        let through = InvestmentBook.addDays(21, to: monday)
        precondition(book.runPlans(through: through))
        precondition(book.planRuns.filter { $0.planID == daily.id }.count == 22)
        precondition(book.planRuns.filter { $0.planID == weekly.id }.map(\.day) == [0, 7, 14, 21].map { InvestmentBook.addDays($0, to: monday) })
        precondition(book.planRuns.filter { $0.planID == biweekly.id }.map(\.day) == [0, 14].map { InvestmentBook.addDays($0, to: monday) })
        let ledger = try book.ledger(book.accounts[0], through: through)
        precondition(ledger.cash == 12620)
        let report = book.planReport(since: [])
        precondition(report.executed == 29 && report.skipped == 0 && report.waiting == 0)
        let previousRuns = book.planRuns
        precondition(!book.runPlans(through: through))
        book.plans[0].nextDay = monday
        precondition(book.runPlans(through: through))
        precondition(book.accounts[0].events.count == 29 && book.planRuns.count == 29)
        precondition(!book.planReport(since: previousRuns).hasResults)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(restored.plans == book.plans && restored.planRuns.count == book.planRuns.count)
        precondition(tables["investment_plans"]?.allSatisfy { $0["month_day"] == nil && $0["frequency"] != nil } == true)

        var waiting = InvestmentBook(accounts: [account])
        let asset = try waiting.register(.init(name: "报价等待", code: "510300", market: "XSHG", kind: .etf, currency: .cny))
        waiting.plans = [.init(accountID: account.id, assetID: asset, amount: 100,
                              schedule: try .init(frequency: .daily, day: 0), nextDay: monday)]
        precondition(waiting.runPlans(through: monday))
        precondition(!waiting.runPlans(through: monday))
        precondition(waiting.planRuns.first?.status == "waiting")
        let firstRuns = waiting.planRuns
        let waitingReport = waiting.planReport(since: firstRuns)
        precondition(waitingReport.executed == 0 && waitingReport.skipped == 0 && waitingReport.waiting == 1)
        precondition(waiting.runPlans(through: InvestmentBook.addDays(1, to: monday)))
        precondition(waiting.planRuns.map(\.status) == ["skipped", "waiting"] && waiting.accounts[0].events.isEmpty)
        let skippedReport = waiting.planReport(since: firstRuns)
        precondition(skippedReport.executed == 0 && skippedReport.skipped == 1 && skippedReport.waiting == 1)
        waiting.plans[0].enabled = false
        precondition(!waiting.planReport(since: waiting.planRuns).hasResults)
    }

    static func balanceSheetKeepsDatedBalancesAndUsesInvestmentValuation() throws {
        let account = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        let first = date(1), second = date(2), third = date(3)
        var book = InvestmentBook(accounts: [account])
        let oldLedger = try JSONEncoder().encode(book)
        book = try JSONDecoder().decode(InvestmentBook.self, from: oldLedger)
        precondition(book.balanceSheet == nil)
        try book.post(.init(day: second, kind: .deposit, amount: 100), accountID: account.id)
        book.fx[.usd] = [.init(day: third, price: 7)]

        var sheet = InvestmentBalanceLedger()
        try sheet.add("存款", category: .cash, amount: 300, at: first)
        try sheet.add("房贷", category: .liabilities, amount: 500, at: first)
        try sheet.update(sheet.accounts[1].id, amount: 450, at: second)
        try sheet.update(sheet.accounts[1].id, amount: 450, at: third)
        try sheet.update(sheet.accounts[1].id, amount: 0, at: third.addingTimeInterval(60))
        book.balanceSheet = sheet
        book = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))

        let before = book.balanceSnapshot(on: first, today: first)
        precondition(before.assets == 300 && before.liabilities == 500 && before.net == -200)
        let missing = book.balanceSnapshot(on: second, today: second)
        precondition(missing.assets == nil && missing.liabilities == 450 && missing.net == nil)
        let after = book.balanceSnapshot(on: third, today: third)
        precondition(after.investment == book.portfolio(on: third)?.value && after.assets == 1000)
        precondition(after.liabilities == 0 && after.net == 1000)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let confirmed = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: tables))
        let liability = confirmed.balanceSheet?.accounts.first { $0.category == .liabilities }
        precondition(liability?.latest(on: first)?.amount == 500)
        precondition(liability?.latest(on: InvestmentBook.addDays(-1, to: first)) == nil)
        let changes = book.balanceChanges(through: third, limit: 5)
        precondition(changes.count == 4 && changes.first?.before == 450 && changes.first?.after == 0)
        precondition(changes[1].before == 500 && changes[1].after == 450)
        precondition(changes.allSatisfy { $0.category != .investments })
        let deficit = InvestmentBalanceSnapshot(day: third, manual: [.cash: 300, .liabilities: 500],
                                                investment: -50, updatedAt: nil)
        precondition(deficit.assets == 300 && deficit.liabilities == 550 && deficit.net == -250)
    }

    static func balanceHistoryFiltersAndReplaysEditedRecords() throws {
        let first = date(1), second = date(2), third = date(3), end = date(31)
        var ledger = InvestmentBalanceLedger()
        try ledger.add("储蓄卡", category: .cash, amount: 100, at: first)
        try ledger.add("储蓄卡", category: .receivables, amount: 700, at: third)
        let accountID = ledger.accounts[0].id
        try ledger.update(accountID, amount: 120, at: second)
        try ledger.update(accountID, amount: 180, at: third.addingTimeInterval(3600))
        var book = InvestmentBook()
        book.balanceSheet = ledger
        book.dailySnapshots = .init(through: end, values: [end: .init(value: 800, gain: 0)])

        let recent = book.balanceChanges(through: end, limit: 1, filter: .account(accountID))
        precondition(recent.count == 1 && recent[0].after == 180)
        let months = book.balanceChanges(through: end, limit: 10, filter: .investment)
        precondition(months.count == 1 && months[0].manualRecord == nil)
        let original = recent[0].manualRecord!.record
        try ledger.replaceRecord(original, accountID: accountID, amount: 150, on: first, now: end)
        do {
            try ledger.deleteRecord(original, accountID: accountID)
            preconditionFailure("An older editor must not delete the changed record")
        } catch InvestmentError.invalid {}
        book.balanceSheet = ledger
        let changes = book.balanceChanges(through: end, limit: 10, filter: .account(accountID))
        precondition(changes.map(\.after) == [120, 150, 100] && changes[0].before == 150)
        precondition(changes[1].manualRecord?.record.id == original.id && changes[1].day == first)
        precondition(book.balanceSnapshot(on: first).manual[.cash] == 150)

        try ledger.deleteRecord(changes[0].manualRecord!.record, accountID: accountID)
        book.balanceSheet = ledger
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let saved = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: tables))
        precondition(saved.balanceSnapshot(on: second).manual[.cash] == 150)
        let remaining = saved.balanceChanges(through: end, limit: 10, filter: .account(accountID))
        precondition(remaining.map(\.after) == [150, 100])
        for change in remaining { try ledger.deleteRecord(change.manualRecord!.record, accountID: accountID) }
        precondition(ledger.accounts[0].id == accountID && ledger.accounts[0].records.isEmpty)
    }

    static func investmentHistoryRecordsOneFrozenSnapshotPerClosedMonth() throws {
        let first = date(1), close = date(31), next = InvestmentBook.addDays(1, to: close)
        let account = InvestmentAccount(name: "投资", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: account.id)
        book.dailySnapshots = .init(through: close, values: [close: .init(value: 120, gain: 20)])
        precondition(book.balanceSnapshot(on: close, today: next).investment == 120)
        precondition(book.investmentMonthEndValues == [close: 120])
        book.dailySnapshots?.values[close] = .init(value: 150, gain: 50)
        precondition(book.balanceSnapshot(on: close, today: next).investment == 150,
                     "Monthly views must read the canonical daily snapshot instead of frozen duplicates")
        precondition(book.balanceChanges(through: next, limit: 10, filter: .investment).map(\.after) == [150])
        book.dailySnapshots?.values.removeValue(forKey: close)
        precondition(book.balanceSnapshot(on: close, today: next).investment == nil,
                     "A missing daily snapshot must remain missing instead of reviving a retired monthly total")
    }

    static func balanceTrendUsesEveryDailySnapshotBeforeFirstMonthClose() throws {
        let account = InvestmentAccount(name: "趋势测试", currency: .cny, type: .securities)
        let first = date(10), second = date(11), today = date(12)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: today, kind: .deposit, amount: 100), accountID: account.id)
        var manual = InvestmentBalanceLedger()
        try manual.add("流动资金", category: .cash, amount: 300, at: first)
        try manual.add("负债", category: .liabilities, amount: 200, at: first)
        book.balanceSheet = manual
        book.dailySnapshots = InvestmentDailySnapshots(through: second, values: [
            first: .init(value: 100, gain: 0), second: .init(value: 120, gain: 20)
        ])
        book.usesServerSnapshots = true

        precondition(book.investmentMonthEndValues.isEmpty)
        precondition(book.balanceSnapshot(on: first, today: today).net == nil)
        let points = book.balanceTrend(from: first, through: today)
        precondition(points.map(\.id) == [first, second, today])
        precondition(points.map { $0.snapshot.investment } == [100, 120, 200])
        precondition(points.map { $0.snapshot.net } == [200, 220, 300])
        precondition(Set(points.map(\.segment)).count == 1)
        precondition(book.balanceTrend(from: second, through: today).map(\.id) == [second, today])
        precondition(book.balanceTrend(from: today, through: today).count == 1)
        precondition(book.balanceTrend(from: today, through: first).isEmpty)
    }

    static func balanceTrendKeepsMissingDaysAndManualBalances() throws {
        let first = date(10), second = date(11), third = date(12), fourth = date(13), today = date(14)
        let account = InvestmentAccount(name: "趋势缺口测试", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: first, kind: .deposit, amount: 150), accountID: account.id)
        var manual = InvestmentBalanceLedger()
        try manual.add("流动资金", category: .cash, amount: 50, at: date(9))
        try manual.add("负债", category: .liabilities, amount: 200, at: date(9))
        book.balanceSheet = manual
        book.dailySnapshots = InvestmentDailySnapshots(through: fourth, values: [
            first: .init(value: 100, gain: 0), third: .init(value: 140, gain: 40)
        ])
        book.usesServerSnapshots = true
        let points = book.balanceTrend(from: date(9), through: today)
        precondition(points.map(\.id) == [date(9), first, second, third, fourth, today])
        precondition(points.map { $0.snapshot.net } == [-150, -50, nil, -10, nil, 0])
        precondition(points[1].segment != points[3].segment && points[3].segment != points[5].segment)
        precondition(points[2].snapshot.liabilities == 200 && points[4].snapshot.assets == nil)

        var manualOnly = InvestmentBook()
        manualOnly.usesServerSnapshots = true
        manualOnly.balanceSheet = manual
        let balances = manualOnly.balanceTrend(from: first, through: today)
        precondition(balances.count == 5 && balances.allSatisfy { $0.snapshot.net == -150 })
    }

    static func balanceTrendCarriesSnapshotsFromNovemberFirst() throws {
        let first = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let before = InvestmentBook.addDays(-1, to: first), second = InvestmentBook.addDays(1, to: first)
        let third = InvestmentBook.addDays(2, to: first), fourth = InvestmentBook.addDays(3, to: first)
        let fifth = InvestmentBook.addDays(4, to: first), today = InvestmentBook.addDays(5, to: first)
        let account = InvestmentAccount(name: "快照沿用", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: before, kind: .deposit, amount: 500), accountID: account.id)
        var manual = InvestmentBalanceLedger()
        try manual.add("流动资金", category: .cash, amount: 50, at: first)
        try manual.update(manual.accounts[0].id, amount: 80, at: third)
        try manual.add("负债", category: .liabilities, amount: 40, at: first)
        book.balanceSheet = manual
        book.dailySnapshots = InvestmentDailySnapshots(through: fifth, values: [
            before: .init(value: 90, gain: 0), first: .init(value: 100, gain: 0), fourth: .init(value: 140, gain: 0)
        ])
        book.usesServerSnapshots = true

        let points = book.balanceTrend(from: first, through: today)
        precondition(points.map { $0.snapshot.investment } == [100, 100, 100, 140, 140, 500])
        precondition(points.map { $0.snapshot.net } == [110, 110, 140, 180, 180, 540])
        precondition(points.map(\.investmentSnapshotDay) == [first, first, first, fourth, fourth, today])
        precondition(Set(points.map(\.segment)).count == 1)
        let trimmed = book.balanceTrend(from: third, through: today)
        precondition(trimmed.first?.snapshot.investment == 100 && trimmed.first?.investmentSnapshotDay == first)
        precondition(book.dailyPortfolio(on: [second, third, fifth]).isEmpty)
        precondition(book.dailySnapshots?.values.count == 3 && book.dailySnapshots?.values[second] == nil)

        let foreign = InvestmentAccount(name: "今日估值缺失", currency: .usd, type: .securities)
        var missingToday = InvestmentBook(accounts: [foreign])
        try missingToday.post(.init(day: first, kind: .deposit, amount: 100), accountID: foreign.id)
        missingToday.dailySnapshots = InvestmentDailySnapshots(through: fifth, values: [first: .init(value: 700, gain: 0)])
        missingToday.usesServerSnapshots = true
        precondition(missingToday.portfolio(on: today) == nil)
        let carriedToday = missingToday.balanceTrend(from: today, through: today).first
        precondition(carriedToday?.snapshot.investment == 700 && carriedToday?.investmentSnapshotDay == first)
    }

    static func balanceTrendStopsCarryAtNovemberFirst() throws {
        let first = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let before = InvestmentBook.addDays(-1, to: first), third = InvestmentBook.addDays(2, to: first)
        let fifth = InvestmentBook.addDays(4, to: first), sixth = InvestmentBook.addDays(5, to: first)
        let today = InvestmentBook.addDays(6, to: first)
        let account = InvestmentAccount(name: "快照回溯边界", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: before, kind: .deposit, amount: 500), accountID: account.id)
        book.dailySnapshots = InvestmentDailySnapshots(through: sixth, values: [
            before: .init(value: 90, gain: 0), third: .init(value: 0, gain: 0), fifth: .init(value: -20, gain: 0)
        ])
        book.usesServerSnapshots = true
        let points = book.balanceTrend(from: before, through: today)
        precondition(points.map { $0.snapshot.investment } == [90, nil, nil, 0, 0, -20, -20, 500])
        precondition(points[1].investmentSnapshotDay == nil && points[2].investmentSnapshotDay == nil)
        precondition(points[0].segment != points[3].segment)
        precondition(points[3].segment == points[6].segment)
        precondition(points[4].investmentSnapshotDay == third && points[6].investmentSnapshotDay == fifth)
        precondition(points[6].snapshot.assets == 0 && points[6].snapshot.liabilities == 20 && points[6].snapshot.net == -20)
        precondition(book.balanceTrend(from: first, through: today).first?.snapshot.investment == nil)
    }

    static func currencyConversionRequiresQuote() throws {
        let account = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let day = date(1)
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
        precondition(book.portfolio(on: day) == nil)
        precondition(book.portfolio(on: day, currency: .usd)?.value == 100)
        precondition(book.convert(100, from: .usd, to: .cny, on: day) == nil)
        precondition(book.convert(0, from: .hkd, to: .usd, on: day) == 0)
        let cny = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        let hkd = InvestmentAccount(name: "港元账户", currency: .hkd, type: .insurance)
        book.accounts.append(contentsOf: [cny, hkd])
        try book.post(.init(day: day, kind: .deposit, amount: 720), accountID: cny.id)
        try book.post(.init(day: day, kind: .deposit, amount: 800), accountID: hkd.id)
        precondition(book.portfolio(on: day, currency: .usd) == nil)
        book.fx[.usd] = [.init(day: day, price: Decimal(string: "7.2")!)]
        book.fx[.hkd] = [.init(day: day, price: Decimal(string: "0.9")!)]
        precondition(book.convert(100, from: .usd, to: .cny, on: day) == 720)
        precondition(book.convert(720, from: .cny, to: .usd, on: day) == 100)
        precondition(book.convert(800, from: .hkd, to: .cny, on: day) == 720)
        precondition(book.convert(800, from: .hkd, to: .usd, on: day) == 100)
        precondition(book.portfolio(on: day)?.value == 2160 && book.portfolio(on: day)?.gain == 0)
        precondition(book.portfolio(on: day, currency: .usd)?.value == 300)
    }

    static func accountCurrencyRestrictsEntries() throws {
        let usd = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        let hkd = InvestmentAccount(name: "港元账户", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [usd, hkd])
        let day = date(1)

        for (account, code, venue, kind) in [
            (usd, "BRK.B", "XNYS", InvestmentKind.stock),
            (hkd, "POLICY-A", "", .insurance)
        ] {
            let id = try book.register(.init(name: code, code: code, market: venue, kind: kind, currency: account.currency))
            try book.post(.init(day: day, kind: .opening, assetID: id, quantity: 1, price: 10), accountID: account.id)
        }

        for (account, code, venue, kind, currency) in [
            (usd, "600519.SH", "", InvestmentKind.stock, InvestmentCurrency.usd),
            (usd, "00700.HK", "", .stock, .usd),
            (usd, "09010.HK", "", .etf, .usd),
            (usd, "VOD.L", "", .stock, .usd),
            (usd, "CU1811", "", .future, .usd),
            (usd, "ESZ6", "XCME", .future, .usd),
            (usd, "VFIAX", "", .fund, .usd),
            (usd, "900901.SH", "", .stock, .usd),
            (hkd, "200002.SZ", "", .stock, .hkd),
            (hkd, "AAPL", "", .stock, .hkd),
            (hkd, "000001", "", .stock, .hkd),
            (hkd, "09010.HK", "", .etf, .hkd),
            (hkd, "80700.HK", "", .stock, .hkd),
            (hkd, "AAPL", "XNAS", .stock, .usd)
        ] {
            let id = try book.register(.init(name: code, code: code, market: venue, kind: kind, currency: currency))
            for event in [InvestmentEventKind.opening, .buy] {
                do {
                    try book.post(.init(day: day, kind: event, assetID: id, quantity: 1, price: 10, margin: 1), accountID: account.id)
                    preconditionFailure("Entry must match the account currency")
                } catch InvestmentError.invalid {}
            }
        }
        precondition(book.accounts.map { $0.events.count } == [1, 1])
        let cny = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        book.accounts.append(cny)
        let hk = try book.register(.init(name: "港股", code: "0700", market: "", kind: .stock, currency: .cny))
        do {
            try book.post(.init(day: day, kind: .opening, assetID: hk, quantity: 1, price: 10), accountID: cny.id)
            preconditionFailure("Hong Kong listings must be rejected in every account")
        } catch InvestmentError.invalid {}
        for (code, kind, type) in [
            ("AAPL", InvestmentKind.stock, InvestmentAccountType.securities), ("VFIAX", .fund, .fundWealth),
            ("CLZ6.NYM", .future, .futures), ("000001.SH", .stock, .securities)
        ] {
            let asset = InvestmentAsset(name: code, code: code, market: "", kind: kind, currency: .cny)
            let account = InvestmentAccount(name: "人民币账户", currency: .cny, type: type)
            do {
                try asset.validateEntry(in: account)
                preconditionFailure("Foreign instruments and indices cannot be recorded as mainland securities")
            } catch InvestmentError.invalid {}
        }
    }

    static func insuranceKeepsOnePolicyPosition() throws {
        let account = InvestmentAccount(name: "保险账户", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [account])
        let asset = InvestmentAsset(name: "测试保单", code: "POLICY-A", market: "", kind: .insurance, currency: .hkd)
        let id = try book.register(asset)
        try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 200), accountID: account.id)
        try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 1, price: 75), accountID: account.id)
        book.addQuotes([.init(day: date(2), price: 0)], assetID: id)
        let current = try book.ledger(book.accounts[0], through: date(2))
        precondition(current.cash == 125 && current.positions[id]?.quantity == 1 && current.positions[id]?.netCost == 175)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 125)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 130), accountID: account.id)
        precondition(book.value(book.accounts[0], on: date(3))?.gain == -45)
    }

    static func insurancePremiumTitlesFollowPaymentOrder() throws {
        let owner = InvestmentAccount(name: "保险", currency: .cny, type: .insurance)
        var book = InvestmentBook(accounts: [owner])
        let policy = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 300), accountID: owner.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: policy, quantity: 1, price: 100), accountID: owner.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: policy, quantity: 1, price: 100), accountID: owner.id)
        let entries = book.accounts[0].events.filter { $0.kind == .buy }
        precondition(book.eventTitle(entries[0], accountID: owner.id) == "首期保费")
        precondition(book.eventTitle(entries[1], accountID: owner.id) == "续期保费")
        precondition(book.eventTitle(entries[0]) == "首期保费")
        precondition(book.asset(policy)?.transactionTitle(.buy) == "缴纳保费")
        try book.deleteEvent(entries[0], accountID: owner.id)
        precondition(book.eventTitle(entries[1], accountID: owner.id) == "首期保费")
    }

    static func increasingPremiumUsesOnlyAdditionalCash() throws {
        for currency in [InvestmentCurrency.cny, .hkd] {
            let owner = InvestmentAccount(name: "保险", currency: currency, type: .insurance)
            var book = InvestmentBook(accounts: [owner])
            let policy = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: currency))
            try book.post(.init(day: date(1), kind: .deposit, amount: 110_000), accountID: owner.id)
            try book.post(.init(day: date(1), kind: .buy, assetID: policy, quantity: 1, price: 110_000), accountID: owner.id)
            let original = book.accounts[0].events.last!
            try book.post(.init(day: date(1), kind: .deposit, amount: 110_000), accountID: owner.id)
            let before = try book.ledger(book.accounts[0], through: date(1))
            precondition(before.cash == 110_000)
            var edited = original
            edited.price = 220_000
            try book.replaceEvent(original, with: edited, accountID: owner.id)
            let after = try book.ledger(book.accounts[0], through: date(1))
            precondition(after.cash == 0 && after.positions[policy]?.netCost == 220_000)
            precondition(book.accounts[0].events.count == 3 && after.flows == 220_000)
            let confirmed = book.accounts[0].events.first { $0.id == original.id }!
            var excessive = confirmed
            excessive.price = 220_001
            do {
                try book.replaceEvent(confirmed, with: excessive, accountID: owner.id)
                preconditionFailure("An actual shortfall must still be rejected")
            } catch InvestmentError.insufficientCash { }

            var nextDay = book
            var laterFunding = nextDay.accounts[0].events.last!
            let incoming = laterFunding
            laterFunding.day = date(2)
            do {
                try nextDay.replaceEvent(incoming, with: laterFunding, accountID: owner.id)
                preconditionFailure("A later day's cash must not fund an earlier premium")
            } catch InvestmentError.insufficientCash { }
        }
    }

    static func renminbiInsuranceCountsCashValueAndRoundTrips() throws {
        let cny = InvestmentAccount(name: "人民币保险", currency: .cny, type: .insurance)
        let hkd = InvestmentAccount(name: "港币保险", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [cny, hkd])
        let policy = try book.register(.init(name: "人民币保单", code: "POLICY-CNY", market: "", kind: .insurance, currency: .cny))
        let hkPolicy = try book.register(.init(name: "港币保单", code: "POLICY-HKD", market: "", kind: .insurance, currency: .hkd))
        try book.post(.init(day: date(1), kind: .opening, assetID: policy, quantity: 1, price: 10_000), accountID: cny.id)
        precondition(book.value(book.accounts[0], on: date(1))?.value == 0, "Missing cash value defaults to zero, never premiums")
        book.addQuotes([.init(day: date(1), price: 8_000, source: "手动录入")], assetID: policy)
        precondition(book.portfolio(on: date(1))?.value == 8_000 && book.portfolio(on: date(1))?.gain == -2_000)
        try book.post(.init(day: date(1), kind: .opening, assetID: hkPolicy, quantity: 1, price: 10_000), accountID: hkd.id)
        book.addQuotes([.init(day: date(1), price: 8_000, source: "手动录入")], assetID: hkPolicy)
        book.addExchangeRates([.init(day: date(1), price: Decimal(string: "0.9")!, isDailyClose: true)], for: .hkd)
        precondition(book.portfolio(on: date(1))?.value == 15_200)
        try book.post(.init(day: date(2), kind: .deposit, amount: 2_000), accountID: cny.id)
        try book.post(.init(day: date(2), kind: .buy, assetID: policy, quantity: 1, price: 2_000), accountID: cny.id)
        book.addQuotes([.init(day: date(2), price: 9_000, source: "手动录入"),
                        .init(day: date(3), price: 0, source: "手动录入")], assetID: policy)
        let ledger = try book.ledger(book.accounts[0], through: date(2))
        precondition(ledger.positions[policy]?.quantity == 1 && ledger.positions[policy]?.netCost == 12_000)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 9_000)
        precondition(book.portfolio(on: date(2))?.value == 16_200, "Premiums are costs and cannot be added to assets again")
        precondition(book.value(book.accounts[0], on: date(3))?.value == 0)
        try book.post(.init(day: date(4), kind: .sell, assetID: policy, quantity: 1, price: 9_500), accountID: cny.id)
        precondition(book.value(book.accounts[0], on: date(4))?.gain == -2_500)
        precondition(book.profitHistory(accountID: cny.id, assetID: policy, on: (1...4).map(date), today: date(4)).map(\.value) == [-2_000, -3_000, -12_000, -2_500])
        let records = InvestmentServerRecords()
        let restored = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
        precondition(restored.accounts[0].currency == .cny && restored.accounts[0].type == .insurance)
        precondition(restored.value(restored.accounts[0], on: date(4))?.gain == -2_500)
    }

    static func insuranceWithdrawalsKeepPolicyAndMoveCash() throws {
        for currency in [InvestmentCurrency.cny, .hkd] {
            let owner = InvestmentAccount(name: "保险", currency: currency, type: .insurance)
            var book = InvestmentBook(accounts: [owner])
            let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: currency))
            try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 10_000), accountID: owner.id)
            book.addQuotes([.init(day: date(1), price: 8_000), .init(day: date(2), price: 8_100)], assetID: id)
            let first = InvestmentEvent(day: date(2), kind: .insuranceWithdrawal, assetID: id, amount: 2_000, settledAmount: 6_000)
            try book.post(first, accountID: owner.id)
            let second = InvestmentEvent(day: date(2), kind: .insuranceWithdrawal, assetID: id, amount: 500)
            try book.post(second, accountID: owner.id)
            let ledger = try book.ledger(book.accounts[0], through: date(2), includeRows: true)
            precondition(ledger.cash == 2_500 && ledger.flows == 10_000)
            precondition(ledger.positions[id]?.quantity == 1 && ledger.positions[id]?.netCost == 10_000)
            precondition(ledger.cashRows.map(\.change) == [2_000, 500])
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_000)
            precondition(book.value(book.accounts[0], on: date(2))?.gain == -2_000)
            precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [date(1), date(2)], today: date(2)).map(\.value) == [-2_000, -2_000])
            precondition(book.holdingHistory(accountID: owner.id, assetID: id, on: [date(2)], today: date(2)).last?.value == 5_500)
            book.addQuotes([.init(day: date(3), price: 5_800)], assetID: id)
            precondition(book.value(book.accounts[0], on: date(3))?.gain == -1_700)
            precondition(book.value(book.accounts[0], on: date(2))?.gain == -2_000)
            let records = InvestmentServerRecords()
            let restored = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
            precondition(restored.accounts[0].events.contains { $0.kind == .insuranceWithdrawal && $0.settledAmount == nil })
            precondition(restored.value(restored.accounts[0], on: date(2))?.gain == -2_000)
            let savedFirst = try require(book.accounts[0].events.first { $0.id == first.id })
            let savedSecond = try require(book.accounts[0].events.first { $0.id == second.id })
            var edited = savedFirst
            edited.amount = 2_500
            edited.settledAmount = 5_900
            try book.replaceEvent(savedFirst, with: edited, accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_400)
            try book.deleteEvent(savedSecond, accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_400)
            try book.deleteEvent(try require(book.accounts[0].events.first { $0.id == first.id }), accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(2))?.value == 8_100)
            let afterDeletion = try book.ledger(book.accounts[0], through: date(2))
            precondition(afterDeletion.cash == 0)
            try book.post(first, accountID: owner.id)
            try book.post(.init(day: date(4), kind: .sell, assetID: id, quantity: 1, price: 6_100), accountID: owner.id)
            precondition(book.value(book.accounts[0], on: date(4))?.gain == -1_900)
            precondition(book.profitHistory(accountID: owner.id, assetID: id, on: [date(4)], today: date(4)).last?.value == -1_900)
            do {
                try book.post(.init(day: date(5), kind: .insuranceWithdrawal, assetID: id, amount: 1), accountID: owner.id)
                preconditionFailure("A closed policy cannot be withdrawn")
            } catch is InvestmentError { }
        }
    }

    static func insuranceWithdrawalsAllowMissingValues() throws {
        let owner = InvestmentAccount(name: "保险", currency: .cny, type: .insurance)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: .cny))
        try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 10_000), accountID: owner.id)
        let withdrawal = InvestmentEvent(day: date(2), kind: .insuranceWithdrawal, assetID: id, amount: 1_000)
        try book.post(withdrawal, accountID: owner.id)
        let ledger = try book.ledger(book.accounts[0], through: date(2))
        precondition(ledger.cash == 1_000 && ledger.positions[id]?.quantity == 1)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 1_000)
        book.addQuotes([.init(day: date(1), price: 500)], assetID: id)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 1_000, "An unavailable remaining cash value defaults to zero")
        book.addQuotes([.init(day: date(3), price: 4_000)], assetID: id)
        precondition(book.value(book.accounts[0], on: date(3))?.value == 5_000)
        let savedWithdrawal = try require(book.accounts[0].events.first { $0.id == withdrawal.id })
        var explicitZero = savedWithdrawal
        explicitZero.settledAmount = 0
        try book.replaceEvent(savedWithdrawal, with: explicitZero, accountID: owner.id)
        precondition(book.value(book.accounts[0], on: date(2))?.value == 1_000)
        let zeroValueLedger = try book.ledger(book.accounts[0], through: date(2))
        precondition(zeroValueLedger.positions[id]?.quantity == 1)
        for (amount, balance) in [(Decimal(0), Optional<Decimal>.none), (-1, nil), (1, -1)] {
            do {
                try book.post(.init(day: date(3), kind: .insuranceWithdrawal, assetID: id, amount: amount, settledAmount: balance), accountID: owner.id)
                preconditionFailure("Invalid withdrawal accepted")
            } catch is InvestmentError { }
        }
    }

    static func insuranceDefaultsToZeroAndAuditsAllProblems() throws {
        let owner = InvestmentAccount(name: "保险", currency: .cny, type: .insurance)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "保单", code: "POLICY", market: "", kind: .insurance, currency: .cny))
        try book.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 1, price: 10_000), accountID: owner.id)
        precondition(book.portfolio(on: date(1), requiresDailyPrices: true)?.value == 0)
        precondition(book.portfolio(on: date(1), requiresDailyPrices: true)?.gain == -10_000)
        book.addQuotes([.init(day: date(3), price: 8_000)], assetID: id)
        precondition(book.portfolio(on: date(2), requiresDailyPrices: true)?.value == 0, "Future cash values must not fill earlier days")
        precondition(book.portfolio(on: date(3), requiresDailyPrices: true)?.value == 8_000)
        book.addExchangeRates([.init(day: date(3), price: 7)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(3), rebuild: true)
        precondition(book.dailySnapshots?.values.count == 3, "Missing insurance cash value must not block historical snapshots")
        var report = book.inspectData(through: date(3))
        precondition(report.errors == 0 && report.notices == 1)
        precondition(report.issues[0].dates == [date(1), date(2)])
        precondition(report.issues[0].dateRanges.contains(" 至 "))

        let cryptoOwner = InvestmentAccount(name: "加密", currency: .usd, type: .crypto)
        book.accounts.append(cryptoOwner)
        let crypto = try book.register(.init(name: "BTC", code: "BTC", market: "", kind: .crypto, currency: .usd))
        try book.post(.init(day: date(1), kind: .opening, assetID: crypto, quantity: 1, price: 100), accountID: cryptoOwner.id)
        var broken = InvestmentAccount(name: "错误流水", currency: .cny, type: .insurance)
        broken.events = [.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 100)]
        book.accounts.append(broken)
        let savedCount = book.dailySnapshots?.values.count
        report = book.inspectData(through: date(3))
        precondition(report.issues.contains { $0.title == "交易记录无法计算" && $0.location.contains("错误流水") })
        precondition(report.issues.contains { $0.title == "缺少历史估值" && $0.location.contains("BTC") && $0.dates.count == 2 })
        precondition(report.issues.contains { $0.title == "缺少当前估值" && $0.location.contains("BTC") })
        precondition(report.issues.contains { $0.title == "缺少汇率" && $0.location.contains("加密") && $0.dates.contains(date(1)) },
                     "Missing prices must not hide missing conversion rates")
        precondition(book.dailySnapshots?.values.count == savedCount, "Inspection must not modify snapshots")

        var healthy = InvestmentBook(accounts: [owner])
        try healthy.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: owner.id)
        healthy.addExchangeRates([.init(day: date(1), price: 7), .init(day: date(2), price: 7)], for: .usd)
        healthy.dailySnapshots = healthy.makeDailySnapshots(through: date(2), rebuild: true)
        precondition(healthy.inspectData(through: date(3)).issues.isEmpty)
        try healthy.post(.init(day: date(2), kind: .deposit, amount: 50), accountID: owner.id)
        precondition(healthy.inspectData(through: date(3)).issues.contains { $0.title == "快照与当前账本不一致" || $0.title == "缺少日终快照" })
    }

    static func stockConnectSettlesInRenminbi() throws {
        let cny = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        let hkd = InvestmentAccount(name: "港元账户", currency: .hkd, type: .insurance)
        var book = InvestmentBook(accounts: [cny, hkd])
        precondition(InvestmentAsset.stockConnectCode("700") == "00700.HK")
        precondition(InvestmentAsset.stockConnectCode("0700.hk") == "00700.HK")
        precondition(InvestmentAsset.stockConnectCode("80700.HK") == nil)
        precondition(InvestmentAsset.stockConnectCode("09010.HK") == nil)
        let asset = InvestmentAsset(name: "腾讯控股", code: "00700.HK",
            market: InvestmentAsset.stockConnectMarket, kind: .stock, currency: .hkd)
        let id = try book.register(asset)
        let opening = InvestmentEvent(day: date(1), kind: .opening, assetID: id, quantity: 10, price: 20, settledAmount: 185)
        do {
            try book.post(opening, accountID: hkd.id)
            preconditionFailure("Stock Connect requires a CNY account")
        } catch InvestmentError.invalid {}
        try book.post(opening, accountID: cny.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: cny.id)
        do {
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 22, settledAmount: 102, fee: 3),
                          accountID: cny.id)
            preconditionFailure("Stock Connect settlement already includes fees")
        } catch InvestmentError.invalid {}
        do {
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 22), accountID: cny.id)
            preconditionFailure("Stock Connect requires the broker settlement amount")
        } catch InvestmentError.invalid {}
        try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 22, settledAmount: 102), accountID: cny.id)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 4, price: 25, settledAmount: 89), accountID: cny.id)
        book.addQuotes([.init(day: date(3), price: 24)], assetID: id)
        book.fx[.hkd] = [.init(day: date(4), price: Decimal(string: "0.9")!)]
        let saved = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))
        let account = saved.accounts[0]
        let ledger = try saved.ledger(account, through: date(4), includeRows: true)
        let position = try require(ledger.positions[id])
        precondition(ledger.cash == 987 && ledger.flows == 1185)
        precondition(ledger.cashRows.map(\.change) == [1000, -102, 89])
        precondition(position.quantity == 11 && position.netCost == 198 && position.lastEntry == 22)
        precondition(saved.value(account, on: date(3)) == nil)
        precondition(saved.positionValue(position, asset: asset, on: date(4)) == Decimal(string: "237.6"))
        precondition(saved.portfolio(on: date(4))?.gain == Decimal(string: "39.6"))
    }

    static func typedAccountsFilterAssets() throws {
        func allows(_ type: InvestmentAccountType, _ currency: InvestmentCurrency, _ kind: InvestmentKind,
                    _ code: String, market: String = "") -> Bool {
            let account = InvestmentAccount(name: "账户", currency: currency, type: type)
            let asset = InvestmentAsset(name: code, code: code, market: market, kind: kind,
                                        currency: market == InvestmentAsset.stockConnectMarket ? .hkd : currency)
            return (try? asset.validateEntry(in: account)) != nil
        }
        precondition(allows(.securities, .cny, .stock, "600519"))
        precondition(allows(.securities, .cny, .etf, "510300"))
        precondition(allows(.securities, .cny, .stock, "00700.HK", market: InvestmentAsset.stockConnectMarket))
        precondition(!allows(.fundWealth, .cny, .stock, "00700.HK", market: InvestmentAsset.stockConnectMarket))
        precondition(!allows(.securities, .cny, .option, "10001313.SH"))
        precondition(!allows(.securities, .cny, .option, "IO2611-C-4000.CFX"))
        precondition(!allows(.futures, .cny, .option, "IO2611-C-4000.CFX"))
        precondition(!allows(.futures, .cny, .option, "10001313.SH"))
        precondition(allows(.fundWealth, .cny, .fund, "110022.OF"))
        precondition(!allows(.fundWealth, .cny, .fund, "501018.SH"))
        precondition(allows(.fundWealth, .cny, .wealth, "理财产品"))
        precondition(!allows(.fundWealth, .cny, .stock, "600519"))
        precondition(!InvestmentAccountType.available(in: .usd).contains(.fundWealth))
        precondition(allows(.securities, .usd, .etf, "QQQ", market: "XNAS"))
        precondition(allows(.crypto, .usd, .crypto, "BTC"))
        precondition(!allows(.securities, .usd, .crypto, "BTC"))
        precondition(allows(.insurance, .hkd, .insurance, "POLICY"))
        precondition(allows(.insurance, .cny, .insurance, "人民币保单"))
        precondition(!allows(.insurance, .usd, .insurance, "POLICY"))
        precondition(!allows(.securities, .cny, .insurance, "POLICY"))
        precondition(!allows(.insurance, .cny, .insurance, "POLICY", market: "XSHG"))
    }

    static func fundWealthAccountsKeepBothKindsAndRoundTrip() throws {
        let account = InvestmentAccount(name: "基金理财", currency: .cny, type: .fundWealth)
        var book = InvestmentBook(accounts: [account])
        let fund = try book.register(.init(name: "场外基金", code: "110022.OF", market: "OF", kind: .fund, currency: .cny))
        let wealth = try book.register(.init(name: "银行理财", code: "理财", market: "", kind: .wealth, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: fund, quantity: 100, price: 2), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: wealth, quantity: 1, price: 300, settledAmount: 300), accountID: account.id)
        book.addQuotes([.init(day: date(2), price: 3)], assetID: fund)
        try book.adjustAssetBalance(assetID: wealth, accountID: account.id, balance: 330, on: date(2))
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        precondition(tables["investment_accounts"]?.first?["account_type"] == "fund_wealth")
        let saved = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(saved.accounts.count == 1 && saved.accounts[0].type == .fundWealth)
        let ledger = try saved.ledger(saved.accounts[0], through: date(2))
        precondition(ledger.cash == 500 && ledger.positions[fund]?.quantity == 100 && ledger.positions[wealth]?.depositBalance == 330)
        precondition(tables["investment_manual_prices"]?.isEmpty == true)
        precondition(saved.value(saved.accounts[0], on: date(2))?.value == 1130)
        precondition(saved.value(saved.accounts[0], on: date(2))?.gain == 130)
    }

    static func transfersMoveCashAsOneOperation() throws {
        let bank = InvestmentAccount(name: "银行", currency: .cny, type: .deposits)
        let broker = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        let foreign = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [bank, broker, foreign])
        let first = date(1), second = date(2)
        try book.post(.init(day: first, kind: .deposit, amount: 1000), accountID: bank.id)
        do {
            try book.transfer(from: bank.id, to: broker.id, amount: 200, remaining: 799, on: second)
            preconditionFailure("An incorrect remaining balance must reject both entries")
        } catch InvestmentError.invalid {}
        do {
            try book.transfer(from: bank.id, to: foreign.id, amount: 350, remaining: 650, on: second)
            preconditionFailure("Cross-currency transfers need the actual receipt")
        } catch InvestmentError.invalid {}
        precondition(book.accounts.map { $0.events.count } == [1, 0, 0])
        try book.transfer(from: bank.id, to: broker.id, amount: 200, remaining: 800, on: second)
        precondition(book.portfolio(on: second)?.value == 1000 && book.portfolio(on: second)?.gain == 0)
        try book.transfer(from: bank.id, to: foreign.id, amount: 350, remaining: 450, received: 50, on: second)
        let events = book.accounts.compactMap { $0.events.last }
        precondition(events[0].transferID == events[2].transferID && events[0].transferID != nil)
        precondition(events[0].transferAccountID == foreign.id && events[2].transferAccountID == bank.id)
        let balances = try book.accounts.map { try book.ledger($0, through: second).cash }
        precondition(balances == [450, 200, 50])
        book.fx[.usd] = [.init(day: second, price: 7)]
        precondition(book.portfolio(on: second)?.value == 1000 && book.portfolio(on: second)?.gain == 0)
    }

    static func depositsUseRecordedBalancesAndCashMovements() throws {
        let account = InvestmentAccount(name: "存款", currency: .cny, type: .deposits)
        var book = InvestmentBook(accounts: [account])
        let first = date(1), adjustment = date(2), interest = date(3), withdrawal = date(4), maturity = date(5)
        let asset = InvestmentAsset(name: "大额存单", code: "UNIQUE", market: "", kind: .certificate, currency: .cny,
                                    depositTerms: .init(annualRate: Decimal(string: "0.02")!, maturity: maturity))
        let id = try book.register(asset)
        try book.post(.init(day: first, kind: .deposit, amount: 200), accountID: account.id)
        try book.post(.init(day: first, kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 100), accountID: account.id)
        try book.post(.init(day: first, kind: .buy, assetID: id, quantity: 1, price: 30, settledAmount: 130), accountID: account.id)
        try book.post(.init(day: adjustment, kind: .adjustment, assetID: id, settledAmount: 133), accountID: account.id)
        try book.post(.init(day: interest, kind: .income, assetID: id, amount: 3, settledAmount: 130), accountID: account.id)
        try book.post(.init(day: withdrawal, kind: .sell, assetID: id, quantity: 1, price: 40, settledAmount: 92), accountID: account.id)
        precondition(book.portfolio(on: first)?.gain == 0)
        precondition(book.portfolio(on: adjustment, requiresDailyPrices: true)?.gain == 3)
        let interestLedger = try book.ledger(book.accounts[0], through: interest)
        precondition(interestLedger.cash == 73 && interestLedger.positions[id]?.netCost == 130)
        precondition(book.portfolio(on: interest)?.gain == 3)
        precondition(book.portfolio(on: withdrawal)?.gain == 5)
        try book.post(.init(day: maturity, kind: .sell, assetID: id, quantity: 1, price: 93, settledAmount: 0), accountID: account.id)
        let ledger = try book.ledger(book.accounts[0], through: maturity, includeRows: true)
        precondition(ledger.cashRows.map(\.change) == [200, -100, -30, 3, 40, 93])
        precondition(book.portfolio(on: maturity)?.gain == 6 && ledger.positions[id]?.realized == 6)

        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        var reloaded = try records.decode(InvestmentServerState(generation: 1, revision: 1, tables: tables))
        precondition(reloaded.asset(id)?.depositTerms == asset.depositTerms)
        precondition(reloaded.portfolio(on: withdrawal)?.gain == 5)
        let original = reloaded.accounts[0].events.first { $0.kind == .adjustment }!
        var edited = original
        edited.settledAmount = 132
        try reloaded.replaceEvent(original, with: edited, accountID: account.id)
        precondition(reloaded.portfolio(on: adjustment)?.gain == 2)
        precondition(reloaded.portfolio(on: maturity)?.gain == 6)
    }

    static func firstServerSnapshotUsesZeroOpeningGain() throws {
        let account = InvestmentAccount(name: "首日", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let stock = try book.register(.init(name: "首日持仓", code: "600000", market: "", kind: .stock, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: stock, quantity: 10, price: 2), accountID: account.id)
        book.addQuotes([.init(day: date(1), price: 3)], assetID: stock)
        book.fx[.usd] = [.init(day: date(1), price: 7)]
        book.dailySnapshots = book.makeDailySnapshots(through: date(3), rebuild: true)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        let firstRow = tables["investment_daily_snapshots"]!.first { $0["snapshot_date"] == InvestmentBook.snapshotDateFormatter().string(from: date(1)) }!
        precondition(firstRow["daily_gain_cny"] == "10", "First saved day uses zero cumulative gain before the ledger started")
        var restored = try records.decode(.init(generation: 1, revision: 1, through: records.day.string(from: date(3)), tables: tables))
        let gains = restored.dailyGains(from: date(1), through: date(3))
        precondition(gains[date(1)] == 10 && gains[date(2)] == 0 && gains[date(3)] == 0,
                     "Server snapshot mode must show the first day's actual gain without a nonexistent prior snapshot")
        let inspection = restored.inspectData(through: date(3))
        precondition(inspection.issues.isEmpty)
        precondition(inspection.snapshotDays == 2 && inspection.latestSnapshotDay == date(2)
                     && inspection.missingSnapshotDays == 0,
                     "Inspection reports saved closed days without counting today's snapshot")
        restored.dailySnapshots?.values.removeValue(forKey: date(2))
        let gap = restored.dailyGains(from: date(1), through: date(3))
        precondition(gap[date(1)] == 10 && gap[date(2)] == nil && gap[date(3)] == nil,
                     "Real gaps and the day following a gap cannot be filled with zero")
        precondition(restored.inspectData(through: date(3)).issues.contains { $0.title == "缺少日终快照" && $0.dates.contains(date(2)) })
        let missingInspection = restored.inspectData(through: date(3))
        precondition(missingInspection.snapshotDays == 1 && missingInspection.latestSnapshotDay == date(1)
                     && missingInspection.missingSnapshotDays == 1,
                     "Snapshot summary must expose an actual gap even when through is up to date")
        let emptyInspection = InvestmentBook().inspectData(through: date(3))
        precondition(emptyInspection.snapshotDays == 0 && emptyInspection.latestSnapshotDay == nil
                     && emptyInspection.missingSnapshotDays == 0)
        restored.dailySnapshots?.values.removeValue(forKey: date(1))
        precondition(restored.dailyGains(from: date(1), through: date(1))[date(1)] == nil,
                     "A missing first snapshot must remain missing")
    }

    static func dailyGainsCarryForwardMarketPrices() throws {
        let friday = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let saturday = InvestmentBook.addDays(1, to: friday)
        let sunday = InvestmentBook.addDays(2, to: friday)
        let monday = InvestmentBook.addDays(3, to: friday)
        let stockAccount = InvestmentAccount(name: "股票", currency: .cny, type: .securities)
        var stocks = InvestmentBook(accounts: [stockAccount])
        let stock = try stocks.register(.init(name: "测试股票", code: "600000", market: "", kind: .stock, currency: .cny))
        try stocks.post(.init(day: friday, kind: .deposit, amount: 100), accountID: stockAccount.id)
        try stocks.post(.init(day: friday, kind: .buy, assetID: stock, quantity: 10, price: 2), accountID: stockAccount.id)
        stocks.addQuotes([.init(day: friday, price: 3)], assetID: stock)
        let stockGains = stocks.dailyGains(from: friday, through: monday)
        precondition(stockGains[friday] == 10 && stockGains[saturday] == 0 && stockGains[sunday] == 0)
        precondition(stockGains[monday] == 0)

        let cryptoAccount = InvestmentAccount(name: "现货", currency: .usd, type: .crypto)
        var crypto = InvestmentBook(accounts: [cryptoAccount])
        let token = try crypto.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try crypto.post(.init(day: friday, kind: .deposit, amount: 100), accountID: cryptoAccount.id)
        try crypto.post(.init(day: friday, kind: .buy, assetID: token, quantity: 10, price: 2), accountID: cryptoAccount.id)
        crypto.fx[.usd] = [.init(day: friday, price: 7)]
        crypto.addQuotes([.init(day: friday, price: 3, isDailyClose: true),
                          .init(day: saturday, price: 4, source: "盘中报价"),
                          .init(day: sunday, price: 5, isDailyClose: true)], assetID: token)
        let incomplete = crypto.dailyGains(from: friday, through: sunday)
        precondition(incomplete[friday] == 70 && incomplete[saturday] == 0 && incomplete[sunday] == 140)
        crypto.addQuotes([.init(day: saturday, price: 4, isDailyClose: true)], assetID: token)
        crypto.addQuotes([.init(day: saturday, price: 99, source: "盘中报价")], assetID: token)
        let completed = crypto.dailyGains(from: friday, through: sunday)
        precondition(completed[friday] == 70 && completed[saturday] == 70 && completed[sunday] == 70)
    }

    static func allAssetPricesCarryAcrossConsecutiveGaps() throws {
        let first = InvestmentBook.calendar.date(from: DateComponents(year: 2024, month: 12, day: 24))!
        let next = InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 1, day: 15))!
        let gap = InvestmentBook.addDays(-1, to: next)
        for kind in [InvestmentKind.stock, .fund, .etf, .option, .future, .crypto, .insurance] {
            let asset = InvestmentAsset(name: kind.title, code: "TEST", market: "", kind: kind, currency: .cny)
            var book = InvestmentBook(assets: [asset.id: asset])
            book.addQuotes([.init(day: first, price: 10, isDailyClose: true),
                            .init(day: next, price: 20, isDailyClose: true)], assetID: asset.id)
            precondition(book.positionQuote(for: asset, on: gap, requiresDailyPrices: true)?.price == 10,
                         "Every quoted asset must carry across consecutive missing days, including weekdays")
            precondition(book.positionQuote(for: asset, on: next, requiresDailyPrices: true)?.price == 20)
            precondition(book.positionQuote(for: asset, on: InvestmentBook.addDays(5, to: next), requiresDailyPrices: true)?.price == 20)
            let before = book.positionQuote(for: asset, on: InvestmentBook.addDays(-1, to: first), requiresDailyPrices: true)
            precondition(kind == .insurance ? before?.price == 0 : before == nil,
                         "A future price must never fill earlier dates")
            if kind != .insurance {
                book.addQuotes([.init(day: gap, price: 99, isDailyClose: false)], assetID: asset.id)
                precondition(book.positionQuote(for: asset, on: gap, requiresDailyPrices: true)?.price == 10,
                             "Carry the last final price past a provisional quote")
            }
            precondition(book.quotes[asset.id]?.filter { $0.day == gap }.allSatisfy { $0.isDailyClose == false } == true,
                         "Carrying a price must not synthesize a final observation")
        }
        let us = InvestmentAsset(name: "US", code: "AAPL", market: "", kind: .stock, currency: .usd)
        let book = InvestmentBook(assets: [us.id: us], quotes: [us.id: [
            .init(day: first, price: 10, isDailyClose: true), .init(day: next, price: 20, isDailyClose: true)
        ]])
        precondition(book.positionQuote(for: us, on: first, requiresDailyPrices: true) == nil)
        precondition(book.positionQuote(for: us, on: next, requiresDailyPrices: true)?.price == 10,
                     "A US session close becomes effective on the following Beijing date")
        precondition(book.positionQuote(for: us, on: InvestmentBook.addDays(1, to: next), requiresDailyPrices: true)?.price == 20)
    }

    static func portfolioHistoryMatchesIndividualValuations() throws {
        let cny = InvestmentAccount(name: "境内", currency: .cny, type: .securities)
        let usd = InvestmentAccount(name: "境外", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [cny, usd])
        let stock = try book.register(.init(name: "测试股票", code: "600000", market: "", kind: .stock, currency: .cny))
        try book.post(.init(day: date(2), kind: .deposit, amount: 100), accountID: cny.id)
        try book.post(.init(day: date(2), kind: .buy, assetID: stock, quantity: 10, price: 5), accountID: cny.id)
        try book.post(.init(day: date(4), kind: .sell, assetID: stock, quantity: 3, price: 8, fee: 1), accountID: cny.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 20), accountID: cny.id)
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: usd.id)
        book.addQuotes([.init(day: date(3), price: 7), .init(day: date(4), price: 8)], assetID: stock)
        book.fx[.usd] = [.init(day: date(2), price: 7), .init(day: date(4), price: Decimal(string: "7.1")!)]
        let days = [date(5), date(3), date(1), date(2), date(3), date(4)]

        for currency in [InvestmentCurrency.cny, .usd] {
            let history = book.portfolioHistory(on: days, currency: currency)
            for day in days {
                let individual = book.portfolio(on: day, currency: currency)
                precondition(history[day]?.value == individual?.value && history[day]?.gain == individual?.gain)
            }
        }
        book.accounts[0].events.append(.init(day: date(4), kind: .withdrawal, amount: -1000))
        let history = book.portfolioHistory(on: days)
        precondition(history[date(3)] != nil && history[date(4)] != nil && history[date(5)] != nil,
                     "Display history should include an overdrawn account instead of hiding its records")
        for day in [date(4), date(5)] {
            precondition(history[day]?.value == book.portfolio(on: day)?.value)
        }
    }

    static func dailySnapshotsUseBeijingCloseAndDatedRates() throws {
        let summer = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!
        let winter = InvestmentBook.calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let calendar = InvestmentBook.calendar
        precondition(calendar.component(.hour, from: InvestmentBook.usEquityClose(on: summer)) == 4)
        precondition(calendar.component(.hour, from: InvestmentBook.usEquityClose(on: winter)) == 5)

        let thursday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        let friday = InvestmentBook.addDays(1, to: thursday)
        let saturday = InvestmentBook.addDays(2, to: thursday)
        let monday = InvestmentBook.addDays(4, to: thursday)
        let usd = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [usd])
        let stock = try book.register(.init(name: "美股", code: "AAPL", market: "", kind: .stock, currency: .usd))
        try book.post(.init(day: friday, kind: .deposit, amount: 100), accountID: usd.id)
        try book.post(.init(day: friday, kind: .buy, assetID: stock, quantity: 10, price: 5), accountID: usd.id)
        book.addExchangeRates([.init(day: friday, price: 7), .init(day: monday, price: 8)], for: .usd)
        book.addQuotes([.init(day: thursday, price: 6, isDailyClose: true),
                        .init(day: friday, price: 9, isDailyClose: false)], assetID: stock)
        book.dailySnapshots = book.makeDailySnapshots(through: monday, rebuild: true)
        precondition(book.dailySnapshots?.values[friday]?.value == 770)
        precondition(book.dailySnapshots?.values[friday]?.gain == 70)
        precondition(book.dailySnapshots?.values[saturday]?.value == 770 && book.dailySnapshots?.values[monday]?.value == 880)

        book.addQuotes([.init(day: friday, price: 7, isDailyClose: true)], assetID: stock)
        precondition(book.dailySnapshots?.values[friday] == nil)
        book.dailySnapshots = book.makeDailySnapshots(through: monday, rebuild: false)
        precondition(book.dailySnapshots?.values[saturday]?.value == 840)
        precondition(book.dailySnapshots?.values[monday]?.value == 960)
        precondition(book.dailyGains(from: friday, through: saturday)[saturday] == 70)
        book.addExchangeRates([.init(day: monday, price: 9)], for: .usd)
        precondition(book.dailySnapshots?.values[saturday]?.value == 840 && book.dailySnapshots?.values[monday] == nil)
        try book.post(.init(day: monday, kind: .deposit, amount: 20), accountID: usd.id)
        book.dailySnapshots = book.makeDailySnapshots(through: monday, rebuild: false)
        let restored = try JSONDecoder().decode(InvestmentBook.self, from: JSONEncoder().encode(book))
        precondition(restored.dailyPortfolio(on: [monday])[monday]?.value == 1260)
        precondition(restored.dailySnapshotReport(through: monday).latest?.valueUSD == 140)
        precondition(restored.dailySnapshotReport(through: monday).includesDay)
        precondition(restored.makeDailySnapshots(through: monday, rebuild: false) == nil)
    }

    static func globalInstrumentIDsAndPrices() throws {
        let vectors: [(InvestmentKind, String, String, InvestmentCurrency, String)] = [
            (.etf, "QQQM", "IEXG", .usd, "ETF:US:QQQM:USD"),
            (.etf, "qqqm.us", "XNMS", .usd, "ETF:US:QQQM:USD"),
            (.stock, "700", "HK_CONNECT", .hkd, "STOCK:HK:00700.HK:HKD"),
            (.stock, "00700.HK", "XHKG", .hkd, "STOCK:HK:00700.HK:HKD"),
            (.fund, "017302", "OF", .cny, "FUND:CN:017302.OF:CNY"),
            (.fund, "017302.OF", "", .cny, "FUND:CN:017302.OF:CNY"),
            (.etf, "159941", "XSHE", .cny, "ETF:CN:159941.SZ:CNY"),
            (.crypto, "BTCUSDT", "BINANCE", .usd, "CRYPTO:CRYPTO:BTC:USD"),
            (.crypto, "BTC/USD", "", .usd, "CRYPTO:CRYPTO:BTC:USD"),
            (.stock, "BRK/B", "NYSE", .usd, "STOCK:US:BRK%2FB:USD")
        ]
        for (kind, symbol, market, currency, expected) in vectors {
            let asset = InvestmentAsset(name: "目录名称", code: symbol, market: market, kind: kind, currency: currency)
            precondition(asset.marketInstrument.id == expected)
        }
        let a = InvestmentAsset(name: "QQQM", code: "QQQM", market: "IEXG", kind: .etf, currency: .usd)
        let b = InvestmentAsset(name: "QQQM", code: "QQQM", market: "XNMS", kind: .etf, currency: .usd)
        var book = InvestmentBook(); book.assets = [a.id: a, b.id: b]
        let day = InvestmentBook.snapshotDateFormatter().date(from: "2026-11-20")!
        book.addQuotes([.init(day: day, price: 100, source: "one", isDailyClose: false)], assetID: a.id)
        book.addQuotes([.init(day: day, price: 101, source: "two", isDailyClose: true)], assetID: b.id)
        let records = InvestmentServerRecords()
        let encoded = try records.encode(book, revision: 1)
        precondition(encoded["market_instruments"]?.count == 1 && encoded["market_daily_prices"]?.count == 1)
        precondition(encoded["market_daily_prices"]?.first?["price"] == "101")
        let decoded = try records.decode(.init(generation: 1, revision: 1, tables: encoded))
        precondition(decoded.assets[a.id]?.market == "IEXG" && decoded.assets[b.id]?.market == "XNMS")
        precondition(decoded.assets[a.id]?.instrumentID == decoded.assets[b.id]?.instrumentID)
        let shared = try records.sharedQuotes(for: b, in: .init(generation: 1, revision: 1, tables: encoded))
        precondition(shared.last?.price == 101,
            "Another ledger can reuse the global price using its canonical identity")
        var mixed = encoded
        mixed["market_daily_prices", default: []].append(["instrument_id": a.marketInstrument.id, "session_date": "2026-11-20", "price_type": "nav", "price": "999", "source": "other", "is_final": "1"])
        let filtered = try records.decode(.init(generation: 1, revision: 1, tables: mixed))
        precondition(filtered.quotes[a.id]?.last?.price == 101, "Each asset must select its own price type")
        let connect = InvestmentAsset(name: "腾讯", code: "00700.HK", market: "HK_CONNECT", kind: .stock, currency: .hkd)
        book.assets[connect.id] = connect
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: records.encode(book, revision: 1)))
        precondition(restored.assets[connect.id]?.isStockConnect == true && restored.assets[connect.id]?.settlementCurrency == .cny)
    }

    static func finalizedExchangeRatesAreReused() throws {
        let yesterday = InvestmentBook.snapshotDateFormatter().date(from: "2026-11-24")!
        let priorDay = InvestmentBook.addDays(-1, to: yesterday)
        let account = InvestmentAccount(name: "USD", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: priorDay, kind: .deposit, amount: 100), accountID: account.id)
        let prior = InvestmentQuote(day: priorDay, price: 7, source: "old", isDailyClose: true)
        let provisional = InvestmentQuote(day: yesterday, price: 7, source: "old", isDailyClose: false)
        let final = InvestmentQuote(day: yesterday, price: Decimal(string: "7.1")!, source: "欧洲央行", isDailyClose: true)
        book.addExchangeRates([prior, provisional], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: yesterday, rebuild: true)
        precondition(book.dailySnapshots?.values[yesterday]?.value == 700,
            "The previous final rate can make snapshots complete before yesterday's rate is finalized")
        precondition(book.historicalMarketDataRequests(through: yesterday, fullHistory: false).rates[.usd] == [yesterday...yesterday])
        book.addExchangeRates([final], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: yesterday, rebuild: true)
        let snapshots = book.dailySnapshots
        precondition(book.historicalMarketDataRequests(through: yesterday, fullHistory: false).rates[.usd] == nil)
        book.addExchangeRates([.init(day: yesterday, price: 9, source: "different", isDailyClose: true)], for: .usd)
        precondition(book.fx[.usd] == [prior, final] && book.dailySnapshots?.through == snapshots?.through &&
            book.dailySnapshots?.values[yesterday]?.value == snapshots?.values[yesterday]?.value &&
            book.dailySnapshots?.values[yesterday]?.value == 710,
            "Final FX must survive duplicate refreshes without invalidating snapshots")
        let encoded = try InvestmentServerRecords().encode(book, revision: 1)
        let decoded = try InvestmentServerRecords().decode(.init(generation: 1, revision: 1, tables: encoded))
        precondition(decoded.fx[.usd]?.first?.isDailyClose == true)
    }

    static func dailyExchangeRatesCarryForwardAcrossMissingDays() throws {
        let first = InvestmentBook.calendar.date(from: DateComponents(year: 2024, month: 12, day: 24))!
        let next = InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 1, day: 2))!
        let end = InvestmentBook.addDays(1, to: next)
        let account = InvestmentAccount(name: "港币", currency: .hkd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: account.id)
        book.addExchangeRates([.init(day: first, price: 1), .init(day: next, price: 2)], for: .hkd)
        book.addExchangeRates([.init(day: first, price: 5)], for: .usd)
        precondition(book.rateToCNY(.hkd, on: InvestmentBook.addDays(-1, to: first), requiresDailyPrice: true) == nil,
                     "Future FX observations must never fill earlier days")
        for offset in 0..<9 {
            let day = InvestmentBook.addDays(offset, to: first)
            precondition(book.rateToCNY(.hkd, on: day, requiresDailyPrice: true) == 1,
                         "Weekdays, holidays and consecutive gaps must carry the previous available rate")
        }
        precondition(book.rateToCNY(.hkd, on: next, requiresDailyPrice: true) == 2)
        precondition(book.rateToCNY(.hkd, on: end, requiresDailyPrice: true) == 2)
        book.dailySnapshots = book.makeDailySnapshots(through: end, rebuild: true)
        precondition(book.dailySnapshotReport(through: end).missing == 0)
        precondition(book.dailySnapshots?.values[InvestmentBook.addDays(1, to: first)]?.value == 100)
        precondition(book.dailySnapshots?.values[next]?.value == 200)
        precondition(book.dailySnapshots?.values[end]?.valueUSD == 40)
        precondition(book.inspectData(through: end).errors == 0)
        precondition(book.missingDailyMarketData(in: first...end).rates.isEmpty)

        book.addExchangeRates([.init(day: end, price: 99, isDailyClose: false)], for: .hkd)
        precondition(book.rateToCNY(.hkd, on: end) == 99)
        precondition(book.rateToCNY(.hkd, on: end, requiresDailyPrice: true) == 2,
                     "Historical snapshots must carry the latest final rate past a provisional observation")
        book.fx[.hkd] = [.init(day: next, price: 2)]
        precondition(book.inspectData(through: end).issues.contains {
            $0.title == "缺少汇率" && $0.dates.contains(first)
        }, "A genuinely missing earlier rate must still be reported")
    }

    static func accountSnapshotsStartWithEachAccountsFirstEvent() throws {
        let early = InvestmentAccount(name: "早开始", currency: .cny, type: .securities)
        let late = InvestmentAccount(name: "晚开始", currency: .cny, type: .securities)
        let empty = InvestmentAccount(name: "尚未记账", currency: .cny, type: .securities)
        let future = InvestmentAccount(name: "未来开始", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [early, late, empty, future])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: early.id)
        try book.post(.init(day: date(3), kind: .deposit, amount: 200), accountID: late.id)
        try book.post(.init(day: date(8), kind: .deposit, amount: 300), accountID: future.id)
        book.addExchangeRates([.init(day: date(1), price: 5, isDailyClose: true)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: true)
        precondition(book.dailySnapshots?.values.count == 4)
        precondition(book.dailySnapshots?.values[date(2)]?.value == 100)
        precondition(book.dailySnapshots?.values[date(3)]?.value == 300)
        precondition(book.dailySnapshots?.accountValues?[early.id]?.keys.min() == date(1))
        precondition(book.dailySnapshots?.accountValues?[late.id]?.keys.min() == date(3))
        precondition(book.dailySnapshots?.accountValues?[late.id]?.count == 2)
        precondition(book.dailySnapshots?.accountValues?[empty.id] == nil)
        precondition(book.dailySnapshots?.accountValues?[future.id] == nil)
        let records = InvestmentServerRecords()
        func encodedAccounts(_ source: InvestmentBook) throws -> [InvestmentServerRow] {
            try records.encode(source, revision: 1)["investment_account_daily_snapshots"] ?? []
        }
        let originalRows = try encodedAccounts(book)
        precondition(originalRows.count == 6)
        let earlyRows = originalRows.filter { $0["account_id"] == early.id.uuidString }
        let restored = try records.decode(.init(generation: 1, revision: 1,
            through: records.day.string(from: date(4)), tables: records.encode(book, revision: 1)))
        precondition(restored.dailySnapshots?.accountValues?[late.id]?.keys.min() == date(3))
        precondition(!restored.inspectData(through: date(4)).issues.contains { $0.title == "账户快照超出记账范围" })

        // Out-of-range derived rows are detected, excluded from writes and repaired.
        var polluted = book
        let zero = InvestmentAccountDay(cash: 0, holdings: 0, gain: 0)
        polluted.dailySnapshots?.accountValues?[late.id]?[date(1)] = zero
        polluted.dailySnapshots?.accountValues?[empty.id] = [date(1): zero]
        let pollutedRows = try encodedAccounts(polluted)
        precondition(pollutedRows == originalRows)
        precondition(polluted.inspectData(through: date(4)).issues.contains {
            $0.title == "账户快照超出记账范围" && $0.dates.contains(date(1))
        })
        polluted.dailySnapshots = polluted.makeDailySnapshots(through: date(4), rebuild: true)
        let repairedRows = try encodedAccounts(polluted)
        precondition(repairedRows == originalRows)

        let original = try require(book.account(late.id)?.events.first)
        var moved = original
        moved.day = date(2)
        try book.replaceEvent(original, with: moved, accountID: late.id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.accountValues?[late.id]?.keys.min() == date(2))
        let movedRows = try encodedAccounts(book)
        precondition(movedRows.filter { $0["account_id"] == early.id.uuidString } == earlyRows,
                     "Changing one account's start must not change another account's snapshot values")
        try book.deleteEvent(try require(book.account(late.id)?.events.first), accountID: late.id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.accountValues?[late.id] == nil)
        let remainingRows = try encodedAccounts(book)
        precondition(remainingRows == earlyRows)
        try book.post(.init(day: date(4), kind: .withdrawal, amount: -100), accountID: early.id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.accountValues?[early.id]?[date(4)]?.cash == 0,
                     "A genuine zero balance after the account starts must keep its snapshot")
        precondition(!book.inspectData(through: date(4)).issues.contains { $0.title == "账户快照超出记账范围" })
    }

    static func changingHistoricalEntriesInvalidatesOnlyTheAffectedDays() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(3), kind: .adjustment, amount: 30), accountID: account.id)
        let first = try require(book.account(account.id)?.events.first)
        let later = try require(book.account(account.id)?.events.last)
        book.addExchangeRates([.init(day: date(1), price: 5), .init(day: date(2), price: 10),
                               .init(day: date(3), price: 10), .init(day: date(4), price: 10)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: true)
        precondition(book.dailySnapshots?.values[date(1)]?.valueUSD == 20)

        var earlier = later
        earlier.day = date(2)
        earlier.amount = 50
        try book.replaceEvent(later, with: earlier, accountID: account.id)
        precondition(book.snapshotStart(rebuild: false) == date(2))
        precondition(book.dailySnapshots?.values[date(1)]?.value == 100)
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.values[date(2)]?.valueUSD == 15)

        let confirmedEarlier = try require(book.account(account.id)?.events.last)
        var moved = confirmedEarlier
        moved.day = date(4)
        try book.replaceEvent(confirmedEarlier, with: moved, accountID: account.id)
        precondition(book.snapshotStart(rebuild: false) == date(2))
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(book.dailySnapshots?.values[date(2)]?.valueUSD == 10)
        try book.deleteEvent(try require(book.account(account.id)?.events.last), accountID: account.id)
        precondition(book.snapshotStart(rebuild: false) == date(4))
        book.dailySnapshots = book.makeDailySnapshots(through: date(4), rebuild: false)
        try book.deleteEvent(first, accountID: account.id)
        precondition(book.earliest == nil && book.dailySnapshots?.values.isEmpty == true)
    }

    static func changingTransfersIsAtomic() throws {
        let source = InvestmentAccount(name: "人民币", currency: .cny, type: .securities)
        let target = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [source, target])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: source.id)
        try book.transfer(from: source.id, to: target.id, amount: 70, remaining: 30, received: 10, on: date(2))
        let incoming = try require(book.account(target.id)?.events.first)
        var edited = incoming
        edited.day = date(3)
        edited.amount = 12
        try book.replaceEvent(incoming, with: edited, accountID: target.id, counterpartAmount: -84)
        let outgoing = try require(book.account(source.id)?.events.last)
        precondition(outgoing.day == date(3) && outgoing.amount == -84)
        try book.post(.init(day: date(4), kind: .withdrawal, amount: -10), accountID: target.id)
        do {
            try book.deleteEvent(outgoing, accountID: source.id)
            preconditionFailure("A transfer that funds a later withdrawal must remain intact")
        } catch InvestmentError.insufficientCash {}
        precondition(book.account(source.id)?.events.contains(outgoing) == true)
        precondition(book.account(target.id)?.events.contains(where: { $0.id == edited.id && $0.amount == edited.amount }) == true)
        try book.deleteEvent(try require(book.account(target.id)?.events.last), accountID: target.id)
        try book.deleteEvent(outgoing, accountID: source.id)
        precondition(book.account(source.id)?.events.count == 1 && book.account(target.id)?.events.isEmpty == true)
    }

    static func dailyQuotesReuseCachedMarketCloses() throws {
        let monday = InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 10, day: 6))!
        let friday = InvestmentBook.addDays(-3, to: monday)
        let saturday = InvestmentBook.addDays(-2, to: monday)
        let tuesday = InvestmentBook.addDays(1, to: monday)
        let account = InvestmentAccount(name: "美元", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "测试", code: "AAPL", market: "", kind: .stock, currency: .usd))
        try book.post(.init(day: saturday, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: saturday, kind: .buy, assetID: id, quantity: 1, price: 100), accountID: account.id)
        let historyStart = InvestmentBook.addDays(-30, to: friday)
        let missing = book.missingDailyMarketData(in: historyStart...tuesday)
        precondition(missing.assets[id] == [friday...friday, monday...monday])
        precondition(missing.rates[.usd] == [friday...tuesday])
        book.addQuotes([.init(day: friday, price: 100, isDailyClose: true),
                        .init(day: monday, price: 110, isDailyClose: false)], assetID: id)
        precondition(book.missingDailyMarketData(in: monday...tuesday).assets.isEmpty,
                     "An earlier close must remain usable past a provisional quote and a missing session")
        book.addQuotes([.init(day: monday, price: 110, isDailyClose: true)], assetID: id)
        book.addExchangeRates([.init(day: friday, price: 7), .init(day: monday, price: 7), .init(day: tuesday, price: 7)], for: .usd)
        let complete = book.missingDailyMarketData(in: historyStart...tuesday)
        precondition(complete.assets.isEmpty && complete.rates.isEmpty)
        book.dailySnapshots = book.makeDailySnapshots(through: tuesday, rebuild: true)
        precondition(book.dailyQuoteWindow(through: tuesday) == nil)
    }

    static func serverRoundTripPreservesShortFuturesAndSnapshots() throws {
        let account = InvestmentAccount(name: "期货", currency: .cny, type: .futures)
        var book = InvestmentBook(accounts: [account])
        let long = InvestmentAsset(name: "沪铜", code: "CU2612.SHF", market: "SHFE", kind: .future,
                                   currency: .cny, multiplier: 5, contractSide: .long)
        var short = long
        short.id = UUID()
        short.contractSide = .short
        let longID = try book.register(long)
        let shortID = try book.register(short)
        precondition(longID != shortID)
        try book.post(.init(day: date(1), kind: .deposit, amount: 1_000), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: shortID, quantity: 2, price: 100, margin: 50), accountID: account.id)
        try book.post(.init(day: date(2), kind: .derivativeSettlement, assetID: shortID, amount: 100, price: 90), accountID: account.id)
        book.addQuotes([.init(day: date(3), price: 85, source: "test", isDailyClose: true)], assetID: shortID)
        book.addExchangeRates([.init(day: date(2), price: 5), .init(day: date(3), price: 5)], for: .usd)
        book.dailySnapshots = book.makeDailySnapshots(through: date(3), rebuild: true)
        precondition(book.dailySnapshots?.values[date(2)]?.value == 1_100)
        precondition(book.dailySnapshots?.values[date(3)]?.value == 1_150)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 3)
        precondition(tables["market_derivative_specs"]?.count == 1)
        precondition(tables["investment_derivative_event_details"]?.contains { $0["trade_action"] == "open_short" } == true)
        let state = InvestmentServerState(generation: 4, revision: 3, through: records.day.string(from: date(3)), tables: tables)
        let restored = try records.decode(state)
        precondition(restored.usesServerSnapshots)
        precondition(restored.assets[shortID]?.contractSide == .short)
        precondition(restored.dailySnapshots?.values[date(3)]?.valueUSD == 230)
        precondition(restored.dailySnapshots?.accountValues?[account.id]?[date(3)]?.gain == 150)
    }

    static func archivesOnlyEmptyAccountsAndPreservesHistory() throws {
        let account = InvestmentAccount(name: "可归档", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = InvestmentAsset(name: "股票", code: "600000", market: "XSHG", kind: .stock, currency: .cny)
        let id = try book.register(asset)
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 10, price: 10), accountID: account.id)
        precondition(book.archiveBlocker(accountID: account.id) != nil, "Missing quotes do not make a held position empty")
        do { try book.setArchived(true, accountID: account.id); preconditionFailure("Nonzero holdings must not archive") }
        catch is InvestmentError { }
        try book.post(.init(day: date(2), kind: .sell, assetID: id, quantity: 10, price: 10), accountID: account.id)
        precondition(book.archiveBlocker(accountID: account.id) != nil, "Cash still prevents archiving")
        try book.post(.init(day: date(2), kind: .withdrawal, amount: -100), accountID: account.id)
        book.plans = [.init(accountID: account.id, amount: 100, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3))]
        let events = try require(book.account(account.id)).events
        let position = try require(book.ledger(book.accounts[0]).positions[id])
        precondition(book.positionIsEmpty(position, assetID: id))
        precondition(!book.positionIsEmpty(.init(quantity: 0, margin: 1), assetID: id))
        try book.setArchived(true, accountID: account.id, at: date(3))
        precondition(book.visibleAccounts(showArchived: false).isEmpty)
        precondition(book.visibleAccounts(showArchived: true).count == 1)
        precondition(book.accounts[0].events == events && !book.plans[0].enabled)
        do { try book.post(.init(day: date(3), kind: .deposit, amount: 1), accountID: account.id); preconditionFailure("Archived accounts are read only") }
        catch is InvestmentError { }
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        var restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(restored.accounts[0].archivedAt == date(3))
        let roundTrip = try records.encode(restored, revision: 1)
        precondition(roundTrip["investment_events"] == tables["investment_events"])
        try restored.setArchived(false, accountID: account.id)
        precondition(restored.visibleAccounts(showArchived: false).count == 1 && !restored.plans[0].enabled)
        try restored.post(.init(day: date(3), kind: .deposit, amount: 1), accountID: account.id)
    }

    static func deletesOnlyTheSelectedHoldingAndItsRecords() throws {
        let left = InvestmentAccount(name: "左", currency: .cny, type: .securities)
        let right = InvestmentAccount(name: "右", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [left, right])
        let id = try book.register(.init(name: "共享标的", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        for account in [left, right] {
            try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
            try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 10), accountID: account.id)
            let event = try require(book.account(account.id)?.events.last)
            let plan = InvestmentPlan(accountID: account.id, assetID: id, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3))
            book.plans.append(plan)
            book.planRuns.append(.init(planID: plan.id, day: date(1), status: "executed", eventID: event.id, executedAt: date(1), detail: nil))
        }
        book.watched = [id]
        book.addQuotes([.init(day: date(2), price: 10)], assetID: id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(2), rebuild: true)
        let rightEvents = try require(book.account(right.id)).events
        try book.deleteInvestment(accountID: left.id, assetID: id)
        let ledger = try book.ledger(try require(book.account(left.id)))
        precondition(ledger.positions[id] == nil && ledger.cash == 100)
        precondition(book.account(right.id)?.events == rightEvents && book.asset(id) != nil && book.watched == [id])
        precondition(book.plans.count == 1 && book.plans[0].accountID == right.id && book.planRuns.count == 1)
        precondition(book.dailySnapshots?.through == date(0))
        precondition(book.investmentMonthEndValues.isEmpty)
        let records = InvestmentServerRecords()
        let rows = try records.encode(book, revision: 2)
        precondition(rows["investment_events"]?.filter { $0["account_id"] == left.id.uuidString }.count == 1)
    }

    static func deletesAccountsAndPairedTransfersAtomically() throws {
        let source = InvestmentAccount(name: "来源", currency: .cny, type: .securities)
        let target = InvestmentAccount(name: "目标", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [source, target])
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: source.id)
        try book.transfer(from: source.id, to: target.id, amount: 50, remaining: 50, on: date(2))
        try book.post(.init(day: date(3), kind: .withdrawal, amount: -40), accountID: target.id)
        let before = book.accounts.map(\.events)
        do { try book.deleteInvestment(accountID: source.id); preconditionFailure("Removing spent transfer proceeds must fail atomically") }
        catch is InvestmentError { }
        precondition(book.accounts.map(\.events) == before && book.accounts.count == 2)
        try book.deleteEvent(try require(book.account(target.id)?.events.last), accountID: target.id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(3), rebuild: true)
        try book.deleteInvestment(accountID: source.id)
        precondition(book.accounts.count == 1 && book.accounts[0].id == target.id && book.accounts[0].events.isEmpty)
        precondition(book.dailySnapshots?.accountValues?[source.id] == nil)
        let rows = try InvestmentServerRecords().encode(book, revision: 3)
        precondition(rows["investment_account_daily_snapshots"]?.allSatisfy { $0["account_id"] != source.id.uuidString } == true)
    }

    static func deletesUnreferencedRegistrationsAndTheirQuotes() throws {
        let account = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let used = try book.register(.init(name: "持仓标的", code: "600000", market: "XSHG", kind: .stock, currency: .cny))
        let planned = try book.register(.init(name: "定投标的", code: "600001", market: "XSHG", kind: .stock, currency: .cny))
        let unrelated = try book.register(.init(name: "独立登记", code: "600002", market: "XSHG", kind: .stock, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: used, quantity: 1, price: 10), accountID: account.id)
        for id in [used, planned, unrelated] { book.addQuotes([.init(day: date(2), price: 10, source: "测试行情")], assetID: id) }
        book.plans = [.init(accountID: account.id, assetID: planned, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3))]
        precondition(book.deletionMessage(accountID: account.id, assetID: used).contains("同时删除无其他引用的标的登记及报价：持仓标的"))
        try book.deleteInvestment(accountID: account.id, assetID: used)
        precondition(book.asset(used) == nil && book.quotes[used] == nil)
        precondition(book.asset(planned) != nil && book.asset(unrelated) != nil && book.quotes[unrelated]?.count == 1)
        let ledger = try book.ledger(try require(book.account(account.id)))
        precondition(ledger.cash == 100 && ledger.positions.isEmpty)
        try book.deleteInvestment(accountID: account.id)
        precondition(book.asset(planned) == nil && book.quotes[planned] == nil && book.plans.isEmpty)
        precondition(book.assets.count == 1 && book.asset(unrelated) != nil)
        let records = InvestmentServerRecords()
        let rows = try records.encode(book, revision: 2)
        precondition(rows["investment_assets"]?.count == 1 && rows["market_instruments"]?.count == 1 && rows["market_daily_prices"]?.count == 1)
        let restored = try records.decode(.init(generation: 1, revision: 2, tables: rows))
        precondition(restored.asset(unrelated) != nil && restored.accounts.isEmpty)
    }

    static func deletionPreservesPlanReferences() throws {
        let owner = InvestmentAccount(name: "证券", currency: .cny, type: .securities)
        let other = InvestmentAccount(name: "另一账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [owner, other])
        let id = try book.register(.init(name: "测试", code: "600000", market: "SH", kind: .stock, currency: .cny))
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 10, price: 1), accountID: owner.id, autoFundCash: true)
        book.plans = [.init(accountID: other.id, assetID: id, amount: 10, schedule: try .init(frequency: .monthly, day: 1), nextDay: date(3), enabled: false)]
        try book.deleteInvestment(accountID: owner.id)
        precondition(book.asset(id) != nil && book.plans.count == 1)
    }

    static func genericBalancesSeparateValuationFromCashFlows() throws {
        let owner = InvestmentAccount(name: "Binance", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "策略账户", code: UUID().uuidString, market: "", kind: .generic, currency: .usd))
        precondition(owner.kinds == [.crypto, .generic])
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 10000, settledAmount: 10400), accountID: owner.id, autoFundCash: true)
        precondition(book.value(book.accounts[0], on: date(1))?.gain == 400)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 10800, on: date(2))
        let adjusted = try book.ledger(book.accounts[0], through: date(2), includeRows: true)
        precondition(adjusted.cash == 0 && adjusted.flows == 10000 && adjusted.cashRows.count == 2)
        precondition(adjusted.positions[id]?.depositBalance == 10800 && book.value(book.accounts[0], on: date(2))?.gain == 800)
        try book.post(.init(day: date(3), kind: .buy, assetID: id, quantity: 1, price: 1000), accountID: owner.id, autoFundCash: true)
        try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 500), accountID: owner.id)
        let moved = try book.ledger(book.accounts[0], through: date(3))
        precondition(moved.cash == 500 && moved.positions[id]?.depositBalance == 11300)
        precondition(book.value(book.accounts[0], on: date(3))?.gain == 800)
        try book.post(.init(day: date(4), kind: .sell, assetID: id, quantity: 1, price: 11300), accountID: owner.id)
        let closed = try book.ledger(book.accounts[0], through: date(4))
        precondition(closed.positions[id]?.quantity == 0 && closed.positions[id]?.realized == 800)
        try book.post(.init(day: date(5), kind: .buy, assetID: id, quantity: 1, price: 2000), accountID: owner.id)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 0, on: date(6))
        precondition(book.value(book.accounts[0], on: date(6))?.gain == -1200)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 2100, on: date(7))
        precondition(book.value(book.accounts[0], on: date(7), requiresDailyPrices: true)?.gain == 900)
        let records = InvestmentServerRecords()
        let tables = try records.encode(book, revision: 1)
        precondition(tables["market_instruments"]?.isEmpty == true)
        precondition(tables["investment_assets"]?.first?["asset_type"] == "generic")
        let restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
        precondition(restored.value(restored.accounts[0], on: date(7))?.gain == 900)
        precondition(!restored.assets[id]!.kind.supportsPlan && !restored.assets[id]!.kind.requiresCatalog)
    }

    static func genericBalancesValidateAndReplayHistory() throws {
        let owner = InvestmentAccount(name: "通用", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [owner])
        let id = try book.register(.init(name: "策略", code: UUID().uuidString, market: "", kind: .generic, currency: .usd))
        let repeated = try book.register(.init(name: "策略", code: UUID().uuidString, market: "", kind: .generic, currency: .usd))
        precondition(id == repeated)
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 0), accountID: owner.id, autoFundCash: true)
        precondition(book.value(book.accounts[0], on: date(1))?.gain == -100)
        try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 150, on: date(2))
        for event in [InvestmentEvent(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 151),
                      .init(day: date(3), kind: .buy, assetID: id, quantity: 1, price: 10, settledAmount: 170),
                      .init(day: date(3), kind: .adjustment, assetID: id, settledAmount: -1)] {
            let before = book.accounts[0].events
            do { try book.post(event, accountID: owner.id, autoFundCash: true); preconditionFailure("invalid balance operation") }
            catch is InvestmentError { }
            precondition(book.accounts[0].events == before)
        }
        do { try book.adjustAssetBalance(assetID: id, accountID: owner.id, balance: 150, on: date(2)); preconditionFailure("unchanged balance") }
        catch is InvestmentError { }
        let original = book.accounts[0].events.last!
        var edited = original; edited.settledAmount = 175
        try book.replaceEvent(original, with: edited, accountID: owner.id)
        precondition(book.value(book.accounts[0], on: date(1))?.gain == -100)
        precondition(book.value(book.accounts[0], on: date(2))?.gain == 75)
        try book.deleteEvent(book.accounts[0].events.last!, accountID: owner.id)
        precondition(book.value(book.accounts[0], on: date(2))?.gain == -100)
        do { try book.assets[id]!.validateEntry(in: .init(name: "人民币", currency: .cny, type: .securities)); preconditionFailure("generic currency") }
        catch is InvestmentError { }
    }

    static func holdingHistoryTracksQuantitiesAndAmounts() throws {
        let account = InvestmentAccount(name: "持仓", currency: .usd, type: .crypto)
        let other = InvestmentAccount(name: "另一账户", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account, other])
        let token = try book.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try book.post(.init(day: date(1), kind: .opening, assetID: token, quantity: 2, price: 10), accountID: account.id)
        try book.post(.init(day: date(1), kind: .opening, assetID: token, quantity: 99, price: 10), accountID: other.id)
        try book.adjustSpotBalance(assetID: token, accountID: account.id, balance: 3, on: date(3))
        try book.post(.init(day: date(4), kind: .sell, assetID: token, quantity: 1, price: 12), accountID: account.id)
        book.addQuotes([.init(day: date(1), price: 10, isDailyClose: true),
                        .init(day: date(3), price: 11, isDailyClose: true),
                        .init(day: date(4), price: 12, isDailyClose: true),
                        .init(day: date(5), price: 13)], assetID: token)
        let days = (0...6).map { InvestmentBook.addDays($0 - 1, to: date(1)) }
        let points = book.holdingHistory(accountID: account.id, assetID: token, on: days, today: date(5))
        precondition(points.map(\.day) == [date(1), date(2), date(3), date(4), date(5)])
        precondition(points.map(\.value) == [2, 2, 3, 2, 2], "Quantity history must be independent of quotes and other accounts")
        precondition(points.allSatisfy { $0.segment == 0 }, "Missing prices must not create gaps in quantity history")
        let one = book.holdingHistory(accountID: account.id, assetID: token, on: [date(5)], today: date(5))
        precondition(one.count == 1 && one[0].value == 2)
        try book.post(.init(day: date(6), kind: .sell, assetID: token, quantity: 2, price: 13), accountID: account.id)
        let closed = book.holdingHistory(accountID: account.id, assetID: token, on: [date(6)], today: date(6))
        precondition(closed.first?.value == 0, "Closing a holding must show zero without requiring a quote")

        let cash = InvestmentAccount(name: "手工资产", currency: .usd, type: .crypto)
        var manual = InvestmentBook(accounts: [cash])
        let balance = try manual.register(.init(name: "余额", code: "BALANCE", market: "", kind: .generic, currency: .usd))
        try manual.post(.init(day: date(1), kind: .opening, assetID: balance, quantity: 1, price: 100), accountID: cash.id)
        try manual.post(.init(day: date(2), kind: .adjustment, assetID: balance, settledAmount: 150), accountID: cash.id)
        let balances = manual.holdingHistory(accountID: cash.id, assetID: balance, on: [date(1), date(2)], today: date(3))
        precondition(balances.map(\.value) == [100, 150], "Manual balances must not require market quotes")
    }

    static func deletedAndRecreatedHoldingsInvalidateSnapshotsWithoutCache() throws {
        let owner = InvestmentAccount(name: "重建持仓", currency: .usd, type: .crypto)
        var original = InvestmentBook(accounts: [owner])
        let id = try original.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try original.post(.init(day: date(1), kind: .opening, assetID: id, quantity: 10, price: 1), accountID: owner.id)
        original.addQuotes((1...4).map { .init(day: date($0), price: 1, isDailyClose: true) }, assetID: id)
        original.addExchangeRates((1...4).map { .init(day: date($0), price: 7) }, for: .usd)
        original.dailySnapshots = original.makeDailySnapshots(through: date(4), rebuild: true)
        var deleted = original
        try deleted.deleteInvestment(accountID: owner.id, assetID: id)
        precondition(deleted.snapshotInputChange(comparedTo: original) == date(1))
        // The previous cutoff may be absent after the last holding is removed.
        deleted.dailySnapshots = nil
        var recreated = deleted
        let nextID = try recreated.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        try recreated.post(.init(day: date(2), kind: .opening, assetID: nextID, quantity: 20, price: 2), accountID: owner.id)
        precondition(recreated.snapshotInputChange(comparedTo: deleted) == date(2))
        precondition(recreated.snapshotInputChange(comparedTo: recreated) == nil)
        recreated.addQuotes((2...4).map { .init(day: date($0), price: 2, isDailyClose: true) }, assetID: nextID)
        recreated.dailySnapshots = recreated.makeDailySnapshots(through: date(4), rebuild: false)
        precondition(recreated.dailySnapshots?.values[date(2)]?.value == 280)
        precondition(!recreated.inspectData(through: date(4)).issues.contains { $0.title == "快照与当前账本不一致" })
        var stale = recreated
        stale.dailySnapshots?.values[date(2)] = .init(value: 70, gain: 0, valueUSD: 10)
        precondition(stale.inspectData(through: date(4)).issues.contains {
            $0.title == "快照与当前账本不一致" && $0.dates.contains(date(2))
        }, "Manual data inspection must report stale history without rewriting it")
        precondition(stale.dailySnapshots?.values[date(2)]?.value == 70)
        stale.dailySnapshots = stale.makeDailySnapshots(through: date(4), rebuild: true)
        precondition(stale.dailySnapshots?.values[date(2)]?.value == 280)
        let records = InvestmentServerRecords()
        let tables = try records.encode(recreated, revision: 3)
        let loaded = try records.decode(.init(generation: 3, revision: 3, through: records.day.string(from: date(4)), tables: tables))
        precondition(loaded.dailySnapshots?.values[date(2)]?.value == 280)
        var moved = recreated
        let event = try require(moved.account(owner.id)?.events.first)
        var changed = event
        changed.day = date(1)
        try moved.replaceEvent(event, with: changed, accountID: owner.id)
        precondition(moved.snapshotInputChange(comparedTo: recreated) == date(1))
    }

    static func fundAndWealthHistoryTracksNetInvestment() throws {
        for kind in [InvestmentKind.fund, .wealth] {
            let account = InvestmentAccount(name: kind.rawValue, currency: .cny, type: .fundWealth)
            var book = InvestmentBook(accounts: [account])
            let id = try book.register(.init(name: "投入测试", code: "000001", market: "", kind: kind, currency: .cny))
            try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
            if kind == .wealth {
                try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 100), accountID: account.id)
                try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 200), accountID: account.id)
                try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 1, price: 100, settledAmount: 100), accountID: account.id)
                try book.adjustAssetBalance(assetID: id, accountID: account.id, balance: 110, on: date(4))
                try book.post(.init(day: date(5), kind: .sell, assetID: id, quantity: 1, price: 110, settledAmount: 0), accountID: account.id)
                let points = book.holdingHistory(accountID: account.id, assetID: id, on: (1...5).map(date), today: date(5))
                precondition(points.map(\.value) == [100, 200, 100, 100, -10])
                continue
            }
            try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 10, price: 10, fee: 1), accountID: account.id)
            try book.post(.init(day: date(2), kind: .buy, assetID: id, quantity: 5, price: 20, fee: 2), accountID: account.id)
            try book.post(.init(day: date(3), kind: .sell, assetID: id, quantity: 4, price: 25, fee: 1), accountID: account.id)
            try book.post(.init(day: date(5), kind: .sell, assetID: id, quantity: 11, price: 10, fee: 1), accountID: account.id)
            book.addQuotes([.init(day: date(4), price: 99)], assetID: id)
            let points = book.holdingHistory(accountID: account.id, assetID: id, on: (1...5).map(date), today: date(5))
            precondition(points.map(\.value) == [101, 203, 104, 104, -5], "Fund and wealth charts must show net invested cash, independent of quantity and quotes")
            precondition(book.asset(id)?.historyUsesInvestment == true && book.asset(id)?.historyUsesAmount == true)
        }
        let etf = InvestmentAsset(name: "ETF", code: "TEST", market: "", kind: .etf, currency: .cny)
        precondition(!etf.historyUsesAmount, "ETF remains a quantity-based asset")
    }

    static func wealthUsesAmountsAndReportedBalances() throws {
        let account = InvestmentAccount(name: "理财余额", currency: .cny, type: .fundWealth)
        var book = InvestmentBook(accounts: [account])
        let id = try book.register(.init(name: "银行理财", code: "PRODUCT", market: "", kind: .wealth, currency: .cny))
        try book.post(.init(day: date(1), kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: id, quantity: 1, price: 500, settledAmount: 500), accountID: account.id)
        try book.adjustAssetBalance(assetID: id, accountID: account.id, balance: 520, on: date(2))
        precondition(book.value(book.accounts[0], on: date(2))?.gain == 20)
        try book.post(.init(day: date(3), kind: .buy, assetID: id, quantity: 1, price: 100, settledAmount: 620), accountID: account.id)
        try book.post(.init(day: date(4), kind: .income, assetID: id, amount: 20, settledAmount: 600), accountID: account.id)
        precondition(book.value(book.accounts[0], on: date(4))?.gain == 20, "An income withdrawal must not count already valued gains twice")
        try book.post(.init(day: date(5), kind: .sell, assetID: id, quantity: 1, price: 200, settledAmount: 405), accountID: account.id)
        precondition(book.value(book.accounts[0], on: date(5))?.gain == 25)
        try book.post(.init(day: date(6), kind: .sell, assetID: id, quantity: 1, price: 410, settledAmount: 0), accountID: account.id)
        let ledger = try book.ledger(book.accounts[0], through: date(6))
        precondition(ledger.cash == 1030 && ledger.positions[id]?.depositBalance == 0 && ledger.positions[id]?.quantity == 0)
        precondition(book.value(book.accounts[0], on: date(6))?.gain == 30)
        precondition(book.quotes[id]?.isEmpty != false, "Wealth balances must not require unit NAV quotes")
        do {
            try book.post(.init(day: date(7), kind: .buy, assetID: id, quantity: 1, price: 100), accountID: account.id)
            preconditionFailure("A wealth cash movement requires the reported balance")
        } catch is InvestmentError { }
        do {
            try book.post(.init(day: date(7), kind: .buy, assetID: id, quantity: 2, price: 100, settledAmount: 200), accountID: account.id)
            preconditionFailure("Wealth amounts cannot be multiplied by a user-entered share count")
        } catch is InvestmentError { }
    }

    static func manualQuotesAreLimitedToInsurance() throws {
        for kind in InvestmentKind.allCases { precondition(kind.supportsManualQuote == (kind == .insurance)) }
        for (kind, code) in [(InvestmentKind.stock, "600036"), (.etf, "510300"), (.fund, "110022.OF"), (.future, "RB2701.SHF"), (.option, "10012189.SH"), (.wealth, "PRODUCT")] {
            var book = InvestmentBook()
            let id = try book.register(.init(name: "自动行情", code: code, market: "", kind: kind, currency: .cny))
            book.addQuotes([.init(day: date(1), price: 10, source: "东方财富", isDailyClose: true)], assetID: id)
            book.addQuotes([.init(day: date(1), price: 99, source: "手动录入")], assetID: id)
            precondition(book.quote(id, on: date(1))?.price == 10 && book.quote(id, on: date(1))?.source == "东方财富")
        }
    }

    static func accountOrderSurvivesSaving() throws {
        var accounts = (0..<4).map { InvestmentAccount(name: "账户\($0)", currency: .cny, type: .securities) }
        accounts[1].archivedAt = date(1)
        for index in accounts.indices {
            accounts[index].events = [.init(day: date(1), kind: .deposit, amount: Decimal(index + 1))]
        }
        let records = InvestmentServerRecords()
        let original = try records.decode(.init(generation: 1, revision: 1,
            tables: records.encode(InvestmentBook(accounts: accounts), revision: 1)))
        var book = original
        let orders = [[0, 3, 2], [2, 0, 3], [3, 2, 0]]
        for order in orders {
            let visible = order.map { accounts[$0].id }
            try book.reorderAccounts(visible)
            precondition(book.visibleAccounts(showArchived: false).map(\.id) == visible)
            precondition(book.accounts[1].id == accounts[1].id, "A hidden archived account must retain its slot")
            precondition(book.snapshotInputChange(comparedTo: original) == nil, "Reordering cannot dirty financial snapshots")
            var tables = try records.encode(book, revision: 1)
            if let rows = tables["investment_accounts"] { tables["investment_accounts"] = Array(rows.reversed()) }
            let restored = try records.decode(.init(generation: 1, revision: 1, tables: tables))
            precondition(restored.accounts.map(\.id) == book.accounts.map(\.id),
                         "Saving and decoding unordered server rows must keep the requested account order")
            for account in restored.accounts {
                precondition(account.events == original.account(account.id)?.events, "Account ordering must not move another account's events")
            }
            book = restored
        }
        let all = accounts.reversed().map(\.id)
        try book.reorderAccounts(all)
        precondition(book.accounts.map(\.id) == all, "Archived accounts can move when included in the displayed list")
        for invalid in [[accounts[0].id, accounts[0].id], [UUID()]] {
            do { try book.reorderAccounts(invalid); preconditionFailure("Invalid account order must be rejected") }
            catch InvestmentError.invalid { }
            precondition(book.accounts.map(\.id) == all, "Rejected ordering must leave every account intact")
        }
    }

    static func date(_ day: Int) -> Date {
        InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 10, day: day))!
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw InvestmentError.invalid("Missing test value") }
        return value
    }
}
