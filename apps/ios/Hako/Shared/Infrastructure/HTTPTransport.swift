import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shared policy for credential-bearing requests. Vendor protocols stay in child apps.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum HTTPTransport {
    static let shared = makeSession()

    static func data(for request: URLRequest, using session: URLSession = shared,
                     source: HakoLogSource = .hako, secrets: [String] = [],
                     logBody: Bool = true) async throws -> (Data, URLResponse) {
        var logRequest = request
        if !logBody { logRequest.httpBody = nil }
        return try await perform(logRequest, source: source, secrets: secrets, body: { logBody ? $0 : nil }) {
            try await session.data(for: request)
        }
    }

    static func download(for request: URLRequest, using session: URLSession,
                         source: HakoLogSource, secrets: [String] = []) async throws -> (URL, URLResponse) {
        try await perform(request, source: source, secrets: secrets, body: { file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= HTTPLogRedactor.bodyLimit else { return nil }
            return try? Data(contentsOf: file)
        }) {
            try await session.download(for: request)
        }
    }

    private static func perform<Value>(
        _ request: URLRequest, source: HakoLogSource, secrets: [String], body: (Value) -> Data?,
        send: () async throws -> (Value, URLResponse)
    ) async throws -> (Value, URLResponse) {
        let started = ContinuousClock.now
        do {
            let (value, response) = try await send()
            record(request, source: source, secrets: secrets, started: started,
                   response: response as? HTTPURLResponse, data: body(value))
            return (value, response)
        } catch {
            record(request, source: source, secrets: secrets, started: started, error: error)
            throw error
        }
    }

    private static func record(_ request: URLRequest, source: HakoLogSource, secrets: [String],
                               started: ContinuousClock.Instant, response: HTTPURLResponse? = nil,
                               data: Data? = nil, error: Error? = nil) {
        var redactor = HTTPLogRedactor(request: request, secrets: secrets)
        let responseDetail = response.map { redactor.response($0, data: data) } ?? "未收到 HTTP 响应"
        let status = response.map { String($0.statusCode) } ?? "无响应"
        let method = request.httpMethod ?? "GET"
        let duration = started.duration(to: .now).components
        let elapsed = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        let cause = error.map { $0 as NSError }.map { "\n传输错误：\($0.domain) \($0.code)" } ?? ""
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        let level: HakoLogLevel = cancelled ? .warning : response == nil || (response?.statusCode ?? 0) >= 400 ? .error : .info
        let detail = redactor.request(request) + "\n\nHTTP 状态：\(status)\n耗时："
            + String(format: "%.0f ms", elapsed) + cause + "\n" + responseDetail
        HakoLogStore.shared.append(source: source, level: level, message: "HTTP \(method) · \(status)",
                                   detail: detail, fullDetail: true)
    }

    static func makeSession(requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 604800,
                            delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config, delegate: delegate ?? NoRedirectDelegate(), delegateQueue: nil)
    }
}

