import Foundation

enum InvestmentCurrency: String, Codable, CaseIterable, Identifiable {
    case cny = "CNY", hkd = "HKD", usd = "USD"

    var id: Self { self }
    var title: String {
        switch self {
        case .cny: "人民币"
        case .hkd: "港币"
        case .usd: "美元"
        }
    }
}

enum InvestmentKind: String, Codable, CaseIterable, Identifiable {
    case stock = "股票", fund = "基金", etf = "ETF", option = "期权", future = "期货", insurance = "保险"
    case wealth = "理财产品", deposit = "定期存款", certificate = "大额存单", crypto = "加密货币", cryptoContract = "合约"

    var id: Self { self }
    var title: String { self == .crypto ? "现货" : rawValue }
    var unit: String {
        switch self {
        case .stock: "股"
        case .fund, .etf, .insurance, .wealth: "份"
        case .option: "张"
        case .future: "手"
        case .deposit, .certificate: "笔"
        case .crypto, .cryptoContract: "单位"
        }
    }
    var usesMargin: Bool { self == .future || self == .cryptoContract }
    var derivative: Bool { self == .option || usesMargin }
    var supportsPlan: Bool { self == .stock || self == .fund || self == .etf }
    var supportsCashDividends: Bool { self == .stock || self == .fund || self == .etf }
    var supportsTradeFees: Bool { self != .insurance && !isTermDeposit }
    var isTermDeposit: Bool { self == .deposit || self == .certificate }
    var isManual: Bool { self == .insurance || self == .wealth || self == .cryptoContract || isTermDeposit }

    static func watchKinds(in currency: InvestmentCurrency) -> [Self] {
        switch currency {
        case .cny: [.stock, .etf, .fund, .future, .option]
        case .usd: [.stock, .etf, .crypto]
        case .hkd: [.stock, .etf]
        }
    }
}

enum InvestmentContractSide: String, Codable, CaseIterable, Identifiable {
    case long = "多仓", short = "空仓"

    var id: Self { self }
}

enum InvestmentStablecoin: String, Codable, CaseIterable, Identifiable {
    case usdt = "USDT", usdc = "USDC"

    var id: Self { self }

    static func isCashCode(_ code: String) -> Bool {
        let symbol = code.uppercased()
        return symbol == InvestmentCurrency.usd.rawValue || Self(rawValue: symbol) != nil
    }
}

enum InvestmentContractBasis: String, Codable, CaseIterable, Identifiable {
    case usd = "美元线性", stablecoin = "U 本位", coin = "币本位"

    var id: Self { self }

    func accepts(_ collateral: InvestmentAsset) -> Bool {
        guard collateral.kind == .crypto, collateral.currency == .usd else { return false }
        switch self {
        case .usd: return false
        case .stablecoin: return InvestmentStablecoin(rawValue: collateral.code) != nil
        case .coin: return !InvestmentStablecoin.isCashCode(collateral.code)
        }
    }
}

enum InvestmentCoinContractQuantity {
    case coins(Decimal, referencePrice: Decimal)
    case notionalUSD(Decimal)
    case contracts(Decimal)

    func contractCount(faceValue: Decimal) throws -> Decimal {
        guard faceValue > 0 else { throw InvestmentError.invalid("请填写有效的每张合约面值。") }
        var count: Decimal
        let permitsRounding: Bool
        switch self {
        case .coins(let amount, let referencePrice):
            guard amount > 0, referencePrice > 0 else { throw InvestmentError.invalid("请填写有效的币量和折算用价格。") }
            count = amount * referencePrice / faceValue
            permitsRounding = true
        case .notionalUSD(let amount):
            count = amount / faceValue
            permitsRounding = false
        case .contracts(let amount):
            count = amount
            permitsRounding = false
        }
        var whole = Decimal()
        NSDecimalRound(&whole, &count, 0, .plain)
        guard whole > 0, permitsRounding || count == whole else {
            throw InvestmentError.invalid("数量必须对应正整数张合约，请检查输入和每张面值。")
        }
        return whole
    }
}

enum InvestmentAccountType: String, Codable, CaseIterable, Identifiable {
    case securities = "证券账户", fund = "基金账户", futures = "期货账户", wealth = "理财账户"
    case deposits = "存款账户", crypto = "加密货币账户", insurance = "保险账户"

    var id: Self { self }

    static func available(in currency: InvestmentCurrency) -> [Self] {
        switch currency {
        case .cny: [.securities, .fund, .futures, .wealth, .deposits]
        case .usd: [.securities, .crypto]
        case .hkd: [.insurance]
        }
    }

    func kinds(in currency: InvestmentCurrency) -> [InvestmentKind] {
        guard Self.available(in: currency).contains(self) else { return [] }
        return switch self {
        case .securities: [.stock, .etf, .option]
        case .fund: [.fund]
        case .futures: [.future, .option]
        case .wealth: [.wealth]
        case .deposits: [.deposit, .certificate]
        case .crypto: [.crypto, .cryptoContract]
        case .insurance: [.insurance]
        }
    }
}

struct InvestmentDepositTerms: Codable, Hashable {
    let annualRate: Decimal
    let maturity: Date
}

