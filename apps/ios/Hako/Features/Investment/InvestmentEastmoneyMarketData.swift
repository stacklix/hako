import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension InvestmentAsset {
    var usesEastmoneyMarketData: Bool {
        if isStockConnect { return kind == .stock || kind == .etf }
        if currency == .usd { return kind == .stock || kind == .etf }
        return currency == .cny && [.stock, .etf, .fund, .future, .option].contains(kind)
    }
}

extension InvestmentQuoteProvider {
    static let eastmoneyTitle = "东方财富"

    private struct EastmoneySearch: Decodable {
        struct Table: Decodable {
            struct Entry: Decodable {
                let Code: String
                let Name: String
                let Classify: String
                let MktNum: String
                var JYS: String?
                var SecurityType: String?
                var SecurityTypeName: String?
                var TypeUS: String?
                var QuoteID: String?
            }
            let Status: Int
            var Data: [Entry]?
        }
        let QuotationCodeTable: Table
    }

    private func eastmoneyData(_ url: URL, referer: String = "https://quote.eastmoney.com/") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await send(request, [])
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if attempt == 0, status == 429 || status >= 500 {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                guard status == 200 else { throw InvestmentError.invalid("东方财富请求失败（HTTP \(status)）") }
                return data
            } catch let error as URLError where attempt == 0 &&
                [.timedOut, .networkConnectionLost, .cannotConnectToHost, .badServerResponse].contains(error.code) {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        throw InvestmentError.invalid("东方财富连接暂不可用")
    }

    private func eastmoneyEntries(_ query: String) async throws -> [EastmoneySearch.Table.Entry] {
        var url = URLComponents(string: "https://searchapi.eastmoney.com/api/suggest/get")!
        url.queryItems = [.init(name: "input", value: query), .init(name: "type", value: "14"),
                          .init(name: "count", value: "100")]
        let data = try await eastmoneyData(url.url!)
        let result = try JSONDecoder().decode(EastmoneySearch.self, from: data).QuotationCodeTable
        guard result.Status == 0 else { throw InvestmentError.invalid("东方财富标的搜索暂不可用") }
        return result.Data ?? []
    }

    private struct EastmoneyMetadata: Decodable {
        struct Table: Decodable {
            let f57: String
            let f107: Int
            var f127: String?
            var f172: String?
            var f198: String?
        }
        let rc: Int
        var data: Table?
    }

    private func eastmoneyMetadata(_ quoteID: String) async throws -> EastmoneyMetadata.Table {
        var url = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/get")!
        url.queryItems = [.init(name: "secid", value: quoteID), .init(name: "fields", value: "f57,f107,f127,f172,f198")]
        let data = try await eastmoneyData(url.url!)
        let result = try JSONDecoder().decode(EastmoneyMetadata.self, from: data)
        let parts = quoteID.split(separator: ".", maxSplits: 1).map(String.init)
        guard result.rc == 0, let table = result.data, table.f57.uppercased() == parts[1].uppercased(),
              table.f107 == Int(parts[0]) else { throw InvestmentError.invalid("东方财富返回的标的元数据不匹配") }
        return table
    }

