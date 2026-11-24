import Foundation
import Combine
import CryptoKit

private final class StockTradeTestSecrets: SecretStorage {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws { values[account] = data }
    func delete(account: String) throws { values.removeValue(forKey: account) }
    func accounts() throws -> [String] { Array(values.keys) }
}

@MainActor private final class StockTradeTestAuth: AuthenticatedServerAccess {
    let publisher = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { publisher.eraseToAnyPublisher() }
    var serverURL = "https://hako.test"
    var username = "owner"
    var authenticated = true
    var hasSavedSession = true
    var logoutPending = false
    var busy = false
    var message: String?
    var requestContext = "console-one"
    var details: [String: Any] = [:]
    var requireConsent = false
    var authorizeBodies: [Bool] = []
    func restore() async { }
    func watchLoginPrompts(_ receive: @escaping @MainActor (Data) throws -> Void) async throws { }
    func openWebSocket(_ path: String, logSource: HakoLogSource) async throws -> (URLSessionWebSocketTask, Data) { throw URLError(.unsupportedURL) }
    func send(_ path: String, method: String, body: [String: Any]?, logSource: HakoLogSource) async throws -> Data {
        if method == "GET" { return try JSONSerialization.data(withJSONObject: details) }
        let explicit = body?["consent"] as? Bool == true
        authorizeBodies.append(explicit)
        if requireConsent && !explicit { throw ServerHTTPError(status: 409, code: "native_consent_required") }
        return try JSONSerialization.data(withJSONObject: ["code": String(repeating: "c", count: 43), "expiresAt": Self.future(60)])
    }
    static func future(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: .now.addingTimeInterval(seconds)) }
}

