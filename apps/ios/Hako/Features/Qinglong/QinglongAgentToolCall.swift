import Foundation

typealias QinglongAgentToolCall = AssistantToolCall<QinglongAgentToolPresentation>

enum QinglongAgentToolPresentation: AssistantToolPresentation {
    typealias Record = QinglongAgentToolCall
    static func title(_ name: String) -> String {
        switch name {
        case "list_resources": "查询面板资源"
        case "read_resource": "读取资源详情"
        case "propose_change": "生成操作草稿"
        default: "调用工具"
        }
    }
    static func icon(_ name: String) -> String {
        switch name { case "list_resources": "list.bullet.rectangle"; case "read_resource": "doc.text.magnifyingglass"; case "propose_change": "doc.badge.plus"; default: "wrench.and.screwdriver" }
    }
    static func summary(_ record: Record) -> String {
        let payload = record.payload, inputs = record.inputs
        if let value = payload["summary"] as? String, payload["status"] as? String == "pending_user_confirmation" { return "已生成草稿 · " + value }
        return inputs.filter { ["资源", "搜索关键词", "资源 ID", "读取内容", "操作"].contains($0.label) }.prefix(3).map(\.value).joined(separator: " · ")
    }
    static func outputs(_ record: Record) -> [AssistantToolField] {
        let payload = record.payload
        if let missing = payload["missing"] as? [String], !missing.isEmpty { return [.init(label: "当时缺少的参数", value: missing.joined(separator: "、"))] }
        if payload["status"] as? String == "pending_user_confirmation" {
            return [.init(label: "生成结果", value: payload["summary"] as? String ?? "已生成操作草稿"),
                    .init(label: "调用结束时", value: "草稿待确认，尚未提交面板操作。")]
        }
        if let rows = payload["items"] as? [[String: Any]] {
            var fields = [AssistantToolField(label: "本次返回", value: "\(rows.count) 条记录")]
            if let total = payload["total"] as? Int { fields.append(.init(label: "匹配总数", value: "\(total) 条")) }
            let names = rows.prefix(5).compactMap { $0["name"] as? String }
            if !names.isEmpty { fields.append(.init(label: rows.count > 5 ? "前 5 条记录" : "返回记录", value: names.joined(separator: "\n"))) }
            if payload["hasMore"] as? Bool == true { fields.append(.init(label: "后续数据", value: "还有更多记录。")) }
            return fields
        }
        if let content = payload["content"] as? String {
            var fields = [AssistantToolField(label: "读取结果", value: "本次返回 \(content.count) 个字符")]
            if let count = payload["totalCharacters"] as? Int { fields.append(.init(label: "原文长度", value: "\(count) 个字符")) }
            if payload["tailOnly"] as? Bool == true { fields.append(.init(label: "读取范围", value: "最近日志的末尾片段")) }
            if payload["hasMore"] as? Bool == true { fields.append(.init(label: "后续数据", value: "尚有未读取内容。")) }
            return fields
        }
        if let summary = payload["summary"] as? String { return [.init(label: payload["state"] as? String ?? "执行结果", value: summary)] }
        return [.init(label: "执行结果", value: "工具已返回，完整内容可在原始结果中查看。")]
    }

    static func resolves(_ earlier: Record, with later: Record) -> Bool {
        guard earlier.name == "propose_change", later.name == "propose_change",
              let before = AssistantToolJSON.decode(earlier.arguments) as? [String: Any],
              let after = AssistantToolJSON.decode(later.arguments) as? [String: Any] else { return false }
        let fields = before["fields"] as? [String: Any] ?? [:]
        let identified = (before["id"] as? String)?.isEmpty == false
            || ["name", "filename"].contains { (fields[$0] as? String)?.isEmpty == false }
        return identified && AssistantToolJSON.contains(before, in: after)
    }
}

extension AssistantToolCall where Presentation == QinglongAgentToolPresentation {
    init(call: LanguageModelCall, panelName: String, at date: Date = .now) {
        let args = call.arguments ?? [:]
        var fields = [Field(label: "面板", value: panelName)]
        if let value = args["resource"] as? String { fields.append(.init(label: "资源", value: QinglongResource(rawValue: value)?.title ?? value)) }
        for (key, label) in [("query", "搜索关键词"), ("id", "资源 ID"), ("offset", "起始位置"), ("limit", "最多返回")] {
            if let value = args[key] { fields.append(.init(label: label, value: String(describing: value))) }
        }
        if let value = args["view"] as? String {
            fields.append(.init(label: "读取内容", value: ["file": "文件", "log": "最近日志", "outcome": "最近执行结果"][value] ?? value))
        }
        if let value = args["operation"] as? String {
            fields.append(.init(label: "操作", value: QinglongAgentAction.Kind(rawValue: value)?.title ?? value))
        }
        if let values = args["fields"] as? [String: String], !values.isEmpty {
            fields.append(.init(label: "填写字段", value: values.keys.sorted().map(QinglongAgentAction.fieldTitle).joined(separator: "、")))
        }
        self.init(call: call, inputs: fields, at: date)
    }
    var message: QinglongAgentConversation.Message {
        .init(id: id, text: title + " · " + statusTitle + "\n" + summary, isUser: false)
    }
    @MainActor
    static func perform(_ call: LanguageModelCall, connection: QinglongConnection,
                        update: (Self) -> Void, operation: () async throws -> String) async throws -> String {
        let raw = call.rawArguments ?? call.arguments.flatMap(AssistantToolJSON.encode) ?? ""
        let arguments = try QinglongAgentTools.redact(raw, connection: connection)
        let safe = LanguageModelCall(id: call.id, name: call.name, arguments: AssistantToolJSON.decode(arguments) as? [String: Any], rawArguments: arguments)
        return try await perform(Self(call: safe, panelName: connection.name), update: update,
            transformResult: { try QinglongAgentTools.redact($0, connection: connection) }, errorResult: { error in
                if let clarification = error as? QinglongAgentClarification {
                    return AssistantToolJSON.encode(["status": "needs_clarification", "missing": clarification.missing])!
                }
                return AssistantToolJSON.encode(["error": error.localizedDescription])!
            }, operation: operation)
    }
}