    func eastmoneyInstruments(_ search: InvestmentInstrumentSearch) async throws -> [InvestmentAsset] {
        guard !search.query.isEmpty, !search.kind.isManual, search.kind != .crypto else { return [] }
        let exact = search.exactAsset
        let query: String
        if search.stockConnect, let code = InvestmentAsset.stockConnectCode(search.query) {
            query = String(code.dropLast(3))
        } else if let mainland = exact.mainlandSymbol {
            query = search.kind.derivative ? Self.eastmoneyContract(mainland.base, venue: mainland.venue, kind: search.kind) : mainland.base
        } else if search.currency == .usd, search.query.uppercased().hasSuffix(".US") {
            query = String(search.query.dropLast(3))
        } else { query = search.query }
        let entries = try await eastmoneyEntries(query)
        var hongKongFundKinds: [String: InvestmentKind] = [:]
        if search.stockConnect {
            for entry in entries where entry.Classify == "HK" && entry.MktNum == "116" && entry.SecurityType == "6" {
                guard InvestmentAsset.stockConnectCode(entry.Code) != nil else { continue }
                // The suggest endpoint also labels REITs as type 6. Its equity industry metadata distinguishes these from ETFs.
                let meta = try await eastmoneyMetadata("116." + entry.Code)
                guard meta.f172 == "HKD", let industry = meta.f127, let industryCode = meta.f198 else { continue }
                if industry.isEmpty && industryCode.isEmpty { hongKongFundKinds[entry.Code] = .etf }
                else if !industry.isEmpty && !industryCode.isEmpty { hongKongFundKinds[entry.Code] = .stock }
            }
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            let name = entry.Name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let code: String
            let market: String
            if search.stockConnect {
                guard search.currency == .hkd, entry.Classify == "HK", entry.MktNum == "116",
                      (entry.SecurityType == "19" && search.kind == .stock) || hongKongFundKinds[entry.Code] == search.kind,
                      let normalized = InvestmentAsset.stockConnectCode(entry.Code) else { return nil }
                code = normalized
                market = InvestmentAsset.stockConnectMarket
            } else if search.currency == .usd {
                guard entry.Classify == "UsStock", ["105", "106", "107"].contains(entry.MktNum),
                      search.kind == .etf ? entry.TypeUS == "5" : (search.kind == .stock && entry.SecurityType == "20") else { return nil }
                code = entry.Code.uppercased()
                // Eastmoney's 107 group includes several US venues; it is not an exact MIC.
                market = ["105": "XNAS", "106": "XNYS", "107": "US"][entry.MktNum]!
            } else if search.currency == .cny, search.kind == .fund {
                guard entry.Classify == "OTCFUND", entry.MktNum == "150" else { return nil }
                code = entry.Code + ".OF"
                market = ""
            } else if search.currency == .cny, search.kind.derivative {
                let venues = ["SHFE": "SHF", "DCE": "DCE", "CZCE": "ZCE", "CFFEX": "CFX", "INE": "INE", "GFEX": "GFE",
                              "SHFEOPTION": "SHF", "DCEOPTION": "DCE", "CZCEOPTION": "ZCE", "CFFEXOPTION": "CFX",
                              "INEOPTION": "INE", "GFEXOPTION": "GFE", "SH": "SH", "SZ": "SZ", "9": "SH", "6": "SZ",
                              "173": "SH", "178": "SZ"]
                guard entry.SecurityTypeName == (search.kind == .future ? "期货" : "期权"),
                      let venue = entry.JYS.flatMap({ venues[$0.uppercased()] }),
                      Self.eastmoneyMarket(venue: venue, kind: search.kind) == entry.MktNum else { return nil }
                code = entry.Code.uppercased() + "." + venue
                market = ""
            } else if search.currency == .cny {
                guard entry.Classify == (search.kind == .etf ? "Fund" : "AStock"), search.kind == .stock || search.kind == .etf else { return nil }
                let candidate = InvestmentAsset(name: name, code: entry.Code, market: "", kind: search.kind, currency: .cny)
                guard let mainland = candidate.mainlandSymbol,
                      ["SH": "1", "SZ": "0", "BJ": "0"][mainland.venue] == entry.MktNum else { return nil }
                code = mainland.base + "." + mainland.venue
                market = ""
            } else { return nil }
            let asset = InvestmentAsset(name: name, code: code, market: market, kind: search.kind, currency: search.currency)
            guard search.permits(asset) else { return nil }
            if let requested = exact.mainlandSymbol {
                guard let matched = asset.mainlandSymbol, requested.venue == matched.venue,
                      Self.normalizedEastmoneyCode(Self.eastmoneyContract(requested.base, venue: requested.venue, kind: search.kind)) ==
                        Self.normalizedEastmoneyCode(matched.base) else { return nil }
            } else if search.stockConnect, let normalized = InvestmentAsset.stockConnectCode(search.query) {
                guard asset.code == normalized else { return nil }
            } else if search.currency == .usd, search.query.uppercased().hasSuffix(".US") {
                guard asset.code == query.uppercased() else { return nil }
            } else {
                guard search.includes(asset) || entry.Code.localizedCaseInsensitiveContains(query) else { return nil }
            }
            guard seen.insert(asset.catalogKey).inserted else { return nil }
            return asset
        }
    }

    private static func normalizedEastmoneyCode(_ code: String) -> String {
        code.uppercased().replacingOccurrences(of: "-", with: "")
    }

    private static func eastmoneyMarket(venue: String, kind: InvestmentKind) -> String? {
        if kind == .future {
            return ["SHF": "113", "DCE": "114", "ZCE": "115", "CFX": "220", "INE": "142", "GFE": "225"][venue]
        }
        if kind == .option {
            return ["SH": "10", "SZ": "12", "SHF": "151", "DCE": "140", "ZCE": "141", "CFX": "221", "INE": "163", "GFE": "226"][venue]
        }
        return ["SH": "1", "SZ": "0", "BJ": "0"][venue]
    }

