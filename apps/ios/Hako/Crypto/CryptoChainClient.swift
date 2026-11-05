import Foundation

extension CryptoClient {
    func walletTotal(_ wallet: CryptoWallet) async throws -> Double {
        try await walletSnapshot(wallet).total
    }

    func walletSnapshot(_ wallet: CryptoWallet) async throws -> CryptoWalletSnapshot {
        try wallet.validate()
        if wallet.network == CryptoWallet.cosmosHub {
            return try await cosmosWalletSnapshot(address:wallet.address)
        }
        if wallet.network == "TRON" {
            let token = try CryptoCredential.load("tronscan").key
            guard !token.isEmpty else { throw HakoError(message:"请在加密资产设置中配置 TRONSCAN API Token。") }
            return try await tronWalletSnapshot(address: wallet.address, token: token)
        }
        let token = try CryptoCredential.load("moralis").key
        guard !token.isEmpty else { throw HakoError(message:"请配置 Moralis API Token 以查询 Ethereum / BSC 资产。") }
        let chain = wallet.network == "Ethereum" ? "eth" : "bsc"
        // User-selected valuation convention: USD equals USDT.
        let assets = try await evmWalletAssets(address:wallet.address,chain:chain,token:token)
        return CryptoWalletSnapshot(total:assets.compactMap(\.value).reduce(0,+),assets:assets)
    }

    func tronWalletTotal(address: String, token: String) async throws -> Double {
        try await tronWalletSnapshot(address:address,token:token).total
    }

    private static let cosmosREST = "https://rest.cosmos.directory/cosmoshub"

    private func cosmosWalletSnapshot(address:String) async throws -> CryptoWalletSnapshot {
        // These are disjoint ownership buckets. Redelegations already belong to
        // the destination delegation and must not be added a second time.
        let bank=try await cosmosRows("/cosmos/bank/v1beta1/balances/\(address)",key:"balances")
        let delegated=try await cosmosRows("/cosmos/staking/v1beta1/delegations/\(address)",key:"delegation_responses")
        let unbonding=try await cosmosRows("/cosmos/staking/v1beta1/delegators/\(address)/unbonding_delegations",key:"unbonding_responses")
        let request=URLRequest(url:URL(string:Self.cosmosREST+"/cosmos/distribution/v1beta1/delegators/\(address)/rewards")!)
        guard let rewards=try await json(request) as? [String:Any], let coins=rewards["total"] as? [[String:Any]] else {
            throw HakoError(message:"Cosmos Hub 奖励响应不完整。")
        }
        func amount(_ value:Any?) throws -> Double {
            let result=try Self.number(value)
            guard result >= 0 else { throw HakoError(message:"Cosmos Hub 余额无效。") }
            return result
        }
        func atom(_ coins:[[String:Any]]) throws -> Double {
            var result=0.0
            for coin in coins {
                guard let denom=coin["denom"] as? String else { throw HakoError(message:"Cosmos Hub 币种缺失。") }
                if denom == "uatom" { result += try amount(coin["amount"]) }
            }
            return result
        }
        var micro=try atom(bank) + atom(coins)
        for row in delegated {
            guard let balance=row["balance"] as? [String:Any], balance["denom"] as? String == "uatom" else {
                throw HakoError(message:"Cosmos Hub 质押余额不完整。")
            }
            micro += try amount(balance["amount"])
        }
        for row in unbonding {
            guard let entries=row["entries"] as? [[String:Any]] else { throw HakoError(message:"Cosmos Hub 解押余额不完整。") }
            for entry in entries { micro += try amount(entry["balance"]) }
        }
        let quantity=micro / 1_000_000
        guard quantity.isFinite else { throw HakoError(message:"Cosmos Hub 资产总额无效。") }
        let value=quantity * (try await price("ATOM"))
        guard value.isFinite else { throw HakoError(message:"Cosmos Hub 估值无效。") }
        return CryptoWalletSnapshot(total:value,assets:[CryptoWalletAsset(id:"uatom",symbol:"ATOM",name:CryptoWallet.cosmosHub,quantity:quantity,value:value)])
    }

    private func cosmosRows(_ path:String,key:String) async throws -> [[String:Any]] {
        var result:[[String:Any]]=[], cursor:String?, seen=Set<String>()
        repeat {
            var url=URLComponents(string:Self.cosmosREST+path)!
            url.queryItems=[URLQueryItem(name:"pagination.limit",value:"200")]
            if let cursor { url.queryItems?.append(URLQueryItem(name:"pagination.key",value:cursor)) }
            // Go's query decoder treats a literal plus as a space; page keys use base64.
            url.percentEncodedQuery=url.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
            guard let object=try await json(URLRequest(url:url.url!)) as? [String:Any],
                  let rows=object[key] as? [[String:Any]], let pagination=object["pagination"] as? [String:Any] else {
                throw HakoError(message:"Cosmos Hub 余额或分页响应不完整。")
            }
            result += rows
            let next=pagination["next_key"]
            guard next == nil || next is NSNull || next is String else { throw HakoError(message:"Cosmos Hub 分页标识无效。") }
            cursor=next as? String
            if let cursor, !cursor.isEmpty {
                guard seen.insert(cursor).inserted, seen.count < 100 else { throw HakoError(message:"Cosmos Hub 资产分页尚未完成。") }
            }
        } while cursor?.isEmpty == false
        return result
    }

