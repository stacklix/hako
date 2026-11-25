import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct StockTradeRoutingTests {
    static func main() throws {
        let roots = ["https://example.com", "https://example.com/"]
        let bases = roots + ["https://example.com/cerno", "https://example.com/cerno/", "https://example.com/apps/cerno/"]
        let endpoints = [["meta"], ["auth", "native", "start"], ["auth", "native", "complete"], ["auth", "session"], ["selection", "latest"], ["stocks", "600519.SH", "bars"], ["alerts"]]
        for base in bases {
            let connection = try StockTradeConnection(origin: base, clientID: "app_cerno").normalized()
            let client = try StockTradeClient(connection: connection)
            precondition(connection.applicationOrigin == "https://example.com")
            for endpoint in endpoints {
                let request = try client.request(endpoint, query: [.init(name: "cursor", value: "a/b?x=y")], token: "application-token")
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let prefix = URLComponents(string: connection.origin)!.path
                precondition(components.path == prefix + "/api/v1/" + endpoint.joined(separator: "/"), "Base path must cover every endpoint")
                precondition(components.host == "example.com" && components.queryItems == [.init(name: "cursor", value: "a/b?x=y")])
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer application-token")
                for header in ["Origin", "Sec-Fetch-Site", "X-Proxy", "Cookie"] { precondition(request.value(forHTTPHeaderField: header) == nil) }
            }
        }
        let encoded = try StockTradeConnection(origin: " HTTPS://EXAMPLE.COM:443/%63erno/ ", clientID: " app ").normalized()
        precondition(encoded.origin == "https://example.com/cerno" && encoded.clientID == "app")
        let nested = try StockTradeConnection(origin: "https://example.com/apps/cerno/", clientID: "app").normalized()
        precondition(nested.applicationOrigin == "https://example.com")
        let unicode = try StockTradeConnection(origin: "https://example.com/选股/", clientID: "app").normalized()
        let canonicalUnicode = try StockTradeConnection(origin: unicode.origin, clientID: "app").normalized()
        precondition(unicode == canonicalUnicode)
        let client = try StockTradeClient(connection: nested)
        for endpoint in [["..", "auth"], ["."], ["//other.example"], ["a/b"], ["a\\b"]] {
            do { _ = try client.request(endpoint); preconditionFailure("Unsafe endpoint accepted") }
            catch StockTradeFailure.configuration { }
        }
        for bad in ["http://example.com/cerno", "https://user:secret@example.com/cerno", "https://example.com/cerno?token=secret", "https://example.com/cerno#fragment",
                    "https://example.com/../other", "https://example.com/cerno/./other", "https://example.com/%2e%2e/other", "https://example.com/cerno%2fother", "https://example.com/cerno%5cother",
                    "https://example.com/cerno/%252e%252e", "https://example.com/cerno//other", "https://example.com/cerno/%00", "https://example.com/cerno/%7f", "https://example.com/cerno/%3Ftoken", "https://example.com/cerno\\other"] {
            precondition(StockTradeConnection.httpsBaseURL(bad) == nil, "Ambiguous or unsafe base address accepted: \(bad)")
        }
        print("Cerno routing: root and nested bases, authorization origin, canonical encoding, headers and path confinement passed")
    }
}
