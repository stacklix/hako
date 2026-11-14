import Foundation
import CoreFoundation

// Model tools expose a bounded set of panel operations, never arbitrary HTTP requests.
enum QinglongAgentTools {
    static let list = LanguageModelTool(name: "list_resources", description: "读取当前面板的资源。返回真实 ID、状态和分页信息；变量值及订阅凭据不返回。任务空闲不代表执行成功。",
        properties: ["resource": resourceSchema, "query": ["type": "string"],
                     "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 50]], required: ["resource"])
    static let detail = LanguageModelTool(name: "read_resource", description: "按列表返回的 ID 读取文件、任务/订阅最近日志或任务最近执行结果。文件和日志可能含敏感数据，仅按用户需要读取。支持分页，日志从末尾读取。",
        properties: ["resource": resourceSchema, "id": ["type": "string"],
                     "view": ["type": "string", "enum": ["file", "log", "outcome"]],
                     "offset": ["type": "integer", "minimum": 0]], required: ["resource", "id", "view"])
    static let propose = LanguageModelTool(name: "propose_change", description: "生成一项待用户点击确认的变更，不执行。create/update 支持任务、环境变量、公开仓库订阅和脚本；配置文件仅 update。run/stop 支持任务和订阅；enable/disable/delete 支持任务、订阅和环境变量。文件更新须先读取原内容。每次只预览一项。",
        properties: ["resource": resourceSchema,
                     "operation": ["type": "string", "enum": QinglongAgentAction.Kind.allCases.map(\.rawValue)],
                     "id": ["type": "string", "description": "已有资源必须使用查询返回的完整 ID"],
                     "draft_id": ["type": "string", "description": "仅纠正当前草稿时填写当前 draft_id；系统保留同一目标未修改的草稿字段。新操作省略。"],
                     "fields": ["type": "object", "properties": Dictionary(uniqueKeysWithValues:
                        ["name", "command", "schedule", "value", "remarks", "url", "alias", "branch", "whitelist", "blacklist", "filename", "directory", "content", "enabled"].map { ($0, ["type": "string", "description": $0 == "enabled" ? "任务自动执行或变量启用状态，仅接受 true / false；不修改时省略" : "字段值"]) }), "additionalProperties": false]],
        required: ["resource", "operation"])
    static var all: [LanguageModelTool] { [list, detail, propose] }
    private static var resourceSchema: [String: Any] { ["type": "string", "enum": QinglongResource.allCases.map(\.rawValue)] }

    static func resource(_ args: [String: Any]) throws -> QinglongResource {
        guard let text = args["resource"] as? String, let value = QinglongResource(rawValue: text) else { throw invalid() }
        return value
    }
    static func integer(_ args: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              range.contains(number.intValue) else { throw invalid() }
        return number.intValue
    }
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    static func invalid() -> QinglongFailure { QinglongFailure(message: "工具参数无效，请重新查询并明确操作目标。") }

    static func redact(_ result: String, connection: QinglongConnection) throws -> String {
        var safe = result
        for secret in [connection.clientID, connection.clientSecret] + connection.headers.map(\.value) where !secret.isEmpty {
            let escaped = try json([secret])
            let encoded = String(escaped.dropFirst(2).dropLast(2))
            safe = safe.replacingOccurrences(of: encoded, with: "[已隐藏连接凭据]")
        }
        return safe
    }

    static func row(_ item: QinglongItem) -> [String: Any] {
        var row: [String: Any] = ["id": item.id, "name": item.title, "state": item.stateText]
        switch item.resource {
        case .tasks:
            for key in ["command", "schedule", "last_running_time"] { row[key] = item.raw[key].text }
        case .envs: row["remarks"] = item.raw["remarks"].text; row["value"] = "[隐藏]"
        case .subscriptions:
            // URLs, hooks and credentials may contain private-repository tokens.
            for key in ["alias", "branch", "schedule", "schedule_type"] { row[key] = item.raw[key].text }
        case .scripts, .configs, .logs: row["path"] = item.filePath; row["directory"] = item.isDirectory
        case .dependencies: row["type"] = item.subtitle; row["state"] = item.dependencyStatus?.title ?? "未知状态"
        }
        for (key, value) in row {
            if let text = value as? String, key != "id", text.count > 2_000 { row[key] = String(text.prefix(2_000)) + "…[已截断]" }
        }
        return row
    }
}

struct QinglongAgentClarification: LocalizedError {
    let missing: [String]
    var errorDescription: String? { "请补充：" + missing.joined(separator: "、") + "。" }
}

struct QinglongAgentAction: Codable {
    enum Kind: String, Codable, CaseIterable {
        case create, update, run, stop, enable, disable, delete
        var title: String {
            switch self { case .create: "创建"; case .update: "修改"; case .run: "运行"; case .stop: "停止"; case .enable: "启用"; case .disable: "禁用"; case .delete: "删除" }
        }
    }
    let resource: QinglongResource
    let kind: Kind
    let itemID: String?
    var fields: [String: String]

    init(_ args: [String: Any]) throws {
        guard Set(args.keys).isSubset(of: ["resource", "operation", "id", "fields"]),
              let operation = args["operation"] as? String, let kind = Kind(rawValue: operation),
              args["fields"] == nil || args["fields"] is [String: String],
              args["id"] == nil || args["id"] is String else { throw QinglongAgentTools.invalid() }
        resource = try QinglongAgentTools.resource(args)
        self.kind = kind
        itemID = args["id"] as? String
        fields = args["fields"] as? [String: String] ?? [:]
        guard kind == .create ? itemID == nil : itemID?.isEmpty == false else { throw QinglongAgentTools.invalid() }
        switch kind {
        case .create, .update:
            let allowed: Set<String>
            switch resource {
            case .tasks: allowed = ["name", "command", "schedule", "enabled"]
            case .envs: allowed = ["name", "value", "remarks", "enabled"]
            case .subscriptions: allowed = ["name", "url", "alias", "branch", "schedule", "whitelist", "blacklist"]
            case .scripts: allowed = kind == .create ? ["filename", "directory", "content"] : ["content"]
            case .configs: guard kind == .update else { throw QinglongAgentTools.invalid() }; allowed = ["content"]
            default: throw QinglongAgentTools.invalid()
            }
            guard (kind == .create || !fields.isEmpty), Set(fields.keys).isSubset(of: allowed),
                  fields.values.allSatisfy({ $0.utf8.count <= 128_000 }) else { throw QinglongAgentTools.invalid() }
            if let enabled = fields["enabled"], !["true", "false"].contains(enabled) { throw QinglongAgentTools.invalid() }
        case .run, .stop:
            guard [.tasks, .subscriptions].contains(resource), fields.isEmpty else { throw QinglongAgentTools.invalid() }
        case .enable, .disable, .delete:
            guard [.tasks, .subscriptions, .envs].contains(resource), fields.isEmpty else { throw QinglongAgentTools.invalid() }
        }
    }

    func validate(item: QinglongItem?) throws {
        let missing = missing(item: item)
        guard missing.isEmpty else { throw QinglongFailure(message: "请补充：" + missing.joined(separator: "、") + "。") }
        if kind == .run, let item, item.running || item.queued {
            throw QinglongFailure(message: "此资源正在运行或排队，请先核对执行状态。")
        }
        if kind == .stop, let item, !item.running && !item.queued {
            throw QinglongFailure(message: "此资源已不在运行或排队，请先核对执行状态。")
        }
        let values = item?.editPayload(fields) ?? .fields(fields)
        if kind == .create || kind == .update {
            let required: [String]
            switch resource {
            case .tasks: required = ["command", "schedule"]
            case .envs: required = ["name", "value"]
            case .subscriptions: required = ["url", "alias"]
            default: required = []
            }
            guard required.allSatisfy({ !values[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw QinglongFailure(message: "缺少必填字段，请补充后重新生成预览。")
            }
            if resource == .subscriptions, kind == .create, fields["schedule"] == nil {
                throw QinglongFailure(message: "请明确订阅的 Cron 表达式。")
            }
            if fields["schedule"] != nil {
                guard [5, 6].contains(values["schedule"].text.split(whereSeparator: \.isWhitespace).count),
                      resource != .subscriptions || item == nil || item?.raw["schedule_type"].text == "crontab" else {
                    throw QinglongFailure(message: "请使用五段或六段 Cron 表达式；间隔订阅请在面板编辑。")
                }
            }
            if let url = fields["url"] {
                guard let parts = URLComponents(string: url), ["http", "https", "ssh"].contains(parts.scheme?.lowercased() ?? ""),
                      parts.host?.isEmpty == false else { throw QinglongFailure(message: "请提供完整的仓库 URL。") }
            }
            if resource == .scripts, kind == .create {
                guard let name = fields["filename"], fields["content"] != nil else { throw QinglongAgentTools.invalid() }
                try QinglongParsing.file(name, directory: fields["directory"] ?? "")
                try QinglongScriptTree.path(name, allowsRoot: false)
                try QinglongScriptTree.path(fields["directory"] ?? "")
            }
        }
    }
    var destructive: Bool { [.delete, .stop].contains(kind) }
    var verb: String { kind.title }
    var enabled: Bool? { fields["enabled"].map { $0 == "true" } }
    var editable: Bool { kind == .create || kind == .update }
    var contentFields: [String: String] { fields.filter { $0.key != "enabled" } }
    func missing(item: QinglongItem?) -> [String] {
        guard editable else { return [] }
        let values = item?.editPayload(contentFields) ?? .fields(contentFields)
        let required: [String]
        switch resource {
        case .tasks: required = ["command", "schedule"]
        case .envs: required = ["name", "value"]
        case .subscriptions: required = kind == .create ? ["url", "alias", "schedule"] : ["url", "alias"]
        case .scripts: required = kind == .create ? ["filename"] : []
        default: required = []
        }
        var result = required.filter { values[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(Self.fieldTitle)
        if [.scripts, .configs].contains(resource), fields["content"] == nil { result.append("文件内容") }
        return result
    }
    func mergingDraft(_ draft: Self?) -> Self {
        guard let draft, editable, resource == draft.resource, kind == draft.kind, itemID == draft.itemID else { return self }
        var value = self
        value.fields = draft.fields.merging(fields, uniquingKeysWith: { _, new in new })
        return value
    }
    static func fieldTitle(_ key: String) -> String {
        ["name": "名称", "command": "执行命令", "schedule": "Cron 表达式", "value": "变量值", "remarks": "备注",
         "url": "仓库地址", "alias": "别名", "branch": "分支", "whitelist": "包含关键词", "blacklist": "排除关键词",
         "filename": "文件名", "directory": "目录", "content": "文件内容", "enabled": "启用状态"][key] ?? key
    }
}

struct QinglongAgentProposal: Identifiable, Codable {
    var id = UUID()
    let revision: UUID
    let connectionID: String
    let action: QinglongAgentAction
    let item: QinglongItem?
    let originalContent: String?
    var title: String { action.verb + action.resource.title + " · " + (item?.title ?? action.fields["name"] ?? action.fields["filename"] ?? action.fields["alias"] ?? "新资源") }

    func restored(revision: UUID, connectionID: String) -> Self? {
        guard self.connectionID == connectionID else { return nil }
        return .init(id: id, revision: revision, connectionID: connectionID, action: action, item: item, originalContent: originalContent)
    }
    var editingFields: [String: String] {
        let keys: [String]
        switch action.resource {
        case .tasks: keys = ["name", "command", "schedule"]
        case .envs: keys = ["name", "value", "remarks"]
        case .subscriptions: keys = ["name", "url", "alias", "branch", "schedule", "whitelist", "blacklist"]
        case .scripts: keys = action.kind == .create ? ["filename", "directory", "content"] : ["content"]
        case .configs: keys = ["content"]
        default: keys = []
        }
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, action.fields[$0] ?? item?.raw[$0].text ?? "") })
    }
    var editingEnabled: Bool { action.enabled ?? !(item?.disabled ?? false) }
    func revising(fields: [String: String], enabled: Bool) throws -> Self {
        guard action.editable else { throw QinglongAgentTools.invalid() }
        var changes = action.fields
        for (key, value) in fields where value != editingFields[key] { changes[key] = value }
        if [.tasks, .envs].contains(action.resource), enabled != editingEnabled { changes["enabled"] = String(enabled) }
        var args: [String: Any] = ["resource": action.resource.rawValue, "operation": action.kind.rawValue, "fields": changes]
        if let id = action.itemID { args["id"] = id }
        let revised = try QinglongAgentAction(args)
        try revised.validate(item: item)
        return .init(id: id, revision: revision, connectionID: connectionID, action: revised, item: item, originalContent: originalContent)
    }

    static func unchanged(_ original: QinglongItem, _ current: QinglongItem) -> Bool {
        original.id == current.id && original.isDirectory == current.isDirectory && original.editPayload([:]) == current.editPayload([:]) && original.disabled == current.disabled
    }
}