struct InvestmentAsset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var code: String
    var market: String
    var kind: InvestmentKind
    var currency: InvestmentCurrency
    var multiplier: Decimal = 1
    var depositTerms: InvestmentDepositTerms?
    var contractSide: InvestmentContractSide?
    var contractBasis: InvestmentContractBasis?
    var collateralAssetID: UUID?
    var settlementStablecoin: InvestmentStablecoin?

    func matches(_ other: Self) -> Bool {
        code == other.code && market == other.market && kind == other.kind && currency == other.currency
            && contractSide == other.contractSide && basis == other.basis && collateralAssetID == other.collateralAssetID
            && settlementStablecoin == other.settlementStablecoin
    }

    static let stockConnectMarket = "HK_CONNECT"
    var isStockConnect: Bool { market == Self.stockConnectMarket }
    var settlementCurrency: InvestmentCurrency { isStockConnect ? .cny : currency }
    var supportsPlan: Bool { kind.supportsPlan && !isStockConnect }
    var kindLabel: String {
        if isStockConnect { return "港股通 · " + kind.title }
        if let contractSide { return kind.title + " · " + basis.rawValue + " · " + contractSide.rawValue }
        return kind.title
    }
    var priceDirection: Decimal { kind == .cryptoContract && contractSide == .short ? -1 : 1 }
    var basis: InvestmentContractBasis { contractBasis ?? .usd }

    func contractExposure(quantity: Decimal, price: Decimal) -> Decimal {
        let units = quantity * multiplier
        return basis == .coin ? units / price : units * price
    }

    func contractProfit(entry: Decimal, exit: Decimal) -> Decimal {
        (basis == .coin ? entry - exit : exit - entry) * priceDirection
    }

    func transactionTitle(_ event: InvestmentEventKind) -> String {
        if kind == .cryptoContract {
            if event == .buy { return "开仓" }
            if event == .sell { return "平仓" }
        }
        if kind == .wealth {
            if event == .buy { return "申购" }
            if event == .sell { return "赎回" }
        }
        if kind.isTermDeposit {
            if event == .buy { return "存入本金" }
            if event == .sell { return "收回本金" }
            if event == .income { return "实收利息" }
        }
        guard kind == .insurance else { return event.rawValue }
        switch event {
        case .buy: return "续缴保费"
        case .sell: return "退保"
        default: return event.rawValue
        }
    }

    static let mainlandMICs = ["SH": "XSHG", "SZ": "XSHE", "BJ": "XBSE"]
    private static let usEquityVenues: Set<String> = ["US", "XNAS", "XNYS", "XASE", "ARCX", "BATS",
        "BATY", "EDGA", "EDGX", "XNGS", "XNMS", "XNCM", "XOTC", "OTCM", "IEXG", "MEMX"]
    private static let usDerivativeVenues: Set<String> = ["US", "XCME", "XCBT", "XNYM", "XCEC", "XCBF", "XCBO"]

    var mainlandSymbol: (base: String, venue: String)? {
        let parts = code.uppercased().split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return nil }
        let base = String(parts[0])
        let suffix = parts.count == 2 ? String(parts[1]) : nil
        let market = self.market.uppercased()
        let aliases: [String: String] = kind.derivative
            ? ["SH":"SH", "SZ":"SZ", "SHF":"SHF", "DCE":"DCE", "ZCE":"ZCE", "CFX":"CFX",
               "INE":"INE", "GFE":"GFE", "XSHG":"SH", "XSHE":"SZ", "SHFE":"SHF", "CZCE":"ZCE", "CFFEX":"CFX", "GFEX":"GFE"]
            : ["SH":"SH", "SZ":"SZ", "BJ":"BJ", "OF":"OF", "XSHG":"SH", "XSHE":"SZ", "XBSE":"BJ"]
        let explicit = suffix.flatMap { aliases[$0] }
        let selected = aliases[market]
        guard suffix == nil || explicit != nil, market.isEmpty || selected != nil,
              explicit == nil || selected == nil || explicit == selected else { return nil }
        let venue = explicit ?? selected

        if kind.derivative {
            guard let venue, kind == .option || (venue != "SH" && venue != "SZ"),
                  base.range(of: #"^[A-Z0-9]+(?:-[A-Z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
            return (base, venue)
        }
        guard base.count == 6, base.utf8.allSatisfy({ (48...57).contains($0) }),
              base != "000000", !base.hasPrefix("900"), !base.hasPrefix("200") else { return nil }
        if kind == .fund {
            let fundVenue = venue ?? "OF"
            return ["OF", "SH", "SZ"].contains(fundVenue) ? (base, fundVenue) : nil
        }
        let inferred: String
        switch kind {
        case .stock:
            if ["60", "68"].contains(where: { base.hasPrefix($0) }) { inferred = "SH" }
            else if ["00", "30"].contains(where: { base.hasPrefix($0) }) { inferred = "SZ" }
            else if ["4", "8", "92"].contains(where: { base.hasPrefix($0) }) { inferred = "BJ" }
            else { return nil }
        case .etf:
            if base.hasPrefix("5") { inferred = "SH" }
            else if base.hasPrefix("15") { inferred = "SZ" }
            else { return nil }
        default: return nil
        }
        return venue == nil || venue == inferred ? (base, inferred) : nil
    }

    static func stockConnectCode(_ code: String) -> String? {
        let symbol = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = symbol.hasSuffix(".HK") ? String(symbol.dropLast(3)) : symbol
        guard (1...5).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(digits), number > 0 else { return nil }
        // The Hong Kong listings used here quote in HKD.
        let otherCounters = [9000...9599, 9700...9849, 10900...10999, 41500...41599, 80000...89999]
        guard !otherCounters.contains(where: { $0.contains(number) }) else { return nil }
        return String(format: "%05d.HK", number)
    }

    var isHongKongEquity: Bool {
        guard kind == .stock || kind == .etf else { return false }
        let symbol = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let venue = market.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if symbol.hasSuffix(".HK") || ["HK", "XHKG", "HKEX", "SEHK"].contains(venue) { return true }
        return venue.isEmpty && (1...5).contains(symbol.count)
            && symbol.utf8.allSatisfy { (48...57).contains($0) }
    }

    func validateEntry(in account: InvestmentAccount) throws {
        let type = account.type
        guard type.kinds(in: account.currency).contains(kind),
              !isStockConnect || account.allowsStockConnect else {
            throw InvestmentError.invalid("此账户类型不支持该资产。")
        }
        try validateMarket(settlingIn: account.currency)
        if account.currency == .cny, kind == .option, let venue = mainlandSymbol?.venue {
            let exchangeTradedETF = venue == "SH" || venue == "SZ"
            guard exchangeTradedETF == (type == .securities) else {
                throw InvestmentError.invalid("ETF 期权归证券账户，商品期权和股指期权归期货账户。")
            }
        }
        if type == .fund, mainlandSymbol?.venue != "OF" {
            throw InvestmentError.invalid("基金账户只录入场外基金。")
        }
    }

    func validateMarket(settlingIn accountCurrency: InvestmentCurrency) throws {
        if isStockConnect {
            guard accountCurrency == .cny, currency == .hkd, kind == .stock || kind == .etf,
                  Self.stockConnectCode(code) == code else {
                throw InvestmentError.invalid("港股通仅支持在人民币账户录入港币报价的股票或 ETF，请检查标的代码。")
            }
            return
        }
        guard !isHongKongEquity else { throw InvestmentError.invalid("港股和港交所 ETF 请通过人民币账户的港股通入口录入。") }
        let mismatch = InvestmentError.invalid("此账户只允许录入以 \(accountCurrency.title)（\(accountCurrency.rawValue)）计价的资产，请检查标的代码和交易所。")
        guard currency == accountCurrency else { throw mismatch }
        let symbol = code.uppercased()
        let venue = market.uppercased()
        if kind == .crypto {
            guard accountCurrency == .usd, venue.isEmpty,
                  symbol.range(of: #"^[A-Z0-9]{1,20}$"#, options: .regularExpression) != nil else { throw mismatch }
            return
        }
        if kind == .cryptoContract {
            guard accountCurrency == .usd, contractSide != nil,
                  symbol.range(of: #"^[A-Z0-9]+(?:[./:_-][A-Z0-9]+)*$"#, options: .regularExpression) != nil else {
                throw InvestmentError.invalid("请填写合约代码和开仓方向。")
            }
            let hasSettlement = switch basis {
            case .usd: collateralAssetID == nil && settlementStablecoin == nil
            case .coin: collateralAssetID != nil && settlementStablecoin == nil
            case .stablecoin: settlementStablecoin != nil ? collateralAssetID == nil : collateralAssetID != nil
            }
            guard hasSettlement else {
                throw InvestmentError.invalid("请选择合约的实际结算币种。")
            }
            return
        }
        if kind == .wealth || kind.isTermDeposit {
            guard accountCurrency == .cny, venue.isEmpty else { throw mismatch }
            return
        }
        switch accountCurrency {
        case .cny:
            guard mainlandSymbol != nil else {
                throw InvestmentError.invalid("请输入境内标的代码，期货和期权请带交易所后缀。")
            }
            return
        case .hkd:
            guard kind == .insurance, venue.isEmpty else { throw mismatch }
            return
        case .usd: break
        }

        let usVenues = kind.derivative ? Self.usDerivativeVenues : Self.usEquityVenues
        guard venue.isEmpty || usVenues.contains(venue) else { throw mismatch }
        let ticker = symbol.hasSuffix(".US") ? String(symbol.dropLast(3)) : symbol
        if kind.derivative {
            guard (usVenues.contains(venue) || symbol.hasSuffix(".US")), !ticker.contains("."), !ticker.isEmpty else {
                throw InvestmentError.invalid("录入美元期货或期权时，请填写美国交易所代码，例如 XCME 或 XCBO。")
            }
            return
        }
        let tickerPattern = #"^[A-Z][A-Z0-9]*(?:[.-][ABC])?$"#
        guard ticker.range(of: tickerPattern, options: .regularExpression) != nil else { throw mismatch }
    }
}

