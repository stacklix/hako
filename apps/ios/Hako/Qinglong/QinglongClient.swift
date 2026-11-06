import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor QinglongClient {
    let connection: QinglongConnection
    private let session: URLSession
    private let ownsSession: Bool
    private var token: String?
    private var expiration: TimeInterval = 0
    private var authentication: Task<(String, TimeInterval), Error>?

    init(connection: QinglongConnection, session: URLSession? = nil) throws {
        self.connection = try connection.normalized()
        ownsSession = session == nil
        self.session = session ?? HTTPTransport.makeSession(requestTimeout: 30, resourceTimeout: 60)
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    private func accessToken() async throws -> String {
        if let token, expiration > Date().timeIntervalSince1970 + 60 { return token }
        if let authentication { return try await authentication.value.0 }
        let connection = self.connection, session = self.session
        let task = Task<(String, TimeInterval), Error> {
            let request = try connection.request(["auth", "token"], query: [
                URLQueryItem(name: "client_id", value: connection.clientID),
                URLQueryItem(name: "client_secret", value: connection.clientSecret)])
            let (data, response) = try await HTTPTransport.data(for: request, using: session, source: .qinglong,
                secrets: [connection.clientID, connection.clientSecret] + connection.headers.map(\.value))
            let root = try Self.response(data, response: response)
            let token = root["data"]["token"].text
            guard !token.isEmpty, let expiry = root["data"]["expiration"].int else {
                throw QinglongFailure(message: "面板未返回有效的访问令牌。")
            }
            return (token, TimeInterval(expiry))
        }
        authentication = task
        do {
            let result = try await task.value
            token = result.0; expiration = result.1; authentication = nil
            return result.0
        } catch { authentication = nil; throw error }
    }

    func testConnection() async throws {
        do { _ = try await accessToken() }
        catch let failure as QinglongFailure { throw failure }
        catch { throw QinglongFailure(message: "无法连接青龙，请检查地址、网络与应用凭据。") }
    }

    func call(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: QinglongJSON? = nil) async throws -> QinglongJSON {
        try Task.checkCancellation()
        let credential: String
        do { credential = try await accessToken() }
        catch is CancellationError { throw CancellationError() }
        catch let failure as QinglongFailure { throw failure }
        catch { throw QinglongFailure(message: "无法获取青龙访问令牌，请检查地址、网络和应用凭据。") }
        try Task.checkCancellation()
        var request = try connection.request(path, query: query, method: method)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let started = Date()
        do {
            let (data, response) = try await HTTPTransport.data(for: request, using: session, source: .qinglong,
                secrets: [connection.clientID, connection.clientSecret] + connection.headers.map(\.value))
            let root = try Self.response(data, response: response)
            try Task.checkCancellation()
            HakoLog.record(.qinglong, "青龙请求完成", detail: "\(method) \(path.first ?? "") · \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return root
        } catch let failure as QinglongFailure {
            if failure.status == 401 { token = nil; expiration = 0 }
            HakoLog.record(.qinglong, .warning, "青龙请求被拒绝", detail: "\(method) \(path.first ?? "") · \(failure.status ?? 0)")
            if method != "GET", failure.outcomeUnknown || failure.status == nil {
                throw QinglongFailure(message: "操作结果未确认，请先刷新远端状态后再操作。", status: failure.status, outcomeUnknown: true)
            }
            throw failure
        } catch {
            if method == "GET", Task.isCancelled { throw CancellationError() }
            let unknown = method != "GET"
            throw QinglongFailure(message: unknown ? "请求结果尚未确认，请刷新远端状态后再操作，避免重复执行。" : "无法读取青龙数据，请检查网络后刷新。", outcomeUnknown: unknown)
        }
    }

    private static func response(_ data: Data, response: URLResponse) throws -> QinglongJSON {
        guard let http = response as? HTTPURLResponse else { throw QinglongFailure(message: "面板响应无效。") }
        let root = try? JSONDecoder().decode(QinglongJSON.self, from: data)
        let code = root?["code"].int
        let status = (200..<300).contains(http.statusCode) ? code ?? http.statusCode : http.statusCode
        guard (200..<300).contains(http.statusCode), code == 200, let root else {
            let message: String
            switch status {
            case 401: message = "应用凭据或 Token 已失效，请检查连接设置后重新刷新。"
            case 403: message = "没有此模块权限，请在青龙应用设置中授权后刷新。"
            case 404, 410: message = "当前青龙版本未提供此接口，或资源已不存在。"
            case 409: message = "远端内容发生变化，请重新读取后再编辑。"
            case 413: message = "内容超过面板允许的大小，未完成保存。"
            case 300..<400: message = "面板返回重定向，请配置最终访问地址。"
            default: message = "青龙请求失败（\(status)），请检查参数或面板状态。"
            }
            throw QinglongFailure(message: message, status: status, outcomeUnknown: !(200..<500).contains(status))
        }
        return root
    }

    func list(_ resource: QinglongResource) async throws -> [QinglongItem] {
        if resource == .tasks {
            var result: [QinglongItem] = [], seen = Set<String>()
            for page in 1...100 {
                let root = try await call([resource.rawValue], query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "100")])
                let data = root["data"], items = try QinglongParsing.items(data, resource: resource)
                for item in items {
                    guard seen.insert(item.id).inserted else { throw QinglongFailure(message: "任务分页发生变化，请重新刷新。") }
                    result.append(item)
                }
                if let total = data["total"].int {
                    if result.count >= total { return result }
                    if items.isEmpty { throw QinglongFailure(message: "任务列表未完整返回，请重新刷新。") }
                } else { return result }
            }
            throw QinglongFailure(message: "任务数量超过单次读取上限。")
        }
        let path = resource == .configs ? ["configs", "files"] : [resource.rawValue]
        return try QinglongParsing.items(try await call(path)["data"], resource: resource)
    }

    func file(_ item: QinglongItem) async throws -> String {
        try QinglongParsing.file(item.filename, directory: item.directory)
        let query: [URLQueryItem] = item.resource == .configs
            ? [URLQueryItem(name: "path", value: item.filePath)]
            : [URLQueryItem(name: "file", value: item.filename), URLQueryItem(name: "path", value: item.directory)]
        let data = try await call([item.resource.rawValue, "detail"], query: query)["data"]
        if case .string(let text) = data { return text }
        if case .string(let text) = data["content"] { return text }
        throw QinglongFailure(message: "面板返回的文件内容格式不受支持。")
    }

    func saveFile(_ item: QinglongItem, content: String, creating: Bool = false) async throws {
        try QinglongParsing.file(item.filename, directory: item.directory)
        let body: QinglongJSON = item.resource == .configs
            ? .fields(["name": item.filePath, "content": content])
            : .fields(["filename": item.filename, "path": item.directory, "content": content])
        _ = try await call(item.resource == .configs ? ["configs", "save"] : ["scripts"], method: creating || item.resource == .configs ? "POST" : "PUT", body: body)
    }

    func createScriptDirectory(name: String, directory: String) async throws {
        try QinglongParsing.file(name, directory: directory)
        try QinglongScriptTree.path(name, allowsRoot: false)
        try QinglongScriptTree.path(directory)
        let entries = try await list(.scripts)
        guard directory.isEmpty || entries.contains(where: { $0.isDirectory && $0.filePath == directory }) else { throw QinglongFailure(message: "创建位置已不存在，请重新打开目录。") }
        let target = [directory, name].filter { !$0.isEmpty }.joined(separator: "/")
        guard !entries.contains(where: { $0.filePath == target }) else { throw QinglongFailure(message: "此目录已存在同名文件或文件夹。") }
        // The API requires filename even for its directory-creation branch.
        _ = try await call(["scripts"], method: "POST", body: .fields(["filename": name, "path": directory, "directory": name]))
    }

    func relocateScript(_ item: QinglongItem, name: String, directory: String) async throws {
        let entries = try await list(.scripts)
        let target = try QinglongScriptTree.destination(for: item, name: name, directory: directory, entries: entries)
        // rename joins both names against path. Root-relative names support moving
        // files AND whole folders in one request, without copying/deleting content.
        _ = try await call(["scripts", "rename"], method: "PUT", body: .fields(["path": "", "filename": item.filePath, "newFilename": target]))
    }

    func createDependency(name: String, type: QinglongDependencyType) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw QinglongFailure(message: "请输入依赖包名。") }
        let dependency: QinglongJSON = .object(["name": .string(name), "type": .number(Double(type.rawValue))])
        _ = try await call([QinglongResource.dependencies.rawValue], method: "POST", body: .array([dependency]))
    }

    func saveEnvironment(_ item: QinglongItem?, fields: [String: String], enabled: Bool) async throws -> QinglongEnvironmentSaveResult {
        let payload = item?.editPayload(fields) ?? .fields(fields)
        let root = try await call(["envs"], method: item == nil ? "POST" : "PUT", body: item == nil ? .array([payload]) : payload)
        let raw = root["data"].array?.first ?? root["data"]
        let returned = QinglongItem(resource: .envs, raw: raw)
        let saved = returned.numberID != nil ? returned : item
        guard let saved, saved.numberID != nil else {
            return QinglongEnvironmentSaveResult(item: nil, stateError: "变量内容已保存，但面板未返回变量编号。请关闭后核对列表，不要重复新增。")
        }
        if (item?.disabled ?? false) == enabled {
            do { try await action(enabled ? "enable" : "disable", item: saved) }
            catch { return QinglongEnvironmentSaveResult(item: saved, stateError: "变量内容已保存，启用状态未确认：" + error.localizedDescription) }
        }
        return QinglongEnvironmentSaveResult(item: saved, stateError: nil)
    }

    func saveTask(_ item: QinglongItem?, fields: [String: String], enabled: Bool?) async throws -> QinglongTaskSaveResult {
        var values = fields
        if item == nil, values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { values.removeValue(forKey: "name") }
        let payload = item?.editPayload(values) ?? .fields(values)
        let root: QinglongJSON
        do { root = try await call(["crons"], method: item == nil ? "POST" : "PUT", body: payload) }
        catch let failure as QinglongFailure where item == nil && failure.outcomeUnknown {
            return QinglongTaskSaveResult(item: nil, stateError: "任务创建结果未确认，请关闭后回到列表核对，不要重复新增。")
        }
        let raw = root["data"].array?.first ?? root["data"]
        let returned = QinglongItem(resource: .tasks, raw: raw)
        guard let saved = returned.numberID != nil ? returned : item, saved.numberID != nil else {
            return QinglongTaskSaveResult(item: nil, stateError: "任务内容已保存，但面板未返回任务编号。请关闭后核对列表，不要重复新增。")
        }
        if let enabled {
            do { try await action(enabled ? "enable" : "disable", item: saved) }
            catch { return QinglongTaskSaveResult(item: saved, stateError: "任务内容已保存，自动执行状态未确认：" + error.localizedDescription) }
        }
        return QinglongTaskSaveResult(item: saved, stateError: nil)
    }

    func action(_ action: String, item: QinglongItem) async throws {
        guard let id = item.numberID else { throw QinglongFailure(message: "此资源缺少有效编号。") }
        _ = try await call([item.resource.rawValue, action], method: "PUT", body: .array([.number(Double(id))]))
    }

    func delete(_ item: QinglongItem) async throws {
        let body: QinglongJSON
        if item.resource == .scripts {
            try QinglongParsing.file(item.filename, directory: item.directory)
            try QinglongScriptTree.path(item.filePath, allowsRoot: false)
            let entries = try await list(.scripts)
            guard entries.contains(where: { $0.filePath == item.filePath && $0.isDirectory == item.isDirectory }) else { throw QinglongFailure(message: "文件或目录已改变，请刷新列表。") }
            body = .fields(["filename": item.filename, "path": item.directory, "type": item.isDirectory ? "directory" : "file"])
        } else {
            guard let id = item.numberID else { throw QinglongFailure(message: "此资源缺少有效编号。") }
            body = .array([.number(Double(id))])
        }
        _ = try await call([item.resource.rawValue], method: "DELETE", body: body)
    }

    func log(_ item: QinglongItem) async throws -> String {
        guard let id = item.numberID else { throw QinglongFailure(message: "任务编号无效。") }
        let root = try await call([item.resource.rawValue, String(id), "log"], query: [URLQueryItem(name: "tail", value: "true"), URLQueryItem(name: "limit", value: "262144")])
        if case .string(let value) = root["data"] { return value }
        if case .string(let value) = root["data"]["content"] { return value }
        throw QinglongFailure(message: "日志尚未生成，或当前面板的日志格式不受支持。")
    }
    func latestOutcome(_ item: QinglongItem) async throws -> QinglongOutcome? {
        guard let id = item.numberID else { return nil }
        let root = try await call(["crons", String(id), "instances"])
        guard let records = root["data"].array else { return nil }
        return records.max(by: { ($0["started_at"].int ?? 0) < ($1["started_at"].int ?? 0) }).map { QinglongOutcome(raw: $0) }
    }
}