@MainActor private final class StockTradeTestBackend: StockTradeAccess {
    let auth: StockTradeTestAuth
    var starts = 0, completes = 0
    var mode = "ok"
    var failComplete = false
    var switchDuringStart = false
    var mismatchPage = false
    var challenge = ""
    init(_ auth: StockTradeTestAuth) { self.auth = auth }
    private let identity = ["id": "account", "issuer": "https://hako.test", "subject": "subject-one", "username": "owner"]
    private func meta(_ snapshot: String = "snap") -> [String: Any] {
        ["snapshotId": snapshot, "revision": "revision", "publishedAt": "2026-11-24T16:00:00+08:00", "dataAsOf": "2026-11-23", "stale": false]
    }
    func data(_ path: [String], query: [URLQueryItem], method: String, body: Data?, token: String?) async throws -> Data {
        let endpoint = path.joined(separator: "/")
        let object: [String: Any]
        if endpoint == "meta" {
            object = ["apiVersion":"1", "timezone":"Asia/Shanghai", "auth":["configured":true,"issuer":"https://hako.test","clientId":"stocktrade","applicationOrigin":"https://trade.test","refreshSupported":false], "features":[:]]
        } else if endpoint == "auth/native/start" {
            starts += 1
            let payload = try JSONSerialization.jsonObject(with: body!) as! [String:String]
            challenge = payload["codeChallenge"]!
            precondition(payload["codeChallengeMethod"] == "S256")
            var details: [String:Any] = ["id":String(repeating:"a",count:43),"issuer":"https://hako.test","clientId":"stocktrade","application":"StockTrade","applicationOrigin":"https://trade.test","nonce":String(repeating:"b",count:43),"expiresAt":StockTradeTestAuth.future(90),"codeChallenge":challenge,"codeChallengeMethod":"S256"]
            auth.details = details
            details["requestId"] = details.removeValue(forKey:"id"); details["loginId"] = "login-\(starts)"
            if switchDuringStart { auth.requestContext = "console-two" }
            object = details
        } else if endpoint == "auth/native/complete" {
            completes += 1
            let payload = try JSONSerialization.jsonObject(with: body!) as! [String:String]
            let computed = Data(SHA256.hash(data: Data(payload["codeVerifier"]!.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            precondition(computed == challenge)
            if failComplete { throw StockTradeFailure.api(status:409,code:"login_finished",requestID:"r",retryable:false) }
            object = ["accessToken":"own-stocktrade-token","tokenType":"Bearer","expiresAt":StockTradeTestAuth.future(3600),"user":identity]
        } else {
            precondition(token == "own-stocktrade-token", "Only the application's token may reach its API")
            if mode == "unavailable" { throw StockTradeFailure.api(status:503,code:"hako_unavailable",requestID:"r",retryable:true) }
            if mode == "revoked" { throw StockTradeFailure.api(status:401,code:"hako_authorization_invalid",requestID:"r",retryable:false) }
            if endpoint == "auth/session" { object = method == "DELETE" ? ["ok":true] : ["user":identity] }
            else if endpoint == "runs/latest" {
                object = meta().merging(["runId":"run-one","status":"complete","candidateCount":1,"reviewCount":1,"recommendationCount":1,"thresholds":[:]]) { _, new in new }
            } else {
                precondition(endpoint == "runs/run-one/recommendations")
                precondition(query.contains { $0.name == "snapshotId" && $0.value == "snap" })
                object = meta(mismatchPage ? "other" : "snap").merging(["items":[["symbol":"600519.SH","name":"测试股票","rank_score":90]],"total":1,"nextCursor":NSNull()]) { _, new in new }
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@main struct StockTradeSessionTests {
    @MainActor static func main() async throws {
        let suite = "stocktrade.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let auth = StockTradeTestAuth(), vault = StockTradeTestSecrets()
        // Keep every fake independently scoped; no production endpoint, Keychain or secret is used.
        let api = StockTradeTestBackend(auth)
        let store = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        try store.configure(.init(origin:"https://trade.test",clientID:"stocktrade"))
        auth.requireConsent = true
        await store.login()
        precondition(store.session == nil && store.consent != nil && api.completes == 0)
        precondition(auth.authorizeBodies == [false], "Consent must not be silently upgraded")
        await store.activate()
        precondition(api.starts == 1, "An existing consent sheet must not be replaced by another activation")
        try await store.confirmConsent()
        precondition(auth.authorizeBodies == [false,true] && api.completes == 1)
        precondition(store.session?.user.subject == "subject-one" && store.rows.count == 1)
        precondition(vault.values.count == 1)
        store.toggleFavorite(store.rows[0]); precondition(store.favorites.count == 1)
        let restored = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        await restored.activate()
        precondition(restored.session != nil && restored.favorites.count == 1 && api.starts == 1)
        api.mode = "unavailable"
        await restored.refresh()
        precondition(restored.session != nil && restored.rows.count == 1, "503 must retain the account and previous snapshot")
        await restored.logout()
        precondition(restored.session != nil, "An uncertain logout must remain retryable")
        api.mode = "revoked"
        await restored.refresh()
        precondition(restored.session == nil && restored.rows.isEmpty && restored.favorites.isEmpty && vault.values.isEmpty)
        api.mode = "ok"; auth.requireConsent = false
        await store.logout()
        precondition(store.session == nil)
        await store.login()
        precondition(store.session != nil)
        api.mismatchPage = true
        await store.refresh()
        precondition(store.error != nil && store.rows.count == 1, "Never replace data with another snapshot's page")
        auth.requestContext = "console-two"
        store.synchronizeContext()
        precondition(store.session == nil && store.rows.isEmpty && store.favorites.isEmpty)
        api.mismatchPage = false; api.switchDuringStart = true
        auth.requestContext = "console-three"; store.synchronizeContext()
        let before = api.completes
        await store.login()
        precondition(store.session == nil && api.completes == before, "Identity changed while start was in flight")
        api.switchDuringStart = false; api.failComplete = true; auth.requireConsent = true
        store.synchronizeContext(); await store.login()
        do { try await store.confirmConsent(); preconditionFailure("Expected consumed exchange") } catch { }
        let count = api.completes
        do { try await store.confirmConsent(); preconditionFailure("Consumed context must not replay") } catch { }
        precondition(api.completes == count)
        let client = try StockTradeClient(connection:.init(origin:"https://trade.test",clientID:"stocktrade"))
        let request = try client.request(["auth","native","complete"],method:"POST",body:Data("{}".utf8),token:"own-token")
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer own-token")
        for name in ["Origin","Sec-Fetch-Site","X-Proxy","Cookie"] { precondition(request.value(forHTTPHeaderField:name) == nil) }
        precondition(request.url?.absoluteString == "https://trade.test/api/v1/auth/native/complete")
        print("StockTrade native session, consent, revocation, paging and direct transport tests passed")
    }
}
