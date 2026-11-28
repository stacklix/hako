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
    var starts = 0, completes = 0, renewals = 0
    var mode = "ok"
    var taskMode = "ok"
    var failComplete = false
    var switchDuringStart = false
    var mismatchPage = false
    var missingPublishedSnapshot = false
    var challenge = ""
    var fingerprint = ""
    var expireAccessOnce = false
    init(_ auth: StockTradeTestAuth) { self.auth = auth }
    private let identity = ["id": "account", "issuer": "https://hako.test", "subject": "subject-one", "username": "owner"]
    private func meta(_ snapshot: String = "snap") -> [String: Any] {
        ["snapshotId": snapshot, "revision": "revision", "publishedAt": "2026-11-24T16:00:00+08:00", "dataAsOf": "2026-11-23", "stale": false]
    }
    func data(_ path: [String], query: [URLQueryItem], method: String, body: Data?, token: String?) async throws -> Data {
        let endpoint = path.joined(separator: "/")
        let object: [String: Any]
        if endpoint == "meta" {
            object = ["apiVersion":"1", "timezone":"Asia/Shanghai", "auth":["configured":true,"issuer":"https://hako.test","clientId":"stocktrade","applicationOrigin":"https://trade.test","refreshSupported":true,"deviceBoundRefresh":true,"sessionAuthority":"cerno"], "features":[:]]
        } else if endpoint == "auth/native/start" {
            starts += 1
            let payload = try JSONSerialization.jsonObject(with: body!) as! [String:String]
            challenge = payload["codeChallenge"]!
            fingerprint = payload["deviceFingerprint"]!
            precondition(fingerprint.count == 64)
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
            object = ["accessToken":"own-stocktrade-token","tokenType":"Bearer","expiresAt":StockTradeTestAuth.future(3600),"deviceId":String(repeating:"a",count:32),"deviceToken":String(repeating:"d",count:64),"user":identity]
        } else if endpoint == "auth/native/refresh" {
            renewals += 1
            if mode == "unavailable" { throw StockTradeFailure.api(status:503,code:"service_unavailable",requestID:"r",retryable:true) }
            if mode == "revoked" { throw StockTradeFailure.api(status:401,code:"device_session_invalid",requestID:"r",retryable:false) }
            let payload = try JSONSerialization.jsonObject(with: body!) as! [String:String]
            precondition(payload["deviceFingerprint"] == fingerprint && payload["deviceToken"] == String(repeating:"d",count:64))
            precondition(token == nil && auth.authorizeBodies.count >= 1)
            object = ["accessToken":"own-stocktrade-token","tokenType":"Bearer","expiresAt":StockTradeTestAuth.future(3600),"deviceId":String(repeating:"a",count:32),"deviceToken":String(repeating:"d",count:64),"user":identity]
        } else if endpoint == "auth/native/logout" {
            if mode == "unavailable" { throw StockTradeFailure.api(status:503,code:"service_unavailable",requestID:"r",retryable:true) }
            precondition(token == nil)
            object = ["ok":true]
        } else {
            precondition(token == "own-stocktrade-token", "Only the application's token may reach its API")
            if endpoint == "auth/session" && method == "GET" && expireAccessOnce {
                expireAccessOnce = false
                throw StockTradeFailure.api(status:401,code:"session_expired",requestID:"r",retryable:false)
            }
            if mode == "unavailable" { throw StockTradeFailure.api(status:503,code:"hako_unavailable",requestID:"r",retryable:true) }
            if mode == "revoked" { throw StockTradeFailure.api(status:401,code:"hako_authorization_invalid",requestID:"r",retryable:false) }
            if endpoint == "tasks" {
                if taskMode == "cancelled-caller" {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.cancelled)
                }
                if taskMode == "transport-cancel" { throw URLError(.cancelled) }
                if taskMode == "offline" { throw URLError(.notConnectedToInternet) }
                object = ["items": [], "nextCursor": NSNull(), "workerOnline": true]
            } else if endpoint == "auth/session" { object = method == "DELETE" ? ["ok":true] : ["user":identity] }
            else if endpoint == "runs/latest" {
                if missingPublishedSnapshot { throw StockTradeFailure.api(status: 404, code: "snapshot_unavailable", requestID: "r", retryable: false) }
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
        precondition(store.entryState == .loading, "The view must wait for its initial authorization attempt")
        auth.requireConsent = true
        await store.login()
        precondition(store.session == nil && store.consent != nil && api.completes == 0)
        precondition(store.entryState == .login, "A settled consent request must not leave startup loading active")
        precondition(auth.authorizeBodies == [false], "Consent must not be silently upgraded")
        await store.activate()
        precondition(api.starts == 1, "An existing consent sheet must not be replaced by another activation")
        try await store.confirmConsent()
        precondition(auth.authorizeBodies == [false,true] && api.completes == 1)
        precondition(store.session?.user.subject == "subject-one" && store.rows.count == 1)
        api.taskMode = "cancelled-caller"
        let cancelledRefresh = Task { @MainActor in await store.refreshWorkflows() }
        await cancelledRefresh.value
        precondition(store.workflowError == nil && store.session != nil && store.rows.count == 1,
                     "Lifecycle cancellation must not show a warning or discard the session/results")
        api.taskMode = "transport-cancel"
        await store.refreshWorkflows()
        precondition(store.workflowError == StockTradeFailure.requestInterrupted.localizedDescription,
                     "Unexplained transport cancellation must remain visible in Chinese")
        api.taskMode = "offline"
        await store.refreshWorkflows()
        precondition(store.workflowError != nil && store.session != nil, "Network errors must not be swallowed")
        api.taskMode = "ok"
        await store.refreshWorkflows()
        precondition(store.workflowError == nil && store.workflowOnline, "A later refresh must recover after cancellation")
        precondition(vault.values.count == 2)
        store.toggleFavorite(store.rows[0]); precondition(store.favorites.count == 1)
        let sessionKey = vault.values.keys.first { $0.hasPrefix("session.v2.") }!
        var expired = try JSONSerialization.jsonObject(with: vault.values[sessionKey]!) as! [String:Any]
        expired["expiresAt"] = StockTradeTestAuth.future(-1)
        vault.values[sessionKey] = try JSONSerialization.data(withJSONObject: expired)
        let approvals = auth.authorizeBodies.count
        auth.authenticated = false
        let renewed = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        await renewed.activate()
        precondition(renewed.session?.valid == true && api.renewals == 1 && api.starts == 1)
        precondition(auth.authorizeBodies.count == approvals, "Device renewal must not contact Hako, even after Console logout")
        api.expireAccessOnce = true
        let expiredAccess = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        await expiredAccess.activate()
        precondition(expiredAccess.session?.valid == true && api.renewals == 2 && api.starts == 1, "Server-side access expiry must use device renewal, including restore")
        precondition(auth.authorizeBodies.count == approvals)
        auth.authenticated = true
        let restored = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        precondition(restored.entryState == .loading, "Stored credentials are not yet read on the first view frame")
        await restored.activate()
        precondition(restored.entryState == .content, "Restoration must settle directly on its loaded result")
        precondition(restored.session != nil && restored.favorites.count == 1 && api.starts == 1)
        let interruptedEntry = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        let cancelledEntry = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await interruptedEntry.activate()
        }
        await cancelledEntry.value
        precondition(interruptedEntry.resultsState == .loading, "An interrupted initial read is still unresolved, not a first-screening prompt")
        await interruptedEntry.activate()
        precondition(interruptedEntry.resultsState == .loaded, "Re-entering after cancellation must retry the normal read")
        api.missingPublishedSnapshot = true
        let noPublication = StockTradeStore(defaults:defaults,secrets:vault,authentication:auth,clientFactory:{ _ in api })
        await noPublication.activate()
        precondition(noPublication.resultsState == .missing, "Only snapshot_unavailable confirms that first screening is appropriate")
        api.missingPublishedSnapshot = false
        await noPublication.activate(force: true)
        precondition(noPublication.resultsState == .loaded && api.starts == 1, "A normal retry reads published data without launching another selection or login")
        api.mode = "unavailable"
        await restored.refresh()
        precondition(restored.session != nil && restored.rows.count == 1, "503 must retain the account and previous snapshot")
        await restored.logout()
        precondition(restored.session != nil, "An uncertain logout must remain retryable")
        api.mode = "revoked"
        await restored.refresh()
        precondition(restored.session == nil && restored.rows.isEmpty && restored.favorites.isEmpty && vault.values.count == 1)
        api.mode = "ok"; auth.requireConsent = false
        await store.logout()
        precondition(store.session == nil)
        precondition(store.entryState == .login, "Explicit logout must not show a startup loader")
        await store.login()
        precondition(store.session != nil)
        api.mismatchPage = true
        await store.refresh()
        precondition(store.error != nil && store.rows.count == 1, "Never replace data with another snapshot's page")
        auth.requestContext = "console-two"
        store.synchronizeContext()
        precondition(store.session != nil, "A Console session change must not revoke Cerno's independently maintained session")
        await store.logout()
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

        let pathSuite = "stocktrade.paths." + UUID().uuidString
        let pathDefaults = UserDefaults(suiteName: pathSuite)!
        defer { pathDefaults.removePersistentDomain(forName: pathSuite) }
        let pathAuth = StockTradeTestAuth(), pathVault = StockTradeTestSecrets()
        let pathAPI = StockTradeTestBackend(pathAuth)
        let prefixed = StockTradeStore(defaults: pathDefaults, secrets: pathVault, authentication: pathAuth, clientFactory: { _ in pathAPI })
        try prefixed.configure(.init(origin: "https://trade.test/cerno/", clientID: "stocktrade"))
        await prefixed.login()
        precondition(prefixed.session != nil && prefixed.error == nil, "An application base path must still authorize against its root origin")
        prefixed.toggleFavorite(prefixed.rows[0])
        let firstPreference = prefixed.preferenceKey
        let firstKeys = Set(pathVault.values.keys)
        let starts = pathAPI.starts
        try prefixed.configure(.init(origin: "https://trade.test/other/", clientID: "stocktrade"))
        precondition(prefixed.session == nil && prefixed.favorites.isEmpty)
        await prefixed.login()
        precondition(prefixed.session != nil && pathAPI.starts == starts + 1, "Another path must not restore the first application's token")
        precondition(prefixed.favorites.isEmpty && prefixed.preferenceKey != firstPreference)
        precondition(pathVault.values.count == 3 && firstKeys.isSubset(of: Set(pathVault.values.keys)))
        try prefixed.configure(.init(origin: "https://trade.test/cerno", clientID: "stocktrade"))
        await prefixed.login()
        precondition(pathAPI.starts == starts + 1 && prefixed.favorites.count == 1, "Returning to the same normalized path restores only its own account data")
        print("Cerno local sessions, device renewal, consent, revocation, paging and direct transport tests passed")
    }
}