    private static func eastmoneyContract(_ base: String, venue: String, kind: InvestmentKind) -> String {
        guard kind.derivative else { return base }
        var code = base.uppercased()
        let prefix = String(code.prefix(while: { $0.isLetter }))
        let rest = String(code.dropFirst(prefix.count))
        if venue == "ZCE", rest.prefix(while: { $0.isNumber }).count == 4 {
            code = prefix + rest.dropFirst()
        }
        if kind == .option, venue == "DCE" { return code.replacingOccurrences(of: "-", with: "").lowercased() }
        if ["SHF", "INE", "GFE", "DCE"].contains(venue) {
            return String(code.prefix(prefix.count)).lowercased() + code.dropFirst(prefix.count)
        }
        return code
    }

    private func eastmoneyQuoteID(for asset: InvestmentAsset) async throws -> String {
        if asset.isStockConnect, let code = InvestmentAsset.stockConnectCode(asset.code) {
            return "116." + code.dropLast(3)
        }
        if let mainland = asset.mainlandSymbol,
           let market = Self.eastmoneyMarket(venue: mainland.venue, kind: asset.kind) {
            return market + "." + Self.eastmoneyContract(mainland.base, venue: mainland.venue, kind: asset.kind)
        }
        if asset.currency == .usd, asset.kind == .stock || asset.kind == .etf {
            let symbol = asset.code.uppercased().hasSuffix(".US") ? String(asset.code.dropLast(3)) : asset.code
            let entries = try await eastmoneyEntries(symbol)
            let allowedMarkets: Set<String>
            switch asset.market.uppercased() {
            case "XNAS", "XNGS", "XNMS", "XNCM": allowedMarkets = ["105"]
            case "XNYS": allowedMarkets = ["106"]
            case "XASE", "ARCX", "BATS", "BATY", "EDGA", "EDGX": allowedMarkets = ["107"]
            default: allowedMarkets = ["105", "106", "107"]
            }
            guard let entry = entries.first(where: {
                $0.Code.uppercased() == symbol.uppercased() && $0.Classify == "UsStock" && allowedMarkets.contains($0.MktNum)
                    && (asset.kind == .etf ? $0.TypeUS == "5" : $0.SecurityType == "20")
            }) else { throw InvestmentError.invalid("东方财富没有匹配的美股标的") }
            return entry.MktNum + "." + entry.Code
        }
        throw InvestmentError.invalid("东方财富不支持此标的的行情查询")
    }

    private struct EastmoneyKlines: Decodable {
        struct Table: Decodable {
            let code: String
            let market: Int
            var klines: [String]?
        }
        let rc: Int
        var data: Table?
    }

    func eastmoneyHistory(asset: InvestmentAsset, start: Date, through end: Date) async throws -> [InvestmentQuote] {
        try asset.validateMarket(settlingIn: asset.settlementCurrency)
        if asset.kind == .fund, asset.mainlandSymbol?.venue == "OF" {
            return try await eastmoneyFundNAV(code: asset.mainlandSymbol!.base, start: start, end: end)
        }
        let quoteID = try await eastmoneyQuoteID(for: asset)
        let parts = quoteID.split(separator: ".", maxSplits: 1).map(String.init)
        let format = Self.eastmoneyDateFormat("yyyyMMdd")
        let dayFormat = Self.eastmoneyDateFormat("yyyy-MM-dd")
        var cursor = InvestmentBook.day(end)
        var quotes: [InvestmentQuote] = []
        while cursor >= start {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")!
            url.queryItems = [.init(name: "secid", value: quoteID), .init(name: "klt", value: "101"),
                              .init(name: "fqt", value: "0"), .init(name: "lmt", value: "10000"),
                              .init(name: "end", value: format.string(from: cursor)),
                              .init(name: "fields1", value: "f1,f2,f3,f4,f5,f6,f7,f8"),
                              .init(name: "fields2", value: "f51,f52,f53,f54,f55,f56")]
            if asset.kind.derivative {
                url.queryItems! += [.init(name: "iscca", value: "1"), .init(name: "forcect", value: "1")]
            } else { url.queryItems!.append(.init(name: "beg", value: format.string(from: start))) }
            let data = try await eastmoneyData(url.url!)
            let result = try JSONDecoder().decode(EastmoneyKlines.self, from: data)
            guard result.rc == 0, let table = result.data, table.market == Int(parts[0]),
                  Self.normalizedEastmoneyCode(table.code) == Self.normalizedEastmoneyCode(parts[1]) else {
                throw InvestmentError.invalid("东方财富没有该标的的历史日线（\(result.rc)），到期合约可能已无数据")
            }
            let bars = table.klines ?? []
            var first: Date?
            for bar in bars {
                let fields = bar.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 3, let day = dayFormat.date(from: String(fields[0])), day <= cursor else { continue }
                first = min(first ?? day, day)
                guard day >= start, day <= end,
                      let price = Decimal(string: String(fields[2]), locale: Locale(identifier: "en_US_POSIX")), price > 0 else { continue }
                quotes.append(.init(day: day, price: price, source: Self.eastmoneyTitle))
            }
            guard bars.count >= 10000, let first, first > start else { break }
            let next = InvestmentBook.addDays(-1, to: first)
            guard next < cursor else { throw InvestmentError.invalid("东方财富历史日线分页没有前进") }
            cursor = next
        }
        return try Self.eastmoneyValid(quotes)
    }

