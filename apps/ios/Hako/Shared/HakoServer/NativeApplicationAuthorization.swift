import Foundation
import CryptoKit
import Security

/// The verifier is generated on the phone and submitted only to the configured
/// application backend. It is never an application Secret or Console token.
struct NativeApplicationLoginProof: Sendable {
    let verifier: String
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeApplicationAuthorizationError.invalidResponse
        }
        verifier = Self.base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Public fields received from the application backend's native/start route.
/// The backend MUST keep redeemToken private. We verify this metadata against
/// the Hako request, rather than trusting its application name or origin.
struct NativeApplicationLoginRequest: Codable, Equatable, Sendable {
    let id: String
    let issuer: String
    let clientId: String
    let applicationOrigin: String
    let nonce: String
    let expiresAt: String
}

struct NativeApplicationConsent: Equatable, Sendable, Identifiable {
    let request: NativeApplicationLoginRequest
    let application: String
    let username: String
    fileprivate let context: String
    var id: String { request.id }

    @MainActor func isCurrent(using authentication: any AuthenticatedServerAccess) -> Bool {
        context == authentication.requestContext && authentication.authenticated && !authentication.logoutPending
    }
}

struct NativeApplicationAuthorizationCode: Decodable, Sendable {
    let code: String
    let expiresAt: String
}

enum NativeApplicationAuthorizationError: Error, LocalizedError {
    case loginRequired
    case invalidResponse
    case bindingMismatch
    case consentRequired(NativeApplicationConsent)

    var errorDescription: String? {
        switch self {
        case .loginRequired: "请先在 Hako 的“服务器与登录”中登录。"
        case .invalidResponse: "原生应用授权响应无效或已过期。"
        case .bindingMismatch: "应用、服务器或登录请求不匹配，已停止授权。"
        case .consentRequired: "首次连接或授权已撤销，请确认使用 Hako 账号登录此应用。"
        }
    }
}

/// Host-owned signing and identity remain behind AuthenticatedServerAccess.
/// Children own the direct backend request and the resulting backend session.
@MainActor final class NativeApplicationAuthorization {
    private let authentication: any AuthenticatedServerAccess
    init(authentication: (any AuthenticatedServerAccess)? = nil) {
        self.authentication = authentication ?? AuthenticatedServerService.shared
    }

    func authorize(_ request: NativeApplicationLoginRequest, proof: NativeApplicationLoginProof,
                   expectedClientID: String, backendOrigin: String) async throws -> NativeApplicationAuthorizationCode {
        let consent = try await inspect(request, proof: proof, expectedClientID: expectedClientID, backendOrigin: backendOrigin)
        return try await send(consent, explicitlyApproved: false)
    }

    /// Call only in response to the user's explicit confirmation in the host UI.
    /// A consent_required response is never automatically retried with true.
    func confirm(_ consent: NativeApplicationConsent) async throws -> NativeApplicationAuthorizationCode {
        try await send(consent, explicitlyApproved: true)
    }

    private func inspect(_ request: NativeApplicationLoginRequest, proof: NativeApplicationLoginProof,
                         expectedClientID: String, backendOrigin: String) async throws -> NativeApplicationConsent {
        guard authentication.authenticated, !authentication.logoutPending else {
            throw NativeApplicationAuthorizationError.loginRequired
        }
        let context = authentication.requestContext
        guard Self.isToken(request.id), Self.isToken(request.nonce), request.clientId == expectedClientID,
              let issuer = Self.origin(authentication.serverURL), Self.origin(request.issuer) == issuer,
              let origin = Self.origin(backendOrigin), Self.origin(request.applicationOrigin) == origin,
              Self.future(request.expiresAt) else { throw NativeApplicationAuthorizationError.bindingMismatch }
        struct Details: Decodable {
            let id, issuer, clientId, application, applicationOrigin, nonce, expiresAt: String
            let codeChallenge, codeChallengeMethod: String
        }
        let data = try await authentication.send("/api/v1/auth/native-app/requests/" + request.id,
            method: "GET", body: nil, logSource: .hako)
        try Task.checkCancellation()
        guard context == authentication.requestContext, authentication.authenticated, !authentication.logoutPending else {
            throw CancellationError()
        }
        let details = try JSONDecoder().decode(Details.self, from: data)
        guard details.id == request.id, details.clientId == expectedClientID,
              Self.origin(details.issuer) == issuer,
              Self.origin(details.applicationOrigin) == origin, details.nonce == request.nonce,
              details.expiresAt == request.expiresAt, Self.future(details.expiresAt),
              details.codeChallengeMethod == "S256", details.codeChallenge == proof.challenge,
              !details.application.isEmpty, details.application.count <= 80 else {
            throw NativeApplicationAuthorizationError.bindingMismatch
        }
        return NativeApplicationConsent(request: request, application: details.application,
            username: authentication.username, context: context)
    }

    private func send(_ consent: NativeApplicationConsent, explicitlyApproved: Bool) async throws -> NativeApplicationAuthorizationCode {
        guard consent.context == authentication.requestContext, authentication.authenticated, !authentication.logoutPending else {
            throw CancellationError()
        }
        guard Self.future(consent.request.expiresAt) else { throw NativeApplicationAuthorizationError.invalidResponse }
        let data: Data
        do {
            data = try await authentication.send("/api/v1/auth/native-app/requests/" + consent.request.id + "/authorize",
                method: "POST", body: ["nonce": consent.request.nonce, "consent": explicitlyApproved], logSource: .hako)
        } catch let error as ServerHTTPError where error.status == 409 && error.code == "native_consent_required" {
            guard consent.context == authentication.requestContext else { throw CancellationError() }
            throw NativeApplicationAuthorizationError.consentRequired(consent)
        }
        try Task.checkCancellation()
        guard consent.context == authentication.requestContext, authentication.authenticated, !authentication.logoutPending else {
            throw CancellationError()
        }
        let result = try JSONDecoder().decode(NativeApplicationAuthorizationCode.self, from: data)
        guard Self.isToken(result.code), Self.future(result.expiresAt) else {
            throw NativeApplicationAuthorizationError.invalidResponse
        }
        return result
    }

    static func origin(_ value: String) -> String? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "https://" + address + (parts.port == nil || parts.port == 443 ? "" : ":\(parts.port!)")
    }

    private static func isToken(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func future(_ value: String) -> Bool {
        ISO8601DateFormatter().date(from: value).map { $0 > .now } ?? false
    }
}
