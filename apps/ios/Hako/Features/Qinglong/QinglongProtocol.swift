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

enum QinglongResource: String, Codable, CaseIterable, Identifiable, Sendable {
    case tasks = "crons", scripts, subscriptions, envs, configs, dependencies, logs
    var id: String { rawValue }
    var title: String {
        switch self { case .tasks: return "任务"; case .scripts: return "脚本"; case .subscriptions: return "订阅"; case .envs: return "环境变量"; case .configs: return "配置文件"; case .dependencies: return "依赖管理"; case .logs: return "日志文件" }
    }
    var symbol: String {
        switch self { case .tasks: return "checklist"; case .scripts: return "doc.text"; case .subscriptions: return "arrow.triangle.branch"; case .envs: return "slider.horizontal.3"; case .configs: return "doc.badge.gearshape"; case .dependencies: return "shippingbox"; case .logs: return "doc.text.magnifyingglass" }
    }
}

enum QinglongDependencyType: Int, CaseIterable, Sendable {
    case nodeJS = 0, python = 1, linux = 2

    var title: String {
        switch self {
        case .nodeJS: return "Node.js"
        case .python: return "Python"
        case .linux: return "Linux"
        }
    }
}

// Matches Qinglong's DependenceStatus enum; unknown values remain unknown.
enum QinglongDependencyStatus: Int, Sendable {
    case installing, installed, installFailed, removing, removed, removeFailed, queued, cancelled
    var title: String {
        switch self {
        case .installing: return "安装中"
        case .installed: return "已安装"
        case .installFailed: return "安装失败"
        case .removing: return "移除中"
        case .removed: return "已移除"
        case .removeFailed: return "移除失败"
        case .queued: return "排队中"
        case .cancelled: return "已取消"
        }
    }
    var failed: Bool { self == .installFailed || self == .removeFailed }
}

