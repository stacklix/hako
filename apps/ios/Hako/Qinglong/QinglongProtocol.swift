import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct QinglongFailure: LocalizedError {
    let message: String
    var status: Int? = nil
    var outcomeUnknown = false
    var errorDescription: String? { message }
}

struct QinglongHeader: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var value = ""
}

struct QinglongConnection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = "我的青龙"
    var address = ""
    var clientID = ""
    var clientSecret = ""
    var headers: [QinglongHeader] = []
    var allowHTTP = false

    func normalized() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, !result.clientID.isEmpty, !result.clientSecret.isEmpty else {
            throw QinglongFailure(message: "请填写连接名称、Client ID 和 Client Secret。")
        }
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw QinglongFailure(message: "请输入有效的面板地址，不含账号、密码、查询参数或片段。")
        }
        guard scheme != "http" || allowHTTP else { throw QinglongFailure(message: "使用 HTTP 时请开启不加密连接。") }
        url.scheme = scheme
        while url.path.hasSuffix("/") { url.path.removeLast() }
        if url.path.hasSuffix("/open") { url.path.removeLast(5) }
        guard let base = url.url else { throw QinglongFailure(message: "面板地址无效。") }
        result.address = base.absoluteString
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let reserved = Set(["authorization", "host", "content-length", "content-type", "accept", "connection", "transfer-encoding", "cookie"])
        var seen = Set<String>()
        result.headers = []
        for var header in headers {
            header.name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if header.name.isEmpty && header.value.isEmpty { continue }
            guard !header.name.isEmpty, header.name.unicodeScalars.allSatisfy(allowed.contains),
                  !reserved.contains(header.name.lowercased()), seen.insert(header.name.lowercased()).inserted,
                  !header.value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw QinglongFailure(message: "自定义请求头名称无效、重复或与内置请求头冲突；值不能包含换行。")
            }
            result.headers.append(header)
        }
        return result
    }

    func request(_ path: [String], query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        let value = try normalized()
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else {
            throw QinglongFailure(message: "接口路径无效。")
        }
        var url = URL(string: value.address)!.appendingPathComponent("open")
        for component in path { url.appendPathComponent(component) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for header in value.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        return request
    }
}

