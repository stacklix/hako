import Foundation

@main
struct InvestmentBookTests {
    static func main() throws {
        try ledgerAndDilutedCost()
        try firstPurchaseRequiresCash()
        try purchasesCanAutomaticallyFundCashShortfalls()
        try tradingFeesAffectCashAndDilutedCost()
        try futuresFeesStaySeparateFromMargin()
        try cryptoContractsTrackDirectionAndMargin()
        try stablecoinContractsShareUSDCash()
        try coinContractInputConvertsToWholeContracts()
        try coinContractsUseInversePricing()
        try coinContractsOnlyRequireConversionForCashChanges()
        try fundingBalanceAdjustmentsTrackSettlementAndAttribution()
        try cashMarginFundingIsRecognizedOnce()
        try stockDistributionsKeepPurchaseCost()
        try fundsAndETFsRecordCashDividends()
        try spotBalanceAdjustmentsUseTokenQuantity()
        try plansUseCashInExecutionOrder()
        try currencyConversionRequiresQuote()
        try accountCurrencyRestrictsEntries()
        try stockConnectSettlesInRenminbi()
        try insuranceKeepsOnePolicyPosition()
        try typedAccountsFilterAssets()
        try transfersMoveCashAsOneOperation()
        try depositsUseRecordedBalancesAndCashMovements()
        try balanceSheetKeepsDatedBalancesAndUsesInvestmentValuation()
        try balanceHistoryFiltersAndReplaysEditedRecords()
        try investmentHistoryRecordsOneFrozenSnapshotPerClosedMonth()
        try dailyGainsRequireCompleteMarketPrices()
        try portfolioHistoryMatchesIndividualValuations()
        try dailySnapshotsUseBeijingCloseAndDatedRates()
        try changingHistoricalEntriesInvalidatesOnlyTheAffectedDays()
        try changingTransfersIsAtomic()
        try dailyQuotesReuseCachedMarketCloses()
        try serverRoundTripPreservesShortFuturesAndSnapshots()
        try archivesOnlyEmptyAccountsAndPreservesHistory()
        try deletesOnlyTheSelectedHoldingAndItsRecords()
        try deletesAccountsAndPairedTransfersAtomically()
        try deletesUnreferencedRegistrationsAndTheirQuotes()
        try deletionPreservesContractAndPlanReferences()
        print("Investment ledger checks passed")
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

    static func purchasesCanAutomaticallyFundCashShortfalls() throws {
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
        precondition(ledger.cashRows.map(\.change) == [105, -105, 30, 15, -45, 100, -45])
        precondition(ledger.cash == 55 && ledger.flows == 250 && ledger.positions[id]?.netCost == 195)

        try book.post(.init(day: date(2), kind: .withdrawal, amount: -55), accountID: account.id)
        let previousEvents = book.accounts[0].events.map(\.id)
        do {
            try book.post(.init(day: day, kind: .buy, assetID: id, quantity: 6, price: 10),
                          accountID: account.id, autoFundCash: true)
            preconditionFailure("A purchase and its top-up must both roll back if a later event would overdraw")
        } catch InvestmentError.insufficientCash {}
        precondition(book.accounts[0].events.map(\.id) == previousEvents)
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

    static func cryptoContractsTrackDirectionAndMargin() throws {
        let account = InvestmentAccount(name: "加密货币账户", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let long = InvestmentAsset(name: "BTC 永续", code: "BTC-PERP", market: "", kind: .cryptoContract, currency: .usd,
                                   contractSide: .long)
        var short = long
        short.id = UUID()
        short.contractSide = .short
        let longID = try book.register(long)
        let shortID = try book.register(short)
        precondition(longID != shortID && account.kinds == [.crypto, .cryptoContract])
        let quantity = Decimal(string: "0.5")!
        let partialQuantity = Decimal(string: "0.25")!
        let day = date(1)
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: longID, quantity: quantity, price: 100, margin: 50, fee: 2),
                      accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: shortID, quantity: quantity, price: 100, margin: 60, fee: 3),
                      accountID: account.id)
        book.addQuotes([.init(day: day, price: 120)], assetID: longID)
        book.addQuotes([.init(day: day, price: 120)], assetID: shortID)
        let opened = try book.ledger(book.accounts[0], through: day)
        precondition(opened.cash == 885 && opened.positions[shortID]?.margin == 60)
        precondition(book.value(book.accounts[0], on: day)?.gain == -5)

        let close = date(2)
        try book.post(.init(day: close, kind: .sell, assetID: shortID, quantity: partialQuantity, price: 80, fee: 1),
                      accountID: account.id)
        let partial = try book.ledger(book.accounts[0], through: close)
        precondition(partial.cash == 919 && partial.positions[shortID]?.margin == 30)
        try book.post(.init(day: close, kind: .sell, assetID: longID, quantity: quantity, price: 120, fee: 2),
                      accountID: account.id)
        try book.post(.init(day: close, kind: .sell, assetID: shortID, quantity: partialQuantity, price: 80, fee: 1),
                      accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: close)
        precondition(closed.cash == 1011 && closed.positions[longID]?.realized == 6 && closed.positions[shortID]?.realized == 5)
    }