    func evmWalletAssets(address:String,chain:String,token:String) async throws -> [CryptoWalletAsset] {
        var assets:[CryptoWalletAsset]=[], cursor:String?, seen=Set<String>()
        repeat {
            var url=URLComponents(string:"https://deep-index.moralis.io/api/v2.2/wallets/\(address)/tokens")!
            url.queryItems=[URLQueryItem(name:"chain",value:chain),URLQueryItem(name:"exclude_spam",value:"true"),URLQueryItem(name:"exclude_unverified_contracts",value:"false")]
            if let cursor { url.queryItems?.append(URLQueryItem(name:"cursor",value:cursor)) }
            var request=URLRequest(url:url.url!)
            request.setValue(token,forHTTPHeaderField:"X-API-Key")
            guard let object=try await json(request) as? [String:Any], let rows=object["result"] as? [[String:Any]] else {
                throw HakoError(message:"链上币种明细响应无效。")
            }
            for row in rows {
                let symbol=row["symbol"] as? String ?? ""
                guard CryptoWalletAsset.isIncluded(symbol) else { continue }
                let quantity=try Self.number(row["balance_formatted"])
                guard quantity > 0 else { continue }
                guard let id=row["token_address"] as? String else { throw HakoError(message:"链上币种地址缺失。") }
                let value=try? Self.number(row["usd_value"])
                assets.append(CryptoWalletAsset(id:id.lowercased(),symbol:symbol,name:row["name"] as? String ?? symbol,quantity:quantity,value:value))
            }
            cursor=object["cursor"] as? String
            if let next=cursor, !next.isEmpty {
                guard seen.insert(next).inserted, seen.count < 100 else { throw HakoError(message:"链上资产分页尚未完成。") }
            }
        } while cursor?.isEmpty == false
        return assets
    }

    func tronWalletSnapshot(address: String, token: String) async throws -> CryptoWalletSnapshot {
        var request = URLRequest(url: URL(string: "https://apilist.tronscanapi.com/api/accountv2?address=\(address)")!)
        request.setValue(token, forHTTPHeaderField: "TRON-PRO-API-KEY")
        guard let account = try await json(request) as? [String: Any],
              account["address"] as? String == address else {
            throw HakoError(message: "TRONSCAN 账户响应无效，未将不完整估值记入总资产。")
        }
        let trx = try Self.tronOwnedTRX(account)
        let trxPrice = try await price("TRX")
        var assets=[CryptoWalletAsset(id:"_",symbol:"TRX",name:"TRON",quantity:trx,value:trx * trxPrice)]
        var total = trx * trxPrice, offset = 0
        while true {
            var r = URLRequest(url:URL(string:"https://apilist.tronscanapi.com/api/account/tokens?address=\(address)&start=\(offset)&limit=200&hidden=1&show=0")!)
            r.setValue(token, forHTTPHeaderField:"TRON-PRO-API-KEY")
            guard let object = try await json(r) as? [String: Any], let list = object["data"] as? [[String: Any]], let count = object["total"] as? Int else { throw HakoError(message:"TRONSCAN 余额响应无效。") }
            for row in list {
                // Native TRX (including stake) comes exclusively from accountv2.
                if row["tokenId"] as? String == "_" { continue }
                if ["trc721","trc1155"].contains(row["tokenType"] as? String ?? "") { continue }
                let symbol=row["tokenAbbr"] as? String ?? row["tokenName"] as? String ?? ""
                guard CryptoWalletAsset.isIncluded(symbol) else { continue }
                let quantity = try Self.number(row["balance"]) / pow(10, try Self.number(row["tokenDecimal"]))
                if quantity == 0 { continue }
                guard let tokenPrice = try? Self.number(row["tokenPriceInTrx"]) else { throw HakoError(message:"TRON 地址存在未定价代币，未将不完整估值记入总资产。") }
                let value=quantity * tokenPrice * trxPrice
                guard let id=row["tokenId"] as? String else { throw HakoError(message:"TRON 币种标识缺失。") }
                assets.append(CryptoWalletAsset(id:id,symbol:symbol,name:row["tokenName"] as? String ?? symbol,quantity:quantity,value:value))
                total += value
            }
            offset += list.count
            if offset >= count { break }
            guard !list.isEmpty, offset < 20000 else { throw HakoError(message:"链上资产分页尚未完成。") }
        }
        return CryptoWalletSnapshot(total:total,assets:assets)
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
