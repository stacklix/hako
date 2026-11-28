import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HakoCredentialValidationHTTP {
    struct Response {
        let status: Int
        let body: [String: Any]
    }
    typealias Send = (URLRequest, [String: String], HakoLogSource) async throws -> Response

    static func send(_ request: URLRequest, _ credentials: [String: String], _ source: HakoLogSource) async throws -> Response {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await MarketAPIRequestContext.$reason.withValue("验证 API 密钥") {
            try await HTTPTransport.data(for: request, source: source,
                secrets: Array(credentials.values), logBody: false, logErrorBody: true)
        }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(status: response.statusCode, body: body)
    }

    static func failure(_ response: Response) -> HakoCredentialValidationResult? {
        switch response.status {
        case 200..<300: nil
        case 401: .init(status: .invalidCredentials, message: "服务商拒绝了鉴权，请检查密钥是否有效。")
        case 403: .init(status: .permissionDenied, message: "服务商拒绝访问，请检查接口权限、IP 白名单或地区限制。")
        case 418, 429: .init(status: .rateLimited, message: "服务商限制了请求，请稍后重试。")
        case 451: .init(status: .unavailable, message: "服务商因地区或合规限制拒绝当前网络出口（HTTP 451），尚不能确认密钥是否有效。请检查当前网络及代理出口。")
        default: .init(status: .unavailable, message: "验证接口未完成请求（HTTP \(response.status)），请稍后重试。")
        }
    }
}
