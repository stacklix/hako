import Foundation
import Combine
import CryptoKit

@MainActor final class WorkshopFilesData: ObservableObject {
    let store: WorkshopStore
    let agent: WorkshopAgent
    let application: WorkshopApplication
    @Published private(set) var directories: [String: [WorkshopProjectFile]] = [:]
    @Published private(set) var modified: [WorkshopProjectFile] = []
    @Published private(set) var searchResults: [WorkshopProjectFile] = []
    @Published private(set) var loadingPaths: Set<String> = []
    @Published private(set) var searching = false
    @Published private(set) var refreshing = false
    @Published private(set) var truncated = false
    @Published var error: String?
    private var searchID = UUID()

    init(store: WorkshopStore, agent: WorkshopAgent, application: WorkshopApplication) {
        self.store = store; self.agent = agent; self.application = application
    }
    func request<T: Decodable>(_ method: String, _ params: [String: Any] = [:]) async throws -> T {
        var params = params; params["applicationId"] = application.id
        return try await store.call(agent, method, params)
    }
    private func pages(_ method: String, _ params: [String: Any] = [:]) async throws -> (entries: [WorkshopProjectFile], truncated: Bool) {
        var result: [WorkshopProjectFile] = [], offset = 0, truncated = false
        repeat {
            try Task.checkCancellation()
            var params = params; params["offset"] = offset
            let page: WorkshopFilePage = try await request(method, params)
            result.append(contentsOf: page.entries); truncated = truncated || page.truncated
            if let next = page.nextOffset {
                guard next > offset, result.count <= 100_000 else { throw HakoError(message: "目录分页无效，请刷新后重试。") }
                offset = next
            } else { break }
        } while true
        var seen: Set<String> = []
        return (result.filter { seen.insert($0.path).inserted }, truncated)
    }
    func directory(_ path: String) async {
        guard !loadingPaths.contains(path) else { return }
        loadingPaths.insert(path); defer { loadingPaths.remove(path) }
        do {
            let value = try await pages("files.list", ["path": path])
            try Task.checkCancellation(); directories[path] = value.entries
            truncated = truncated || value.truncated
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; error = nil; truncated = false
        defer { refreshing = false }
        await directory("")
        do {
            let value = try await pages("files.modified")
            try Task.checkCancellation(); modified = value.entries; truncated = truncated || value.truncated
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func search(_ query: String) async {
        let ticket = UUID(); searchID = ticket
        searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        defer { if searchID == ticket { searching = false } }
        guard searching else { searchResults = []; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let value = try await pages("files.list", ["path": "", "query": query])
            try Task.checkCancellation()
            guard ticket == searchID else { return }
            searchResults = value.entries; truncated = value.truncated; error = nil
        } catch is CancellationError { }
        catch { if ticket == searchID { self.error = error.localizedDescription } }
    }
}

@MainActor final class WorkshopFileEditorData: ObservableObject {
    @Published var draft = "" { didSet { if dirty { notice = nil } } }
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published private(set) var editable = false
    @Published private(set) var viewable = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    @Published private(set) var reason: String?
    @Published private(set) var notice: String?
    private var baseline = ""
    private var revision = ""
    private var encoding = ""
    private var scope = ""
    var dirty: Bool { draft != baseline }
    var canSave: Bool { editable && dirty && !loading && !saving && !uncertain }

    func load(_ client: WorkshopFilesData, file: WorkshopProjectFile) async {
        loading = true; error = nil; notice = nil
        defer { loading = false }
        do {
            let ticket = client.store.scope
            var value: WorkshopFileRead = try await client.request("files.read", ["path": file.path, "offset": 0])
            let initial = value
            guard let name = initial.encoding, let version = initial.revision else {
                viewable = false; editable = false; reason = initial.reason; return
            }
            var bytes = Data()
            while true {
                guard let chunk = value.data.flatMap({ Data(base64Encoded: $0) }), bytes.count + chunk.count <= WorkshopFileText.limit,
                      value.revision == version, value.size == initial.size else { throw HakoError(message: "文件内容校验失败，请重新读取。") }
                bytes.append(chunk)
                guard let next = value.nextOffset else { break }
                guard next == bytes.count, !chunk.isEmpty else { throw HakoError(message: "文件分页无效。") }
                value = try await client.request("files.read", ["path": file.path, "offset": next, "revision": version])
            }
            guard bytes.count == initial.size, Self.hash(bytes) == version,
                  let text = WorkshopFileText.decode(bytes, encoding: name) else { throw HakoError(message: "无法解码文本文件。") }
            guard ticket == client.store.scope else { throw CancellationError() }
            baseline = text; draft = text; revision = version; encoding = name; scope = ticket
            viewable = true; editable = initial.editable; reason = initial.reason; uncertain = false
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func save(_ client: WorkshopFilesData, file: WorkshopProjectFile) async -> Bool {
        guard canSave else { return false }
        saving = true; error = nil; notice = nil
        defer { saving = false }
        var committing = false
        do {
            guard scope == client.store.scope else { throw HakoError(message: "连接配置已变化，请重新打开文件。") }
            let proposed = draft
            guard let bytes = WorkshopFileText.encode(proposed, encoding: encoding), bytes.count <= WorkshopFileText.limit else {
                throw HakoError(message: "文本文件超过 256 KB，或包含无法编码的内容。")
            }
            let id = UUID().uuidString.lowercased(), hash = Self.hash(bytes)
            struct Position: Decodable { let offset: Int }
            let start: Position = try await client.request("files.write.begin", ["transferId": id, "path": file.path,
                "revision": revision, "sha256": hash, "size": bytes.count, "encoding": encoding])
            guard start.offset == 0 else { throw HakoError(message: "文件传输起始位置无效。") }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let next = min(offset + 8192, bytes.count)
                let reply: Position = try await client.request("files.write.chunk", ["transferId": id, "offset": offset,
                    "data": bytes.subdata(in: offset..<next).base64EncodedString()])
                guard reply.offset == next else { throw HakoError(message: "文件上传校验失败。") }
                offset = next
            }
            struct Saved: Decodable { let revision: String; let size: Int }
            committing = true
            let result: Saved = try await client.request("files.write.commit", ["transferId": id])
            guard scope == client.store.scope, result.revision == hash, result.size == bytes.count else { throw HakoError(message: "保存回执校验失败。") }
            revision = hash; baseline = proposed; notice = "文件已保存。"; return true
        } catch {
            let failure = error as? WorkshopFailure
            let rejected = failure.map { ["file_conflict", "file_read_only", "file_access_failed", "invalid_params", "file_transfer_missing", "file_link"].contains($0.code) } ?? false
            uncertain = committing && !rejected
            self.error = uncertain ? "保存结果未确认，草稿已保留。请重新读取电脑文件核对，勿直接重复保存。" : error.localizedDescription
            if failure?.code == "file_conflict" { editable = false }
            return false
        }
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
