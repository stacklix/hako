import Foundation

@main struct ConsoleWebLoginTests {
    static func main() throws {
        let origin = "https://monitor.example.com"
        let id = String(repeating: "A", count: 43)
        var url = URLComponents()
        url.scheme = "hako"; url.host = "admin-login"
        url.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "server", value: origin), URLQueryItem(name: "request", value: id)]
        let valid = url.string!
        let parsed = try ConsoleWebLoginPayload(valid, origin: origin)
        precondition(parsed.requestId == id)
        precondition(!ConsoleWebLoginPayload.validID(id + "\n"))
        for invalid in [valid + "&request=" + id, valid + "&other=1", valid + "#fragment", valid.replacingOccurrences(of: "v=1", with: "v=2"),
                        valid.replacingOccurrences(of: "hako://", with: "https://"), valid.replacingOccurrences(of: "hako://", with: "hako://user@"), valid.replacingOccurrences(of: "admin-login?", with: "admin-login/path?"),
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
        print("PASS: Console QR parsing, origin binding, malformed requests, source IP decoding and expiration")
    }
}