struct InvestmentQuote: Codable, Identifiable {
    var day: Date
    var price: Decimal
    var source: String?
    var id: Date { day }
}

enum InvestmentEventKind: String, Codable {
    case deposit = "转入", withdrawal = "提取", adjustment = "余额调整"
    case opening = "首次录入", buy = "买入", sell = "卖出"
    case transferOut = "划出", transferIn = "划入", income = "收益"
    case dividend = "现金分红", bonusShares = "送股"
    case stakingReward = "质押奖励", spotAdjustment = "现货余额调整"
    case funding = "资金费", marginTransfer = "保证金划转"
}

enum InvestmentFundingTarget: String, Codable, CaseIterable, Identifiable {
    case available = "可用余额", margin = "该仓保证金"

    var id: Self { self }
}

struct InvestmentEvent: Codable, Identifiable {
    var id = UUID()
    var day: Date
    var kind: InvestmentEventKind
    var assetID: UUID?
    var amount: Decimal = 0
    var quantity: Decimal = 0
    var price: Decimal = 0
    var margin: Decimal = 0
    var settledAmount: Decimal?
    var fee: Decimal?
    var settlementRate: Decimal?
    var fundingTarget: InvestmentFundingTarget?
    var unallocatedFunding: Bool?
    var transferAccountID: UUID?
    var transferID: UUID?

    func title(for asset: InvestmentAsset?) -> String {
        if kind == .marginTransfer { return amount > 0 ? "增加保证金" : "减少保证金" }
        if unallocatedFunding == true { return "账户资金费" }
        return asset?.transactionTitle(kind) ?? kind.rawValue
    }
}

struct InvestmentAccount: Codable, Identifiable {
    var id = UUID()
    var name: String
    var currency: InvestmentCurrency
    var events: [InvestmentEvent] = []
    var notes: [UUID: String] = [:]
    var type: InvestmentAccountType

    var kinds: [InvestmentKind] { type.kinds(in: currency) }
    var allowsStockConnect: Bool { currency == .cny && type == .securities }
}

struct InvestmentPlan: Codable, Identifiable {
    var id = UUID()
    var accountID: UUID
    var assetID: UUID?
    var amount: Decimal
    var monthDay: Int
    var nextDay: Date
    var enabled: Bool = true
    var lastResult: String?
}

