import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct HTTPProxyTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        for target in ["127.0.0.1:80", "192.168.1.4:65535", "[fd00::1]:8080"] {
            check(HakoHTTPProxy.validTarget(target), "Valid target rejected: \(target)")
        }
        for target in ["", "localhost:80", "http://127.0.0.1:80", "127.0.0.1", "127.0.0.1:0", "127.0.0.1:65536",
                       "127.0.0.1:80/path", "127.0.0.1:80?x", "user@127.0.0.1:80", "999.1.1.1:80", " 127.0.0.1:80", "::1:80"] {
            check(!HakoHTTPProxy.validTarget(target), "Invalid target accepted: \(target)")
        }
        var request = URLRequest(url: URL(string: "https://original.example/a%2Fb?q=hello%20world")!)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 255, 128, 10])
        request.setValue("127.0.0.1:8080", forHTTPHeaderField: "x-proxy")
        request.setValue("Bearer target-secret", forHTTPHeaderField: "Authorization")
        let params = try HakoHTTPProxy.parameters(request)
        check(params["url"] as? String == request.url?.absoluteString, "URL path/query changed")
        check(params["body"] as? String == HakoHTTPProxy.encodeBody(request.httpBody!), "Binary body corrupted")
        check(params["timeoutMs"] as? Int == 8000, "Timeout not bounded")
        let headers = params["headers"] as! [String: String]
        check(!headers.keys.contains { $0.lowercased() == "x-proxy" }, "Control header forwarded")
        check(headers["Authorization"] == "Bearer target-secret", "Target auth lost")
        request.httpBody = nil
        request.httpBodyStream = InputStream(data: Data([0, 255, 128, 10]))
        check(try HakoHTTPProxy.parameters(request)["body"] as? String == params["body"] as? String, "Stream body corrupted")
        request.httpBodyStream = nil
        request.httpBody = Data(repeating: 1, count: HakoHTTPProxy.requestLimit + 1)
        do { _ = try HakoHTTPProxy.parameters(request); preconditionFailure("Oversized upload accepted") } catch { }
        let url = URL(string: "https://original.example/a")!
        let response = HakoHTTPProxy.Response(status: 404, headers: ["Content-Type": "application/octet-stream"], body: "AP-A")
        let (data, http) = try response.unpack(for: url)
        check(data == Data([0, 255, 128]) && http.statusCode == 404 && http.url == url, "Response not preserved")
        do { _ = try HakoHTTPProxy.Response(status: 200, headers: [:], body: "bad!").unpack(for: url); preconditionFailure("Invalid Base64 accepted") } catch { }
        check(HakoHTTPProxy.settingsKey(server: "https://a", account: "b") != HakoHTTPProxy.settingsKey(server: "https://b", account: "a"), "Configuration scope collision")
        print("PASS: proxy routing, binary and stream upload, size limits, response status and scoped settings")
    }
}
