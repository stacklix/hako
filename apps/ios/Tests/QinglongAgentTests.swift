import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The Linux suite exercises panel operations and file persistence, never Keychain.
#if os(Linux)
enum SecretAccessibility { case whenUnlocked, afterFirstUnlock }
protocol SecretStorage {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws
}
enum SecureStorage {
    static func namespace(_ name: String) -> any SecretStorage { UnavailableStorage() }
    private struct UnavailableStorage: SecretStorage {
        func read(account: String) throws -> Data? { throw CocoaError(.featureUnsupported) }
        func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws { throw CocoaError(.featureUnsupported) }
    }
}
#endif

private final class AgentPanelProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, String))?
    static func respond(_ handler: @escaping (URLRequest) throws -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let result: Result<(Int, String), Error>
            do { result = .success(try Self.handler!(request)) } catch { result = .failure(error) }
            Self.lock.unlock()
            let (status, text) = try result.get()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct QinglongAgentTests {
    @MainActor
    static func main() async throws {
        try rejectsUnsupportedAndIncompleteOperations()
        try metadataHidesSecrets()
        try conversationsAreIsolatedAndRetainCommitMarker()
        try confirmedCardsRetainReplyAndDetails()
        try cardTransitionsNeverReplayOperations()
        try await submissionRechecksTaskAndRetainsHiddenFields()
        try await changedResourceNeverWrites()
        try await changedFileNeverWrites()
        try await connectionChangeNeverWrites()
        try await runningTaskNeverRunsAgain()
        try await uncertainWriteIsNotRetried()
        try await missingCreatedIDDoesNotRepeatCreate()
        try draftInputsAndCallsPersistIndependently()
        try draftEditingKeepsTargetAndUnchangedFields()
        try activeDraftRestoresWithoutReplayingSubmission()
        try await toolRecordsRetainEveryAttemptAndRedactCredentials()
        try await cancelledToolKeepsItsRecord()
        streamingRepliesRetainContentAcrossRetries()
        try await editedDraftWritesOnlyAfterConfirmation()
        try assertAssistantFileRoundTrip(QinglongAgentConversationFile(url: URL(fileURLWithPath: "Tests/Fixtures/qinglong-assistant.plist")))
        toolFollowUpsRequireTheSameTarget()
        print("Qinglong assistant tests passed (21 groups)")
    }

    static func toolFollowUpsRequireTheSameTarget() {
        func record(_ name: String, missing: Bool) -> QinglongAgentToolCall {
            var fields = ["name": name, "command": "task check.js"]
            if !missing { fields["schedule"] = "0 2 * * *" }
            var value = QinglongAgentToolCall(call: .init(id: "same", name: "propose_change", arguments: ["resource": "crons", "operation": "create", "fields": fields]), panelName: "面板")
            value.finish(result: missing ? #"{"status":"needs_clarification","missing":["Cron"]}"#
                         : #"{"status":"pending_user_confirmation","summary":"新建任务"}"#, elapsed: 0.1)
            return value
        }
        let pending = record("任务一", missing: true), complete = record("任务一", missing: false), other = record("任务二", missing: false)
        let records = [pending.id: pending, complete.id: complete, other.id: other]
        precondition(AssistantToolFollowUp.resolved(timeline: [.init(id: pending.id), .init(id: other.id)], records: records).isEmpty)
        precondition(AssistantToolFollowUp.resolved(timeline: [.init(id: pending.id), .init(id: other.id), .init(id: complete.id)], records: records) == [pending.id: complete.id])
        precondition(pending.statusTitle == "参数待完善" && pending.outputs.first?.value == "Cron")
    }

    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection") } catch {}
    }
    static func draftInputsAndCallsPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = QinglongAgentConversationFile(url: directory.appendingPathComponent("one.plist"))
        let other = QinglongAgentConversationFile(url: directory.appendingPathComponent("two.plist"))
        let draft = proposal(try action(), item: try item(task))
        var record = QinglongAgentToolCall(call: .init(id: "one", name: "list_resources", arguments: ["resource": "crons"]), panelName: "面板一")
        record.finish(result: "{\"total\":0,\"items\":[]}", elapsed: 0.25)
        try file.save(.init(messages: [.init(text: "先核对", isUser: false), record.message], history: Data("[]".utf8),
                            modelKey: "one", format: .openAI, proposal: draft, commitStarted: false))
        let original = try Data(contentsOf: file.url)
        let composer = AssistantComposerDraft(text: "还没发送的补充", attachments: [.init(photoIdentifier: "photo", data: Data([1, 2, 3]))])
        try file.saveComposerDraft(composer); try file.saveToolCalls([record])
        let unchanged = try Data(contentsOf: file.url)
        let restoredComposer = try file.loadComposerDraft(), restoredTools = try file.loadToolCalls()
        precondition(original == unchanged && restoredComposer == composer && restoredTools == [record])
        let isolatedComposer = try other.loadComposerDraft(), isolatedTools = try other.loadToolCalls()
        precondition(isolatedComposer.isEmpty && isolatedTools.isEmpty)
        let saved = try file.load()!
        precondition(saved.proposal?.id == draft.id && saved.messages.map(\.id).last == record.id)
        try file.remove()
        let removed = try file.load(), emptyDraft = try file.loadComposerDraft(), emptyTools = try file.loadToolCalls()
        precondition(removed == nil && emptyDraft.isEmpty && emptyTools.isEmpty)
    }
    static func draftEditingKeepsTargetAndUnchangedFields() throws {
        let draft = proposal(try action(fields: ["name": "草稿名称"]), item: try item(task))
        var values = draft.editingFields
        values["schedule"] = "0 3 * * *"
        let edited = try draft.revising(fields: values, enabled: draft.editingEnabled)
        precondition(edited.id == draft.id && edited.item == draft.item && edited.revision == draft.revision)
        precondition(edited.action.fields == ["name": "草稿名称", "schedule": "0 3 * * *"])
        precondition(edited.editingFields["command"] == "task check.js" && edited.action.enabled == nil)
        var operation = QinglongAgentConversation.Operation(proposal: draft, panelName: "面板")
        precondition(operation.revise(edited) && operation.proposal.action.fields == edited.action.fields)
        precondition(operation.finish(.superseded, result: "新草稿已生成") && !operation.revise(edited) && !operation.begin())
        let initial = try action("envs", "create", id: nil, fields: ["name": "COOKIE", "value": "new-private-value", "remarks": "备注"])
        let correction = try action("envs", "create", id: nil, fields: ["remarks": "更正备注"]).mergingDraft(initial)
        precondition(correction.fields["value"] == "new-private-value" && correction.fields["remarks"] == "更正备注")
        let context = try QinglongAgentConversation.draftContext(proposal(correction, item: nil))
        precondition(context.contains("draft_id") && context.contains("更正备注") && !context.contains("new-private-value"))
        let missing = try action("crons", "create", id: nil, fields: [:]).missing(item: nil)
        precondition(missing == ["执行命令", "Cron 表达式"])
        rejects { _ = try action(fields: ["enabled": "perhaps"]) }
        let remove = proposal(try action("crons", "delete", fields: [:]), item: try item(task))
        rejects { _ = try remove.revising(fields: [:], enabled: true) }
    }
    static func activeDraftRestoresWithoutReplayingSubmission() throws {
        let draft = proposal(try action(), item: try item(task))
        let ticket = UUID()
        let active = draft.restored(revision: ticket, connectionID: draft.connectionID)!
        precondition(active.id == draft.id && active.revision == ticket && active.action.fields == draft.action.fields)
        precondition(draft.restored(revision: ticket, connectionID: "different-panel") == nil)
        var pending = QinglongAgentConversation.Operation(proposal: draft, panelName: "面板")
        pending.restore(active: active)
        precondition(pending.state == .pending && pending.proposal.revision == ticket)
        precondition(pending.begin())
        pending.restore(active: active)
        precondition(pending.state == .unverified && !pending.begin())
        var accepted = QinglongAgentConversation.Operation(proposal: draft, panelName: "面板")
        precondition(accepted.begin() && accepted.finish(.accepted, result: "已接受"))
        accepted.restore(active: active)
        precondition(accepted.state == .accepted && !accepted.begin())
    }
    @MainActor static func toolRecordsRetainEveryAttemptAndRedactCredentials() async throws {
        var connection = QinglongConnection()
        connection.name = "面板"; connection.clientID = "private-client-id"; connection.clientSecret = "secret-credential"
        let call = LanguageModelCall(id: "same-id", name: "read_resource", arguments: ["resource": "scripts", "id": "scripts:a.js", "view": "file"])
        var records: [QinglongAgentToolCall] = []
        for _ in 0..<2 {
            let result = try await QinglongAgentToolCall.perform(call, connection: connection, update: { records.append($0) }) {
                precondition(records.last?.state == .running)
                return "{\"content\":\"secret-credential\",\"totalCharacters\":17}"
            }
            precondition(!result.contains("secret-credential") && records.last?.result == result)
        }
        precondition(records.count == 4 && records[0].id != records[2].id && records[0].id == records[1].id)
        precondition(records[1].state == .succeeded && records[1].elapsed! >= 0)
        let missing = try await QinglongAgentToolCall.perform(call, connection: connection, update: { records.append($0) }) {
            throw QinglongAgentClarification(missing: ["执行命令", "Cron 表达式"])
        }
        precondition(records.last?.state == .needsClarification && missing.contains("Cron") && records.last?.outputs.first?.value.contains("执行命令") == true)
        _ = try await QinglongAgentToolCall.perform(call, connection: connection, update: { records.append($0) }) {
            throw QinglongFailure(message: "secret-credential 查询失败")
        }
        precondition(records.last?.state == .failed && records.last?.result?.contains("secret-credential") == false)
        let bad = LanguageModelCall(id: "bad", name: "list_resources", arguments: nil, rawArguments: "{\"resource\":")
        _ = try await QinglongAgentToolCall.perform(bad, connection: connection, update: { records.append($0) }) { throw QinglongAgentTools.invalid() }
        precondition(records.last?.arguments == bad.rawArguments && records.last?.state == .failed)
        _ = try await QinglongAgentToolCall.perform(call, connection: connection, update: { records.append($0) }) {
            "{\"status\":\"pending_user_confirmation\",\"summary\":\"修改任务\"}"
        }
        precondition(records.last?.outputs.last?.value.contains("尚未提交") == true)
        precondition(records[0].restored().state == .interrupted && records[0].restored().elapsed == nil)
    }
    @MainActor static func cancelledToolKeepsItsRecord() async throws {
        let call = LanguageModelCall(id: "cancel", name: "list_resources", arguments: ["resource": "crons"])
        var records: [QinglongAgentToolCall] = []
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let running = Task {
            try await QinglongAgentToolCall.perform(call, connection: .init(), update: { records.append($0) }) {
                continuation.yield(()); continuation.finish()
                try await Task.sleep(for: .seconds(30))
                return "{}"
            }
        }
        for await _ in ready { break }
        running.cancel()
        do { _ = try await running.value; preconditionFailure("Cancelled call completed") } catch is CancellationError {}
        precondition(records.count == 2 && records.last?.state == .cancelled && records.last?.result == nil)
    }
    static func streamingRepliesRetainContentAcrossRetries() {
        var stream = QinglongAgentStream()
        let firstID = stream.id
        stream.beginResponse(continuing: false)
        stream.receive(.init(text: "<p>先核对任务</p>", thinking: "核对目标"))
        precondition(stream.progressTitle(.waitingForResponse).contains("请求已发送"))
        _ = stream.progressTitle(.retrying(1))
        stream.receive(.init())
        precondition(stream.text.contains("核对任务") && stream.thinking.contains("核对目标"))
        stream.receive(.init(text: "<p>任务已查到</p>", thinking: "检查结果"))
        stream.finishResponse("<p>任务已查到</p>")
        let saved = stream.message(incomplete: false)!
        precondition(saved.id == firstID && saved.html?.fragment.contains("任务已查到") == true)
        let next = QinglongAgentStream()
        precondition(next.id != saved.id && saved.html?.fragment.contains("任务已查到") == true)
    }
    @MainActor static func editedDraftWritesOnlyAfterConfirmation() async throws {
        var writes: [String] = []
        let panel = try client { request in
            if request.httpMethod == "GET" { return (200, "{\"code\":200,\"data\":[" + task + "]}") }
            writes.append(request.url!.path)
            if request.url!.path == "/open/crons" {
                let body = try JSONDecoder().decode(QinglongJSON.self, from: request.httpBody!)
                precondition(body["schedule"].text == "0 4 * * *" && body["task_before"].text == "private hook")
                precondition(body["enabled"] == .null)
                return (200, "{\"code\":200,\"data\":" + task + "}")
            }
            precondition(request.url!.path == "/open/crons/disable")
            return (200, "{\"code\":200}")
        }
        let draft = proposal(try action(), item: try item(task))
        var fields = draft.editingFields; fields["schedule"] = "0 4 * * *"
        let edited = try draft.revising(fields: fields, enabled: false)
        precondition(writes.isEmpty && edited.action.enabled == false)
        try await edited.submit(using: panel, ensureSession: {})
        precondition(writes == ["/open/crons", "/open/crons/disable"])
    }
    static func action(_ resource: String = "crons", _ operation: String = "update", id: String? = "crons:1", fields: [String: String] = ["name": "新名称"]) throws -> QinglongAgentAction {
        var args: [String: Any] = ["resource": resource, "operation": operation, "fields": fields]
        if let id { args["id"] = id }
        return try .init(args)
    }
    static func item(_ raw: String, resource: QinglongResource = .tasks) throws -> QinglongItem {
        .init(resource: resource, raw: try JSONDecoder().decode(QinglongJSON.self, from: Data(raw.utf8)))
    }
    static let task = #"{"id":1,"name":"每日检查","command":"task check.js","schedule":"0 2 * * *","status":1,"task_before":"private hook","labels":["keep"]}"#
    static func rejectsUnsupportedAndIncompleteOperations() throws {
        rejects { _ = try action("logs", "delete", id: "logs:a.log", fields: [:]) }
        rejects { _ = try action("dependencies", "run", fields: [:]) }
        rejects { _ = try action("configs", "create", id: nil, fields: ["content": "x"]) }
        rejects { _ = try action(fields: ["Authorization": "steal"]) }
        rejects { _ = try action(id: nil) }
        rejects { _ = try QinglongAgentAction(["resource": "crons", "operation": "run", "id": 1]) }
        rejects { _ = try QinglongAgentAction(["resource": "crons", "operation": "run", "id": "crons:1", "endpoint": "/admin"]) }
        rejects { try action("scripts", "create", id: nil, fields: ["filename": "../bad.js", "content": "x"]).validate(item: nil) }
        rejects { try action("crons", "create", id: nil, fields: ["name": "缺少命令"]).validate(item: nil) }
        rejects { try action("subscriptions", "create", id: nil, fields: ["url": "https://example.test/r", "alias": "repo"]).validate(item: nil) }
        rejects { _ = try QinglongAgentTools.integer(["offset": true], "offset", default: 0, range: 0...50) }
        rejects { _ = try QinglongAgentTools.integer(["offset": 1.5], "offset", default: 0, range: 0...50) }
        let original = try item(task)
        try action().validate(item: original)
        try action("scripts", "create", id: nil, fields: ["filename": "empty.js", "content": ""]).validate(item: nil)
    }
    static func metadataHidesSecrets() throws {
        let environment = try item(#"{"id":2,"name":"COOKIE","value":"secret-cookie","remarks":"账户一","status":0}"#, resource: .envs)
        let subscription = try item(#"{"id":3,"name":"仓库","url":"https://user:secret@example.test/r","sub_before":"private hook"}"#, resource: .subscriptions)
        let text = try QinglongAgentTools.json([QinglongAgentTools.row(environment), QinglongAgentTools.row(subscription)])
        precondition(!text.contains("secret") && !text.contains("private hook") && text.contains("COOKIE"))
        var connection = QinglongConnection()
        connection.clientID = "client-abc"; connection.clientSecret = "secret/with\"quote"
        connection.headers = [.init(name: "X-Test", value: "header-secret")]
        let result = try QinglongAgentTools.redact(QinglongAgentTools.json(["content": "client-abc secret/with\"quote header-secret"]), connection: connection)
        let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: String]
        precondition(!parsed["content"]!.contains("secret") && !parsed["content"]!.contains("client-abc"))
    }
    static func conversationsAreIsolatedAndRetainCommitMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = QinglongAgentConversationFile(url: directory.appendingPathComponent("one.plist"))
        let other = QinglongAgentConversationFile(url: directory.appendingPathComponent("two.plist"))
        let proposal = QinglongAgentProposal(revision: UUID(), connectionID: "one", action: try action(), item: try item(task), originalContent: nil)
        let messages: [QinglongAgentConversation.Message] = [.init(text: "查询", isUser: true, images: [Data([1,2])]), .init(text: "", isUser: false, html: AssistantHTML("<p>已生成预览</p>"))]
        try file.save(.init(messages: messages, history: Data("[]".utf8), modelKey: "model", format: .openAI, proposal: proposal, commitStarted: true))
        let restored = try file.load()!
        precondition(restored.commitStarted && restored.proposal?.id == proposal.id && restored.proposal?.item == proposal.item)
        precondition(restored.messages.first?.images == [Data([1,2])] && restored.messages.last?.html?.fragment == "<p>已生成预览</p>")
        let isolated = try other.load(); precondition(isolated == nil)
        try file.remove(); try file.remove()
    }

    static func confirmedCardsRetainReplyAndDetails() throws {
        let draft = proposal(try action("crons", "create", id: nil,
            fields: ["name": "连通性检查", "command": "curl --fail https://example.test", "schedule": "*/5 * * * *"]), item: nil)
        let explanation = AssistantHTML("<p>命令会读取进程中的代理环境变量。</p>")!
        var message = QinglongAgentConversation.Message(id: draft.id, text: "", isUser: false, html: explanation,
            operation: .init(proposal: draft, panelName: "测试面板"))
        precondition(message.operation?.begin() == true)
        precondition(message.operation?.finish(.accepted, result: "创建任务的请求已被面板接受。") == true)
        precondition(message.id == draft.id && message.html?.fragment == explanation.fragment)
        precondition(message.operation?.proposal.action.fields == draft.action.fields)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = QinglongAgentConversationFile(url: directory.appendingPathComponent("retained.plist"))
        try file.save(.init(messages: [message], history: Data("[]".utf8), modelKey: "model", format: .openAI,
                            proposal: nil, commitStarted: false))
        let saved = try file.load()!
        precondition(saved.proposal == nil && saved.messages.count == 1)
        let restored = saved.messages[0]
        precondition(restored.id == draft.id && restored.html?.fragment == explanation.fragment)
        precondition(restored.operation?.state == .accepted && restored.operation?.result == message.operation?.result)
        precondition(restored.operation?.proposal.action.fields["command"] == "curl --fail https://example.test")
        precondition(restored.operation?.proposal.action.fields["schedule"] == "*/5 * * * *")
    }

    static func cardTransitionsNeverReplayOperations() throws {
        let draft = proposal(try action(), item: try item(task))
        var pending = QinglongAgentConversation.Operation(proposal: draft, panelName: "测试面板")
        precondition(!pending.finish(.accepted, result: "未点击确认"))
        precondition(pending.begin() && !pending.begin())
        var interrupted = pending
        interrupted.restore()
        precondition(interrupted.state == .unverified && !interrupted.begin())
        precondition(pending.finish(.accepted, result: "已接受") && !pending.begin())
        pending.restore()
        precondition(pending.state == .accepted && pending.result == "已接受")
        var stale = QinglongAgentConversation.Operation(proposal: draft, panelName: "测试面板")
        stale.restore()
        precondition(stale.state == .expired && !stale.begin())
        var discarded = QinglongAgentConversation.Operation(proposal: draft, panelName: "测试面板")
        precondition(discarded.finish(.discarded, result: "未提交") && !discarded.begin())
        for state in [QinglongAgentConversation.Operation.State.failed, .unverified] {
            var failed = QinglongAgentConversation.Operation(proposal: draft, panelName: "测试面板")
            precondition(failed.begin() && failed.finish(state, result: "请先核对远端状态") && !failed.begin())
            precondition(failed.proposal.id == draft.id)
        }
    }

    static func client(_ handler: @escaping (URLRequest) throws -> (Int, String)) throws -> QinglongClient {
        AgentPanelProtocol.respond { request in
            if request.url!.path == "/open/auth/token" { return (200, #"{"code":200,"data":{"token":"test-token","expiration":9999999999}}"#) }
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentPanelProtocol.self]
        var connection = QinglongConnection()
        connection.address = "https://panel.test"; connection.clientID = "test-id"; connection.clientSecret = "test-secret"
        return try .init(connection: connection, session: URLSession(configuration: configuration))
    }
    static func proposal(_ action: QinglongAgentAction, item: QinglongItem?, content: String? = nil) -> QinglongAgentProposal {
        .init(revision: UUID(), connectionID: "panel", action: action, item: item, originalContent: content)
    }
    @MainActor static func submissionRechecksTaskAndRetainsHiddenFields() async throws {
        var writes = 0
        let panel = try client { request in
            if request.httpMethod == "GET" { return (200, "{\"code\":200,\"data\":[" + task + "]}") }
            writes += 1
            let body = try JSONDecoder().decode(QinglongJSON.self, from: request.httpBody!)
            precondition(body["name"].text == "新名称" && body["task_before"].text == "private hook" && body["labels"].array?.count == 1)
            precondition(request.httpMethod == "PUT" && request.url!.path == "/open/crons")
            return (200, "{\"code\":200,\"data\":" + task + "}")
        }
        let preview = proposal(try action(), item: try item(task))
        precondition(writes == 0)
        try await preview.submit(using: panel, ensureSession: {})
        precondition(writes == 1)
    }
    @MainActor static func expectNoWrite(_ preview: QinglongAgentProposal, response: String, content: String? = nil, check: @escaping () throws -> Void = {}) async throws {
        var writes = 0
        let panel = try client { request in
            if request.httpMethod != "GET" { writes += 1; return (200, #"{"code":200,"data":{}}"#) }
            if request.url!.path.hasSuffix("/detail"), let content { return (200, try QinglongAgentTools.json(["code": 200, "data": content])) }
            return (200, "{\"code\":200,\"data\":[" + response + "]}")
        }
        do { try await preview.submit(using: panel, ensureSession: check); preconditionFailure("Should not submit") }
        catch {}
        precondition(writes == 0)
    }
    @MainActor static func changedResourceNeverWrites() async throws {
        try await expectNoWrite(proposal(try action(), item: try item(task)), response: task.replacingOccurrences(of: "task check.js", with: "task changed.js"))
    }
    @MainActor static func changedFileNeverWrites() async throws {
        let file = try item(#"{"title":"check.js","parent":"","type":"file"}"#, resource: .scripts)
        try await expectNoWrite(proposal(try action("scripts", id: file.id, fields: ["content": "new"]), item: file, content: "original"), response: #"{"title":"check.js","type":"file"}"#, content: "changed by another client")
    }
    @MainActor static func connectionChangeNeverWrites() async throws {
        var checks = 0
        try await expectNoWrite(proposal(try action(), item: try item(task)), response: task, check: {
            checks += 1
            if checks > 1 { throw CancellationError() }
        })
    }
    @MainActor static func runningTaskNeverRunsAgain() async throws {
        let run = try action("crons", "run", fields: [:])
        try await expectNoWrite(proposal(run, item: try item(task)), response: task.replacingOccurrences(of: "\"status\":1", with: "\"status\":0"))
    }
    @MainActor static func uncertainWriteIsNotRetried() async throws {
        var writes = 0
        let panel = try client { request in
            if request.httpMethod == "GET" { return (200, "{\"code\":200,\"data\":[" + task + "]}") }
            writes += 1; throw URLError(.timedOut)
        }
        do { try await proposal(try action(), item: try item(task)).submit(using: panel, ensureSession: {}); preconditionFailure("Expected unknown outcome") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        precondition(writes == 1)
    }
    @MainActor static func missingCreatedIDDoesNotRepeatCreate() async throws {
        var writes = 0
        let panel = try client { request in
            if request.httpMethod == "GET" { return (200, #"{"code":200,"data":[]}"#) }
            writes += 1; return (200, #"{"code":200,"data":{}}"#)
        }
        let create = try action("crons", "create", id: nil, fields: ["command": "task new.js", "schedule": "0 2 * * *"])
        do { try await proposal(create, item: nil).submit(using: panel, ensureSession: {}); preconditionFailure("Expected incomplete result") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        precondition(writes == 1)
    }
}
