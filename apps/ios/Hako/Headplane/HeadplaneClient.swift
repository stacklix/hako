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
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                Self.logFailure(request, error: error, secrets: [connection.apiKey])
                throw error
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                Self.logFailure(request, response: http, data: data, secrets: [connection.apiKey])
            }
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
        if resource.plainJSON { return try await readJSON(resource) }
        do { return try await call(resource, fields: nil) }
        catch let failure as HeadplaneFailure where failure.status == 401 {
            cookies = []
            return try await call(resource, fields: nil) // safe reads retry once; mutations never replay
        }
    }

    func submit(_ resource: HeadplaneResource, fields: [String: String]) async throws -> HeadplaneJSON {
        guard !resource.plainJSON else { throw HeadplaneFailure(message: "服务器诊断接口仅支持读取。") }
        return try await call(resource, fields: fields)
    }

    private func readJSON(_ resource: HeadplaneResource) async throws -> HeadplaneJSON {
        try Task.checkCancellation()
        var request = try connection.request(resource)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if resource == .serverInfo {
            guard let secret = connection.infoSecret, !secret.isEmpty else {
                throw HeadplaneFailure(message: "请在连接设置中填写版本查询密钥（server.info_secret）。")
            }
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        }
        // These endpoints do not use the API Key login or its session Cookie.
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw HeadplaneFailure(message: "无法连接 Headplane，服务器健康状态未知。")
        }
        guard let http = response as? HTTPURLResponse else { throw HeadplaneFailure.incompatible }
        HakoLog.record(.headplane, "Headplane 诊断完成", detail: "GET \(resource.path) · \(http.statusCode)")
        if [301, 302, 303, 307, 308].contains(http.statusCode) {
            throw HeadplaneFailure(message: "诊断接口返回重定向，请核对 Headplane 管理地址。", status: http.statusCode)
        }
        if resource == .serverInfo, [401, 403].contains(http.statusCode) {
            throw HeadplaneFailure(message: "版本查询被拒绝（HTTP \(http.statusCode)）。请确认服务端已配置 server.info_secret，且与此处填写的密钥一致。", status: http.statusCode)
        }
        guard http.statusCode == 200 || (resource == .health && http.statusCode == 500) else {
            throw HeadplaneFailure(message: "无法读取服务器诊断信息（HTTP \(http.statusCode)），请核对管理地址、版本及反向代理设置。", status: http.statusCode)
        }
        guard data.count <= 1024 * 1024, let value = try? JSONDecoder().decode(HeadplaneJSON.self, from: data), !value.object.isEmpty else {
            throw HeadplaneFailure(message: "诊断接口响应无法识别（HTTP \(http.statusCode)），请核对管理地址及反向代理设置。", status: http.statusCode)
        }
        if resource == .health {
            guard (http.statusCode == 200 && value["status"].string == "OK") || (http.statusCode == 500 && value["status"].string == "ERROR") else {
                throw HeadplaneFailure(message: "健康检查返回未知结果（HTTP \(http.statusCode)），请查看服务端日志。", status: http.statusCode)
            }
        }
        return value
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
            Self.logFailure(request, error: error, secrets: [connection.apiKey] + valid.map(\.value))
            throw HeadplaneFailure(message: fields == nil ? "无法连接 Headplane，请检查网络后刷新。" : "操作结果尚未确认，请先刷新远端状态，勿重复提交。", outcomeUnknown: fields != nil)
        }
        guard let http = response as? HTTPURLResponse else { throw HeadplaneFailure.incompatible }
        if http.statusCode >= 400 {
            Self.logFailure(request, response: http, data: data, secrets: [connection.apiKey] + valid.map(\.value))
        } else {
            HakoLog.record(.headplane, "Headplane 请求完成", detail: "\(request.httpMethod ?? "GET") \(resource.path) · \(http.statusCode)")
        }
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

    // Keep the raw wire body (including HTML and turbo-stream) before decoding can fail.
    private static func logFailure(_ request: URLRequest, response: HTTPURLResponse? = nil,
                                   data: Data = Data(), error: Error? = nil, secrets: [String]) {
        var secrets = secrets
        let responseHeaders = response?.allHeaderFields.reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        } ?? [:]
        if let url = response?.url {
            secrets += HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url).map(\.value)
        }
        func headers(_ values: [String: String]) -> String {
            values.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { key, value in
                let sensitive = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"].contains(key.lowercased())
                return "\(key): \(sensitive ? "[已隐藏]" : value)"
            }.joined(separator: "\n")
        }
        func body(_ value: Data?) -> String {
            guard let value, !value.isEmpty else { return "[空]" }
            return String(data: value, encoding: .utf8) ?? "[Base64]\n\(value.base64EncodedString())"
        }
        let detail = """
        请求
        \(request.httpMethod ?? "GET") \(HakoLog.safeURL(request.url?.absoluteString ?? ""))
        \(headers(request.allHTTPHeaderFields ?? [:]))

        请求正文
        \(body(request.httpBody))

        响应
        \(response.map { "HTTP \($0.statusCode)" } ?? "[未收到 HTTP 响应]")
        \(headers(responseHeaders))

        响应正文
        \(body(data))
        \(error.map { "\n传输错误\n\($0.localizedDescription)" } ?? "")
        """
        HakoLogStore.shared.append(source: .headplane, level: .error, message: "Headplane 请求失败",
                                   detail: detail, secrets: secrets, fullDetail: true)
    }
    private func sanitized(_ message: String) -> String {
        var result = message.replacingOccurrences(of: connection.apiKey, with: "[已隐藏]")
        if let secret = connection.infoSecret, !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[已隐藏]") }
        return String(result.prefix(500))
    }
}