    private struct EastmoneyFundHistory: Decodable {
        struct Table: Decodable {
            struct Row: Decodable {
                let FSRQ: String
                var DWJZ: String?
            }
            var LSJZList: [Row]?
            var FundType: String?
            var SYType: String?
        }
        let ErrCode: Int
        var Data: Table?
        var TotalCount: Int?
        var PageIndex: Int?
    }

    private func eastmoneyFundNAV(code: String, start: Date, end: Date) async throws -> [InvestmentQuote] {
        let format = Self.eastmoneyDateFormat("yyyy-MM-dd")
        var page = 1
        var quotes: [InvestmentQuote] = []
        var previousFirst: String?
        var received = 0
        while true {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://api.fund.eastmoney.com/f10/lsjz")!
            url.queryItems = [.init(name: "fundCode", value: code), .init(name: "pageIndex", value: String(page)),
                              .init(name: "pageSize", value: "100"), .init(name: "startDate", value: format.string(from: start)),
                              .init(name: "endDate", value: format.string(from: end))]
            let data = try await eastmoneyData(url.url!, referer: "https://fundf10.eastmoney.com/")
            let result = try JSONDecoder().decode(EastmoneyFundHistory.self, from: data)
            guard result.ErrCode == 0, let table = result.Data else { throw InvestmentError.invalid("天天基金历史净值暂不可用") }
            guard table.FundType != "005", table.SYType?.contains("万份") != true else {
                throw InvestmentError.invalid("该货币基金返回的是每万份收益，不能作为单位净值；暂时无法提供此基金的单位净值行情。")
            }
            let rows = table.LSJZList ?? []
            guard !rows.isEmpty else {
                if let total = result.TotalCount, received < total {
                    throw InvestmentError.invalid("天天基金历史净值分页数据不完整")
                }
                break
            }
            guard result.PageIndex == nil || result.PageIndex == page, rows.first?.FSRQ != previousFirst else {
                throw InvestmentError.invalid("天天基金历史净值分页没有前进")
            }
            previousFirst = rows.first?.FSRQ
            received += rows.count
            for row in rows {
                guard let day = format.date(from: row.FSRQ), day >= start, day <= end,
                      let value = row.DWJZ, let price = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), price > 0 else { continue }
                quotes.append(.init(day: day, price: price, source: Self.eastmoneyTitle + " · 天天基金", isDailyClose: true))
            }
            if let total = result.TotalCount {
                if received >= total { break }
            } else if rows.count < 100 { break }
            page += 1
            guard page <= 1000 else { throw InvestmentError.invalid("天天基金历史净值页数异常") }
        }
        return try Self.eastmoneyValid(quotes)
    }

    private static func eastmoneyDateFormat(_ pattern: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = InvestmentBook.calendar
        format.timeZone = InvestmentBook.calendar.timeZone
        format.dateFormat = pattern
        return format
    }

    private static func eastmoneyValid(_ quotes: [InvestmentQuote]) throws -> [InvestmentQuote] {
        let result = InvestmentBook.merge([], quotes)
        guard !result.isEmpty else { throw InvestmentError.invalid("东方财富没有可用的历史收盘价或基金净值") }
        return result
    }
}