// Preserve optional server fields when editing; JSON payloads stay in this child app.
enum QinglongJSON: Codable, Equatable, Sendable {
    case object([String: QinglongJSON]), array([QinglongJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self { object[key] ?? .null }
    var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    var text: String {
        switch self { case .string(let v): return v; case .number(let v): return v.rounded() == v ? String(format: "%.0f", v) : String(v); default: return "" }
    }
    var int: Int? { if case .number(let v) = self, v.isFinite, v > Double(Int.min), v < Double(Int.max) { return Int(v) }; return Int(text) }
    var flag: Bool { self == .bool(true) || int == 1 }
    static func fields(_ fields: [String: String]) -> Self { .object(fields.mapValues(Self.string)) }
}

enum QinglongResource: String, CaseIterable, Identifiable, Sendable {
    case tasks = "crons", scripts, subscriptions, envs, configs, dependencies, logs
    var id: String { rawValue }
    var title: String {
        switch self { case .tasks: return "任务"; case .scripts: return "脚本"; case .subscriptions: return "订阅"; case .envs: return "环境变量"; case .configs: return "配置文件"; case .dependencies: return "依赖管理"; case .logs: return "日志文件" }
    }
    var symbol: String {
        switch self { case .tasks: return "checklist"; case .scripts: return "doc.text"; case .subscriptions: return "arrow.triangle.branch"; case .envs: return "slider.horizontal.3"; case .configs: return "doc.badge.gearshape"; case .dependencies: return "shippingbox"; case .logs: return "doc.text.magnifyingglass" }
    }
}

struct QinglongItem: Identifiable, Equatable, Sendable {
    let resource: QinglongResource
    var raw: QinglongJSON
    var id: String { resource.rawValue + ":" + (raw["id"].text.isEmpty ? filePath : raw["id"].text) }
    var numberID: Int? { raw["id"].int }
    var language: String {
        switch (filename as NSString).pathExtension.lowercased() { case "py": return "Python"; case "js": return "JavaScript"; case "ts": return "TypeScript"; case "sh": return "Shell"; default: return "文本" }
    }
    var lastRunText: String {
        guard let time = raw["last_running_time"].int, time > 0 else { return "尚无执行记录" }
        return Date(timeIntervalSince1970: Double(time) / (time > 1_000_000_000_000 ? 1000 : 1)).formatted(date: .abbreviated, time: .shortened)
    }
    var title: String {
        for key in ["name", "title", "filename", "alias"] where !raw[key].text.isEmpty { return raw[key].text }
        return raw["command"].text.isEmpty ? filePath : raw["command"].text
    }
    var filename: String { !raw["title"].text.isEmpty ? raw["title"].text : !raw["filename"].text.isEmpty ? raw["filename"].text : raw["name"].text }
    var directory: String { raw["parent"].text.isEmpty ? raw["path"].text : raw["parent"].text }
    var filePath: String { raw["key"].text.isEmpty ? [directory, filename].filter { !$0.isEmpty }.joined(separator: "/") : raw["key"].text }
    var disabled: Bool { resource == .envs ? raw["status"].int == 1 : raw["isDisabled"].flag || raw["is_disabled"].flag || raw["status"].int == 2 }
    var running: Bool { (resource == .tasks || resource == .subscriptions) && raw["status"].int == 0 }
    var stateText: String {
        if disabled { return "已禁用" }
        if running { return "运行中" }
        if resource == .envs { return "已启用" }
        if raw["status"].int == 3 { return "排队中" }
        return "空闲"
    }
    var subtitle: String {
        switch resource {
        case .tasks: return [raw["schedule"].text, raw["command"].text].filter { !$0.isEmpty }.joined(separator: " · ")
        case .subscriptions: return raw["url"].text
        case .envs: return raw["remarks"].text
        case .scripts, .configs, .logs: return directory.isEmpty ? "根目录" : directory
        case .dependencies: return ["Node.js", "Python3", "Linux"][min(2, max(0, raw["type"].int ?? 0))]
        }
    }
    func editPayload(_ changes: [String: String]) -> QinglongJSON {
        let keys: [String]
        switch resource {
        case .tasks: keys = ["id", "command", "schedule", "name", "labels", "sub_id", "extra_schedules", "task_before", "task_after", "log_name", "allow_multiple_instances", "work_dir"]
        case .subscriptions: keys = ["id", "type", "name", "url", "alias", "schedule_type", "schedule", "interval_schedule", "whitelist", "blacklist", "branch", "dependences", "pull_type", "pull_option", "extensions", "sub_before", "sub_after", "proxy", "autoAddCron", "autoDelCron"]
        case .envs: keys = ["id", "name", "value", "remarks", "labels"]
        default: keys = []
        }
        var values = raw.object.filter { keys.contains($0.key) }
        if resource == .subscriptions {
            for key in ["autoAddCron", "autoDelCron"] where values[key] != nil { values[key] = .bool(raw[key].flag) }
        }
        for (key, value) in changes { values[key] = .string(value) }
        return .object(values)
    }
}

struct QinglongEnvironmentSaveResult: Sendable {
    let item: QinglongItem?
    let stateError: String?
}

struct QinglongOutcome: Equatable, Sendable {
    let raw: QinglongJSON
    var failed: Bool { raw["status"].int == 3 || raw["status"].int == 1 && raw["exit_code"].int.map { $0 != 0 } == true }
    var succeeded: Bool { raw["status"].int == 1 && raw["exit_code"].int == 0 }
    var stateText: String { failed ? "失败" : succeeded ? "成功" : raw["status"].int == 2 ? "已停止" : "结果未知" }
    var summary: String {
        guard let time = raw["started_at"].int else { return stateText }
        return Date(timeIntervalSince1970: Double(time) / (time > 1_000_000_000_000 ? 1000 : 1)).formatted(date: .abbreviated, time: .shortened) + " · " + stateText
    }
}

enum QinglongParsing {
    static func items(_ data: QinglongJSON, resource: QinglongResource) throws -> [QinglongItem] {
        guard let list = data.array ?? data["data"].array else { throw QinglongFailure(message: "面板返回的列表格式不受支持。") }
        func flatten(_ values: [QinglongJSON]) -> [QinglongItem] {
            values.flatMap { value -> [QinglongItem] in
                if value["type"].text == "directory" || value["isDir"].flag { return flatten(value["children"].array ?? []) }
                if let children = value["children"].array, !children.isEmpty { return flatten(children) }
                let file = value.text.isEmpty ? value : .fields(["title": value.text])
                return [QinglongItem(resource: resource, raw: file)]
            }
        }
        let result = flatten(list)
        guard Set(result.map(\.id)).count == result.count else { throw QinglongFailure(message: "列表包含重复标识，请刷新。") }
        return result
    }
    static func file(_ name: String, directory: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !directory.hasPrefix("/"), !directory.contains("\\"),
              !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !(name + directory).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw QinglongFailure(message: "文件名或相对目录无效。")
        }
    }
}
