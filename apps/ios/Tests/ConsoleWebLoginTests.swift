import Foundation

@main struct ConsoleWebLoginTests {
    static func main() throws {
        let origin = "https://monitor.example.com"
        let id = String(repeating: "A", count: 43)
        var url = URLComponents()
        url.scheme = "hako"; url.host = "web-login"
        url.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "server", value: origin), URLQueryItem(name: "request", value: id)]
        let valid = url.string!
        let parsed = try ConsoleWebLoginPayload(valid, origin: origin)
        precondition(parsed.requestId == id)
        precondition(!ConsoleWebLoginPayload.validID(id + "\n"))
        let appPayload = try ConsoleWebLoginPayload(valid.replacingOccurrences(of: "v=1", with: "v=2"), origin: origin)
        precondition(appPayload.isApplication && !appPayload.isOIDC)
        let oidcPayload = try ConsoleWebLoginPayload(valid.replacingOccurrences(of: "v=1", with: "v=3"), origin: origin)
        precondition(oidcPayload.isApplication && oidcPayload.isOIDC)
        let oidcLink = valid.replacingOccurrences(of: "v=1", with: "v=3")
        precondition(ConsoleWebLoginPayload.allowsOIDCLink(oidcLink, source: URL(string: origin + "/oidc/requests/" + id), origin: origin))
        for source in [origin + "/oidc/requests/" + id + "?extra=1", "https://evil.example/oidc/requests/" + id, origin + "/admin/", origin + "/oidc/requests/" + String(repeating: "B", count: 43)] {
            precondition(!ConsoleWebLoginPayload.allowsOIDCLink(oidcLink, source: URL(string: source), origin: origin))
        }
        for invalid in [valid + "&request=" + id, valid + "&other=1", valid + "#fragment", valid.replacingOccurrences(of: "v=1", with: "v=4"),
                        valid.replacingOccurrences(of: "web-login?", with: "admin-login?"),
                        valid.replacingOccurrences(of: "hako://", with: "https://"), valid.replacingOccurrences(of: "hako://", with: "hako://user@"), valid.replacingOccurrences(of: "web-login?", with: "web-login/path?"),
                        valid.replacingOccurrences(of: "request=" + id, with: "request=../bad")] {
            do { _ = try ConsoleWebLoginPayload(invalid, origin: origin); fatalError("Unsafe QR payload accepted") }
            catch is ConsoleWebLoginError { }
        }
        do { _ = try ConsoleWebLoginPayload(valid, origin: "https://other.example.com"); fatalError("Cross-server QR accepted") }
        catch ConsoleWebLoginError.serverMismatch { }
        do { _ = try ConsoleWebLoginPayload(valid, origin: "http://monitor.example.com"); fatalError("HTTP origin accepted") }
        catch ConsoleWebLoginError.serverMismatch { }
        let future = ISO8601DateFormatter().string(from: .now.addingTimeInterval(80))
        let request = ConsoleWebLoginRequest(id: id, origin: origin, confirmationCode: "123456", browser: "Safari", requestedAt: "", expiresAt: future, nonce: id)
        try request.validate(origin: origin, requestId: id)
        do { try request.validate(origin: origin, requestId: id, applicationRequest: true); fatalError("Missing application details accepted") }
        catch ConsoleWebLoginError.invalidRequest { }
        var appRequest = request
        appRequest.application = "iLinker"; appRequest.applicationOrigin = "https://notify.example.com"; appRequest.purpose = "login"
        try appRequest.validate(origin: origin, requestId: id, applicationRequest: true)
        var oidc = appRequest; oidc.purpose = "oidc"; oidc.scopes = "openid profile"
        try oidc.validate(origin: origin, requestId: id, applicationRequest: true, oidcRequest: true)
        do { try oidc.validate(origin: origin, requestId: id, oidcRequest: false); fatalError("OIDC request substitution accepted") }
        catch ConsoleWebLoginError.invalidRequest { }
        oidc.scopes = "openid email"
        do { try oidc.validate(origin: origin, requestId: id); fatalError("Unsupported identity scope accepted") }
        catch ConsoleWebLoginError.invalidRequest { }
        appRequest.applicationOrigin = "http://unsafe.example.com"
        do { try appRequest.validate(origin: origin, requestId: id); fatalError("Unsafe application origin accepted") }
        catch ConsoleWebLoginError.invalidRequest { }
        for target in ["http://192.168.0.2:8001", "http://10.0.0.2", "http://172.16.0.1:3000", "http://172.31.255.254", "http://169.254.1.2", "http://localhost:8001", "http://nas.local:8001", "http://127.0.0.1", "http://[::1]:8001", "http://[fd12::2]:8001", "http://[fe80::1]", "http://[::ffff:192.168.0.2]:8001"] {
            appRequest.applicationOrigin = target
            try appRequest.validate(origin: origin, requestId: id, applicationRequest: true)
        }
        for target in ["http://8.8.8.8", "http://172.32.0.1", "http://[2001:4860::1]", "http://0.0.0.0", "http://192.168.0.2/path", "http://user@192.168.0.2", "http://192.168.0.2?", "http://192.168.0.2#", "http://192.168.0.2:0", "http://192.168.0.2:65536", "ftp://192.168.0.2"] {
            precondition(!ConsoleWebLoginRequest.validApplicationOrigin(target), "Invalid application origin accepted")
        }
        var fields: [String: String] = ["id": id, "origin": origin, "confirmationCode": "123456", "browser": "Chrome",
                                      "requestedAt": "", "expiresAt": future, "nonce": id, "clientIP": "2001:db8::12"]
        let withIP = try JSONDecoder().decode(ConsoleWebLoginRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        precondition(withIP.clientIP == "2001:db8::12")
        try withIP.validate(origin: origin, requestId: id)
        fields.removeValue(forKey: "clientIP")
        let withoutIP = try JSONDecoder().decode(ConsoleWebLoginRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        precondition(withoutIP.clientIP == nil)
        let expired = ConsoleWebLoginRequest(id: id, origin: origin, confirmationCode: "123456", browser: "Safari", requestedAt: "", expiresAt: "2000-01-01T00:00:00Z", nonce: id)
        do { try expired.validate(origin: origin, requestId: id); fatalError("Expired approval accepted") }
        catch ConsoleWebLoginError.expired { }
        let prompt = ConsoleLoginPrompt(id: id, origin: origin, application: "Example", applicationOrigin: "https://client.example", scopes: "openid profile", browser: "Chrome", clientIP: "198.51.100.1", requestedAt: "", expiresAt: future, nonce: id)
        try prompt.validate(origin: origin)
        try ConsoleLoginPromptList(issuer: origin, requests: [prompt]).validate(origin: origin)
        let entered = prompt.confirmationRequest(code: "123456")
        precondition(entered.confirmationCode == "123456" && entered.purpose == "oidc")
        for code in ["", "12345", "1234567", "１２３４５６", "12345\n", "abcdef"] { precondition(!ConsoleLoginPrompt.validCode(code)) }
        precondition(ConsoleLoginPrompt.validCode("000000"))
        var promptFields: [String: String] = ["id": id, "origin": origin, "application": "", "applicationOrigin": "", "purpose": "", "scopes": "", "browser": "Safari", "clientIP": "127.0.0.1", "requestedAt": "", "expiresAt": future, "nonce": id]
        let adminPrompt = try JSONDecoder().decode(ConsoleLoginPrompt.self, from: JSONSerialization.data(withJSONObject: promptFields))
        try adminPrompt.validate(origin: origin)
        precondition(adminPrompt.title == "Hako 管理控制台" && !adminPrompt.isApplication)
        for purpose in ["login", "bind"] {
            promptFields["purpose"] = purpose; promptFields["application"] = "Example"; promptFields["applicationOrigin"] = "https://client.example"
            let scanPrompt = try JSONDecoder().decode(ConsoleLoginPrompt.self, from: JSONSerialization.data(withJSONObject: promptFields))
            try scanPrompt.validate(origin: origin)
            precondition(scanPrompt.effectivePurpose == purpose && scanPrompt.isApplication)
        }
        promptFields["scopes"] = "openid profile"
        let mixedPrompt = try JSONDecoder().decode(ConsoleLoginPrompt.self, from: JSONSerialization.data(withJSONObject: promptFields))
        do { try mixedPrompt.validate(origin: origin); fatalError("Non-OIDC prompt claimed OIDC scopes") }
        catch ConsoleWebLoginError.invalidRequest { }
        do { try prompt.validate(origin: "https://other.example"); fatalError("Prompt server substitution accepted") }
        catch ConsoleWebLoginError.serverMismatch { }
        do { try ConsoleLoginPromptList(issuer: origin, requests: [prompt,prompt]).validate(origin: origin); fatalError("Duplicate prompt accepted") }
        catch ConsoleWebLoginError.invalidRequest { }
        do { try prompt.confirmationRequest(code: "12345").validate(origin: origin, requestId: id); fatalError("Malformed entered code accepted") }
        catch ConsoleWebLoginError.invalidRequest { }
        print("PASS: Console QR and foreground prompt parsing, server binding, entered codes, duplicate prompts, source IP and expiration")
    }
}
