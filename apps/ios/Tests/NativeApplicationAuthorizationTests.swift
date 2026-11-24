import Foundation
import Combine

@MainActor private final class NativeAuthFake: AuthenticatedServerAccess {
    let publisher = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { publisher.eraseToAnyPublisher() }
    var serverURL = "https://hako.example.com"
    var username = "owner"
    var authenticated = true
    var hasSavedSession = true
    var logoutPending = false
    var busy = false
    var message: String?
    var requestContext = "first-account-session"
    var details: [String: Any] = [:]
    var calls: [(String, String, [String: Any]?)] = []
    var requireConsent = false
    var changeContextOnRead = false
    func watchLoginPrompts(_ receive: @escaping @MainActor (Data) throws -> Void) async throws { }
    func openWebSocket(_ path: String, logSource: HakoLogSource) async throws -> (URLSessionWebSocketTask, Data) { throw URLError(.unsupportedURL) }
    func restore() async { }
    func send(_ path: String, method: String, body: [String: Any]?, logSource: HakoLogSource) async throws -> Data {
        calls.append((path, method, body))
        if method == "GET" {
            if changeContextOnRead { requestContext = "second-account-session" }
            return try JSONSerialization.data(withJSONObject: details)
        }
        if requireConsent && body?["consent"] as? Bool != true {
            throw ServerHTTPError(status: 409, code: "native_consent_required")
        }
        return try JSONSerialization.data(withJSONObject: ["code": String(repeating: "c", count: 43),
            "expiresAt": ISO8601DateFormatter().string(from: .now.addingTimeInterval(60))])
    }
}

@main struct NativeApplicationAuthorizationTests {
    @MainActor static func main() async throws {
        let proof = try NativeApplicationLoginProof()
        let expiry = ISO8601DateFormatter().string(from: .now.addingTimeInterval(90))
        func request(issuer: String = "https://hako.example.com", origin: String = "https://trade.example.com") -> NativeApplicationLoginRequest {
            NativeApplicationLoginRequest(id: String(repeating: "a", count: 43), issuer: issuer,
                clientId: "stocktrade", applicationOrigin: origin, nonce: String(repeating: "b", count: 43), expiresAt: expiry)
        }
        func configuredFake() -> NativeAuthFake {
            let fake = NativeAuthFake()
            fake.details = ["id": request().id, "issuer": fake.serverURL, "clientId": "stocktrade",
                "application": "Cerno", "applicationOrigin": "https://trade.example.com", "nonce": request().nonce,
                "expiresAt": expiry, "codeChallenge": proof.challenge, "codeChallengeMethod": "S256"]
            return fake
        }
        func rejected(_ fake: NativeAuthFake, _ value: NativeApplicationLoginRequest,
                      client: String = "stocktrade", origin: String = "https://trade.example.com") async {
            do {
                _ = try await NativeApplicationAuthorization(authentication: fake).authorize(value, proof: proof, expectedClientID: client, backendOrigin: origin)
                preconditionFailure("A mismatched login binding was accepted")
            } catch NativeApplicationAuthorizationError.bindingMismatch { }
            catch { preconditionFailure("Unexpected rejection: \(error)") }
        }
        precondition(NativeApplicationAuthorization.origin("https://TRADE.example.com:443/") == "https://trade.example.com")
        for value in ["http://trade.example.com", "https://user@trade.example.com", "https://trade.example.com/path", "https://trade.example.com?token=x", "", "https://"] {
            precondition(NativeApplicationAuthorization.origin(value) == nil)
        }
        let fake = configuredFake()
        let service = NativeApplicationAuthorization(authentication: fake)
        _ = try await service.authorize(request(), proof: proof, expectedClientID: "stocktrade", backendOrigin: "https://trade.example.com")
        precondition(fake.calls.count == 2 && fake.calls[1].2?["consent"] as? Bool == false)
        await rejected(configuredFake(), request(issuer: ""))
        await rejected(configuredFake(), request(issuer: "http://hako.example.com"))
        let invalidIssuer = configuredFake(); invalidIssuer.serverURL = ""
        await rejected(invalidIssuer, request(issuer: ""))
        await rejected(configuredFake(), request(), client: "another-app")
        await rejected(configuredFake(), request(origin: "https://evil.example.com"))
        await rejected(configuredFake(), request(), origin: "http://trade.example.com")
        for (field, value) in [("issuer", "https://evil.example.com"), ("applicationOrigin", "https://evil.example.com"),
                               ("clientId", "another-app"), ("codeChallenge", String(repeating: "z", count: 43)),
                               ("nonce", String(repeating: "z", count: 43))] {
            let mismatch = configuredFake(); mismatch.details[field] = value
            await rejected(mismatch, request())
            precondition(mismatch.calls.count == 1, "Invalid metadata must never be authorized")
        }
        let switched = configuredFake(); switched.changeContextOnRead = true
        do {
            _ = try await NativeApplicationAuthorization(authentication: switched).authorize(request(), proof: proof,
                expectedClientID: "stocktrade", backendOrigin: "https://trade.example.com")
            preconditionFailure("A response from the previous identity was accepted")
        } catch is CancellationError { }
        precondition(switched.calls.count == 1)
        let first = configuredFake(); first.requireConsent = true
        let firstService = NativeApplicationAuthorization(authentication: first)
        var pending: NativeApplicationConsent?
        do {
            _ = try await firstService.authorize(request(), proof: proof, expectedClientID: "stocktrade", backendOrigin: "https://trade.example.com")
            preconditionFailure("Consent request was hidden")
        } catch NativeApplicationAuthorizationError.consentRequired(let consent) { pending = consent }
        precondition(first.calls.count == 2 && first.calls[1].2?["consent"] as? Bool == false,
            "The client must not silently upgrade consent:false to true")
        precondition(pending!.isCurrent(using: first))
        _ = try await firstService.confirm(pending!)
        precondition(first.calls.count == 3 && first.calls[2].2?["consent"] as? Bool == true)
        first.requestContext = "new-session"
        precondition(!pending!.isCurrent(using: first), "Host UI must close a consent from another identity")
        do { _ = try await firstService.confirm(pending!); preconditionFailure("Stale consent survived an identity change") }
        catch is CancellationError { }
        precondition(first.calls.count == 3)
        print("Native application authorization tests passed")
    }
}