// Redact structured fields before formatting; known credentials are also removed from free text.
struct HTTPLogRedactor {
    static let bodyLimit = 8 * 1024
    private var secrets: Set<String>
    private let hidden = "[已隐藏]"
    init(request: URLRequest, secrets: [String]) {
        self.secrets=Set(secrets.filter { !$0.isEmpty })
        if let url=request.url,let components=URLComponents(url:url,resolvingAgainstBaseURL:false) {
            for value in [components.user,components.password].compactMap({$0}) where !value.isEmpty { self.secrets.insert(value) }
            for item in components.queryItems ?? [] where Self.sensitive(item.name) {
                if let value=item.value { collectSecret(value,field:item.name) }
            }
        }
        collect(request.allHTTPHeaderFields ?? [:])
        if let body=request.httpBody, body.count <= Self.bodyLimit {
            if let object=try? JSONSerialization.jsonObject(with:body,options:.fragmentsAllowed) { collect(object) }
            if request.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true,
               let form=String(data:body,encoding:.utf8) {
                let parts=URLComponents(string:"https://localhost/?"+form)
                for item in parts?.queryItems ?? [] where Self.sensitive(item.name) {
                    if let value=item.value { collectSecret(value,field:item.name) }
                }
            }
        }
    }
    private static func sensitive(_ name:String, value:Any? = nil) -> Bool {
        let key=name.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["signaturemethod","signatureversion"].contains(key) { return false }
        // Asset lists may also be named "tokens". Still redact credential fields within each holding.
        if key == "tokens", let holdings = value as? [[String:Any]], holdings.allSatisfy({
            $0["symbol"] is String && ($0["balance"] is String || $0["balance"] is NSNumber)
        }) { return false }
        return ["key","auth","authentication","jwt","session","sessionid","sessionkey","dpop","nonce",
                "codeverifier","websocketurl","commandcontent","output"].contains(key)
            || key.contains("token")
            || ["apikey","accesskey","secret","password","passwd","authorization","signature","cookie","privatekey","credential"].contains { key.contains($0) }
    }
    private mutating func collectSecret(_ value:Any, field:String) {
        if let value=value as? String,!value.isEmpty {
            secrets.insert(value)
            if ["bearer ", "basic ", "dpop "].contains(where: { value.lowercased().hasPrefix($0) }) {
                if let token=value.split(whereSeparator:{$0.isWhitespace}).last { secrets.insert(String(token)) }
            }
            if field.lowercased().contains("cookie") {
                for part in value.split(separator:";") {
                    let pair=part.split(separator:"=",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
                    if pair.count == 2,!pair[1].isEmpty,!["path","domain","expires","max-age","samesite"].contains(pair[0].lowercased()) { secrets.insert(pair[1]) }
                }
            }
        }
        else if let values=value as? [Any] { for value in values { collectSecret(value,field:field) } }
        else if let values=value as? [String:Any] { for value in values.values { collectSecret(value,field:field) } }
    }
    private mutating func collect(_ object:Any) {
        if let values=object as? [String:Any] {
            for (key,value) in values {
                if Self.sensitive(key,value:value) { collectSecret(value,field:key) } else { collect(value) }
            }
        } else if let values=object as? [Any] { for value in values { collect(value) } }
    }
    func text(_ value:String) -> String {
        var result=value
        for secret in secrets.sorted(by:{$0.count > $1.count}) {
            result=result.replacingOccurrences(of:secret,with:hidden)
            if let encoded=secret.addingPercentEncoding(withAllowedCharacters:.alphanumerics) {
                result=result.replacingOccurrences(of:encoded,with:hidden,options:.caseInsensitive)
            }
            if let encoded=try? JSONSerialization.data(withJSONObject:secret,options:.fragmentsAllowed),
               let escaped=String(data:encoded,encoding:.utf8),escaped.count > 2 {
                result=result.replacingOccurrences(of:String(escaped.dropFirst().dropLast()),with:hidden)
            }
        }
        return HakoLog.sanitize(result,limit:Int.max)
    }
    private func plainText(_ value:String) -> String {
        var result=text(value)
        // Cover credential key/value pairs in non-JSON error bodies and JSON string values too.
        let name=#"(?:[A-Za-z0-9_-]*(?:token|secret|password|passwd|api[_-]?key|access[_-]?key|authorization|signature|cookie|private[_-]?key|dpop|nonce)[A-Za-z0-9_-]*)"#
        let pair="(?i)(\\b"+name+#"[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'[^']*'|[^\s,;&<>]+)"#
        result=result.replacingOccurrences(of:pair,with:"$1\""+hidden+"\"",options:.regularExpression)
        result=result.replacingOccurrences(of:#"(?im)((?:set-cookie|cookie|authorization|proxy-authorization)\s*:\s*)[^\r\n]*"#,with:"$1"+hidden,options:.regularExpression)
        result=result.replacingOccurrences(of:#"(?is)-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----.*?-----END (?:[A-Z ]*PRIVATE KEY)-----"#,with:hidden,options:.regularExpression)
        return HakoLog.sanitize(result,limit:Int.max)
    }
    private func redact(_ object:Any) -> Any {
        if let values=object as? [String:Any] {
            return values.reduce(into:[String:Any]()) { result,item in
                result[item.key]=Self.sensitive(item.key,value:item.value) ? hidden : redact(item.value)
            }
        }
        if let values=object as? [Any] { return values.map(redact) }
        if let value=object as? String { return plainText(value) }
        return object
    }
    private func formatted(_ object:Any, limit:Int = 12 * 1024) -> String {
        guard let data=try? JSONSerialization.data(withJSONObject:redact(object),options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]),
              let value=String(data:data,encoding:.utf8) else { return "[无法格式化正文]" }
        return HakoLog.sanitize(text(value),limit:limit)
    }
    private mutating func body(_ data:Data?, contentType:String?) -> String {
        guard let data else { return "[文件或流式正文未读取]" }
        guard !data.isEmpty else { return "[空]" }
        guard data.count <= Self.bodyLimit else { return "[\(data.count) 字节，超过 \(Self.bodyLimit) 字节，正文已省略]" }
        let mime=contentType?.lowercased() ?? ""
        if ["image/","audio/","video/","multipart/","application/octet-stream","application/zip","text/x-script"].contains(where: { mime.hasPrefix($0) }) {
            return "[二进制或编码正文，\(data.count) 字节]"
        }
        if let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) {
            collect(object)
            return formatted(object)
        }
        guard !data.contains(where: { $0 < 32 && $0 != 9 && $0 != 10 && $0 != 13 }),
              let value=String(data:data,encoding:.utf8) else { return "[非文本正文，\(data.count) 字节]" }
        return plainText(value)
    }
    mutating func request(_ request:URLRequest) -> String {
        var components=request.url.flatMap { URLComponents(url:$0,resolvingAgainstBaseURL:false) }
        var query=[String:[String]]()
        for item in components?.queryItems ?? [] { query[item.name,default:[]].append(item.value ?? "") }
        components?.user=nil;components?.password=nil;components?.query=nil;components?.fragment=nil
        let headers=request.allHTTPHeaderFields ?? [:]
        // Discover body secrets before rendering headers or query values that might echo them.
        let contents=body(request.httpBody ?? Data(),contentType:request.value(forHTTPHeaderField:"Content-Type"))
        return text("方法："+(request.httpMethod ?? "GET")+"\nURL："+(components?.string.map { String($0.prefix(2048)) } ?? "[无效地址]")
            + "\n查询参数：\n"+formatted(query)+"\n请求头：\n"+formatted(headers)
            + "\n请求正文：\n"+(request.httpBodyStream == nil ? contents : "[流式正文未读取，避免影响请求]"))
    }
    mutating func response(_ response:HTTPURLResponse,data:Data?) -> String {
        let headers=response.allHeaderFields.reduce(into:[String:Any]()) { $0[String(describing:$1.key)]=$1.value }
        collect(headers)
        let contents=body(data,contentType:response.value(forHTTPHeaderField:"Content-Type"))
        return text("响应头：\n"+formatted(headers)+"\n响应正文：\n"+contents)
    }
}
