import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol StockTradeAccess: Sendable {
    func data(_ path: [String], query: [URLQueryItem], method: String, body: Data?, token: String?) async throws -> Data
}

final class StockTradeClient: StockTradeAccess, @unchecked Sendable {
    let connection: StockTradeConnection
    private let session: URLSession
    private let ownsSession: Bool
    init(connection: StockTradeConnection, session: URLSession? = nil) throws {
        self.connection = try connection.normalized()
        ownsSession = session == nil
        self.session = session ?? HTTPTransport.makeSession(requestTimeout: 25, resourceTimeout: 60, useSystemProxy: false)
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    func request(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                 token: String? = nil) throws -> URLRequest {
        guard path.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != "." && $0 != ".." }),
              var parts = URLComponents(string: connection.origin) else { throw StockTradeFailure.configuration }
        // Each segment is separately encoded; callers cannot inject another origin or query.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        parts.percentEncodedPath += "/api/v1/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw StockTradeFailure.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        // No X-Proxy, Origin, Sec-Fetch-Site, Console credentials or cookies.
        return request
    }

    func data(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
              token: String? = nil) async throws -> Data {
        let request = try request(path, query: query, method: method, body: body, token: token)
        let (data, response) = try await HTTPTransport.data(for: request, using: session, source: .stockTrade,
            secrets: [token].compactMap { $0 }, logBody: false, marketUsage: nil, marketGate: nil)
        guard let response = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else {
            throw StockTradeFailure.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let code, message, requestId: String; let retryable: Bool }
            guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else { throw StockTradeFailure.invalidResponse }
            // Do not display an upstream-controlled message which may contain secrets.
            throw StockTradeFailure.api(status: response.statusCode, code: String(failure.code.prefix(80)),
                requestID: String(failure.requestId.prefix(80)), retryable: failure.retryable)
        }
        return data
    }
}
