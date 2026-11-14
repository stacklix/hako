import Foundation

extension QinglongAgentProposal {
    @MainActor
    func submit(using client: QinglongClient, ensureSession: () throws -> Void) async throws {
        try ensureSession()
        let action = self.action
        var currentItem = item
        let entries = try await client.list(action.resource)
        try ensureSession()
        if let original = item {
            guard let current = entries.first(where: { $0.id == original.id }), QinglongAgentProposal.unchanged(original, current) else {
                throw QinglongFailure(message: "远端资源已改变，未提交操作。请重新生成预览。")
            }
            currentItem = current
            if let content = originalContent {
                guard try await client.file(current) == content else { throw QinglongFailure(message: "远端文件已改变，未保存。请重新读取。") }
            }
        } else if action.resource == .scripts { try Self.checkNewScript(action, entries: entries) }
        try ensureSession()
        try action.validate(item: currentItem)
        switch action.kind {
        case .create, .update:
            switch action.resource {
            case .tasks:
                let result = try await client.saveTask(item, fields: action.contentFields, enabled: action.enabled)
                if let issue = result.stateError { throw QinglongFailure(message: issue, outcomeUnknown: true) }
            case .envs:
                let result = try await client.saveEnvironment(item, fields: action.contentFields, enabled: action.enabled ?? !(item?.disabled ?? false))
                if let issue = result.stateError { throw QinglongFailure(message: issue, outcomeUnknown: true) }
            case .subscriptions:
                var fields = action.fields
                if action.kind == .create { fields["type"] = "public-repo"; fields["schedule_type"] = "crontab" }
                let body = item?.editPayload(fields) ?? .fields(fields)
                _ = try await client.call(["subscriptions"], method: action.kind == .create ? "POST" : "PUT", body: body)
            case .scripts, .configs:
                let item = currentItem ?? QinglongItem(resource: .scripts, raw: .fields(["title": action.fields["filename"] ?? "", "parent": action.fields["directory"] ?? ""]))
                try await client.saveFile(item, content: action.fields["content"] ?? "", creating: action.kind == .create)
            default: throw QinglongAgentTools.invalid()
            }
        case .delete:
            guard let item = item else { throw QinglongAgentTools.invalid() }
            try await client.delete(item)
        default:
            guard let item = item else { throw QinglongAgentTools.invalid() }
            try await client.action(action.kind.rawValue, item: item)
        }
    }
    static func checkNewScript(_ action: QinglongAgentAction, entries: [QinglongItem]) throws {
        let directory = action.fields["directory"] ?? ""
        let path = [directory, action.fields["filename"] ?? ""].filter { !$0.isEmpty }.joined(separator: "/")
        guard !entries.contains(where: { $0.filePath == path }), directory.isEmpty || entries.contains(where: { $0.isDirectory && $0.filePath == directory }) else {
            throw QinglongFailure(message: "已有同名文件，或目标目录已不存在。请重新查询。")
        }
    }
}