struct QinglongItem: Codable, Identifiable, Equatable, Sendable {
    let resource: QinglongResource
    var raw: QinglongJSON
    var id: String { resource.rawValue + ":" + (raw["id"].text.isEmpty ? filePath : raw["id"].text) }
    var numberID: Int? { raw["id"].int }
    var dependencyStatus: QinglongDependencyStatus? { raw["status"].int.flatMap(QinglongDependencyStatus.init(rawValue:)) }
    var isDirectory: Bool { raw["type"].text == "directory" || raw["isDir"].flag }
    var language: String {
        switch (filename as NSString).pathExtension.lowercased() { case "py": return "Python"; case "js": return "JavaScript"; case "ts": return "TypeScript"; case "sh": return "Shell"; default: return "文本" }
    }
    var lastRunText: String {
        guard let time = raw["last_running_time"].int, time > 0 else { return "尚无执行记录" }
        return Date(timeIntervalSince1970: Double(time) / (time > 1_000_000_000_000 ? 1000 : 1)).formatted(date: .abbreviated, time: .shortened)
    }
    var scheduleDescription: String {
        var parts = raw["schedule"].text.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count == 6 {
            guard parts.removeFirst() == "0" else { return "自定义计划" }
        }
        guard parts.count == 5, parts[2] == "*", parts[3] == "*" else { return "自定义计划" }
        if parts[4] == "*", parts[1] == "*" {
            if parts[0] == "*" { return "每分钟" }
            if parts[0].hasPrefix("*/"), let interval = Int(parts[0].dropFirst(2)), (1...59).contains(interval) { return "每 \(interval) 分钟" }
        }
        guard let minute = Int(parts[0]), (0...59).contains(minute) else { return "自定义计划" }
        if parts[4] == "*", parts[1].hasPrefix("*/"), let interval = Int(parts[1].dropFirst(2)), (1...23).contains(interval) { return "每 \(interval) 小时 · 第 \(minute) 分钟" }
        guard let hour = Int(parts[1]), (0...23).contains(hour) else { return "自定义计划" }
        let time = String(format: "%02d:%02d", hour, minute)
        if parts[4] == "*" { return "每天 " + time }
        if let weekday = Int(parts[4]), (0...7).contains(weekday) { return "每周" + ["日", "一", "二", "三", "四", "五", "六"][weekday % 7] + " " + time }
        return "自定义计划"
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
    var queued: Bool { (resource == .tasks || resource == .subscriptions) && raw["status"].int == 3 }
    var stateText: String {
        if running { return "运行中" }
        if queued { return "排队中" }
        if disabled { return "已禁用" }
        if resource == .envs { return "已启用" }
        return "空闲"
    }
    var subtitle: String {
        switch resource {
        case .tasks: return [raw["schedule"].text, raw["command"].text].filter { !$0.isEmpty }.joined(separator: " · ")
        case .subscriptions: return raw["url"].text
        case .envs: return raw["remarks"].text
        case .scripts, .configs, .logs: return directory.isEmpty ? "根目录" : directory
        case .dependencies:
            return raw["type"].int.flatMap(QinglongDependencyType.init(rawValue:))?.title ?? "未知类型"
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

struct QinglongTaskSaveResult: Sendable {
    let item: QinglongItem?
    let stateError: String?
}

enum QinglongPermissionResult: Equatable {
    case pending, checking, readable, denied(String), failed(String)
    init(error: Error) {
        if (error as? QinglongFailure)?.status == 403 { self = .denied(error.localizedDescription) }
        else { self = .failed(error.localizedDescription) }
    }
    var title: String {
        switch self { case .pending: return "待检测"; case .checking: return "检测中"; case .readable: return "可读取"; case .denied: return "无权限"; case .failed: return "读取失败" }
    }
    var message: String? {
        switch self { case .denied(let message), .failed(let message): return message; default: return nil }
    }
    var completed: Bool { self != .pending && self != .checking }
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
        if resource == .scripts { return try QinglongScriptTree.entries(list) }
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

// A path-keyed snapshot retains empty directories as well as files. All UI and
// mutation paths are relative to Qinglong's script root, never OS absolute paths.
enum QinglongScriptTree {
    static func path(_ path: String, allowsRoot: Bool = true) throws {
        if path.isEmpty && allowsRoot { return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { throw QinglongFailure(message: "目录无效。") }
        for part in parts {
            try QinglongParsing.file(String(part), directory: "")
            guard part.utf8.count <= 255 else { throw QinglongFailure(message: "文件名过长。") }
        }
    }
    static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    static func contains(_ path: String, in directory: String) -> Bool { path == directory || path.hasPrefix(directory + "/") }
    static func entries(_ list: [QinglongJSON]) throws -> [QinglongItem] {
        var values: [String: QinglongItem] = [:]
        func visit(_ nodes: [QinglongJSON], parent: String) throws {
            for node in nodes {
                let item = QinglongItem(resource: .scripts, raw: node.text.isEmpty ? node : .fields(["title": node.text]))
                let directory = item.directory.isEmpty ? parent : item.directory
                let key = item.raw["key"].text.isEmpty ? [directory, item.filename].filter { !$0.isEmpty }.joined(separator: "/") : item.raw["key"].text
                try path(key, allowsRoot: false)
                let name = key.split(separator: "/").last.map(String.init) ?? ""
                guard !name.isEmpty, values[key] == nil,
                      item.filename.isEmpty || item.filename == name,
                      item.directory.isEmpty || item.directory == Self.parent(key) else {
                    throw QinglongFailure(message: "脚本列表包含重复或不一致的路径，请刷新。")
                }
                var raw = item.raw.object
                raw["title"] = .string(name); raw["parent"] = .string(Self.parent(key)); raw["key"] = .string(key)
                raw["type"] = .string(item.isDirectory || (item.raw["type"].text != "file" && item.raw["children"].array != nil) ? "directory" : "file")
                raw.removeValue(forKey: "children"); raw.removeValue(forKey: "id")
                let entry = QinglongItem(resource: .scripts, raw: .object(raw))
                values[key] = entry
                if entry.isDirectory { try visit(item.raw["children"].array ?? [], parent: key) }
            }
        }
        try visit(list, parent: "")
        // Some panel versions return a flat list. Keep ancestor folders visible.
        for key in Array(values.keys) {
            var directory = parent(key)
            while !directory.isEmpty {
                if let existing = values[directory], !existing.isDirectory { throw QinglongFailure(message: "脚本列表的文件与目录路径冲突。") }
                if values[directory] == nil {
                    values[directory] = QinglongItem(resource: .scripts, raw: .fields(["title": String(directory.split(separator: "/").last!), "parent": parent(directory), "key": directory, "type": "directory"]))
                }
                directory = parent(directory)
            }
        }
        return values.values.sorted { $0.filePath.localizedStandardCompare($1.filePath) == .orderedAscending }
    }
    static func children(_ entries: [QinglongItem], directory: String) -> [QinglongItem] {
        entries.filter { $0.directory == directory }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
    }
    static func destination(for item: QinglongItem, name: String, directory: String, entries: [QinglongItem]) throws -> String {
        try QinglongParsing.file(name, directory: directory)
        try path(directory); try path(name, allowsRoot: false); try path(item.filePath, allowsRoot: false)
        guard item.resource == .scripts, let source = entries.first(where: { $0.filePath == item.filePath }), source.isDirectory == item.isDirectory else {
            throw QinglongFailure(message: "源文件或目录已改变，请刷新列表。")
        }
        guard directory.isEmpty || entries.contains(where: { $0.filePath == directory && $0.isDirectory }) else { throw QinglongFailure(message: "目标目录已不存在，请重新选择。") }
        if item.isDirectory && contains(directory, in: item.filePath) { throw QinglongFailure(message: "不能移动到自身或子目录。") }
        let target = [directory, name].filter { !$0.isEmpty }.joined(separator: "/")
        guard target != item.filePath else { throw QinglongFailure(message: "名称和目录没有变化。") }
        guard !entries.contains(where: { $0.filePath == target }) else { throw QinglongFailure(message: "目标目录已有同名文件或文件夹。") }
        return target
    }
}
