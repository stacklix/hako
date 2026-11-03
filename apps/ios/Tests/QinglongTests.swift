import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class QinglongMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, String))?
    static func respond(_ block: @escaping (URLRequest) throws -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; handler = block
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
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@MainActor private final class QinglongRefreshBarrier {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct QinglongTests {
    @MainActor static func refreshHandoff() async {
        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<10_000 {
                if condition() { return }
                await Task.yield()
            }
            preconditionFailure("Refresh task did not reach its checkpoint")
        }
        let coordinator = QinglongRefreshCoordinator()
        let cancelledRead = QinglongRefreshBarrier()
        var reads = 0, replacementStarted = false, rendered = false
        let first = Task { await coordinator.run(.scripts) { reads += 1; await cancelledRead.pause() } }
        await waitUntil { cancelledRead.entered }
        first.cancel()
        let replacement = Task {
            replacementStarted = true
            await coordinator.run(.scripts) { reads += 1; rendered = true }
        }
        await waitUntil { replacementStarted }
        for _ in 0..<10 { await Task.yield() }
        precondition(!rendered, "Replacement must wait until the cancelled reader releases its slot")
        cancelledRead.release()
        await first.value; await replacement.value
        precondition(reads == 2 && rendered, "Entering scripts must recover without opening the create sheet")

        let sharedRead = QinglongRefreshBarrier()
        var followerStarted = false, duplicateReads = 0
        let owner = Task { await coordinator.run(.scripts) { await sharedRead.pause() } }
        await waitUntil { sharedRead.entered }
        let follower = Task { followerStarted = true; await coordinator.run(.scripts) { duplicateReads += 1 } }
        await waitUntil { followerStarted }
        for _ in 0..<10 { await Task.yield() }
        sharedRead.release()
        await owner.value; await follower.value
        precondition(duplicateReads == 0, "Concurrent active readers share the completed request")

        let pendingRead = QinglongRefreshBarrier()
        var waiterStarted = false
        let pendingOwner = Task { await coordinator.run(.scripts) { await pendingRead.pause() } }
        await waitUntil { pendingRead.entered }
        let waiter = Task { waiterStarted = true; await coordinator.run(.scripts) { preconditionFailure("Cancelled waiter loaded data") } }
        await waitUntil { waiterStarted }
        waiter.cancel(); await waiter.value
        pendingRead.release(); await pendingOwner.value

        let oldConnection = QinglongRefreshBarrier(), newConnection = QinglongRefreshBarrier()
        let old = Task { await coordinator.run(.scripts) { await oldConnection.pause() } }
        await waitUntil { oldConnection.entered }
        coordinator.invalidate()
        let current = Task { await coordinator.run(.scripts) { await newConnection.pause() } }
        await waitUntil { newConnection.entered }
        oldConnection.release(); await old.value
        var currentFollowerStarted = false
        let currentFollower = Task { currentFollowerStarted = true; await coordinator.run(.scripts) { preconditionFailure("Old connection completion released the new request") } }
        await waitUntil { currentFollowerStarted }
        for _ in 0..<10 { await Task.yield() }
        newConnection.release(); await current.value; await currentFollower.value
    }
    static func main() async throws {
        await refreshHandoff()
        let decoder = JSONDecoder()
        func json(_ value: String) throws -> QinglongJSON { try decoder.decode(QinglongJSON.self, from: Data(value.utf8)) }
        func reject(_ connection: QinglongConnection) {
            do { _ = try connection.normalized(); fatalError("Invalid connection accepted") } catch is QinglongFailure {} catch { fatalError("Unexpected error") }
        }
        var connection = QinglongConnection(name: "测试面板", address: "https://panel.example.com/panel/open/", clientID: "demo+id", clientSecret: "test?secret&=", headers: [QinglongHeader(name: "X-Service", value: "qinglong")])
        connection = try connection.normalized()
        precondition(connection.address == "https://panel.example.com/panel")
        let request = try connection.request(["envs"])
        precondition(request.url?.absoluteString == "https://panel.example.com/panel/open/envs")
        precondition(request.value(forHTTPHeaderField: "X-Service") == "qinglong")
        for name in ["Authorization", "host", "Content-Type", "Accept", "bad header", "X-Test\n"] {
            var invalid = connection; invalid.headers = [QinglongHeader(name: name == "X-Test\n" ? "X\nTest" : name, value: "value")]; reject(invalid)
        }
        var invalid = connection; invalid.headers = [QinglongHeader(name: "X-Test", value: "injected\r\nValue")]; reject(invalid)
        invalid = connection; invalid.headers += [QinglongHeader(name: "x-service", value: "duplicate")]; reject(invalid)
        invalid = connection; invalid.headers = [QinglongHeader()]; let emptyHeaders = try invalid.normalized(); precondition(emptyHeaders.headers.isEmpty)
        for address in ["http://panel.local", "https://u:p@panel.local", "https://panel.local?secret=a", "https://panel.local/#login", "https://panel.local/a/../b"] {
            invalid = connection; invalid.address = address; reject(invalid)
        }
        for (name, directory) in [("../file", ""), ("file.py", "../scripts"), ("file.py", "/absolute"), ("file\n.py", "")] {
            do { try QinglongParsing.file(name, directory: directory); fatalError("Unsafe file accepted") } catch is QinglongFailure {}
        }
        let tree = try json(#"[{"title":"repo","type":"directory","children":[{"title":"demo.py","parent":"repo","key":"repo/demo.py","type":"file"}]}]"#)
        let files = try QinglongParsing.items(tree, resource: .scripts)
        precondition(files.count == 2 && files[0].isDirectory && files[1].filename == "demo.py" && files[1].directory == "repo")
        let dependencies = try QinglongParsing.items(try json(#"[{"id":1,"name":"axios","type":0,"status":1},{"id":2,"name":"lxml","type":1,"status":2},{"id":3,"name":"curl","type":2,"status":5},{"id":4,"name":"future","type":99,"status":99}]"#), resource: .dependencies)
        precondition(dependencies[0].dependencyStatus == .installed && dependencies[0].subtitle == "Node.js")
        precondition(dependencies[1].dependencyStatus == .installFailed && dependencies[1].subtitle == "Python")
        precondition(dependencies.filter { $0.dependencyStatus?.failed == true }.map(\.numberID) == [2, 3], "Both install and removal failures need attention")
        precondition(dependencies[3].dependencyStatus == nil && dependencies[3].subtitle == "未知类型", "Unknown server enum values must not imply a known type or successful install")
        let sub = QinglongItem(resource: .subscriptions, raw: try json(#"{"id":7,"type":"private-repo","url":"https://repo.example.com","alias":"repo","schedule_type":"interval","interval_schedule":{"type":"hours","value":2},"is_disabled":1,"autoAddCron":1,"pull_option":{"username":"u","password":"p"},"status":1}"#))
        precondition(sub.disabled)
        let edited = sub.editPayload(["name":"renamed"])
        precondition(edited["interval_schedule"]["value"].int == 2 && edited["pull_option"]["password"].text == "p" && edited["autoAddCron"] == .bool(true) && edited["status"] == .null)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QinglongMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try QinglongClient(connection: connection, session: session)
        var tokenRequests = 0, listRequests = 0
        QinglongMockProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "X-Service") == "qinglong")
            if request.url!.path.hasSuffix("auth/token") {
                tokenRequests += 1
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query.first { $0.name == "client_id" }?.value == connection.clientID)
                precondition(query.first { $0.name == "client_secret" }?.value == connection.clientSecret)
                return (200, #"{"code":200,"data":{"token":"test-access-token","expiration":9999999999}}"#)
            }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
            listRequests += 1
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            return (200, "{\"code\":200,\"data\":{\"data\":[{\"id\":\(page),\"name\":\"task-\(page)\",\"status\":1}],\"total\":2}}")
        }
        let list = try await client.list(.tasks)
        precondition(list.count == 2 && listRequests == 2 && tokenRequests == 1)
        _ = try await client.list(.tasks)
        precondition(tokenRequests == 1, "Token must be cached")
        let manualTask = QinglongItem(resource: .tasks, raw: try json(#"{"id":17,"name":"manual-only","status":1,"isDisabled":1}"#))
        let disabledRunning = QinglongItem(resource: .tasks, raw: try json(#"{"id":17,"status":0,"isDisabled":1}"#))
        let disabledQueued = QinglongItem(resource: .tasks, raw: try json(#"{"id":17,"status":3,"isDisabled":1}"#))
        precondition(manualTask.disabled && !manualTask.running)
        precondition(disabledRunning.disabled && disabledRunning.running && disabledRunning.stateText == "运行中", "Automatic scheduling being disabled must not hide an active manual run")
        precondition(disabledQueued.disabled && disabledQueued.queued && disabledQueued.stateText == "排队中")
        var manualRequests = [String]()
        QinglongMockProtocol.respond { request in
            manualRequests.append(request.url!.path)
            precondition(request.httpMethod == "PUT" && request.url!.path.hasSuffix("crons/run"))
            let payload = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            precondition(payload == .array([.number(17)]))
            return (200, #"{"code":200}"#)
        }
        try await client.action("run", item: manualTask)
        precondition(manualRequests == ["/panel/open/crons/run"] && manualTask.disabled, "Manual run submits once and must not enable automatic scheduling")
        var writes = 0
        QinglongMockProtocol.respond { request in
            writes += 1
            precondition(request.httpMethod == "PUT")
            throw URLError(.timedOut)
        }
        do { try await client.action("run", item: list[0]); fatalError("Timeout accepted") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        precondition(writes == 1, "Never retry an uncertain mutation")
        QinglongMockProtocol.respond { _ in (200, #"{"code":403,"message":"secret must not be echoed"}"#) }
        do { _ = try await client.list(.envs); fatalError("Business error accepted") }
        catch let failure as QinglongFailure { precondition(failure.status == 403 && !failure.message.contains("secret")) }
        QinglongMockProtocol.respond { _ in (500, "not json") }
        do { try await client.action("run", item: list[0]); fatalError("Server error accepted") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        QinglongMockProtocol.respond { _ in (200, #"{"code":401}"#) }
        do { _ = try await client.list(.envs); fatalError("Expired token accepted") } catch is QinglongFailure {}
        tokenRequests = 0
        QinglongMockProtocol.respond { request in
            if request.url!.path.hasSuffix("auth/token") { tokenRequests += 1; return (200, #"{"code":200,"data":{"token":"new","expiration":9999999999}}"#) }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
            return (200, #"{"code":200,"data":[]}"#)
        }
        _ = try await client.list(.envs)
        precondition(tokenRequests == 1, "Next explicit request obtains a new token")
        var bodyChecked = false
        QinglongMockProtocol.respond { request in
            precondition(request.httpMethod == "PUT" && request.url!.path.hasSuffix("scripts"))
            if let body = QinglongMockProtocol.body(request) { let payload = try json(String(decoding: body, as: UTF8.self)); precondition(payload["filename"].text == "demo.py" && payload["content"].text == ""); bodyChecked = true }
            return (200, #"{"code":200}"#)
        }
        try await client.saveFile(files[1], content: "")
        precondition(bodyChecked, "Empty file content must be sent explicitly")
        try await scriptBrowser(client)
        try await directoryCreation(client)
        let failure = QinglongOutcome(raw: try json(#"{"status":1,"exit_code":1,"started_at":1793670000}"#))
        let success = QinglongOutcome(raw: try json(#"{"status":1,"exit_code":0}"#))
        let unknown = QinglongOutcome(raw: try json(#"{"status":1}"#))
        precondition(failure.failed && !failure.succeeded && success.succeeded && !success.failed)
        precondition(!unknown.succeeded && !unknown.failed, "Missing exit code must not imply success")
        QinglongMockProtocol.respond { request in
            precondition(request.url!.path.hasSuffix("crons/1/instances"))
            return (200, #"{"code":200,"data":[{"status":1,"exit_code":0,"started_at":100},{"status":3,"started_at":200}]}"#)
        }
        let outcome = try await client.latestOutcome(list[0])
        precondition(outcome?.failed == true, "Use the newest real instance, independent of response ordering")
        var environmentRequests = [String]()
        QinglongMockProtocol.respond { request in
            let path = request.url!.path
            environmentRequests.append(request.httpMethod! + " " + path)
            if path.hasSuffix("envs/disable") {
                let ids = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
                precondition(ids == .array([.number(42)]))
                return (200, #"{"code":200}"#)
            }
            precondition(request.httpMethod == "POST")
            let body = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            precondition(body.array?.first?["name"].text == "TEST_ENV" && body.array?.first?["status"] == .null)
            return (200, #"{"code":200,"data":[{"id":42,"name":"TEST_ENV","value":"demo","status":0}]}"#)
        }
        let fields = ["name": "TEST_ENV", "value": "demo", "remarks": "test"]
        let disabledEnvironment = try await client.saveEnvironment(nil, fields: fields, enabled: false)
        precondition(disabledEnvironment.item?.numberID == 42 && disabledEnvironment.stateError == nil && environmentRequests.count == 2)
        environmentRequests = []
        let enabledEnvironment = try await client.saveEnvironment(nil, fields: fields, enabled: true)
        precondition(enabledEnvironment.stateError == nil && environmentRequests.count == 1, "Default enabled creation requires no extra mutation")
        QinglongMockProtocol.respond { request in
            if request.url!.path.hasSuffix("envs/enable") { return (403, #"{"code":403}"#) }
            precondition(request.httpMethod == "PUT")
            return (200, #"{"code":200,"data":{"id":42,"name":"TEST_ENV","value":"demo","status":1}}"#)
        }
        let oldEnvironment = QinglongItem(resource: .envs, raw: try json(#"{"id":42,"status":1}"#))
        let partial = try await client.saveEnvironment(oldEnvironment, fields: fields, enabled: true)
        precondition(partial.item?.numberID == 42 && partial.stateError != nil, "Preserve the saved ID when only the state operation fails")
        QinglongMockProtocol.respond { _ in (200, #"{"code":200,"data":[]}"#) }
        let missingID = try await client.saveEnvironment(nil, fields: fields, enabled: false)
        precondition(missingID.item == nil && missingID.stateError != nil, "Never invent an ID or repeat creation after an incomplete save response")
        let taskFields = ["name": "edited", "command": "task demo.js", "schedule": "0 2 * * *"]
        let oldTask = QinglongItem(resource: .tasks, raw: try json(#"{"id":51,"name":"old","command":"old.js","schedule":"0 1 * * *","isDisabled":0,"labels":["keep"],"extra_schedules":[{"schedule":"0 3 * * *"}],"work_dir":"repo"}"#))
        var taskRequests = [String]()
        QinglongMockProtocol.respond { request in
            taskRequests.append(request.httpMethod! + " " + request.url!.path)
            let body = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            if request.url!.path.hasSuffix("crons/disable") {
                precondition(body == .array([.number(51)]))
            } else {
                precondition(request.httpMethod == "PUT" && body["id"].int == 51 && body["command"].text == "task demo.js")
                precondition(body["labels"].array?.first?.text == "keep" && body["extra_schedules"].array?.first?["schedule"].text == "0 3 * * *" && body["work_dir"].text == "repo")
                precondition(body["isDisabled"] == .null && body["status"] == .null, "State must use its separate endpoint")
            }
            return (200, #"{"code":200,"data":{"id":51,"isDisabled":0}}"#)
        }
        let taskSaved = try await client.saveTask(oldTask, fields: taskFields, enabled: false)
        precondition(taskSaved.stateError == nil && taskRequests == ["PUT /panel/open/crons", "PUT /panel/open/crons/disable"])
        taskRequests = []
        _ = try await client.saveTask(oldTask, fields: taskFields, enabled: nil)
        precondition(taskRequests == ["PUT /panel/open/crons"], "Unchanged automatic execution must not trigger extra scheduler mutations")
        taskRequests = []
        var denyState = true
        QinglongMockProtocol.respond { request in
            taskRequests.append(request.httpMethod! + " " + request.url!.path)
            if request.url!.path.hasSuffix("crons/disable") { return (denyState ? 403 : 200, denyState ? #"{"code":403}"# : #"{"code":200}"#) }
            return (200, #"{"code":200,"data":{"id":52,"isDisabled":0}}"#)
        }
        let taskPartial = try await client.saveTask(nil, fields: taskFields, enabled: false)
        precondition(taskPartial.item?.numberID == 52 && taskPartial.stateError != nil)
        denyState = false
        _ = try await client.saveTask(taskPartial.item, fields: taskFields, enabled: false)
        precondition(taskRequests == ["POST /panel/open/crons", "PUT /panel/open/crons/disable", "PUT /panel/open/crons", "PUT /panel/open/crons/disable"], "Retry a partially saved task by ID, never create it twice")
        var uncertainCreates = 0
        QinglongMockProtocol.respond { request in
            precondition(request.httpMethod == "POST"); uncertainCreates += 1
            throw URLError(.timedOut)
        }
        let uncertainTask = try await client.saveTask(nil, fields: taskFields, enabled: false)
        precondition(uncertainTask.item == nil && uncertainTask.stateError != nil && uncertainCreates == 1, "An uncertain create must block retries until the list is checked")
        var incompleteCreates = 0
        QinglongMockProtocol.respond { request in
            precondition(request.httpMethod == "POST"); incompleteCreates += 1
            return (200, #"{"code":200,"data":{}}"#)
        }
        let incompleteTask = try await client.saveTask(nil, fields: taskFields, enabled: false)
        precondition(incompleteTask.item == nil && incompleteTask.stateError != nil && incompleteCreates == 1)
        QinglongMockProtocol.respond { request in
            precondition(request.httpMethod == "POST")
            let body = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            precondition(body["name"] == .null && body["command"].text == "task demo.js", "An empty optional name must be omitted from create, as required by the server schema")
            return (200, #"{"code":200,"data":{"id":53}}"#)
        }
        _ = try await client.saveTask(nil, fields: taskFields.merging(["name":""]) { _, new in new }, enabled: nil)
        var rejectedSaves = 0
        QinglongMockProtocol.respond { _ in rejectedSaves += 1; return (403, #"{"code":403}"#) }
        do { _ = try await client.saveTask(oldTask, fields: taskFields, enabled: false); fatalError("Rejected task save accepted") }
        catch is QinglongFailure {}
        precondition(rejectedSaves == 1, "Never change automatic execution if content save fails")
        precondition(QinglongPermissionResult(error: QinglongFailure(message: "denied", status: 403)) == .denied("denied"))
        precondition(QinglongPermissionResult(error: QinglongFailure(message: "expired", status: 401)) == .failed("expired"), "Authentication failure is not a module permission denial")
        precondition(QinglongPermissionResult(error: QinglongFailure(message: "unsupported", status: 404)) == .failed("unsupported"))
        if case .failed = QinglongPermissionResult(error: URLError(.timedOut)) {} else { fatalError("Network failure must not imply permission denial") }
        precondition(!QinglongPermissionResult.pending.completed && !QinglongPermissionResult.checking.completed && QinglongPermissionResult.readable.completed)
        for (schedule, description) in [("0 2 * * *", "每天 02:00"), ("0 0 3 * * 0", "每周日 03:00"), ("*/5 * * * *", "每 5 分钟"), ("30 0 2 * * *", "自定义计划"), ("0 25 * * *", "自定义计划")] {
            precondition(QinglongItem(resource: .tasks, raw: .fields(["schedule": schedule])).scheduleDescription == description)
        }
        var logReads = 0
        QinglongMockProtocol.respond { request in
            precondition(request.httpMethod == "GET" && request.url!.path.hasSuffix("crons/1/log"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "tail", value: "true")) && query.contains(URLQueryItem(name: "limit", value: "262144")))
            logReads += 1
            return (200, logReads == 1 ? #"{"code":200,"data":"[开始] 执行任务"}"# : #"{"code":200,"data":{"content":"[开始] 执行任务\n[完成] 退出码 0"}}"#)
        }
        let firstLog = try await client.log(list[0])
        let updatedLog = try await client.log(list[0])
        precondition(firstLog == "[开始] 执行任务" && updatedLog.hasSuffix("退出码 0") && logReads == 2)
        print("Qinglong tests passed, including script directories and mutations, partial task saves, permission classification and refreshed execution logs.")
    }

    static func scriptBrowser(_ client: QinglongClient) async throws {
        func json(_ value: String) throws -> QinglongJSON { try JSONDecoder().decode(QinglongJSON.self, from: Data(value.utf8)) }
        let fixture = #"[{"title":"repo","type":"directory","children":[{"title":"empty","type":"directory","children":[]},{"title":"demo.py","type":"file"}]},{"title":"target","type":"directory","children":[]},{"title":"demo.py","type":"file","children":[]}]"#
        let entries = try QinglongParsing.items(try json(fixture), resource: .scripts)
        precondition(entries.count == 5)
        let roots = QinglongScriptTree.children(entries, directory: "")
        precondition(roots.map(\.filePath) == ["repo", "target", "demo.py"] && !roots.last!.isDirectory, "Directories sort first; file children metadata must not change its type")
        precondition(QinglongScriptTree.children(entries, directory: "repo").map(\.filePath) == ["repo/empty", "repo/demo.py"])
        precondition(QinglongScriptTree.children(entries, directory: "repo/empty").isEmpty, "Empty folders must remain navigable")
        let inferred = try QinglongParsing.items(try json(#"[{"key":"one/two/file.js","title":"file.js","type":"file"}]"#), resource: .scripts)
        precondition(Set(inferred.map(\.filePath)) == ["one", "one/two", "one/two/file.js"])
        let source = entries.first { $0.filePath == "repo/demo.py" }!, folder = roots[0]
        let moved = try QinglongScriptTree.destination(for: source, name: source.filename, directory: "target", entries: entries)
        precondition(moved == "target/demo.py")
        for (item, name, directory) in [(folder, "repo", "repo/empty"), (folder, "repo", "repo"), (source, "demo.py", ""), (source, "../bad", "target"), (source, "test.py", "missing"), (source, "demo.py", "repo")] {
            do { _ = try QinglongScriptTree.destination(for: item, name: name, directory: directory, entries: entries); fatalError("Invalid destination accepted") } catch is QinglongFailure {}
        }
        for path in ["/absolute", "../escape", "repo//child", "repo/", "repo/./child", "repo\\child", "bad\nname", String(repeating: "字", count: 86)] {
            do { try QinglongScriptTree.path(path, allowsRoot: false); fatalError("Unsafe script path accepted") } catch is QinglongFailure {}
        }
        for text in [#"[{"key":"../bad","title":"bad"}]"#, #"[{"key":"repo/file.py","title":"other.py"}]"#, #"[{"title":"same"},{"title":"same"}]"#, #"[{"title":"one","type":"file"},{"key":"one/child","title":"child"}]"#] {
            do { _ = try QinglongParsing.items(try json(text), resource: .scripts); fatalError("Invalid tree accepted") } catch is QinglongFailure {}
        }
        var requests = [String]()
        var expectedSource = "repo/demo.py", expectedTarget = "target/demo.py", expectedType = "file"
        var rejectRead = false, uncertainWrite = false
        QinglongMockProtocol.respond { request in
            let method = request.httpMethod!, path = request.url!.path
            requests.append(method + " " + path)
            if method == "GET" {
                precondition(path.hasSuffix("/scripts"), "Preflight reads the tree, never script contents")
                return rejectRead ? (403, #"{"code":403}"#) : (200, "{\"code\":200,\"data\":" + fixture + "}")
            }
            if uncertainWrite { throw URLError(.timedOut) }
            let body = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            if method == "PUT" {
                precondition(path.hasSuffix("/scripts/rename") && body["filename"].text == expectedSource && body["path"].text == "" && body["newFilename"].text == expectedTarget)
                precondition(body["content"] == .null, "Moving must not rewrite contents or lose directory children")
            } else {
                precondition(method == "DELETE" && path.hasSuffix("/scripts"))
                precondition(body["filename"].text == "repo" && body["path"].text == "" && body["type"].text == expectedType)
            }
            return (200, #"{"code":200}"#)
        }
        try await client.relocateScript(source, name: source.filename, directory: "target")
        precondition(requests.count == 2 && requests.last == "PUT /panel/open/scripts/rename")
        requests = []; expectedTarget = "repo/renamed.py"
        try await client.relocateScript(source, name: "renamed.py", directory: "repo")
        precondition(requests.count == 2)
        requests = []; expectedSource = "repo"; expectedTarget = "target/repo"
        try await client.relocateScript(folder, name: "repo", directory: "target")
        precondition(requests.count == 2, "Whole folder moves use one mutation")
        requests = []
        do { try await client.relocateScript(source, name: "demo.py", directory: ""); fatalError("Overwrite accepted") } catch is QinglongFailure {}
        precondition(requests.count == 1 && requests[0].hasPrefix("GET"), "A fresh collision must prevent the mutation")
        requests = []; rejectRead = true
        do { try await client.relocateScript(source, name: "next.py", directory: "repo"); fatalError("Failed preflight accepted") } catch is QinglongFailure {}
        precondition(requests.count == 1)
        requests = []; rejectRead = false; uncertainWrite = true
        do { try await client.relocateScript(source, name: "next.py", directory: "repo"); fatalError("Uncertain write accepted") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        precondition(requests.count == 2, "An uncertain rename or move must never retry")
        requests = []; uncertainWrite = false; expectedType = "directory"
        try await client.delete(folder)
        precondition(requests == ["GET /panel/open/scripts", "DELETE /panel/open/scripts"])
        requests = []
        let stale = QinglongItem(resource: .scripts, raw: .fields(["title":"gone.py", "type":"file"]))
        do { try await client.delete(stale); fatalError("Stale deletion accepted") } catch is QinglongFailure {}
        precondition(requests.count == 1, "Deleting a vanished item must not send DELETE")
    }

    static func directoryCreation(_ client: QinglongClient) async throws {
        func json(_ value: String) throws -> QinglongJSON { try JSONDecoder().decode(QinglongJSON.self, from: Data(value.utf8)) }
        let fixture = #"[{"title":"repo","type":"directory","children":[{"title":"existing","type":"directory","children":[]},{"title":"script.py","type":"file"}]}]"#
        var requests = [String](), expectedName = "new-folder", expectedDirectory = ""
        var rejectRead = false, rejectWrite = false, uncertainWrite = false
        QinglongMockProtocol.respond { request in
            let method = request.httpMethod!
            requests.append(method)
            precondition(request.url!.path == "/panel/open/scripts")
            if method == "GET" {
                return rejectRead ? (403, #"{"code":403}"#) : (200, "{\"code\":200,\"data\":" + fixture + "}")
            }
            precondition(method == "POST")
            let body = try json(String(decoding: QinglongMockProtocol.body(request)!, as: UTF8.self))
            precondition(body == .fields(["filename": expectedName, "path": expectedDirectory, "directory": expectedName]), "Directory creation must supply the required filename and directory branch, never script content")
            if uncertainWrite { throw URLError(.timedOut) }
            return rejectWrite ? (403, #"{"code":403}"#) : (200, #"{"code":200}"#)
        }
        try await client.createScriptDirectory(name: expectedName, directory: expectedDirectory)
        precondition(requests == ["GET", "POST"], "Root directory creation needs one write after checking current entries")
        requests = []; expectedName = "中文 子目录"; expectedDirectory = "repo"
        try await client.createScriptDirectory(name: expectedName, directory: expectedDirectory)
        precondition(requests == ["GET", "POST"], "Nested paths, Unicode and spaces must be sent as JSON fields")
        for (name, directory) in [("repo", ""), ("existing", "repo"), ("script.py", "repo"), ("new", "gone"), ("new", "repo/script.py")] {
            requests = []
            do { try await client.createScriptDirectory(name: name, directory: directory); fatalError("Collision or missing parent accepted") } catch is QinglongFailure {}
            precondition(requests == ["GET"], "Conflicts with either files or folders must prevent mkdir")
        }
        for (name, directory) in [("", ""), ("..", ""), ("one/two", ""), ("bad\\name", ""), ("bad\nname", ""), ("new", "/absolute"), ("new", "../escape"), (String(repeating: "字", count: 86), "")] {
            requests = []
            do { try await client.createScriptDirectory(name: name, directory: directory); fatalError("Unsafe directory accepted") } catch is QinglongFailure {}
            precondition(requests.isEmpty, "Invalid paths must fail before any request")
        }
        requests = []; rejectRead = true
        do { try await client.createScriptDirectory(name: expectedName, directory: expectedDirectory); fatalError("Failed preflight accepted") } catch is QinglongFailure {}
        precondition(requests == ["GET"])
        requests = []; rejectRead = false; rejectWrite = true
        do { try await client.createScriptDirectory(name: expectedName, directory: expectedDirectory); fatalError("Denied mkdir accepted") }
        catch let failure as QinglongFailure { precondition(failure.status == 403 && !failure.outcomeUnknown) }
        precondition(requests == ["GET", "POST"])
        requests = []; rejectWrite = false; uncertainWrite = true
        do { try await client.createScriptDirectory(name: expectedName, directory: expectedDirectory); fatalError("Uncertain mkdir accepted") }
        catch let failure as QinglongFailure { precondition(failure.outcomeUnknown) }
        precondition(requests == ["GET", "POST"], "An uncertain directory creation must never retry")
    }
}
