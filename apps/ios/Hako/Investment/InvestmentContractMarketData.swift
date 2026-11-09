import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum InvestmentContractExchange: String, CaseIterable {
    case binance = "BINANCE", htx = "HTX"

    var title: String { self == .binance ? "Binance" : "HTX" }

    init?(asset: InvestmentAsset) {
        guard asset.kind == .cryptoContract, asset.basis != .usd else { return nil }
        self.init(rawValue: asset.market)
    }
}

struct InvestmentContractListing: Identifiable {
    let asset: InvestmentAsset
    let settlementCode: String
    var id: UUID { asset.id }
}

extension InvestmentQuoteProvider {
    private struct BinanceCatalog: Decodable {
        struct Contract: Decodable {
            let symbol: String
            let baseAsset: String
            let quoteAsset: String
            let marginAsset: String
            let contractType: String
            let status: String?
            let contractStatus: String?
            let contractSize: Decimal?
        }
        let symbols: [Contract]
    }

    private struct HTXCatalog: Decodable {
        struct Contract: Decodable {
            let symbol: String
            let contract_code: String
            let contract_size: Decimal
            let contract_status: Int
            let delivery_date: String?
            let trade_partition: String?
        }
        let status: String
        let data: [Contract]?
    }

    func contractCatalog(_ exchange: InvestmentContractExchange, basis: InvestmentContractBasis) async throws -> [InvestmentContractListing] {
        guard basis != .usd else { return [] }
        switch exchange {
        case .binance:
            let (host, path) = binanceEndpoint(basis)
            let data = try await publicMarketData(host: host, path: path + "/exchangeInfo")
            let response = try JSONDecoder().decode(BinanceCatalog.self, from: data)
            return response.symbols.compactMap { row in
                guard (row.contractStatus ?? row.status) == "TRADING", !row.contractType.isEmpty else { return nil }
                let size: Decimal
                if basis == .coin {
                    guard row.quoteAsset == "USD", row.baseAsset == row.marginAsset,
                          let faceValue = row.contractSize, faceValue > 0 else { return nil }
                    size = faceValue
                } else {
                    guard row.quoteAsset == row.marginAsset, ["USDT", "USDC"].contains(row.marginAsset) else { return nil }
                    size = 1
                }
                return contractListing(code: row.symbol, pair: row.baseAsset + "/" + row.quoteAsset,
                                       exchange: exchange, basis: basis, size: size, settlement: row.marginAsset,
                                       delivery: row.contractType != "PERPETUAL")
            }
        case .htx:
            if basis == .stablecoin {
                return try await htxCatalog(path: "/linear-swap-api/v1/swap_contract_info",
                                            query: [.init(name: "business_type", value: "all")], basis: basis)
            }
            async let perpetual = try? htxCatalog(path: "/swap-api/v1/swap_contract_info", basis: basis)
            async let delivery = try? htxCatalog(path: "/api/v1/contract_contract_info", basis: basis)
            let (swaps, futures) = await (perpetual, delivery)
            try Task.checkCancellation()
            guard swaps != nil || futures != nil else { throw InvestmentError.invalid("HTX 合约目录暂不可用") }
            return (swaps ?? []) + (futures ?? [])
        }
    }

    private func htxCatalog(path: String, query: [URLQueryItem] = [], basis: InvestmentContractBasis) async throws -> [InvestmentContractListing] {
        let data = try await publicMarketData(host: "api.hbdm.com", path: path, query: query)
        let response = try JSONDecoder().decode(HTXCatalog.self, from: data)
        guard response.status == "ok", let contracts = response.data else { throw InvestmentError.invalid("HTX 合约目录暂不可用") }
        return contracts.compactMap { row in
            guard row.contract_status == 1, row.contract_size > 0 else { return nil }
            let quote: String
            if basis == .coin {
                quote = "USD"
            } else {
                guard let currency = row.trade_partition, ["USDT", "USDC"].contains(currency) else { return nil }
                quote = currency
            }
            return contractListing(code: row.contract_code, pair: row.symbol + "/" + quote, exchange: .htx, basis: basis,
                                   size: row.contract_size, settlement: basis == .coin ? row.symbol : quote,
                                   delivery: !(row.delivery_date ?? "").isEmpty)
        }
    }

