import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Never forward an API key to a redirected host (including a login portal).
final class ArcaneSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class ArcaneClient: @unchecked Sendable {
    let connection: ArcaneConnection
    let session: URLSession
    private let ownsSession: Bool

    init(connection: ArcaneConnection, session: URLSession? = nil) throws {
        self.connection = try connection.normalized()
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 960
            self.session = URLSession(configuration: config, delegate: ArcaneSessionDelegate(), delegateQueue: nil)
        }
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    func request(_ path: [String], query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        var request = try connection.request(path, query: query, method: method)
        if method != "GET" { request.timeoutInterval = 900 }
        return request
    }

    func environments() async throws -> [ArcaneEnvironment] {
        try await pages(["environments"], as: ArcaneEnvironment.self)
    }

    func containers(_ environment: String) async throws -> [ArcaneContainer] {
        try await pages(["environments", environment, "containers"], as: ArcaneContainer.self)
    }

    private func pages<T: Decodable & Identifiable>(_ path: [String], as: T.Type) async throws -> [T] where T.ID == String {
        var items: [T] = []
        var seen = Set<String>()
        while items.count < 10_000 {
            try Task.checkCancellation()
            let page: ArcaneEnvelope<[T]> = try await envelope(path,
                query: [URLQueryItem(name: "start", value: String(items.count)), URLQueryItem(name: "limit", value: "100"),
                        URLQueryItem(name: "sort", value: "name"), URLQueryItem(name: "order", value: "asc")])
            for item in page.data {
                guard seen.insert(item.id).inserted else {
                    throw ArcaneFailure(message: "资源列表在分页期间发生变化，请重新刷新。")
                }
                items.append(item)
            }
            if let total = page.pagination?.totalItems, items.count >= total { return items }
            if page.data.isEmpty {
                guard page.pagination?.totalItems == nil || items.count >= page.pagination!.totalItems else {
                    throw ArcaneFailure(message: "资源分页尚未完整返回，请重新刷新。")
                }
                return items
            }
            if page.pagination == nil && page.data.count < 100 { return items }
        }
        throw ArcaneFailure(message: "资源数量超过本客户端单次加载的 10,000 项上限。")
    }

    func details(_ environment: String, id: String) async throws -> ArcaneContainerDetails {
        try await read(["environments", environment, "containers", id], as: ArcaneContainerDetails.self)
    }

    func projects(_ environment: String) async throws -> [ArcaneProjectSummary] {
        try await pages(["environments", environment, "projects"], as: ArcaneProjectSummary.self)
    }

    func projectDocument(_ environment: String, project: String) async throws -> ArcaneProjectDocument {
        let value = try await read(["environments", environment, "projects", project, "compose"], as: ArcaneProjectDocument.self)
        guard value.id == project else { throw ArcaneFailure(message: "服务端返回的项目与请求不一致。") }
        return value
    }

    func workspace(_ environment: String, project: String) async throws -> ArcaneWorkspace {
        let value = try await read(["environments", environment, "projects", project, "workspace"], as: ArcaneWorkspace.self)
        for entry in value.files { try ArcaneWorkspacePath.validate(entry.relativePath) }
        guard Set(value.files.map(\.relativePath)).count == value.files.count else { throw ArcaneFailure(message: "服务端返回了重复的项目文件路径。") }
        return value
    }

    func workspaceFile(_ environment: String, project: String, path: String) async throws -> ArcaneWorkspaceContent {
        try ArcaneWorkspacePath.validate(path)
        let value = try await read(["environments", environment, "projects", project, "workspace", "file"],
                                   query: [URLQueryItem(name: "relativePath", value: path)], as: ArcaneWorkspaceContent.self)
        guard value.relativePath == path else { throw ArcaneFailure(message: "服务端返回的文件路径与请求不一致。") }
        return value
    }

