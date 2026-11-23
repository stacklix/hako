import Foundation
import Combine
import CryptoKit

extension DeviceFilePath {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@MainActor final class DeviceFilesStore: ObservableObject {
    let agent: ConsoleAgent
    private let client = DeviceMonitorClient.shared
    private let context: String
    private let pendingKey: String
    @Published var root = ""
    @Published var path = ""
    @Published var entries: [DeviceFileEntry] = []
    @Published var nextOffset: Int?
    @Published var truncated = false
    @Published var showHidden = false
    @Published var loading = false
    @Published var writing = false
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var pendingID: String?
    init(agent: ConsoleAgent) {
        self.agent = agent; context = client.requestContext
        pendingKey = DeviceCardOrder.storageKey(server: client.serverURL, account: client.username, agent: agent.id, group: "files-pending")
        pendingID = UserDefaults.standard.string(forKey: pendingKey)
    }
    var canRequest: Bool {
        context == client.requestContext && client.authenticated && !client.logoutPending
            && (client.agents.first { $0.id == agent.id }?.online ?? agent.online)
    }
    var canWrite: Bool { canRequest && !writing && pendingID == nil }
    func call<T: Decodable>(_ command: String, _ params: [String: Any], as: T.Type) async throws -> T {
        guard canRequest else { throw HakoError(message: "设备已离线或登录状态已改变，请重新连接后操作。") }
        let result = try await client.invokeAgent(agent, method: command, version: 1, params: params, as: T.self)
        guard canRequest, !Task.isCancelled else { throw CancellationError() }
        return result
    }
    func page(path: String, query: String = "", offset: Int = 0, hidden: Bool? = nil) async throws -> DeviceFilePage {
        let result = try await call(DeviceFilesCommand.list, ["path": path, "query": query, "offset": offset, "showHidden": hidden ?? showHidden], as: DeviceFilePage.self)
        guard result.valid(expectedPath: path, offset: offset) else { throw HakoError(message: "文件列表格式无效，请重新读取。") }
        return result
    }
    func load(path target: String? = nil, more: Bool = false) async {
        guard !loading else { return }
        let target = target ?? path
        guard DeviceFilePath.valid(target) else { return }
        loading = true; error = nil; defer { loading = false }
        let offset = more ? (nextOffset ?? 0) : 0
        do {
            let result = try await page(path: target, offset: offset)
            root = result.root; path = target
            entries = more ? entries + result.entries.filter { next in !entries.contains { $0.id == next.id } } : result.entries
            nextOffset = result.nextOffset; truncated = result.truncated
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func read(_ entry: DeviceFileEntry) async throws -> DeviceFileDocument {
        var data = Data(), revision: String?, encoding: String?, editable = false, reason: String?
        repeat {
            var params: [String: Any] = ["path": entry.path, "offset": data.count]
            if let revision { params["revision"] = revision }
            let reply = try await call(DeviceFilesCommand.read, params, as: DeviceFileRead.self)
            guard reply.size >= 0 else { throw HakoError(message: "文件大小无效。") }
            if reply.encoding == nil {
                guard data.isEmpty, !reply.editable else { throw HakoError(message: "文件读取格式无效。") }
                return .init(revision: reply.revision, encoding: nil, editable: false, reason: reply.reason, text: nil)
            }
            guard reply.size <= DeviceFileDocument.limit, let hash = reply.revision, DeviceFilePath.isDigest(hash),
                  let chunk = reply.data.flatMap({ Data(base64Encoded: $0) }), chunk.count <= 8192,
                  data.count + chunk.count <= reply.size, revision == nil || revision == hash,
                  encoding == nil || encoding == reply.encoding else { throw HakoError(message: "文件读取格式无效。") }
            revision = hash; encoding = reply.encoding; editable = reply.editable; reason = reply.reason
            data.append(chunk)
            if let next = reply.nextOffset {
                guard !chunk.isEmpty, next == data.count, next < reply.size else { throw HakoError(message: "文件分块位置无效。") }
            } else {
                guard data.count == reply.size, DeviceFilePath.digest(data) == hash,
                      let text = DeviceFileDocument.decode(data, encoding: encoding!) else { throw HakoError(message: "文件内容或编码校验失败，请重新读取。") }
                return .init(revision: revision, encoding: encoding, editable: editable, reason: reason, text: text)
            }
        } while true
    }
    private func pending(_ id: String?) {
        pendingID = id
        if let id { UserDefaults.standard.set(id, forKey: pendingKey) }
        else { UserDefaults.standard.removeObject(forKey: pendingKey) }
    }
    func acknowledgePending() { guard !writing else { return }; pending(nil); notice = "已结束结果核对" }
    private func accept(_ reply: DeviceFileOperation, id: String) throws -> DeviceFileOperation {
        guard reply.isValid, reply.requestId.lowercased() == id.lowercased() else { throw HakoError(message: "操作回执无效，请核对原操作结果。") }
        guard reply.state != "unknown" else { throw HakoError(message: reply.error ?? "操作结果待确认，请刷新目录核对。") }
        pending(nil)
        guard reply.state == "completed" else { throw HakoError(message: reply.error ?? "文件操作失败，请刷新目录核对。") }
        return reply
    }
    func mutate(_ operation: String, path: String, name: String? = nil, revision: String? = nil) async throws {
        guard canWrite else { throw HakoError(message: "请先核对上一项操作结果，再执行新的文件操作。") }
        writing = true; defer { writing = false }
        let id = UUID().uuidString.lowercased()
        var params: [String: Any] = ["requestId": id, "operation": operation, "path": path]
        if let name { params["name"] = name }
        if let revision { params["revision"] = revision }
        pending(id)
        let result = try await call(DeviceFilesCommand.mutate, params, as: DeviceFileOperation.self)
        _ = try accept(result, id: id)
        notice = "操作已完成"; await load()
    }
    func save(_ entry: DeviceFileEntry, document: DeviceFileDocument, text: String) async throws -> DeviceFileDocument {
        guard canWrite, document.editable, let revision = document.revision, let encoding = document.encoding,
              let bytes = DeviceFileDocument.encode(text, encoding: encoding), bytes.count <= DeviceFileDocument.limit else {
            throw HakoError(message: "当前文件不可保存、上次结果待确认或内容超过 256 KB。")
        }
        writing = true; defer { writing = false }
        let id = UUID().uuidString.lowercased(), hash = DeviceFilePath.digest(bytes)
        let begin = try await call(DeviceFilesCommand.begin, ["requestId": id, "path": entry.path, "revision": revision, "sha256": hash, "size": bytes.count, "encoding": encoding], as: DeviceFileWriteOffset.self)
        guard begin.offset == 0 else { throw HakoError(message: "文件传输起点无效。") }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 8192, bytes.count)
            let reply = try await call(DeviceFilesCommand.chunk, ["requestId": id, "offset": offset, "data": bytes.subdata(in: offset..<end).base64EncodedString()], as: DeviceFileWriteOffset.self)
            guard reply.offset == end else { throw HakoError(message: "文件传输位置无效。") }; offset = end
        }
        // Only commit can change the file. Persist its ID before sending it.
        pending(id)
        let reply = try await call(DeviceFilesCommand.commit, ["requestId": id], as: DeviceFileOperation.self)
        let result = try accept(reply, id: id)
        guard result.revision == hash else { throw HakoError(message: "保存回执与草稿不一致，请重新读取核对。") }
        notice = "文件已保存"; await load()
        return .init(revision: hash, encoding: encoding, editable: true, reason: nil, text: text)
    }
    @discardableResult func resolvePending() async -> DeviceFileOperation? {
        guard let id = pendingID, !writing else { return nil }
        writing = true; error = nil; defer { writing = false }
        do {
            let reply = try await call(DeviceFilesCommand.operation, ["requestId": id], as: DeviceFileOperation.self)
            let result = try accept(reply, id: id)
            notice = "已确认操作完成"; await load(); return result
        } catch { self.error = error.localizedDescription; return nil }
    }
}
