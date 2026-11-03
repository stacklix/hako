import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol HeadplaneAccess: Sendable {
    func read(_ resource: HeadplaneResource) async throws -> HeadplaneJSON
    func submit(_ resource: HeadplaneResource, fields: [String: String]) async throws -> HeadplaneJSON
}

actor HeadplaneClient: HeadplaneAccess {
    let connection: HeadplaneConnection
    private let session: URLSession
    private let ownsSession: Bool
    private var cookies: [HTTPCookie] = []
    private var authentication: Task<[HTTPCookie], Error>?

    init(connection: HeadplaneConnection, session: URLSession? = nil) throws {
        self.connection = try connection.normalized()
        self.session = session ?? HTTPTransport.makeSession(requestTimeout: 30, resourceTimeout: 45)
        ownsSession = session == nil
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }

    private func authenticate() async throws {
        if cookies.contains(where: { $0.expiresDate == nil || $0.expiresDate! > .now }) { return }
        if let authentication { cookies = try await authentication.value; return }
        let connection = self.connection, session = self.session
        let task = Task<[HTTPCookie], Error> {
            var request = try connection.request(.login, data: false, method: "POST")
            request.httpBody = Self.form(["api_key": connection.apiKey])
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, let url = request.url,
                  [302, 303].contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
                  let destination = URL(string: location, relativeTo: url)?.absoluteURL,
                  Self.sameOrigin(destination, url), !destination.path.contains("login"), !destination.path.contains("oidc") else {
                throw HeadplaneFailure(message: "登录失败，请检查 Headplane 地址、API Key 和 API Key 登录是否已启用。", status: 401)
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { if let k = $1.key as? String { $0[k] = String(describing: $1.value) } }
            let accepted = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter {
                $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == url.host?.lowercased()
                && (!$0.isSecure || url.scheme == "https")
                && ($0.expiresDate == nil || $0.expiresDate! > .now)
            }
            guard !accepted.isEmpty else { throw HeadplaneFailure(message: "Headplane 未返回有效登录会话，请检查 Cookie 和 HTTPS 配置。") }
            return accepted
        }
        authentication = task
        do { cookies = try await task.value; authentication = nil }
        catch { authentication = nil; throw error }
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
        && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }

    func read(_ resource: HeadplaneResource) async throws -> HeadplaneJSON {
        do { return try await call(resource, fields: nil) }
        catch let failure as HeadplaneFailure where failure.status == 401 {
            cookies = []
            return try await call(resource, fields: nil) // safe reads retry once; mutations never replay
        }
    }

    func submit(_ resource: HeadplaneResource, fields: [String: String]) async throws -> HeadplaneJSON {
        try await call(resource, fields: fields)
    }

    private func call(_ resource: HeadplaneResource, fields: [String: String]?) async throws -> HeadplaneJSON {
        try Task.checkCancellation()
        try await authenticate()
        try Task.checkCancellation()
        var request = try connection.request(resource, method: fields == nil ? "GET" : "POST")
        if let fields {
            if resource == .machines {
                var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "index", value: "")]; request.url = parts.url
            }
            request.httpBody = Self.form(fields)
        }
        let valid = cookies.filter { cookie in
            let path = request.url!.path
            return (cookie.expiresDate == nil || cookie.expiresDate! > .now)
                && (path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
        }
        request.setValue(HTTPCookie.requestHeaderFields(with: valid)["Cookie"], forHTTPHeaderField: "Cookie")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if fields == nil && (Task.isCancelled || (error as? URLError)?.code == .cancelled) { throw CancellationError() }
            throw HeadplaneFailure(message: fields == nil ? "无法连接 Headplane，请检查网络后刷新。" : "操作结果尚未确认，请先刷新远端状态，勿重复提交。", outcomeUnknown: fields != nil)
        }
        guard let http = response as? HTTPURLResponse else { throw HeadplaneFailure.incompatible }
        HakoLog.record(.headplane, "Headplane 请求完成", detail: "\(request.httpMethod ?? "GET") \(resource.path) · \(http.statusCode)")
        if http.statusCode == 401 { cookies = []; throw HeadplaneFailure(message: "会话失效，请重新连接。", status: 401) }
        if [301, 302, 303, 307, 308].contains(http.statusCode) || http.value(forHTTPHeaderField: "X-Remix-Redirect") != nil {
            cookies = []
            throw HeadplaneFailure(message: "Headplane 要求重新登录或重定向，请核对管理地址。", status: 401)
        }
        let root: HeadplaneJSON
        do { root = try HeadplaneStream.decode(data) }
        catch {
            throw HeadplaneFailure(message: fields == nil ? "无法读取 Headplane 数据（HTTP \(http.statusCode)），请核对管理地址及版本。" : "后台响应无法识别，操作可能已生效，请刷新核对。", status: http.statusCode, outcomeUnknown: fields != nil)
        }
        if !root["redirect"].text.isEmpty {
            if root["redirect"].text.contains("login") { cookies = []; throw HeadplaneFailure(message: "会话已失效，请重新连接。", status: 401) }
            if fields?["action_id"] == "delete", root["redirect"].text.hasSuffix("/machines") { return .object(["success": .bool(true)]) }
            throw HeadplaneFailure(message: "后台返回了意外跳转，请刷新核对。", outcomeUnknown: fields != nil)
        }
        let value: HeadplaneJSON
        do { value = try HeadplaneStream.payload(root, resource: resource, action: fields != nil) }
        catch let failure as HeadplaneFailure {
            let status = failure.status ?? http.statusCode
            // Production React Router hides the underlying loader exception.
            // Suggest configuration checks without claiming to know the server's cause.
            let message = resource == .dns && fields == nil && status >= 500 && failure.message == "Unexpected Server Error"
                ? "Headplane 无法读取 DNS（HTTP \(status)）。请检查 Headplane 网页的 DNS 页面及服务端日志。可能原因包括 Headscale 配置文件未挂载、无法读取或账号权限不足；仅配置 API Key 不足以读取 DNS。"
                : failure.message
            throw HeadplaneFailure(message: sanitized(message), status: status,
                                   outcomeUnknown: fields != nil && (failure.status == nil || http.statusCode >= 500))
        }
        // Agent loaders return their last synchronization error as status data.
        // HTTP/route errors and failed actions must still be rejected.
        let agentStatus = resource == .agent && fields == nil && value["enabled"].flag
        if http.statusCode >= 400 || value["success"] == .bool(false) || value["ok"] == .bool(false) || (!agentStatus && value.object["error"]?.string != nil) {
            let detail = value["error"].string ?? value["errors"]["form"].string ?? value["message"].string ?? value.string ?? "后台拒绝此操作，请检查权限和输入。"
            throw HeadplaneFailure(message: sanitized(detail), status: http.statusCode, outcomeUnknown: fields != nil && http.statusCode >= 500)
        }
        if fields != nil {
            guard value["success"].flag || value["ok"].flag || !value["message"].text.isEmpty || value.string == "Pre-auth key expired" else {
                throw HeadplaneFailure(message: "未能确认操作结果，请刷新核对。", outcomeUnknown: true)
            }
            if fields?["action_id"] == "add_preauthkey", value["key"].text.isEmpty {
                throw HeadplaneFailure(message: "密钥可能已创建，但未返回完整密钥。请刷新列表核对，勿重复创建。", outcomeUnknown: true)
            }
        }
        return value
    }
    private func sanitized(_ message: String) -> String {
        String(message.replacingOccurrences(of: connection.apiKey, with: "[已隐藏]").prefix(500))
    }
}