    func saveProjectFile(_ environment: String, project: String, kind: ArcaneProjectFileKind,
                         baseline: String, content: String) async throws -> ArcaneProjectDocument {
        // The dedicated Compose/.env endpoint has no revision field. Re-read the
        // edited field before writing; never send unrelated configuration fields.
        let current = try await projectDocument(environment, project: project)
        guard current.editable(kind) else { throw ArcaneFailure(message: "此配置由 Git 同步管理或项目已归档，不能修改。") }
        guard current.content(kind) == baseline else {
            throw ArcaneFailure(message: "此文件已被其他操作修改，当前草稿已保留。请重新读取服务器内容后再编辑。", status: 409)
        }
        var request = try request(["environments", environment, "projects", project], method: "PUT")
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ArcaneProjectPatch(kind: kind, content: content))
        return try decodeWriteResponse(try await send(request), as: ArcaneProjectDocument.self)
    }

    func saveWorkspaceFile(_ environment: String, project: String, path: String, revision: String,
                           baseline: String, content: String) async throws -> ArcaneWorkspace {
        try ArcaneWorkspacePath.validate(path)
        guard !revision.isEmpty else { throw ArcaneFailure(message: "缺少项目文件版本，请重新读取目录后再保存。") }
        let manifest = ArcaneWorkspaceManifest(fileTreeRevision: revision, fileChanges: [.init(relativePath: path)])
        let boundary = "Hako-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"manifest\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try JSONEncoder().encode(manifest))
        append("\r\n")
        for (index, text) in [content, baseline].enumerated() {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"content-\(index).txt\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n")
            append(text); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = try request(["environments", environment, "projects", project, "workspace"], method: "PUT")
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // baselineIndex makes the server reject concurrent edits to this file.
        return try decodeWriteResponse(try await send(request), as: ArcaneWorkspace.self)
    }

    private func decodeWriteResponse<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        do {
            let value = try JSONDecoder().decode(ArcaneEnvelope<T>.self, from: data)
            guard value.success == true else { throw ArcaneFailure(message: "无法确认文件保存结果，请重新读取服务器内容核对。", outcomeUnknown: true) }
            return value.data
        } catch let error as ArcaneFailure { throw error }
        catch { throw ArcaneFailure(message: "无法确认文件保存结果，请重新读取服务器内容核对。", outcomeUnknown: true) }
    }

    func checkUpdate(_ environment: String, image: String, containerID: String) async throws -> ArcaneContainerUpdate {
        let update = try await read(["environments", environment, "image-updates", "check"],
            query: [URLQueryItem(name: "imageRef", value: image)], as: ArcaneUpdateInfo.self)
        return update.forContainer(containerID)
    }

    func perform(_ action: ArcaneAction, environment: String, id: String) async throws -> String? {
        var path = ["environments", environment, "containers", id]
        var query: [URLQueryItem] = []
        if action == .delete {
            query = [URLQueryItem(name: "force", value: "false"), URLQueryItem(name: "volumes", value: "false")]
        } else { path.append(action.rawValue) }
        let response = try await send(try request(path, query: query, method: action == .delete ? "DELETE" : "POST"))
        if response.isEmpty {
            if action == .redeploy { throw ArcaneFailure(message: "未收到重建后的容器 ID，请刷新列表核对更新结果。", outcomeUnknown: true) }
            return action == .delete ? nil : id
        }
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["success"] as? Bool == true else {
            throw ArcaneFailure(message: "服务端操作响应无法确认，请刷新容器状态后核对，勿直接重复操作。", outcomeUnknown: true)
        }
        let result = object["data"] as? [String: Any]
        if result?["success"] as? Bool == false || !(result?["failed"] as? [String] ?? []).isEmpty {
            throw ArcaneFailure(message: "服务端报告操作未全部成功，请查看 Arcane 活动记录并刷新容器状态。", outcomeUnknown: true)
        }
        if action == .redeploy {
            // The ID changes on recreation; never reconnect the old container's socket.
            guard let newID = result?["id"] as? String, !newID.isEmpty else {
                throw ArcaneFailure(message: "服务端已响应，但没有返回重建后的容器 ID。请刷新列表核对更新结果。", outcomeUnknown: true)
            }
            return newID
        }
        return action == .delete ? nil : id
    }

    func activities(_ environment: String) async throws -> [ArcaneActivity] {
        try await read(["environments", environment, "activities"], query: [URLQueryItem(name: "limit", value: "100")], as: [ArcaneActivity].self)
    }

    func activity(_ environment: String, id: String) async throws -> ArcaneActivityDetail {
        try await read(["environments", environment, "activities", id], as: ArcaneActivityDetail.self)
    }

    func downloadLogs(_ environment: String, id: String) async throws -> URL {
        do {
            var request = try request(["environments", environment, "containers", id, "logs", "download"])
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse else { throw ArcaneFailure(message: "日志下载响应无效。") }
            guard response.statusCode == 200 else { throw failure(response.statusCode, method: "GET") }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256 * 1_048_576 else { throw ArcaneFailure(message: "日志文件超过 256 MB，请在 Arcane 服务端下载。") }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("hako-arcane-\(UUID().uuidString).log")
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch let failure as ArcaneFailure { throw failure }
        catch { throw ArcaneFailure(message: "无法下载日志，请检查网络及 containers:logs 权限。") }
    }

    func stream(_ environment: String, id: String, kind: String,
                consume: @escaping @Sendable (Data) async throws -> Void) async throws {
        let query = kind == "logs" ? [URLQueryItem(name: "tail", value: "100"), URLQueryItem(name: "follow", value: "true"),
                                      URLQueryItem(name: "timestamps", value: "true"), URLQueryItem(name: "format", value: "json")] : []
        let request = try connection.request(["environments", environment, "ws", "containers", id, kind], query: query, websocket: true)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        try await withTaskCancellationHandler {
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }
            do {
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    try Task.checkCancellation()
                    let data: Data
                    switch frame {
                    case .data(let value): data = value
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = object["error"] as? String, !error.isEmpty {
                        throw ArcaneFailure(message: "实时订阅失败：" + redacted(error))
                    }
                    try await consume(data)
                }
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let failure = error as? ArcaneFailure { throw failure }
                let code = (socket.response as? HTTPURLResponse)?.statusCode
                if let code, code != 101 { throw failure(code, method: "GET") }
                throw ArcaneFailure(message: "实时连接已断开。请检查网络、容器状态、API Key 权限和反向代理的 WebSocket 支持。")
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }

    private func read<T: Decodable>(_ path: [String], query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        let response: ArcaneEnvelope<T> = try await envelope(path, query: query)
        return response.data
    }

    private func envelope<T: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> ArcaneEnvelope<T> {
        let data = try await send(try request(path, query: query))
        do {
            let value = try JSONDecoder().decode(ArcaneEnvelope<T>.self, from: data)
            guard value.success != false else { throw ArcaneFailure(message: "Arcane 返回失败状态，请检查服务端活动记录。") }
            return value
        } catch let failure as ArcaneFailure { throw failure }
        catch { throw ArcaneFailure(message: "无法解析 Arcane 响应。请核对服务地址及版本，当前按 v2.17.1 接口实现。") }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let mutation = request.httpMethod != "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ArcaneFailure(message: "Arcane 返回了无效响应。", outcomeUnknown: mutation)
            }
            guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, method: request.httpMethod ?? "GET") }
            if mutation && http.statusCode == 202 {
                throw ArcaneFailure(message: "Arcane 已接受操作，但尚未确认完成。请刷新状态并核对活动记录。", outcomeUnknown: true)
            }
            guard data.count <= 16 * 1_048_576 else { throw ArcaneFailure(message: "服务端响应过大，请在 Arcane 中检查资源数量。", outcomeUnknown: mutation) }
            return data
        } catch let error as ArcaneFailure { throw error }
        catch {
            if Task.isCancelled && !mutation { throw CancellationError() }
            if mutation {
                throw ArcaneFailure(message: "网络请求未能确认完成，操作可能仍在 Arcane 执行。请先刷新状态并核对活动记录，不要直接重复操作。", outcomeUnknown: true)
            }
            throw ArcaneFailure(message: "无法连接 Arcane。请检查网络、地址及证书；HTTP 地址需明确开启不加密连接。")
        }
    }

    private func failure(_ status: Int, method: String) -> ArcaneFailure {
        let text: String
        switch status {
        case 300..<400: text = "Arcane 返回重定向；为保护 API Key，已停止请求。请填写最终服务地址。"
        case 401: text = "API Key 无效或已过期，请在 Arcane 连接设置中更新。"
        case 403: text = "API Key 没有当前环境或操作的权限，请在 Arcane 中调整授权。"
        case 404: text = "找不到环境、容器或接口。容器可能已重建，请刷新列表；也请核对 Arcane 版本。"
        case 409: text = "资源状态冲突或已有操作正在执行，请刷新状态后再处理。"
        case 429: text = "Arcane 请求过于频繁，请稍后刷新。"
        default: text = "Arcane 请求失败（HTTP \(status)），请核对服务端活动记录。"
        }
        return ArcaneFailure(message: text, status: status, outcomeUnknown: method != "GET" && status >= 500)
    }

    func redacted(_ value: String) -> String {
        String(value.replacingOccurrences(of: connection.apiKey, with: "[已隐藏]").prefix(2_000))
    }
}