    static func stablecoinContractsShareUSDCash() throws {
        let account = InvestmentAccount(name: "加密货币", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let contract = try book.register(.init(name: "BTC 永续", code: "BTCUSDT", market: "", kind: .cryptoContract, currency: .usd,
                                               contractSide: .long, contractBasis: .stablecoin, settlementStablecoin: .usdt))
        let usdcContract = try book.register(.init(name: "BTC 永续", code: "BTCUSDC", market: "", kind: .cryptoContract, currency: .usd,
                                                   contractSide: .short, contractBasis: .stablecoin, settlementStablecoin: .usdc))
        let day = date(1), next = date(2)
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        for code in ["USD", "USDT", "USDC"] {
            let token = try book.register(.init(name: code, code: code, market: "", kind: .crypto, currency: .usd))
            do {
                try book.post(.init(day: day, kind: .buy, assetID: token, quantity: 1, price: 1), accountID: account.id)
                preconditionFailure("USD cash equivalents must not create separate spot positions")
            } catch InvestmentError.invalid {}
        }
        try book.post(.init(day: day, kind: .buy, assetID: contract, quantity: 2, price: 100, margin: 50, fee: 1),
                      accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: usdcContract, quantity: 1, price: 100, margin: 30, fee: 1),
                      accountID: account.id)
        do {
            try book.post(.init(day: day, kind: .buy, assetID: usdcContract, quantity: 1, price: 100, margin: 918, fee: 1),
                          accountID: account.id)
            preconditionFailure("Margin and fee must fit within the shared cash balance")
        } catch InvestmentError.insufficientCash {}
        book.addQuotes([.init(day: day, price: 120)], assetID: contract)
        book.addQuotes([.init(day: day, price: 100)], assetID: usdcContract)
        let opened = try book.ledger(book.accounts[0], through: day)
        precondition(opened.cash == 918 && opened.reservedCollateral.isEmpty && opened.positions.count == 2)
        precondition(book.value(book.accounts[0], on: day)?.value == 1038)
        try book.post(.init(day: day, kind: .marginTransfer, assetID: contract, amount: 10), accountID: account.id)
        do {
            try book.post(.init(day: day, kind: .marginTransfer, assetID: contract, amount: 909), accountID: account.id)
            preconditionFailure("Additional margin must fit within available USD cash")
        } catch InvestmentError.insufficientCash {}
        do {
            try book.post(.init(day: day, kind: .marginTransfer, assetID: contract, amount: -61), accountID: account.id)
            preconditionFailure("Released margin cannot exceed the amount reserved for this position")
        } catch InvestmentError.invalid {}
        try book.post(.init(day: day, kind: .marginTransfer, assetID: contract, amount: -5), accountID: account.id)
        let adjusted = try book.ledger(book.accounts[0], through: day, includeRows: true)
        precondition(adjusted.cash == 913 && adjusted.positions[contract]?.margin == 55)
        precondition(adjusted.cashRows.suffix(2).map(\.change) == [-10, 5])
        precondition(adjusted.positions[contract]?.quantity == 2 && adjusted.positions[contract]?.lastEntry == 100)
        precondition(adjusted.positions[contract]?.contractEntry == 200 && adjusted.positions[contract]?.realized == -1)
        precondition(book.value(book.accounts[0], on: day)?.value == 1038)
        let partial = InvestmentEvent(day: next, kind: .sell, assetID: contract, quantity: 1, price: 120, fee: 2)
        try book.post(partial, accountID: account.id)
        let remaining = try book.ledger(book.accounts[0], through: next, includeRows: true)
        precondition(remaining.cash == Decimal(string: "958.5")! && remaining.positions[contract]?.margin == Decimal(string: "27.5")!)
        precondition(remaining.cashRows.last?.change == Decimal(string: "45.5")! && remaining.collateralChanges[partial.id] == 18)
        precondition(remaining.positions[contract]?.realized == 17)
        try book.post(.init(day: next, kind: .sell, assetID: contract, quantity: 1, price: 90, fee: 1),
                      accountID: account.id)
        try book.post(.init(day: next, kind: .sell, assetID: usdcContract, quantity: 1, price: 90),
                      accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: next)
        precondition(closed.cash == 1015 && closed.positions[contract]?.margin == 0)
        precondition(closed.positions[contract]?.realized == 6 && closed.positions[usdcContract]?.realized == 9)
        precondition(book.value(book.accounts[0], on: next)?.gain == 15)
    }

