import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HeadplaneFailure: LocalizedError, Sendable {
    let message: String
    var status: Int? = nil
    var outcomeUnknown = false
    var errorDescription: String? { message }
    static let incompatible = Self(message: "Headplane 返回的数据格式不受支持，请核对部署版本与管理地址。")
}

struct HeadplaneConnection: Codable, Equatable, Sendable {
    var name = "Homelab"
    var address = ""
    var apiKey = ""
    var allowHTTP = false

    func normalized() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, !result.apiKey.isEmpty,
              result.apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw HeadplaneFailure(message: "请填写实例名称和有效的 API Key。")
        }
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !parts.path.contains("\\"), !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw HeadplaneFailure(message: "请输入 Headplane 管理地址，不含账号、查询参数或片段。")
        }
        guard scheme == "https" || allowHTTP else { throw HeadplaneFailure(message: "HTTP 连接需明确开启不加密连接。") }
        parts.scheme = scheme
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/admin" }
        guard let url = parts.url else { throw HeadplaneFailure.incompatible }
        result.address = url.absoluteString
        return result
    }

    func request(_ resource: HeadplaneResource, data: Bool = true, method: String = "GET") throws -> URLRequest {
        let c = try normalized()
        var url = URL(string: c.address)!
        for component in resource.path.split(separator: "/") { url.appendPathComponent(String(component)) }
        if data { url = url.appendingPathExtension("data") }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if data && method == "GET" { parts.queryItems = [URLQueryItem(name: "_routes", value: resource.routeID)] }
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("text/x-script, application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            origin.path = ""; origin.query = nil; origin.fragment = nil
            request.setValue(origin.string, forHTTPHeaderField: "Origin")
            request.setValue(c.address + "/", forHTTPHeaderField: "Referer")
        }
        return request
    }
}

enum HeadplaneResource: String, Hashable, Sendable {
    case login, machines, policy, dns, keys, agent
    var path: String {
        switch self { case .login: return "login"; case .machines: return "machines"; case .policy: return "acls"
        case .dns: return "dns"; case .keys: return "settings/auth-keys"; case .agent: return "settings/agent" }
    }
    var routeID: String {
        switch self {
        case .login: return "routes/auth/login/page"
        case .agent: return "routes/settings/agent"
        default: return "routes/" + path + "/overview"
        }
    }
}

enum HeadplaneJSON: Codable, Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    subscript(_ key: String) -> Self { object[key] ?? .null }
    var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var text: String {
        switch self { case .string(let v): return v; case .number(let v): return String(format: "%.0f", v); default: return "" }
    }
    var flag: Bool { self == .bool(true) }
    var strings: [String] { array?.compactMap(\.string) ?? [] }
    var int: Int? { if case .number(let n) = self { return Int(exactly: n) }; return nil }
}

struct HeadplaneUser: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String
    init(_ value: HeadplaneJSON) throws {
        id = value["id"].text; name = Self.displayName(value); email = value["email"].text
        guard !id.isEmpty, !name.isEmpty else { throw HeadplaneFailure.incompatible }
    }
    static func displayName(_ value: HeadplaneJSON) -> String {
        ["name", "displayName", "email", "id"].map { value[$0].text }.first { !$0.isEmpty } ?? ""
    }
}

struct HeadplaneNode: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let addresses: [String]
    let online: Bool
    let expired: Bool
    let lastSeen: String
    let expiry: String
    let userID: String
    let userName: String
    let tags: [String]
    let availableRoutes: [String]
    let approvedRoutes: [String]
    let os: String
    let version: String
    var subnetRoutes: [String] { Array(Set(availableRoutes + approvedRoutes)).filter { !Self.isExit($0) }.sorted() }
    var exitRoutes: [String] { availableRoutes.filter(Self.isExit) }
    var exitApproved: Bool { approvedRoutes.contains(where: Self.isExit) }
    static func isExit(_ route: String) -> Bool { route == "0.0.0.0/0" || route == "::/0" }
    var status: String { expired ? "已过期" : online ? "在线" : "离线" }
    var symbol: String {
        if !availableRoutes.isEmpty { return "wifi.router" }
        let system = os.lowercased()
        if system.contains("ios") || system.contains("android") { return "iphone" }
        if system.contains("mac") { return "laptopcomputer" }
        if system.contains("windows") { return "desktopcomputer" }
        return "server.rack"
    }
    init(_ v: HeadplaneJSON) throws {
        id = v["id"].text; name = v["givenName"].text.isEmpty ? v["name"].text : v["givenName"].text
        guard !id.isEmpty, !name.isEmpty, let ips = v["ipAddresses"].array,
              case .bool(let isOnline) = v["online"] else { throw HeadplaneFailure.incompatible }
        addresses = ips.compactMap(\.string); online = isOnline
        expiry = v["expiry"].text; lastSeen = v["lastSeen"].text
        expired = v["expired"].flag || (HeadplaneDate.parse(expiry).map { $0 < .now } ?? false)
        userID = v["user"]["id"].text; userName = HeadplaneUser.displayName(v["user"])
        tags = v["tags"].array != nil ? v["tags"].strings : Array(Set(v["validTags"].strings + v["forcedTags"].strings)).sorted()
        availableRoutes = v["availableRoutes"].strings; approvedRoutes = v["approvedRoutes"].strings
        os = v["hostInfo"]["OS"].text; version = v["hostInfo"]["IPNVersion"].text
    }
}