struct InvestmentPosition {
    var quantity: Decimal = 0
    var netCost: Decimal = 0
    var realized: Decimal = 0
    var margin: Decimal = 0
    var contractEntry: Decimal = 0
    var lastEntry: Decimal?

    func value(at price: Decimal, asset: InvestmentAsset) -> Decimal {
        let face = price * quantity * asset.multiplier
        return asset.kind.usesMargin ? margin + (face - contractEntry) * asset.priceDirection : face
    }
}

struct InvestmentCashRow: Identifiable {
    var event: InvestmentEvent
    var change: Decimal
    var balance: Decimal
    var id: UUID { event.id }
}

struct InvestmentLedger {
    var cash: Decimal = 0
    var flows: Decimal = 0
    var cashIncome: Decimal = 0
    var positions: [UUID: InvestmentPosition] = [:]
    var reservedCollateral: [UUID: Decimal] = [:]
    var collateralChanges: [UUID: Decimal] = [:]
    var cashRows: [InvestmentCashRow] = []

    func fundingBalance(for asset: InvestmentAsset, target: InvestmentFundingTarget) -> Decimal? {
        guard let position = positions[asset.id] else { return nil }
        if target == .margin { return position.quantity > 0 ? position.margin : nil }
        if let id = asset.collateralAssetID {
            return (positions[id]?.quantity ?? 0) - reservedCollateral[id, default: 0]
        }
        return cash
    }

    mutating func transferMargin(_ amount: Decimal, for asset: InvestmentAsset) throws {
        guard var position = positions[asset.id], position.quantity > 0 else {
            throw InvestmentError.invalid("该日期没有可调整保证金的仓位。")
        }
        let margin = position.margin + amount
        guard margin >= 0 else { throw InvestmentError.invalid("减少金额不能超过该仓已占用保证金。") }

        if let id = asset.collateralAssetID {
            let reserved = reservedCollateral[id, default: 0] + amount
            guard reserved <= (positions[id]?.quantity ?? 0) else { throw InvestmentError.insufficientCollateral }
            reservedCollateral[id] = reserved
        } else {
            guard cash >= amount else { throw InvestmentError.insufficientCash }
            cash -= amount
            position.netCost += amount
        }
        position.margin = margin
        positions[asset.id] = position
    }

    mutating func settleContract(_ event: InvestmentEvent, asset: InvestmentAsset, collateral: InvestmentAsset?) throws -> Decimal {
        var position = positions[asset.id] ?? InvestmentPosition()
        let exposure = asset.contractExposure(quantity: event.quantity, price: event.price)
        var settlementChange = -(event.fee ?? 0)
        let marginChange: Decimal
        if event.kind == .sell {
            guard position.quantity >= event.quantity else { throw InvestmentError.insufficientPosition }
            let fraction = event.quantity / position.quantity
            let releasedMargin = position.margin * fraction
            let entry = position.contractEntry * fraction
            settlementChange += asset.contractProfit(entry: entry, exit: exposure)
            marginChange = -releasedMargin
            position.contractEntry -= entry
            position.quantity -= event.quantity
        } else {
            marginChange = event.margin
            position.contractEntry += exposure
            position.quantity += event.quantity
            position.lastEntry = event.price
        }
        position.margin += marginChange
        let usdChange: Decimal
        if let collateral {
            let reserved = reservedCollateral[collateral.id, default: 0] + marginChange
            usdChange = try applyCollateralChange(settlementChange, id: collateral.id, reserved: reserved, rate: event.settlementRate)
        } else {
            // U-margined contracts use the USD cash balance at 1:1.
            usdChange = settlementChange
            cash += usdChange - marginChange
            position.netCost = position.margin
        }
        position.realized += usdChange
        positions[asset.id] = position
        return settlementChange
    }

    mutating func applyFunding(_ event: InvestmentEvent, asset: InvestmentAsset) throws {
        guard let target = event.fundingTarget, let balance = fundingBalance(for: asset, target: target),
              var position = positions[asset.id] else {
            throw InvestmentError.invalid("该日期没有可调整的合约余额。")
        }
        guard balance + event.amount >= 0 else {
            if asset.collateralAssetID != nil { throw InvestmentError.insufficientCollateral }
            throw InvestmentError.insufficientCash
        }
        let marginChange = target == .margin ? event.amount : 0
        let usdChange: Decimal
        if let id = asset.collateralAssetID {
            let reserved = reservedCollateral[id, default: 0] + marginChange
            usdChange = try applyCollateralChange(event.amount, id: id, reserved: reserved, rate: event.settlementRate)
        } else {
            usdChange = event.amount
            if target == .available { cash += event.amount }
            position.netCost += marginChange
        }
        position.margin += marginChange
        if event.unallocatedFunding != true { position.realized += usdChange }
        positions[asset.id] = position
    }

    private mutating func applyCollateralChange(_ change: Decimal, id: UUID, reserved: Decimal, rate: Decimal?) throws -> Decimal {
        guard let rate, rate > 0 else {
            throw InvestmentError.invalid("请填写结算币兑美元单价。")
        }
        var token = positions[id] ?? InvestmentPosition()
        token.quantity += change
        guard token.quantity >= reserved else { throw InvestmentError.insufficientCollateral }
        let usdChange = change * rate
        token.netCost += usdChange
        if token.quantity == 0 {
            token.realized -= token.netCost
            token.netCost = 0
        }
        reservedCollateral[id] = reserved
        positions[id] = token
        return usdChange
    }
}

struct InvestmentValuation {
    var value: Decimal
    var gain: Decimal
}

enum InvestmentError: LocalizedError {
    case invalid(String)
    case insufficientCash
    case insufficientPosition
    case insufficientCollateral

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .insufficientCash: "该笔记录会使账户现金余额为负。"
        case .insufficientPosition: "卖出数量超过成交日可用持仓。"
        case .insufficientCollateral: "可用结算币余额不足，请检查持仓及已占用保证金。"
        }
    }
}