    private func contractListing(code: String, pair: String, exchange: InvestmentContractExchange, basis: InvestmentContractBasis,
                                 size: Decimal, settlement: String, delivery: Bool) -> InvestmentContractListing {
        let asset = InvestmentAsset(name: pair + (delivery ? " 交割" : " 永续"), code: code, market: exchange.rawValue,
                                    kind: .cryptoContract, currency: .usd, multiplier: size, contractBasis: basis)
        return InvestmentContractListing(asset: asset, settlementCode: settlement)
    }

    private struct BinanceMark: Decodable {
        let symbol: String
        let markPrice: String
        let time: Int64
    }

    private struct HTXMark: Decodable {
        struct Bar: Decodable {
            let id: Int64
            let close: String
        }
        let status: String
        let ch: String?
        let data: [Bar]?
    }

    func contractMark(_ asset: InvestmentAsset, now: Date = .now) async throws -> InvestmentQuote {
        guard let exchange = InvestmentContractExchange(asset: asset) else {
            throw InvestmentError.invalid("没有适用的合约报价交易所")
        }
        let sample: (price: String, time: Date)
        switch exchange {
        case .binance:
            let (host, path) = binanceEndpoint(asset.basis)
            let data = try await publicMarketData(host: host, path: path + "/premiumIndex",
                                                  query: [.init(name: "symbol", value: asset.code)])
            let marks = asset.basis == .coin ? try JSONDecoder().decode([BinanceMark].self, from: data)
                : [try JSONDecoder().decode(BinanceMark.self, from: data)]
            guard let mark = marks.first(where: { $0.symbol == asset.code }) else {
                throw InvestmentError.invalid("合约报价代码不匹配")
            }
            sample = (mark.markPrice, Date(timeIntervalSince1970: Double(mark.time) / 1_000))
        case .htx:
            let path: String
            let codeParameter: String
            if asset.basis == .stablecoin {
                path = "linear_swap_mark_price_kline"
                codeParameter = "contract_code"
            } else if asset.code.hasSuffix("-USD") {
                path = "swap_mark_price_kline"
                codeParameter = "contract_code"
            } else {
                path = "mark_price_kline"
                codeParameter = "symbol"
            }
            let data = try await publicMarketData(host: "api.hbdm.com", path: "/index/market/history/" + path, query: [
                .init(name: codeParameter, value: asset.code), .init(name: "period", value: "1min"), .init(name: "size", value: "1")
            ])
            let mark = try JSONDecoder().decode(HTXMark.self, from: data)
            guard mark.status == "ok", mark.ch?.uppercased() == "MARKET." + asset.code + ".MARK_PRICE.1MIN",
                  let bar = mark.data?.first else { throw InvestmentError.invalid("没有匹配的 HTX 合约标记价格") }
            sample = (bar.close, Date(timeIntervalSince1970: Double(bar.id)))
        }
        guard let price = Decimal(string: sample.price, locale: Locale(identifier: "en_US_POSIX")), price > 0,
              (-120...300).contains(now.timeIntervalSince(sample.time)) else {
            throw InvestmentError.invalid("合约标记价格无效或已过期")
        }
        return InvestmentQuote(day: InvestmentBook.day(sample.time), price: price, source: exchange.title + " 标记价格")
    }

    private struct CoinbaseSpot: Decodable {
        struct Price: Decodable {
            let amount: String
            let base: String
            let currency: String
        }
        let data: Price
    }

    func coinbaseSpotUSDQuote(code: String) async throws -> InvestmentQuote {
        let data = try await publicMarketData(host: "api.coinbase.com", path: "/v2/prices/" + code + "-USD/spot")
        let price = try JSONDecoder().decode(CoinbaseSpot.self, from: data).data
        guard price.base == code, price.currency == "USD",
              let amount = Decimal(string: price.amount, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
            throw InvestmentError.invalid("没有有效的现货美元报价")
        }
        return InvestmentQuote(day: InvestmentBook.day(), price: amount, source: "Coinbase 现货")
    }

    private func binanceEndpoint(_ basis: InvestmentContractBasis) -> (String, String) {
        basis == .coin ? ("dapi.binance.com", "/dapi/v1") : ("fapi.binance.com", "/fapi/v1")
    }

    private func publicMarketData(host: String, path: String, query: [URLQueryItem] = []) async throws -> Data {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = path
        if !query.isEmpty { url.queryItems = query }
        guard let endpoint = url.url else { throw URLError(.badURL) }
        let (data, response) = try await send(URLRequest(url: endpoint, timeoutInterval: 10), [])
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw InvestmentError.invalid(host + " 行情接口暂不可用")
        }
        return data
    }
}