struct HeadplaneMachines: Sendable {
    let nodes: [HeadplaneNode]
    let users: [HeadplaneUser]
    let writable: Bool
    let preAuth: Bool
    init(_ value: HeadplaneJSON) throws {
        guard let list = value["populatedNodes"].array ?? value["nodes"].array,
              let people = value["users"].array else { throw HeadplaneFailure.incompatible }
        nodes = try list.map(HeadplaneNode.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        users = try people.map(HeadplaneUser.init)
        guard Set(nodes.map(\.id)).count == nodes.count, Set(users.map(\.id)).count == users.count else { throw HeadplaneFailure.incompatible }
        writable = value["writable"].flag; preAuth = value["preAuth"].flag
    }
}

struct HeadplanePolicy: Sendable {
    let text: String
    let writable: Bool
    init(_ value: HeadplaneJSON) throws {
        guard let text = value["policy"].string else { throw HeadplaneFailure.incompatible }
        self.text = text; writable = value["writable"].flag && value["access"].flag
    }
    // Read-only projection. The editor always submits the original text, preserving HuJSON comments.
    var summary: HeadplaneJSON? { try? JSONDecoder().decode(HeadplaneJSON.self, from: Data(HeadplaneHuJSON.strip(HeadplaneHuJSON.strip(text)).utf8)) }
}

struct HeadplaneAgentStatus: Sendable {
    let enabled: Bool
    let nodeCount: Int?
    let syncedAt: String
    let error: String?
    let reason: String
    let needsApproval: Bool

    init(_ value: HeadplaneJSON) throws {
        guard case .bool(let enabled) = value["enabled"] else { throw HeadplaneFailure.incompatible }
        self.enabled = enabled
        nodeCount = value["nodeCount"].int.flatMap { $0 >= 0 ? $0 : nil }
        syncedAt = value["syncedAt"].text
        error = value["error"].text.isEmpty ? nil : value["error"].text
        reason = value["reason"].text
        needsApproval = enabled && syncedAt.isEmpty && !value["authUrl"].text.isEmpty
    }

    var healthy: Bool { enabled && error == nil && !syncedAt.isEmpty }
    var status: String {
        if !enabled { return "Agent 未启用" }
        if error != nil { return "同步异常" }
        if needsApproval { return "等待授权" }
        return syncedAt.isEmpty ? "等待同步" : "已同步"
    }
    var nodeCountText: String { nodeCount.map(String.init) ?? "未提供" }
}

struct HeadplaneKey: Identifiable, Sendable {
    let id: String
    let secret: String
    let userID: String
    let userName: String
    let expiry: String
    let reusable: Bool
    let used: Bool
    let tags: [String]
    var active: Bool { !(HeadplaneDate.parse(expiry).map { $0 < .now } ?? false) && (!used || reusable) }
    init(_ v: HeadplaneJSON, user: HeadplaneJSON) throws {
        id = v["id"].text; secret = v["key"].text
        guard !id.isEmpty else { throw HeadplaneFailure.incompatible }
        userID = v["user"]["id"].text.isEmpty ? user["id"].text : v["user"]["id"].text
        userName = HeadplaneUser.displayName(v["user"]).isEmpty ? HeadplaneUser.displayName(user) : HeadplaneUser.displayName(v["user"])
        expiry = v["expiration"].text; reusable = v["reusable"].flag; used = v["used"].flag
        tags = v["aclTags"].strings
    }
}

enum HeadplaneKeyCreation {
    static func fields(userID: String, tags: String, days: Int, reusable: Bool, ephemeral: Bool) throws -> [String: String] {
        guard !userID.isEmpty else { throw HeadplaneFailure(message: "请选择所属用户。") }
        guard days >= 1 else { throw HeadplaneFailure(message: "有效期至少为 1 天。") }
        var parsed: [String] = []
        for part in tags.components(separatedBy: CharacterSet(charactersIn: ",，\n")) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let tag = trimmed.hasPrefix("tag:") ? trimmed : "tag:" + trimmed
            guard tag.range(of: "^tag:[a-zA-Z][a-zA-Z0-9-]*$", options: .regularExpression) != nil else {
                throw HeadplaneFailure(message: "标签名称需以字母开头，仅包含字母、数字或连字符，例如 tag:server。")
            }
            if !parsed.contains(tag) { parsed.append(tag) }
        }
        return ["action_id": "add_preauthkey", "user_id": userID, "expiry": String(days),
                "reusable": reusable ? "on" : "off", "ephemeral": ephemeral ? "on" : "off",
                "acl_tags": parsed.joined(separator: ",")]
    }
}

enum HeadplaneDate {
    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty, !value.hasPrefix("0001-") else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: value)
    }
    static func display(_ value: String, empty: String = "未提供") -> String {
        parse(value)?.formatted(date: .abbreviated, time: .shortened) ?? (value.isEmpty || value.hasPrefix("0001-") ? empty : value)
    }
}

enum HeadplaneHuJSON {
    static func strip(_ text: String) -> String {
        let c = Array(text); var output = "", i = 0, quoted = false, escaped = false
        while i < c.count {
            let ch = c[i], next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if quoted {
                output.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { quoted = false }
                i += 1; continue
            }
            if ch == "\"" { quoted = true; output.append(ch); i += 1; continue }
            if ch == "/", next == "/" { while i < c.count && c[i] != "\n" { i += 1 }; output.append(" "); continue }
            if ch == "/", next == "*" {
                i += 2; while i + 1 < c.count && !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2; output.append(" "); continue
            }
            if ch == "," {
                var n = i + 1; while n < c.count && c[n].isWhitespace { n += 1 }
                if n < c.count && (c[n] == "]" || c[n] == "}") { i += 1; continue }
            }
            output.append(ch); i += 1
        }
        // A second pass removes trailing commas separated by comments.
        return output
    }
}
