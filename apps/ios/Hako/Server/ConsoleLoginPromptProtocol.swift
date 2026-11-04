import Foundation

struct ConsoleLoginPrompt: Decodable, Identifiable {
    let id: String
    let origin: String
    let application: String
    let applicationOrigin: String
    let scopes: String
    let browser: String
    let clientIP: String
    let requestedAt: String
    let expiresAt: String
    let nonce: String
    var expiry: Date? { ISO8601DateFormatter().date(from: expiresAt) }

    static func validCode(_ value: String) -> Bool {
        value.range(of: "\\A[0-9]{6}\\z", options: .regularExpression) != nil
    }

    func validate(origin expected: String) throws {
        guard !application.isEmpty, application.utf8.count <= 80, browser.count <= 256, clientIP.count <= 128 else {
            throw ConsoleWebLoginError.invalidRequest
        }
        // Reuse the existing OIDC metadata validator; this placeholder is never
        // displayed or submitted. The discovery response contains no code.
        try confirmationRequest(code: "000000").validate(origin: expected, requestId: id, applicationRequest: true, oidcRequest: true)
    }

    func confirmationRequest(code: String) -> ConsoleWebLoginRequest {
        ConsoleWebLoginRequest(id: id, origin: origin, confirmationCode: code, browser: browser,
            clientIP: clientIP, requestedAt: requestedAt, expiresAt: expiresAt, nonce: nonce,
            application: application, applicationOrigin: applicationOrigin, purpose: "oidc", scopes: scopes)
    }
}

struct ConsoleLoginPromptList: Decodable {
    let issuer: String
    let requests: [ConsoleLoginPrompt]
    func validate(origin: String) throws {
        guard issuer == origin else { throw ConsoleWebLoginError.serverMismatch }
        guard requests.count <= 32, Set(requests.map(\.id)).count == requests.count else { throw ConsoleWebLoginError.invalidRequest }
        for request in requests { try request.validate(origin: origin) }
    }
}
