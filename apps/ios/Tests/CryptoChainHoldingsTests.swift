import Foundation

@main struct CryptoChainHoldingsTests {
    static func main() {
        let tron = CryptoWallet(name:"Tronlink1",network:"TRON",address:"T-address")
        let reserve = CryptoWallet(name:"备用钱包",network:"TRON",address:"T-reserve")
        let ethereum = CryptoWallet(name:"Ethereum",network:"Ethereum",address:"0xAbCd")
        let alias = CryptoWallet(name:"重复地址",network:"Ethereum",address:"0xabcd")
        func asset(_ symbol:String,_ quantity:Double,_ value:Double?) -> CryptoWalletAsset {
            CryptoWalletAsset(id:UUID().uuidString,symbol:symbol,name:symbol,quantity:quantity,value:value)
        }
        let tronSnapshot = CryptoWalletSnapshot(total:15975.6,assets:[asset("TRX",50000,15974.8),asset("USDT",0.8,0.8)])
        let evmSnapshot = CryptoWalletSnapshot(total:1400,assets:[asset(" usdt ",1200,1200),asset("USDT",200,200),asset("USDC",0,0),asset("OTHER",5,500)])
        let result = CryptoChainHolding.aggregate([
            (tron,tronSnapshot),
            (ethereum,evmSnapshot),
            (alias,evmSnapshot),
            (reserve,CryptoWalletSnapshot(total:300,assets:[asset("USDT",300,300)]))
        ])
        precondition(result.map(\.symbol) == ["TRX","USDT"],"Sort by valuation; omit zero holdings and unsupported coins")
        let usdt = result.first { $0.symbol == "USDT" }!
        precondition(abs(usdt.quantity-1700.8) < 0.000001 && abs(usdt.value!-1700.8) < 0.000001,"Sum all chains and addresses, normalize symbols, combine same-address tokens")
        precondition(usdt.positions.count == 3 && usdt.networks == ["Ethereum","TRON"],"Deduplicate the same EVM address case-insensitively without merging different chains or addresses")
        precondition(usdt.positions.first { $0.wallet.id == ethereum.id }?.quantity == 1400,"Keep per-address totals consistent with the coin total")
        precondition(!usdt.partiallyPriced,"Fully quoted balances have a complete valuation")
        let partial = CryptoChainHolding.aggregate([
            (tron,tronSnapshot),
            (reserve,CryptoWalletSnapshot(total:0,assets:[asset("USDT",300,nil)]))
        ]).first { $0.symbol == "USDT" }!
        precondition(partial.quantity == 300.8 && partial.value == 0.8 && partial.partiallyPriced,"Retain unpriced quantity and explicitly identify partial USDT totals")
        let unpriced = CryptoChainHolding.aggregate([(reserve,CryptoWalletSnapshot(total:0,assets:[asset("ETH",2,nil)]))]).first!
        precondition(unpriced.value == nil && !unpriced.partiallyPriced,"Missing prices are not zero-value balances")
        precondition(CryptoChainHolding.aggregate([]).isEmpty,"Missing snapshots must not fabricate zero balances")
        print("Chain holdings: cross-chain/address totals, deduplication, normalized symbols, filtering, partial and missing quotes passed")
    }
}
