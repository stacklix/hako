import Foundation

private final class TronMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Any))?
    static func respond(_ block: @escaping (URLRequest) throws -> (Int, Any)) {
        lock.lock(); defer { lock.unlock() }; handler = block
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let callback = Self.handler!
            Self.lock.unlock()
            let (status, object) = try callback(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct CryptoChainTests {
    static let address = "TSTVYwFDp7SBfZk7Hrz3tucwQVASyJdwC7"
    static let empty: [String: Any] = [
        "address": address, "balance": 0,
        "frozenForBandWidth": 0, "frozenForEnergy": 0,
        "delegateFrozenForBandWidth": 0, "delegateFrozenForEnergy": 0,
        "frozenForBandWidthV2": 0, "frozenForEnergyV2": 0,
        "delegatedFrozenV2BalanceForBandwidth": 0, "delegatedFrozenV2BalanceForEnergy": 0,
        "unfreezeV2": 0, "canWithdrawAmountV2": 0
    ]
    static func main() async throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        func rejects(_ account: [String: Any]) {
            do { _ = try CryptoClient.tronOwnedTRX(account); fatalError("Invalid staking data accepted") } catch {}
        }
        check(try CryptoClient.tronOwnedTRX(empty) == 0, "Zero balances are valid")
        // Mixed string and numeric sun values, both stake versions and outgoing delegations.
        var account = empty
        account.merge([
            "balanceStr": "10000001", "balance": 10_000_000,
            "frozenForBandWidth": 20_000_000, "frozenForEnergy": "30000000",
            "delegateFrozenForBandWidth": 4_000_000, "delegateFrozenForEnergy": 6_000_000,
            "frozenForBandWidthV2": "40000000", "frozenForEnergyV2": 50_000_000,
            "delegatedFrozenV2BalanceForBandwidth": 7_000_000, "delegatedFrozenV2BalanceForEnergy": "8000000",
            "unfreezeV2": 9_000_000, "canWithdrawAmountV2": "11000000",
            "totalFrozen": 60_000_000, "totalFrozenV2": 105_000_000,
            "acquiredDelegateFrozenForBandWidth": 1_000_000_000,
            "acquiredDelegateFrozenForEnergy": 1_000_000_000,
            "acquiredDelegatedFrozenV2BalanceForBandwidth": 1_000_000_000,
            "acquiredDelegatedFrozenV2BalanceForEnergy": 1_000_000_000
        ]) { _, new in new }
        check(abs(try CryptoClient.tronOwnedTRX(account) - 195.000001) < 0.0000001,
              "Count owned principal once, exclude incoming delegations, preserve sun precision")
        for field in empty.keys where field != "address" {
            var invalid = empty; invalid.removeValue(forKey: field); rejects(invalid)
            for value: Any in ["bad", "nan", NSNull(), -1] {
                invalid = empty; invalid[field] = value; rejects(invalid)
            }
        }
        // Moving the same principal through unstaking and withdrawal preserves net worth.
        for field in ["frozenForEnergyV2", "delegatedFrozenV2BalanceForEnergy", "unfreezeV2", "canWithdrawAmountV2", "balance"] {
            var state = empty; state[field] = 100_000_000
            check(try CryptoClient.tronOwnedTRX(state) == 100, "Principal stays owned throughout the staking lifecycle")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TronMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CryptoClient(session: session)
        let owned = account
        TronMockProtocol.respond { request in
            let url = request.url!
            if url.host == "api.huobi.pro" { return (200, ["tick": ["close": 0.25]]) }
            check(request.value(forHTTPHeaderField: "TRON-PRO-API-KEY") == "test-token", "Authenticate every TRONSCAN request")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            check(query.first { $0.name == "address" }?.value == address, "Query the requested account")
            if url.path == "/api/accountv2" { return (200, owned) }
            check(url.path == "/api/account/tokens", "Keep paginated token valuation")
            let start = query.first { $0.name == "start" }!.value!
            if start == "0" {
                return (200, ["total": 3, "data": [
                    ["tokenId": "_", "tokenType": "trc10", "balance": "195000001", "tokenDecimal": 6, "tokenPriceInTrx": 1],
                    ["tokenId": "usdt", "tokenType": "trc20", "balance": "2000000", "tokenDecimal": 6, "tokenPriceInTrx": 4]
                ]])
            }
            check(start == "2", "Advance through token pages")
            return (200, ["total": 3, "data": [["tokenType": "trc721"]]])
        }
        let total = try await client.tronWalletTotal(address: address, token: "test-token")
        check(abs(total - 50.75000025) < 0.0000001, "Combine staked TRX and tokens in USDT without double counting native TRX")

        // Staked-only wallets need no native token entry in the token list.
        var stakeOnly = empty; stakeOnly["frozenForEnergyV2"] = 100_000_000
        let stakeResponse = stakeOnly
        TronMockProtocol.respond { request in
            if request.url!.path == "/api/accountv2" { return (200, stakeResponse) }
            if request.url!.host == "api.huobi.pro" { return (200, ["tick": ["close": 0.25]]) }
            return (200, ["total": 0, "data": []])
        }
        check(try await client.tronWalletTotal(address: address, token: "test-token") == 25, "Include staking with zero liquid balance")

        for (status, object): (Int, [String: Any]) in [(503, [:]), (200, [:]), (200, ["address": address, "balance": 0])] {
            TronMockProtocol.respond { _ in (status, object) }
            do {
                _ = try await client.tronWalletTotal(address: address, token: "test-token")
                fatalError("Failed or incomplete account data must not yield a partial total")
            } catch {}
        }
        for failTokens in [false, true] {
            TronMockProtocol.respond { request in
                if request.url!.path == "/api/accountv2" { return (200, stakeResponse) }
                if request.url!.host == "api.huobi.pro" { return (200, ["tick": ["close": 0.25]]) }
                if failTokens { return (503, [:]) }
                return (200, ["total": 1, "data": [["tokenId": "unpriced", "balance": "1", "tokenDecimal": 0]]])
            }
            do {
                _ = try await client.tronWalletTotal(address: address, token: "test-token")
                fatalError("Token failure or missing price must not return only the staked total")
            } catch {}
        }
        print("Crypto chain: staking, ownership, units, pagination, authentication and failure checks passed")
    }
}
