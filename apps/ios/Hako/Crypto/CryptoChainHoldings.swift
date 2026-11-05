import Foundation

struct CryptoChainPosition: Identifiable {
    let wallet: CryptoWallet
    var quantity: Double
    var value: Double?
    var id: String { wallet.identity }
}

struct CryptoChainHolding: Identifiable {
    let symbol: String
    let name: String
    var positions: [CryptoChainPosition]
    var id: String { symbol }
    var quantity: Double { positions.reduce(0) { $0 + $1.quantity } }
    var value: Double? {
        let values = positions.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0,+)
    }
    var partiallyPriced: Bool { value != nil && positions.contains { $0.value == nil } }
    var networks: [String] { Array(Set(positions.map { $0.wallet.network })).sorted() }

    static func aggregate(_ snapshots: [(CryptoWallet,CryptoWalletSnapshot)]) -> [Self] {
        var seen = Set<String>()
        var holdings: [String:Self] = [:]
        for (wallet,snapshot) in snapshots where seen.insert(wallet.identity).inserted {
            let groups = Dictionary(grouping:snapshot.assets.filter { CryptoWalletAsset.isIncluded($0.symbol) }) {
                $0.symbol.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
            }
            for (symbol,assets) in groups {
                let quantity = assets.reduce(0) { $0 + $1.quantity }
                guard quantity != 0 else { continue }
                // A missing quote must not make an address's incomplete valuation look complete.
                let value: Double? = assets.allSatisfy { $0.value != nil } ? assets.compactMap(\.value).reduce(0,+) : nil
                let position = CryptoChainPosition(wallet:wallet,quantity:quantity,value:value)
                if holdings[symbol] == nil {
                    holdings[symbol] = Self(symbol:symbol,name:assets.first?.name ?? symbol,positions:[])
                }
                holdings[symbol]?.positions.append(position)
            }
        }
        return holdings.values.sorted {
            if $0.value != $1.value { return ($0.value ?? -1) > ($1.value ?? -1) }
            return $0.symbol < $1.symbol
        }
    }
}