    static func coinContractInputConvertsToWholeContracts() throws {
        let screenshot = InvestmentCoinContractQuantity.coins(Decimal(string: "36087.2")!,
                                                              referencePrice: Decimal(string: "0.310913")!)
        let estimated = try screenshot.contractCount(faceValue: 10)
        let nominal = try InvestmentCoinContractQuantity.notionalUSD(11220).contractCount(faceValue: 10)
        let direct = try InvestmentCoinContractQuantity.contracts(1122).contractCount(faceValue: 10)
        precondition(estimated == 1122 && nominal == estimated && direct == estimated)

        do {
            _ = try InvestmentCoinContractQuantity.notionalUSD(11219).contractCount(faceValue: 10)
            preconditionFailure("USD notional must correspond to whole contracts")
        } catch InvestmentError.invalid {}
        do {
            _ = try InvestmentCoinContractQuantity.coins(35080, referencePrice: 0).contractCount(faceValue: 10)
            preconditionFailure("A coin quantity needs a positive reference price")
        } catch InvestmentError.invalid {}
    }

    static func coinContractsOnlyRequireConversionForCashChanges() throws {
        let account = InvestmentAccount(name: "币本位", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let day = date(1)
        let token = try book.register(.init(name: "TRX", code: "TRX", market: "", kind: .crypto, currency: .usd))
        let contract = try book.register(.init(name: "TRXUSD", code: "TRX-USD", market: "HTX", kind: .cryptoContract,
                                              currency: .usd, multiplier: 10, contractSide: .long,
                                              contractBasis: .coin, collateralAssetID: token))
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: token, quantity: 100, price: 1), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: contract, quantity: 1, price: 1, margin: 5), accountID: account.id)
        let opened = try book.ledger(book.accounts[0], through: day)
        precondition(opened.reservedCollateral[token] == 5 && opened.positions[token]?.quantity == 100)
        precondition(opened.positions[contract]?.realized == 0)
        for event in [
            InvestmentEvent(day: day, kind: .buy, assetID: contract, quantity: 1, price: 1, margin: 5, fee: 1),
            InvestmentEvent(day: day, kind: .sell, assetID: contract, quantity: 1, price: 2)
        ] {
            do {
                try book.post(event, accountID: account.id)
                preconditionFailure("Nonzero coin cash flows still need a USD conversion price")
            } catch InvestmentError.invalid {}
        }
        try book.post(.init(day: day, kind: .sell, assetID: contract, quantity: 1, price: 1), accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: day)
        precondition(closed.reservedCollateral[token] == 0 && closed.positions[token]?.quantity == 100)
        precondition(closed.positions[contract]?.quantity == 0 && closed.positions[contract]?.realized == 0)
    }

    static func coinContractsUseInversePricing() throws {
        let account = InvestmentAccount(name: "加密货币", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let token = try book.register(.init(name: "Bitcoin", code: "BTC", market: "", kind: .crypto, currency: .usd))
        let asset = InvestmentAsset(name: "BTCUSD 反向合约", code: "BTCUSD", market: "", kind: .cryptoContract, currency: .usd,
                                    multiplier: 100, contractSide: .long, contractBasis: .coin, collateralAssetID: token)
        let contract = try book.register(asset)
        let open = date(1), close = date(2)
        let fee = Decimal(string: "0.001")!
        try book.post(.init(day: open, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: open, kind: .buy, assetID: token, quantity: Decimal(string: "0.1")!, price: 1000), accountID: account.id)
        try book.post(.init(day: open, kind: .buy, assetID: contract, quantity: 2, price: 1000, margin: Decimal(string: "0.05")!,
                            fee: fee, settlementRate: 1000), accountID: account.id)
        book.addQuotes([.init(day: open, price: 1000), .init(day: close, price: 2000)], assetID: token)
        book.addQuotes([.init(day: close, price: 2000)], assetID: contract)
        precondition(book.value(book.accounts[0], on: close)?.value == 1298)
        let original = try book.ledger(book.accounts[0], through: close)
        try book.post(.init(day: close, kind: .marginTransfer, assetID: contract, amount: Decimal(string: "0.02")!),
                      accountID: account.id)
        try book.post(.init(day: close, kind: .marginTransfer, assetID: contract, amount: Decimal(string: "-0.01")!),
                      accountID: account.id)
        do {
            try book.post(.init(day: close, kind: .marginTransfer, assetID: contract, amount: Decimal(string: "0.04")!),
                          accountID: account.id)
            preconditionFailure("Coin-margined collateral transfers must use only unreserved spot balance")
        } catch InvestmentError.insufficientCollateral {}
        let adjusted = try book.ledger(book.accounts[0], through: close)
        precondition(adjusted.cash == original.cash && adjusted.positions[token]?.quantity == original.positions[token]?.quantity)
        precondition(adjusted.positions[token]?.netCost == original.positions[token]?.netCost)
        precondition(adjusted.positions[contract]?.quantity == original.positions[contract]?.quantity)
        precondition(adjusted.positions[contract]?.contractEntry == original.positions[contract]?.contractEntry)
        precondition(adjusted.positions[contract]?.realized == original.positions[contract]?.realized)
        precondition(adjusted.positions[contract]?.margin == Decimal(string: "0.06")!)
        precondition(adjusted.reservedCollateral[token] == Decimal(string: "0.06")!)
        precondition(book.value(book.accounts[0], on: close)?.value == 1298)
        for _ in 0..<2 {
            try book.post(.init(day: close, kind: .sell, assetID: contract, quantity: 1, price: 2000, fee: fee, settlementRate: 2000),
                          accountID: account.id)
        }
        let closed = try book.ledger(book.accounts[0], through: close)
        precondition(closed.cash == 900 && closed.reservedCollateral[token] == 0)
        precondition(closed.positions[token]?.quantity == Decimal(string: "0.197")!)
        precondition(closed.positions[contract]?.realized == 195 && book.value(book.accounts[0], on: close)?.gain == 294)
        var short = asset
        short.contractSide = .short
        let profit = short.contractProfit(entry: short.contractExposure(quantity: 1, price: 1000),
                                          exit: short.contractExposure(quantity: 1, price: 2000))
        precondition(profit == Decimal(string: "-0.05")!)
    }

    static func fundingBalanceAdjustmentsTrackSettlementAndAttribution() throws {
        let account = InvestmentAccount(name: "加密货币", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let contract = try book.register(.init(name: "BTC 永续", code: "BTCUSDT", market: "", kind: .cryptoContract, currency: .usd,
                                               contractSide: .long, contractBasis: .stablecoin, settlementStablecoin: .usdt))
        let day = date(1), fundingDay = date(2)
        try book.post(.init(day: day, kind: .deposit, amount: 1000), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: contract, quantity: 2, price: 100, margin: 50), accountID: account.id)
        book.addQuotes([.init(day: day, price: 100)], assetID: contract)

        try book.adjustFundingBalance(assetID: contract, accountID: account.id, target: .available, balance: 947,
                                      rate: nil, attributeToContract: false, on: fundingDay)
        precondition(book.accounts[0].events.last?.unallocatedFunding == true)
        try book.adjustFundingBalance(assetID: contract, accountID: account.id, target: .margin, balance: 52,
                                      rate: nil, attributeToContract: false, on: fundingDay)
        let adjusted = try book.ledger(book.accounts[0], through: fundingDay, includeRows: true)
        precondition(adjusted.cash == 947 && adjusted.cashRows.count == 3)
        precondition(adjusted.reservedCollateral.isEmpty && adjusted.positions[contract]?.netCost == 52)
        precondition(adjusted.positions[contract]?.margin == 52 && adjusted.positions[contract]?.realized == 2)
        precondition(book.value(book.accounts[0], on: fundingDay)?.gain == -1)

        try book.post(.init(day: fundingDay, kind: .sell, assetID: contract, quantity: 2, price: 110, fee: Decimal(string: "0.5")!),
                      accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: fundingDay)
        precondition(closed.cash == Decimal(string: "1018.5")! && closed.positions[contract]?.margin == 0)
        precondition(closed.positions[contract]?.realized == Decimal(string: "21.5")!)
        precondition(book.value(book.accounts[0], on: fundingDay)?.gain == Decimal(string: "18.5")!)
    }

    static func cashMarginFundingIsRecognizedOnce() throws {
        let account = InvestmentAccount(name: "加密货币", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account])
        let contract = try book.register(.init(name: "BTC 永续", code: "BTC-PERP", market: "", kind: .cryptoContract,
                                               currency: .usd, contractSide: .short))
        let day = date(1), next = date(2)
        try book.post(.init(day: day, kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: day, kind: .buy, assetID: contract, quantity: 1, price: 10, margin: 50), accountID: account.id)
        try book.adjustFundingBalance(assetID: contract, accountID: account.id, target: .margin, balance: 52,
                                      rate: nil, attributeToContract: true, on: next)
        book.addQuotes([.init(day: next, price: 10)], assetID: contract)
        let open = try book.ledger(book.accounts[0], through: next)
        precondition(open.cash == 50 && open.positions[contract]?.netCost == 52 && open.positions[contract]?.realized == 2)
        precondition(book.value(book.accounts[0], on: next)?.gain == 2)
        try book.post(.init(day: next, kind: .sell, assetID: contract, quantity: 1, price: 10), accountID: account.id)
        let closed = try book.ledger(book.accounts[0], through: next)
        precondition(closed.cash == 102 && closed.positions[contract]?.realized == 2)
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
            (.init(name: "基金账户", currency: .cny, type: .fund),
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

    static func plansUseCashInExecutionOrder() throws {
        let account = InvestmentAccount(name: "定投账户", currency: .cny, type: .securities)
        var book = InvestmentBook(accounts: [account])
        let asset = try book.register(InvestmentAsset(name: "测试ETF", code: "510300", market: "XSHG", kind: .etf, currency: .cny))
        let first = date(1), second = date(2), third = date(3)
        book.plans = [
            InvestmentPlan(accountID: account.id, assetID: asset, amount: 100, monthDay: 1, nextDay: first),
            InvestmentPlan(accountID: account.id, amount: 105, monthDay: 2, nextDay: second)
        ]
        book.runPlans(through: first)
        precondition(book.plans[0].nextDay == first && book.accounts[0].events.isEmpty)
        book.addQuotes([.init(day: third, price: 6)], assetID: asset)
        book.runPlans(through: third)
        book.runPlans(through: third)
        let ledger = try book.ledger(book.accounts[0], through: third)
        precondition(ledger.cash == 9 && ledger.positions[asset]?.quantity == 16)
        precondition(book.accounts[0].events.map(\.kind) == [.deposit, .buy])
        precondition(book.plans.allSatisfy { $0.nextDay > third })
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
        var ledger = InvestmentBalanceLedger(investmentMonthEnds: [end: 800])
        try ledger.add("储蓄卡", category: .cash, amount: 100, at: first)
        try ledger.add("储蓄卡", category: .receivables, amount: 700, at: third)
        let accountID = ledger.accounts[0].id
        try ledger.update(accountID, amount: 120, at: second)
        try ledger.update(accountID, amount: 180, at: third.addingTimeInterval(3600))
        var book = InvestmentBook()
        book.balanceSheet = ledger

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
        let local = InvestmentAccount(name: "人民币账户", currency: .cny, type: .securities)
        let foreign = InvestmentAccount(name: "美元账户", currency: .usd, type: .securities)
        var book = InvestmentBook(accounts: [local, foreign])
        let first = date(1), octoberEnd = date(31)
        let novemberStart = InvestmentBook.addDays(1, to: octoberEnd)
        let novemberEnd = InvestmentBook.addDays(29, to: novemberStart)
        let decemberStart = InvestmentBook.addDays(1, to: novemberEnd)
        try book.post(.init(day: first, kind: .deposit, amount: 300), accountID: local.id)
        try book.post(.init(day: first, kind: .deposit, amount: 100), accountID: foreign.id)
        try book.post(.init(day: date(15), kind: .deposit, amount: 20), accountID: foreign.id)
        precondition(!book.recordCompletedInvestmentMonths(before: octoberEnd))
        precondition(!book.recordCompletedInvestmentMonths(before: novemberStart))
        precondition(book.balanceSnapshot(on: octoberEnd, today: novemberStart).investment == nil)

        book.fx[.usd] = [.init(day: octoberEnd, price: 7)]
        precondition(book.recordCompletedInvestmentMonths(before: novemberStart))
        let saved = try JSONEncoder().encode(book)
        book = try JSONDecoder().decode(InvestmentBook.self, from: saved)
        book.fx[.usd] = [.init(day: octoberEnd, price: 8)]
        precondition(!book.recordCompletedInvestmentMonths(before: novemberEnd))
        precondition(book.balanceSnapshot(on: octoberEnd, today: novemberStart).investment == 1140)
        precondition(book.balanceSnapshot(on: novemberStart, today: novemberStart).investment == 1260)
        precondition(book.balanceSnapshot(on: novemberStart, today: novemberEnd).investment == 1140)

        precondition(book.recordCompletedInvestmentMonths(before: decemberStart))
        precondition(!book.recordCompletedInvestmentMonths(before: decemberStart))
        let snapshots = book.balanceChanges(through: decemberStart, limit: 5)
        precondition(snapshots.map(\.day) == [novemberEnd, octoberEnd])
        precondition(snapshots.map(\.after) == [1260, 1140] && snapshots.first?.before == 1140)
        precondition(snapshots.allSatisfy { $0.name == "投资理财" && $0.category == .investments })
        precondition(book.balanceDates(from: first, through: decemberStart) == [first, octoberEnd, novemberEnd, decemberStart])
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
            ("AAPL", InvestmentKind.stock, InvestmentAccountType.securities), ("VFIAX", .fund, .fund),
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
        precondition(!allows(.fund, .cny, .stock, "00700.HK", market: InvestmentAsset.stockConnectMarket))
        precondition(!allows(.securities, .cny, .option, "10001313.SH"))
        precondition(!allows(.securities, .cny, .option, "IO2611-C-4000.CFX"))
        precondition(!allows(.futures, .cny, .option, "IO2611-C-4000.CFX"))
        precondition(!allows(.futures, .cny, .option, "10001313.SH"))
        precondition(allows(.fund, .cny, .fund, "110022.OF"))
        precondition(!allows(.fund, .cny, .fund, "501018.SH"))
        precondition(allows(.securities, .usd, .etf, "QQQ", market: "XNAS"))
        precondition(allows(.crypto, .usd, .crypto, "BTC"))
        precondition(!allows(.securities, .usd, .crypto, "BTC"))
        precondition(allows(.insurance, .hkd, .insurance, "POLICY"))
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

    static func dailyGainsRequireCompleteMarketPrices() throws {
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
        precondition(stockGains[monday] == nil)

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
        precondition(incomplete[friday] == 70 && incomplete[saturday] == nil && incomplete[sunday] == nil)
        crypto.addQuotes([.init(day: saturday, price: 4, isDailyClose: true)], assetID: token)
        crypto.addQuotes([.init(day: saturday, price: 99, source: "盘中报价")], assetID: token)
        let completed = crypto.dailyGains(from: friday, through: sunday)
        precondition(completed[friday] == 70 && completed[saturday] == 70 && completed[sunday] == 70)
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
        precondition(history[date(3)] != nil && history[date(4)] == nil && history[date(5)] == nil)
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
        precondition(book.dailySnapshots?.values[saturday] == nil && book.dailySnapshots?.values[monday] == nil)

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
        precondition(book.missingDailyMarketData(in: monday...tuesday).assets[id] == [monday...monday])
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
        book.plans = [.init(accountID: account.id, amount: 100, monthDay: 1, nextDay: date(3))]
        let events = try require(book.account(account.id)).events
        let position = try require(book.ledger(book.accounts[0]).positions[id])
        precondition(book.positionIsEmpty(position, assetID: id))
        precondition(!book.positionIsEmpty(.init(quantity: 0, margin: 1), assetID: id))
        precondition(!book.positionIsEmpty(.init(quantity: 0), assetID: id, reserved: 1))
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
            let plan = InvestmentPlan(accountID: account.id, assetID: id, amount: 10, monthDay: 1, nextDay: date(3))
            book.plans.append(plan)
            book.planRuns.append(.init(planID: plan.id, day: date(1), status: "executed", eventID: event.id, executedAt: date(1), detail: nil))
        }
        book.watched = [id]
        book.addQuotes([.init(day: date(2), price: 10)], assetID: id)
        book.dailySnapshots = book.makeDailySnapshots(through: date(2), rebuild: true)
        book.balanceSheet = InvestmentBalanceLedger(investmentMonthEnds: [date(0): 100, date(31): 200])
        let rightEvents = try require(book.account(right.id)).events
        try book.deleteInvestment(accountID: left.id, assetID: id)
        let ledger = try book.ledger(try require(book.account(left.id)))
        precondition(ledger.positions[id] == nil && ledger.cash == 100)
        precondition(book.account(right.id)?.events == rightEvents && book.asset(id) != nil && book.watched == [id])
        precondition(book.plans.count == 1 && book.plans[0].accountID == right.id && book.planRuns.count == 1)
        precondition(book.dailySnapshots?.through == date(0))
        precondition(book.balanceSheet?.investmentSnapshots == [date(0): 100])
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
        book.plans = [.init(accountID: account.id, assetID: planned, amount: 10, monthDay: 1, nextDay: date(3))]
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

    static func deletionPreservesContractAndPlanReferences() throws {
        let account = InvestmentAccount(name: "加密", currency: .usd, type: .crypto)
        let other = InvestmentAccount(name: "另一账户", currency: .usd, type: .crypto)
        var book = InvestmentBook(accounts: [account, other])
        let token = try book.register(.init(name: "TRON", code: "TRX", market: "", kind: .crypto, currency: .usd))
        let contract = try book.register(.init(name: "TRX/USD 永续", code: "TRX-USD", market: "HTX", kind: .cryptoContract,
            currency: .usd, multiplier: 10, contractSide: .short, contractBasis: .coin, collateralAssetID: token))
        try book.post(.init(day: date(1), kind: .deposit, amount: 100), accountID: account.id)
        try book.post(.init(day: date(1), kind: .buy, assetID: token, quantity: 100, price: 1), accountID: account.id)
        book.addQuotes([.init(day: date(2), price: 1)], assetID: token)
        var withoutHolding = book
        try withoutHolding.deleteInvestment(accountID: account.id, assetID: token)
        precondition(withoutHolding.asset(token) != nil && withoutHolding.quotes[token] != nil)
        precondition(withoutHolding.asset(contract)?.collateralAssetID == token)

        try book.post(.init(day: date(2), kind: .buy, assetID: contract, quantity: 1, price: 1, margin: 10), accountID: account.id)
        let before = book.accounts.map(\.events)
        do { try book.deleteInvestment(accountID: account.id, assetID: token); preconditionFailure("Collateral in use cannot be removed") }
        catch is InvestmentError { }
        precondition(book.accounts.map(\.events) == before && book.asset(token) != nil)
        var watched = book
        watched.watched = [contract]
        try watched.deleteInvestment(accountID: account.id)
        precondition(watched.asset(contract) != nil && watched.asset(token) != nil && watched.watched == [contract])
        var planned = book
        planned.plans = [.init(accountID: other.id, assetID: token, amount: 10, monthDay: 1, nextDay: date(3), enabled: false)]
        try planned.deleteInvestment(accountID: account.id)
        precondition(planned.asset(contract) == nil && planned.asset(token) != nil && planned.plans.count == 1)
        try book.deleteInvestment(accountID: account.id)
        precondition(book.assets.isEmpty && book.quotes.isEmpty)
    }

    static func date(_ day: Int) -> Date {
        InvestmentBook.calendar.date(from: DateComponents(year: 2025, month: 10, day: day))!
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw InvestmentError.invalid("Missing test value") }
        return value
    }
}
