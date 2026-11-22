import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HakoHTTPProxy {
    static let command = "action.network.http.proxy"
    static let requestLimit = 512 * 1024
    static let responseLimit = 8 * 1024 * 1024

    static func settingsKey(server: String, account: String) -> String {
        "hako.httpProxy.agent." + (try! JSONEncoder().encode([server, account])).base64EncodedString()
    }

    static func parameters(_ request: URLRequest) throws -> [String: Any] {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let target = request.value(forHTTPHeaderField: "X-Proxy"), validTarget(target) else {
            throw failure("X-Proxy 必须为 IP:端口，IPv6 使用 [IP]:端口。")
        }
        var body = request.httpBody ?? Data()
        // URLSession may expose an ordinary POST body as a stream to URLProtocol.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? failure("无法读取代理请求体。") }
                if count == 0 { break }
                guard body.count + count <= requestLimit else { throw failure("代理请求体不能超过 512 KiB。") }
                body.append(buffer, count: count)
            }
        }
        guard body.count <= requestLimit else { throw failure("代理请求体不能超过 512 KiB。") }
        let method = request.httpMethod ?? "GET"
        guard !["CONNECT", "TRACE"].contains(method.uppercased()) else { throw failure("代理不支持 CONNECT 或 TRACE。") }
        let headers = (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != "x-proxy" }
        return ["url": url.absoluteString, "target": target, "method": method,
                "headers": headers, "body": encodeBody(body),
                "timeoutMs": Int(max(1, min(8000, request.timeoutInterval * 1000)))]
    }

    static func validTarget(_ target: String) -> Bool {
        guard !target.isEmpty, target == target.trimmingCharacters(in: .whitespacesAndNewlines),
              let separator = target.lastIndex(of: ":") else { return false }
        let host = String(target[..<separator])
        let portText = target[target.index(after: separator)...]
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText), (1...65535).contains(port) else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            // The Agent performs the authoritative IPv6 parse before any network operation.
            let address = host.dropFirst().dropLast()
            return address.contains(":") && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) && Int($0).map { (0...255).contains($0) } == true
        }
    }

    struct Reply: Decodable {
        let result: Response?
        let error: Failure?
        struct Failure: Decodable { let code: String; let message: String }
    }
    struct Response: Decodable {
        let status: Int
        let headers: [String: String]
        let body: String

        func unpack(for url: URL) throws -> (Data, HTTPURLResponse) {
            guard (200...599).contains(status), body.utf8.count <= (responseLimit + 2) / 3 * 4,
                  let data = Data(base64Encoded: body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")), data.count <= responseLimit,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw HakoHTTPProxy.failure("Agent 返回的代理响应无效或超过 8 MiB。")
            }
            return (data, response)
        }
    }
    static func encodeBody(_ body: Data) -> String {
        body.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "HakoHTTPProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