struct InvestmentBook: Codable {
    var accounts: [InvestmentAccount] = []
    var assets: [UUID: InvestmentAsset] = [:]
    var quotes: [UUID: [InvestmentQuote]] = [:]
    var fx: [InvestmentCurrency: [InvestmentQuote]] = [:]
    var watched: [UUID] = []
    var plans: [InvestmentPlan] = []
    var balanceSheet: InvestmentBalanceLedger? = nil

    // Use one accounting day across the ledger and date-only market data.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 2
        return calendar
    }
    static func day(_ date: Date = .now) -> Date { calendar.startOfDay(for: date) }
    static func addDays(_ count: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: count, to: date) ?? date
    }

    var earliest: Date? { accounts.flatMap(\.events).map(\.day).min() }
    func account(_ id: UUID) -> InvestmentAccount? { accounts.first { $0.id == id } }
    func asset(_ id: UUID?) -> InvestmentAsset? { id.flatMap { assets[$0] } }

    mutating func register(_ asset: InvestmentAsset) throws -> UUID {
        guard !asset.code.isEmpty, !asset.name.isEmpty, asset.multiplier > 0,
              !asset.code.contains(","), !asset.market.contains(",") else {
            throw InvestmentError.invalid("请输入有效的名称、代码和合约乘数。")
        }
        if let known = assets.values.first(where: { $0.matches(asset) }) {
            guard known.multiplier == asset.multiplier else {
                throw InvestmentError.invalid("该标的已经使用不同的合约乘数。")
            }
            return known.id
        }
        assets[asset.id] = asset
        return asset.id
    }

    func orderedEvents(_ account: InvestmentAccount, through day: Date) -> [InvestmentEvent] {
        account.events.enumerated().filter { $0.element.day <= day }
            .sorted { $0.element.day == $1.element.day ? $0.offset < $1.offset : $0.element.day < $1.element.day }
            .map(\.element)
    }

    func ledger(_ account: InvestmentAccount, through day: Date = Self.day(), includeRows: Bool = false) throws -> InvestmentLedger {
        var ledger = InvestmentLedger()
        for event in orderedEvents(account, through: day) {
            let before = ledger.cash
            switch event.kind {
            case .deposit, .withdrawal, .transferOut, .transferIn:
                ledger.cash += event.amount
                ledger.flows += event.amount
            case .adjustment:
                ledger.cash += event.amount
                ledger.cashIncome += event.amount
            case .funding:
                guard let asset = asset(event.assetID), asset.kind == .cryptoContract else {
                    throw InvestmentError.invalid("找不到资金费对应的合约。")
                }
                try ledger.applyFunding(event, asset: asset)
                if asset.collateralAssetID != nil || event.fundingTarget == .margin { continue }
            case .marginTransfer:
                guard let asset = asset(event.assetID), asset.kind == .cryptoContract else {
                    throw InvestmentError.invalid("找不到保证金划转对应的合约。")
                }
                try ledger.transferMargin(event.amount, for: asset)
                if asset.collateralAssetID != nil { continue }
            case .income, .dividend:
                guard let id = event.assetID, var position = ledger.positions[id] else {
                    throw InvestmentError.invalid("找不到该产品的持仓记录。")
                }
                ledger.cash += event.amount
                position.realized += event.amount
                ledger.positions[id] = position
            case .bonusShares, .stakingReward, .spotAdjustment:
                guard let id = event.assetID, var position = ledger.positions[id] else {
                    throw InvestmentError.invalid("找不到该标的的持仓记录。")
                }
                position.quantity += event.quantity
                guard position.quantity >= 0 else { throw InvestmentError.insufficientPosition }
                guard position.quantity >= ledger.reservedCollateral[id, default: 0] else {
                    throw InvestmentError.insufficientCollateral
                }
                if position.quantity == 0 {
                    position.realized -= position.netCost
                    position.netCost = 0
                }
                ledger.positions[id] = position
                continue
            case .opening, .buy, .sell:
                guard let id = event.assetID, let asset = assets[id], asset.settlementCurrency == account.currency else {
                    throw InvestmentError.invalid("标的与账户币种不一致。")
                }
                if asset.kind == .cryptoContract, asset.basis != .usd {
                    let collateral = self.asset(asset.collateralAssetID)
                    let usesSharedCash = asset.basis == .stablecoin && asset.settlementStablecoin != nil && asset.collateralAssetID == nil
                    guard event.kind != .opening, usesSharedCash || collateral.map(asset.basis.accepts) == true else {
                        throw InvestmentError.invalid("请选择有效的结算币种。")
                    }
                    let change = try ledger.settleContract(event, asset: asset, collateral: collateral)
                    if includeRows { ledger.collateralChanges[event.id] = change }
                    if collateral != nil { continue }
                } else {
                    var position = ledger.positions[id] ?? InvestmentPosition()
                    if event.kind == .sell {
                        let cashValue = try cashTradeValue(event, asset: asset)
                        guard position.quantity >= event.quantity else { throw InvestmentError.insufficientPosition }
                        guard position.quantity - ledger.reservedCollateral[id, default: 0] >= event.quantity else {
                            throw InvestmentError.insufficientCollateral
                        }
                        var proceeds = cashValue
                        if asset.kind.usesMargin {
                            let releasedMargin = position.margin * event.quantity / position.quantity
                            let releasedEntry = position.contractEntry * event.quantity / position.quantity
                            proceeds = releasedMargin + (cashValue - releasedEntry) * asset.priceDirection
                            position.margin -= releasedMargin
                            position.contractEntry -= releasedEntry
                        }
                        proceeds -= event.fee ?? 0
                        ledger.cash += proceeds
                        position.netCost -= proceeds
                        position.quantity -= event.quantity
                        if position.quantity == 0 {
                            position.realized -= position.netCost
                            position.netCost = 0
                            position.margin = 0
                            position.contractEntry = 0
                        }
                    } else {
                        let purchase = try cashPurchase(event, asset: asset)
                        if asset.kind.isTermDeposit, position.quantity > 0 {
                            throw InvestmentError.invalid("定期存款和大额存单请逐笔录入。")
                        }
                        if asset.kind == .insurance, event.kind == .opening, position.quantity > 0 {
                            throw InvestmentError.invalid("该保单已录入，请记一笔续缴保费。")
                        }
                        if event.kind == .opening { ledger.flows += purchase.debit } else { ledger.cash -= purchase.debit }
                        if asset.kind.usesMargin {
                            position.margin += purchase.margin
                            position.contractEntry += purchase.value
                        }
                        position.netCost += purchase.debit
                        if asset.kind == .insurance {
                            position.quantity = 1
                        } else {
                            position.quantity += event.quantity
                            if event.kind == .buy { position.lastEntry = event.price }
                        }
                    }
                    ledger.positions[id] = position
                }
            }
            guard ledger.cash >= 0 else { throw InvestmentError.insufficientCash }
            if includeRows, event.kind != .opening {
                ledger.cashRows.append(InvestmentCashRow(event: event, change: ledger.cash - before, balance: ledger.cash))
            }
        }
        return ledger
    }

    private func cashTradeValue(_ event: InvestmentEvent, asset: InvestmentAsset) throws -> Decimal {
        if asset.isStockConnect {
            guard let amount = event.settledAmount, amount > 0 else {
                throw InvestmentError.invalid("请填写券商交割单上的实际人民币金额。")
            }
            return amount
        }
        return event.price * event.quantity * asset.multiplier
    }

    private func cashPurchase(_ event: InvestmentEvent, asset: InvestmentAsset) throws -> (value: Decimal, margin: Decimal, debit: Decimal) {
        let value = try cashTradeValue(event, asset: asset)
        let margin = asset.kind == .cryptoContract ? event.margin : event.margin * event.quantity
        let debit = (asset.kind.usesMargin ? margin : value) + (event.fee ?? 0)
        return (value, margin, debit)
    }

    mutating func post(_ event: InvestmentEvent, accountID: UUID, today: Date = Self.day(), autoFundCash: Bool = false) throws {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }), event.day <= today else {
            throw InvestmentError.invalid("请选择有效的账户和记账日期。")
        }
        if let fee = event.fee, fee != 0 {
            guard fee > 0, event.kind == .buy || event.kind == .sell,
                  let asset = asset(event.assetID), asset.kind.supportsTradeFees, !asset.isStockConnect else {
                throw InvestmentError.invalid("请检查交易费用。港股通请填写已含费用的实际交收金额。")
            }
        }
        var draft = accounts[index]
        switch event.kind {
        case .transferOut, .transferIn:
            guard event.transferID != nil, event.transferAccountID != nil,
                  event.kind == .transferOut ? event.amount < 0 : event.amount > 0 else {
                throw InvestmentError.invalid("资金划转缺少对应流水。")
            }
        case .income:
            guard let asset = asset(event.assetID), asset.kind == .wealth || asset.kind.isTermDeposit, event.amount > 0 else {
                throw InvestmentError.invalid("请输入有效的收益金额。")
            }
            try asset.validateEntry(in: accounts[index])
        case .funding:
            guard let asset = asset(event.assetID), asset.kind == .cryptoContract, let target = event.fundingTarget,
                  event.amount != 0, target != .margin || event.unallocatedFunding != true else {
                throw InvestmentError.invalid("请选择合约余额并填写有效的资金费调整。")
            }
            try asset.validateEntry(in: accounts[index])
        case .marginTransfer:
            guard let asset = asset(event.assetID), asset.kind == .cryptoContract, event.amount != 0 else {
                throw InvestmentError.invalid("请选择合约并填写有效的保证金划转金额。")
            }
            try asset.validateEntry(in: accounts[index])
        case .dividend, .bonusShares:
            guard let asset = asset(event.assetID), asset.kind.supportsCashDividends else {
                throw InvestmentError.invalid("请选择股票、ETF 或基金。")
            }
            if event.kind == .dividend {
                guard event.amount > 0 else { throw InvestmentError.invalid("请输入实际到账的分红金额。") }
            } else {
                guard asset.kind == .stock else { throw InvestmentError.invalid("只有股票可以录入送股。") }
                guard event.quantity > 0, event.quantity == Decimal(NSDecimalNumber(decimal: event.quantity).int64Value) else {
                    throw InvestmentError.invalid("送股数量必须为正整数。")
                }
            }
            try asset.validateEntry(in: accounts[index])
        case .stakingReward, .spotAdjustment:
            guard let asset = asset(event.assetID), asset.kind == .crypto,
                  event.kind == .stakingReward ? event.quantity > 0 : event.quantity < 0 else {
                throw InvestmentError.invalid("请选择现货并填写有效的调整数量。")
            }
            try asset.validateEntry(in: accounts[index])
        case .deposit, .withdrawal, .adjustment:
            guard event.amount != 0,
                  event.kind != .deposit || event.amount > 0,
                  event.kind != .withdrawal || event.amount < 0 else {
                throw InvestmentError.invalid("请输入有效的现金变动金额。")
            }
        case .opening, .buy, .sell:
            guard let asset = asset(event.assetID), event.quantity > 0,
                  event.price > 0 || (asset.kind == .insurance && event.kind == .sell && event.price == 0),
                  (asset.kind != .insurance && !asset.kind.isTermDeposit) || event.quantity == 1,
                  !asset.kind.usesMargin || event.kind == .sell || event.margin > 0 else {
                throw InvestmentError.invalid("请输入有效的数量、价格和保证金。")
            }
            try asset.validateEntry(in: accounts[index])
            if event.kind != .sell, asset.kind == .crypto, InvestmentStablecoin.isCashCode(asset.code) {
                throw InvestmentError.invalid("USD、USDC 和 USDT 统一计入 USD 现金余额，请在现金管理中记账。")
            }
            if asset.kind.isTermDeposit, event.kind != .sell {
                guard let terms = asset.depositTerms, terms.annualRate >= 0, terms.maturity >= event.day else {
                    throw InvestmentError.invalid("请填写存款利率和有效到期日。")
                }
            }
            if autoFundCash, event.kind == .buy, asset.kind != .cryptoContract || asset.basis == .usd {
                let purchase = try cashPurchase(event, asset: asset)
                let cash = try ledger(draft, through: event.day).cash
                if purchase.debit > cash {
                    draft.events.append(.init(day: event.day, kind: .deposit, amount: purchase.debit - cash))
                }
            }
        }
        draft.events.append(event)
        _ = try ledger(draft, through: today)
        accounts[index] = draft
    }

    mutating func recordDistribution(assetID: UUID, accountID: UUID, cash: Decimal, shares: Decimal = 0, on date: Date) throws {
        guard cash >= 0, shares >= 0, cash > 0 || shares > 0 else {
            throw InvestmentError.invalid(asset(assetID)?.kind == .stock ? "请填写分红金额或送股股数。" : "请输入实际到账的分红金额。")
        }
        let day = Self.day(date)
        var draft = self
        if cash > 0 {
            try draft.post(.init(day: day, kind: .dividend, assetID: assetID, amount: cash), accountID: accountID)
        }
        if shares > 0 {
            try draft.post(.init(day: day, kind: .bonusShares, assetID: assetID, quantity: shares), accountID: accountID)
        }
        self = draft
    }

    mutating func adjustSpotBalance(assetID: UUID, accountID: UUID, balance: Decimal, on date: Date) throws {
        let day = Self.day(date)
        guard balance >= 0, let account = account(accountID),
              let position = try ledger(account, through: day).positions[assetID] else {
            throw InvestmentError.invalid("请选择已有现货持仓并填写调整后余额。")
        }
        let change = balance - position.quantity
        guard change != 0 else { throw InvestmentError.invalid("调整后余额与账面数量相同。") }
        let kind: InvestmentEventKind = change > 0 ? .stakingReward : .spotAdjustment
        try post(.init(day: day, kind: kind, assetID: assetID, quantity: change), accountID: accountID)
    }

    mutating func adjustFundingBalance(assetID: UUID, accountID: UUID, target: InvestmentFundingTarget,
                                       balance: Decimal, rate: Decimal?, attributeToContract: Bool, on date: Date) throws {
        let day = Self.day(date)
        guard balance >= 0, let account = account(accountID), let asset = asset(assetID), asset.kind == .cryptoContract,
              let current = try ledger(account, through: day).fundingBalance(for: asset, target: target) else {
            throw InvestmentError.invalid("请选择有效的合约和调整后余额。")
        }
        let change = balance - current
        guard change != 0 else { throw InvestmentError.invalid("调整后余额与账面余额相同。") }
        let settledRate = asset.collateralAssetID.flatMap { rate ?? quote($0, on: day)?.price }
        try post(.init(day: day, kind: .funding, assetID: assetID, amount: change, settlementRate: settledRate,
                       fundingTarget: target, unallocatedFunding: target == .available && !attributeToContract),
                 accountID: accountID)
        if let id = asset.collateralAssetID, let rate = settledRate, quote(id, on: day) == nil {
            addQuotes([.init(day: day, price: rate, source: "结算币录入")], assetID: id)
        }
    }

    mutating func transfer(from sourceID: UUID, to targetID: UUID, amount: Decimal, remaining: Decimal,
                           received: Decimal? = nil, on day: Date = Self.day()) throws {
        guard sourceID != targetID, let source = account(sourceID), let target = account(targetID), amount > 0 else {
            throw InvestmentError.invalid("请选择不同的目标账户并填写划出金额。")
        }
        let incoming: Decimal
        if source.currency == target.currency {
            incoming = amount
        } else {
            guard let received, received > 0 else {
                throw InvestmentError.invalid("跨币种划转请填写目标账户实际到账金额。")
            }
            incoming = received
        }
        let day = Self.day(day)
        let balance = try ledger(source, through: day).cash
        guard amount <= balance else { throw InvestmentError.insufficientCash }
        guard remaining == balance - amount else {
            throw InvestmentError.invalid("划出后余额应为 " + (balance - amount).formatted(.currency(code: source.currency.rawValue)) + "。")
        }
        let transferID = UUID()
        var draft = self
        try draft.post(.init(day: day, kind: .transferOut, amount: -amount, transferAccountID: targetID, transferID: transferID), accountID: sourceID)
        try draft.post(.init(day: day, kind: .transferIn, amount: incoming, transferAccountID: sourceID, transferID: transferID), accountID: targetID)
        self = draft
    }

    func quote(_ id: UUID, on day: Date = Self.day()) -> InvestmentQuote? {
        quotes[id]?.last { $0.day <= day }
    }

    func settlementUnit(for asset: InvestmentAsset) -> String {
        asset.settlementStablecoin?.rawValue ?? self.asset(asset.collateralAssetID)?.code ?? asset.settlementCurrency.rawValue
    }

    func fundingUnit(for asset: InvestmentAsset, target: InvestmentFundingTarget) -> String {
        if target == .available && asset.collateralAssetID == nil { return asset.settlementCurrency.rawValue }
        return settlementUnit(for: asset)
    }

    func quoteUnit(for asset: InvestmentAsset) -> String {
        asset.basis == .stablecoin ? settlementUnit(for: asset) : asset.currency.rawValue
    }

    mutating func addQuotes(_ values: [InvestmentQuote], assetID: UUID) {
        quotes[assetID] = Self.merge(quotes[assetID] ?? [], values, allowZero: assets[assetID]?.kind == .insurance)
    }

    static func merge(_ old: [InvestmentQuote], _ new: [InvestmentQuote], allowZero: Bool = false) -> [InvestmentQuote] {
        var days: [Date: InvestmentQuote] = [:]
        for quote in old + new where quote.price > 0 || (allowZero && quote.price == 0) { days[quote.day] = quote }
        return days.values.sorted { $0.day < $1.day }
    }

    func value(_ account: InvestmentAccount, on day: Date = Self.day()) -> InvestmentValuation? {
        guard let ledger = try? ledger(account, through: day) else { return nil }
        var equity = ledger.cash
        for (id, position) in ledger.positions where position.quantity > 0 {
            guard let asset = assets[id], let value = positionValue(position, asset: asset, on: day) else { return nil }
            equity += value
        }
        return InvestmentValuation(value: equity, gain: equity - ledger.flows)
    }

    func positionValue(_ position: InvestmentPosition, asset: InvestmentAsset, on day: Date = Self.day()) -> Decimal? {
        if position.quantity == 0 { return 0 }
        if asset.kind.isTermDeposit { return position.netCost }
        guard let quote = quote(asset.id, on: day) else { return nil }
        if asset.kind == .cryptoContract, let collateral = asset.collateralAssetID {
            guard let rate = self.quote(collateral, on: day)?.price else { return nil }
            let exposure = asset.contractExposure(quantity: position.quantity, price: quote.price)
            return asset.contractProfit(entry: position.contractEntry, exit: exposure) * rate
        }
        let value = position.value(at: quote.price, asset: asset)
        if !asset.isStockConnect { return value }
        return rateToCNY(.hkd, on: day).map { value * $0 }
    }

    func portfolio(on day: Date, currency: InvestmentCurrency = .cny) -> InvestmentValuation? {
        let destinationRate = rateToCNY(currency, on: day)
        var native = InvestmentValuation(value: 0, gain: 0)
        var converted = InvestmentValuation(value: 0, gain: 0)
        for account in accounts {
            guard let local = value(account, on: day) else { return nil }
            if local.value == 0, local.gain == 0 { continue }
            if account.currency == currency {
                native.value += local.value
                native.gain += local.gain
            } else {
                guard let rate = rateToCNY(account.currency, on: day),
                      destinationRate != nil else { return nil }
                converted.value += local.value * rate
                converted.gain += local.gain * rate
            }
        }
        guard let rate = destinationRate else { return native }
        return InvestmentValuation(value: native.value + converted.value / rate,
                                   gain: native.gain + converted.gain / rate)
    }

    func convert(_ amount: Decimal, from source: InvestmentCurrency, to destination: InvestmentCurrency,
                 on day: Date = Self.day()) -> Decimal? {
        if source == destination || amount == 0 { return amount }
        guard let sourceRate = rateToCNY(source, on: day),
              let destinationRate = rateToCNY(destination, on: day) else { return nil }
        return amount * sourceRate / destinationRate
    }

    private func rateToCNY(_ currency: InvestmentCurrency, on day: Date) -> Decimal? {
        if currency == .cny { return 1 }
        return fx[currency]?.last { $0.day <= day && $0.price > 0 }?.price
    }

    static func nextRun(_ monthDay: Int, after date: Date) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(day: monthDay, hour: 0), matchingPolicy: .strict) ?? date
    }

    mutating func runPlans(through today: Date = Self.day()) {
        var waiting = Set<UUID>()
        while let due = plans.filter({ $0.enabled && $0.nextDay <= today && !waiting.contains($0.id) })
            .map({ duePlan($0, through: today) })
            .min(by: { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day < rhs.day }
                return lhs.plan.assetID == nil && rhs.plan.assetID != nil
            }), let index = plans.firstIndex(where: { $0.id == due.plan.id }) {
            guard due.next > due.plan.nextDay else {
                plans[index].enabled = false
                plans[index].lastResult = "执行日期无效，任务已暂停。"
                continue
            }
            if let event = due.event {
                do {
                    try post(event, accountID: due.plan.accountID, today: today)
                    plans[index].lastResult = "已记账"
                } catch {
                    plans[index].lastResult = "已跳过 · " + error.localizedDescription
                }
            } else {
                plans[index].lastResult = due.message
            }
            if due.waiting { waiting.insert(due.plan.id) }
            else { plans[index].nextDay = due.next }
        }
    }

    private struct DuePlan {
        var plan: InvestmentPlan
        var next: Date
        var event: InvestmentEvent?
        var message: String?
        var waiting = false
        var day: Date { event?.day ?? plan.nextDay }
    }

    private func duePlan(_ plan: InvestmentPlan, through today: Date) -> DuePlan {
        let next = Self.nextRun(plan.monthDay, after: plan.nextDay)
        var due = DuePlan(plan: plan, next: next)
        guard let id = plan.assetID else {
            due.event = InvestmentEvent(day: plan.nextDay, kind: .deposit, amount: plan.amount)
            return due
        }
        guard let asset = assets[id], asset.supportsPlan else {
            due.message = "买入标的不可用，已跳过。"
            return due
        }
        guard let quote = quotes[id]?.first(where: { $0.day >= plan.nextDay && $0.day < next && $0.day <= today }) else {
            due.waiting = next > today
            due.message = due.waiting ? "等待可用报价。" : "当期缺少报价，已跳过。"
            return due
        }
        let scale = asset.kind == .fund ? 4 : 0
        var exact = plan.amount / quote.price
        var quantity = Decimal()
        NSDecimalRound(&quantity, &exact, scale, .down)
        if quantity > 0 {
            due.event = InvestmentEvent(day: quote.day, kind: .buy, assetID: id, quantity: quantity, price: quote.price)
        } else {
            due.message = "金额不足以买入最小数量，已跳过。"
        }
        return due
    }
}
