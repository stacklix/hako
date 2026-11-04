import Foundation

extension CryptoClient {
    func walletTotal(_ wallet: CryptoWallet) async throws -> Double {
        try wallet.validate()
        if wallet.network == "TRON" {
            let token = try CryptoCredential.load("tronscan").key
            guard !token.isEmpty else { throw HakoError(message:"请在加密资产设置中配置 TRONSCAN API Token。") }
            var total = 0.0, offset = 0
            let trxPrice = try await price("TRX")
            while true {
                var r = URLRequest(url:URL(string:"https://apilist.tronscanapi.com/api/account/tokens?address=\(wallet.address)&start=\(offset)&limit=200&hidden=1&show=0")!)
                r.setValue(token, forHTTPHeaderField:"TRON-PRO-API-KEY")
                guard let object = try await json(r) as? [String: Any], let list = object["data"] as? [[String: Any]], let count = object["total"] as? Int else { throw HakoError(message:"TRONSCAN 余额响应无效。") }
                for row in list {
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
}
