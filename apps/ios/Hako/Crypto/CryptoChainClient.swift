import Foundation

extension CryptoClient {
    func walletTotal(_ wallet: CryptoWallet) async throws -> Double {
        try wallet.validate()
        if wallet.network == "TRON" {
            let token = try CryptoCredential.load("tronscan").key
            guard !token.isEmpty else { throw HakoError(message:"请在加密资产设置中配置 TRONSCAN API Token。") }
            return try await tronWalletTotal(address: wallet.address, token: token)
        }
        let token = try CryptoCredential.load("moralis").key
        guard !token.isEmpty else { throw HakoError(message:"请配置 Moralis API Token 以查询 Ethereum / BSC 资产。") }
        let chain = wallet.network == "Ethereum" ? "eth" : "bsc"
        var r = URLRequest(url:URL(string:"https://deep-index.moralis.io/api/v2.2/wallets/\(wallet.address)/net-worth?chains%5B0%5D=\(chain)&exclude_spam=true&exclude_unverified_contracts=false")!)
        r.setValue(token,forHTTPHeaderField:"X-API-Key")
        guard let o = try await json(r) as? [String: Any] else { throw HakoError(message:"链上资产响应无效。") }
        let usd = try Self.number(o["total_networth_usd"])
        // USD and USDT are not assumed to have a fixed 1:1 exchange rate.
        let quote = try await json(URLRequest(url:URL(string:"https://api.coingecko.com/api/v3/simple/price?ids=tether&vs_currencies=usd")!))
        guard let data = quote as? [String: Any], let tether = data["tether"] as? [String: Any] else { throw HakoError(message:"USDT/USD 报价缺失。") }
        let rate = try Self.number(tether["usd"])
        guard rate > 0 else { throw HakoError(message:"USDT/USD 报价无效。") }
        return usd / rate
    }

    func tronWalletTotal(address: String, token: String) async throws -> Double {
        var request = URLRequest(url: URL(string: "https://apilist.tronscanapi.com/api/accountv2?address=\(address)")!)
        request.setValue(token, forHTTPHeaderField: "TRON-PRO-API-KEY")
        guard let account = try await json(request) as? [String: Any],
              account["address"] as? String == address else {
            throw HakoError(message: "TRONSCAN 账户响应无效，未将不完整估值记入总资产。")
        }
        let trx = try Self.tronOwnedTRX(account)
        let trxPrice = try await price("TRX")
        var total = trx * trxPrice, offset = 0
        while true {
            var r = URLRequest(url:URL(string:"https://apilist.tronscanapi.com/api/account/tokens?address=\(address)&start=\(offset)&limit=200&hidden=1&show=0")!)
            r.setValue(token, forHTTPHeaderField:"TRON-PRO-API-KEY")
            guard let object = try await json(r) as? [String: Any], let list = object["data"] as? [[String: Any]], let count = object["total"] as? Int else { throw HakoError(message:"TRONSCAN 余额响应无效。") }
            for row in list {
                // Native TRX (including stake) comes exclusively from accountv2.
                if row["tokenId"] as? String == "_" { continue }
                if ["trc721","trc1155"].contains(row["tokenType"] as? String ?? "") { continue }
                let quantity = try Self.number(row["balance"]) / pow(10, try Self.number(row["tokenDecimal"]))
                if quantity == 0 { continue }
                guard let tokenPrice = try? Self.number(row["tokenPriceInTrx"]) else { throw HakoError(message:"TRON 地址存在未定价代币，未将不完整估值记入总资产。") }
                total += quantity * tokenPrice * trxPrice
            }
            offset += list.count
            if offset >= count { break }
            guard !list.isEmpty, offset < 20000 else { throw HakoError(message:"链上资产分页尚未完成。") }
        }
        return total
    }

    static func tronOwnedTRX(_ account: [String: Any]) throws -> Double {
        // accountv2 amounts are in sun (1 TRX = 1,000,000 sun).
        // Sum disjoint owned balances, not totalFrozen/totalFrozenV2 or resource values.
        // Outgoing delegation remains owned; incoming delegation belongs to another account.
        let fields = [
            "frozenForBandWidth", "frozenForEnergy",
            "delegateFrozenForBandWidth", "delegateFrozenForEnergy",
            "frozenForBandWidthV2", "frozenForEnergyV2",
            "delegatedFrozenV2BalanceForBandwidth", "delegatedFrozenV2BalanceForEnergy",
            "unfreezeV2", "canWithdrawAmountV2"
        ]
        func amount(_ value: Any?) throws -> Double {
            guard let value = try? Self.number(value), value >= 0 else {
                throw HakoError(message: "TRONSCAN 余额或质押数据不完整，未将不完整估值记入总资产。")
            }
            return value
        }
        var sun = try amount(account["balanceStr"] ?? account["balance"])
        for field in fields { sun += try amount(account[field]) }
        guard sun.isFinite else { throw HakoError(message: "TRONSCAN 资产总额无效。") }
        return sun / 1_000_000
    }
}
