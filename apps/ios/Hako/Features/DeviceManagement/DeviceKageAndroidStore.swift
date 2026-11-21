import Foundation
import Combine
import CryptoKit

@MainActor final class KageAndroidStore: ObservableObject {
    private static var sessions: [String: KageAndroidStore] = [:]
    static func session(_ agent: ConsoleAgent) -> KageAndroidStore {
        let client = DeviceMonitorClient.shared
        let key = client.requestContext + "\n" + agent.id
        if let value = sessions[key] { return value }
        let value = KageAndroidStore(agent: agent)
        sessions[key] = value
        return value
    }
    let agent: ConsoleAgent
    private let client = DeviceMonitorClient.shared
    private let context: String
    private let pendingKey: String
    @Published var inventory: KageAndroidInventory?
    @Published var details: [String: KageAndroidDetail] = [:]
    @Published var operations: [KageAndroidOperation] = []
    @Published var pending: [String: String] = [:]
    @Published var error: String?
    @Published var loading = false
    @Published var submitting = false
    @Published var uploadProgress: Double?
    @Published private(set) var screenshots: [String: Data] = [:]
    @Published private(set) var screenshotPreviews: [String: Data] = [:]
    @Published private(set) var screenshotPreviewLoading: Set<String> = []
    @Published private(set) var screenshotProgress: [String: Double] = [:]
    @Published private(set) var screenshotErrors: [String: String] = [:]
    private var screenshotDownloads: [String: Task<Void, Never>] = [:]
    private var screenshotOrder: [String] = []
    private var watching: [String: Task<Void, Never>] = [:]
    init(agent: ConsoleAgent) {
        let client = DeviceMonitorClient.shared
        self.agent = agent; context = client.requestContext
        pendingKey = DeviceCardOrder.storageKey(server: client.serverURL, account: client.username, agent: agent.id, group: "android-pending")
        pending = (try? JSONDecoder().decode([String: String].self, from: UserDefaults.standard.data(forKey: pendingKey) ?? Data())) ?? [:]
    }
    var computerOnline: Bool { client.agents.first { $0.id == agent.id }?.online ?? agent.online }
    var canRequest: Bool { context == client.requestContext && client.authenticated && !client.logoutPending }
    func current(_ device: KageAndroidDevice) -> KageAndroidDevice { inventory?.devices.first { $0.id == device.id } ?? device }
    func namiLabel(_ device: KageAndroidDevice) -> String {
        guard let id = current(device).agentId else { return "未关联 Nami" }
        return client.agents.first { $0.id == id }?.online == true ? "Nami 在线" : "Nami 离线"
    }
    func canControl(_ device: KageAndroidDevice) -> Bool { canRequest && computerOnline && current(device).available }
    func accept(_ value: KageAndroidInventory?) {
        if let value, value.isValid, inventory == nil || value.sampledAt >= inventory!.sampledAt { inventory = value }
    }
    func refresh() async {
        guard canRequest, !loading else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            let value = try await call(KageAndroidCommand.list, as: KageAndroidInventory.self)
            guard value.isValid else { throw HakoError(message: "Android 设备列表格式无效。") }
            accept(value)
            for id in pending.keys where watching[id] == nil { watch(id) }
        } catch { fail(error) }
    }
    func refreshDetail(_ device: KageAndroidDevice, serial: String? = nil) async {
        guard canControl(device) else { return }
        do {
            var params: [String: Any] = ["deviceId": device.id]
            if let serial { params["serial"] = serial }
            let value = try await call(KageAndroidCommand.detail, params: params, as: KageAndroidDetail.self)
            guard value.isValid, value.id == device.id else { throw HakoError(message: "Android 数据格式无效。") }
            if details[device.id] == nil || value.sampledAt >= details[device.id]!.sampledAt { details[device.id] = value }
        } catch { fail(error) }
    }
    func loadOperations(_ device: KageAndroidDevice) async {
        guard canRequest else { return }
        do {
            let reply = try await call(KageAndroidCommand.operations, params: ["deviceId": device.id], as: KageAndroidOperations.self)
            guard reply.operations.allSatisfy(\.isValid) else { throw HakoError(message: "操作记录格式无效。") }
            for value in reply.operations { merge(value); if value.active { pending[value.id] = value.deviceId; watch(value.id) } }
            savePending()
        } catch { fail(error) }
    }
    @discardableResult func submit(_ operation: String, device: KageAndroidDevice? = nil, serial: String? = nil,
                                  extra: [String: Any] = [:]) async -> KageAndroidOperation? {
        guard canRequest, computerOnline, !submitting else { return nil }
        if pending.values.contains(device?.id ?? "computer") {
            error = "这台手机已有操作待确认，请先查询原操作结果。"
            return nil
        }
        if let device, !canControl(device), operation != "associate" { return nil }
        submitting = true; error = nil; defer { submitting = false }
        let id = UUID().uuidString.lowercased()
        var params = extra
        params["requestId"] = id; params["operation"] = operation
        if let device { params["deviceId"] = device.id }
        if let serial { params["serial"] = serial }
        // Persist before sending. A lost reply never creates a second operation.
        pending[id] = device?.id ?? "computer"; savePending()
        do {
            let value = try await call(KageAndroidCommand.execute, params: params, as: KageAndroidOperation.self)
            guard value.isValid, value.id == id else { throw HakoError(message: "操作响应格式无效，请按原编号查询。") }
            merge(value); watch(id)
            return value
        } catch let failure as ConsoleAgentError {
            // A structured rejection did not enqueue an operation. Transport
            // failures retain the request ID so the caller queries, not resends.
            pending.removeValue(forKey: id); savePending()
            error = failure.localizedDescription
            return nil
        } catch {
            fail(error)
            self.error = "操作结果待确认（\(id)）。请查询原操作记录，不要直接重复提交。\n" + (self.error ?? "")
            return nil
        }
    }
    private func savePending() { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: pendingKey) }
    private func merge(_ value: KageAndroidOperation) {
        guard value.isValid else { return }
        operations.removeAll { $0.id == value.id }; operations.append(value)
        operations.sort { $0.createdAt > $1.createdAt }
        if operations.count > 100 { operations = Array(operations.prefix(100)) }
        if !value.active { pending.removeValue(forKey: value.id); savePending() }
    }
    func check(_ id: String) async {
        guard canRequest else { return }
        do {
            let value = try await call(KageAndroidCommand.operation, params: ["requestId": id], as: KageAndroidOperation.self)
            guard value.isValid, value.id == id else { throw HakoError(message: "操作记录格式无效。") }
            merge(value)
            if value.hasScreenshot { await loadScreenshot(id) }
            if !value.active {
                await refresh()
                if let device = inventory?.devices.first(where: { $0.id == value.deviceId }) { await refreshDetail(device) }
                if ["start", "restart", "install"].contains(value.kind) { _ = await client.fetchAgents() }
            }
        } catch { fail(error) }
    }
    private func watch(_ id: String) {
        guard watching[id] == nil else { return }
        watching[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.watching.removeValue(forKey: id) }
            for _ in 0..<180 {
                guard self.canRequest, !Task.isCancelled else { return }
                await self.check(id)
                if let value = self.operations.first(where: { $0.id == id }), !value.active { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func logs(_ device: KageAndroidDevice, serial: String?) async -> String? {
        do {
            var p: [String: Any] = ["deviceId": device.id]; if let serial { p["serial"] = serial }
            return try await call(KageAndroidCommand.logs, params: p, as: KageAndroidLog.self).text
        } catch { fail(error); return nil }
    }
    func upload(_ url: URL, device: KageAndroidDevice, serial: String?) {
        guard canControl(device), uploadProgress == nil else { return }
        uploadProgress = 0; error = nil
        Task {
            defer { uploadProgress = nil }
            do {
                let bytes = try await Task.detached {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard (1...256 * 1024 * 1024).contains(size), url.pathExtension.lowercased() == "apk" else { throw HakoError(message: "请选择不超过 256 MB 的 APK 文件。") }
                    return try Data(contentsOf: url)
                }.value
                let id = UUID().uuidString.lowercased(), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                var offset = 0
                while offset < bytes.count {
                    guard canRequest else { throw CancellationError() }
                    let end = min(offset + 8192, bytes.count)
                    let reply = try await call(KageAndroidCommand.upload, params: ["uploadId": id, "fileName": url.lastPathComponent,
                        "length": bytes.count, "sha256": hash, "offset": offset, "data": bytes.subdata(in: offset..<end).base64EncodedString()], as: KageAndroidUpload.self)
                    guard reply.uploadId == id, reply.received == end, reply.completed == (end == bytes.count) else { throw HakoError(message: "APK 上传状态无效。") }
                    offset = end; uploadProgress = Double(offset) / Double(bytes.count)
                }
                _ = await submit("install", device: device, serial: serial, extra: ["uploadId": id])
            } catch { fail(error) }
        }
    }
    func loadScreenshot(_ id: String, reload: Bool = false) async {
        guard canRequest, operations.contains(where: { $0.id == id && $0.hasScreenshot }) else { return }
        if let download = screenshotDownloads[id] { await download.value; return }
        if !reload, screenshotPreviews[id] != nil || screenshots[id] != nil { return }
        if reload { screenshotPreviews.removeValue(forKey: id) }
        screenshotErrors.removeValue(forKey: id)
        screenshotPreviewLoading.insert(id)
        let download = Task { [weak self] in
            guard let self else { return }
            defer { self.screenshotDownloads.removeValue(forKey: id); self.screenshotPreviewLoading.remove(id) }
            do {
                let reply = try await self.call(KageAndroidCommand.preview, params: ["requestId": id], as: KageAndroidScreenshotPreview.self)
                guard let data = reply.bytes else { throw HakoError(message: "截图预览数据无效，请重新读取。") }
                guard self.canRequest else { return }
                self.screenshotPreviews[id] = data
                self.trimScreenshots(id)
            } catch {
                if self.canRequest, !(error is CancellationError) { self.screenshotErrors[id] = error.localizedDescription }
            }
        }
        screenshotDownloads[id] = download
        await download.value
    }
    func loadOriginalScreenshot(_ id: String) async {
        guard canRequest, operations.contains(where: { $0.id == id && $0.hasScreenshot }) else { return }
        let key = id + ":original"
        if let download = screenshotDownloads[key] { await download.value; return }
        if screenshots[id] != nil { return }
        screenshotErrors.removeValue(forKey: id)
        screenshotProgress[id] = 0
        let download = Task { [weak self] in
            guard let self else { return }
            defer { self.screenshotDownloads.removeValue(forKey: key); self.screenshotProgress.removeValue(forKey: id) }
            do {
                let data = try await KageAndroidScreenshotDownload.read(fetch: { offset in
                    try await self.call(KageAndroidCommand.artifact,
                        params: ["requestId": id, "offset": offset], as: KageAndroidArtifact.self)
                }, progress: { self.screenshotProgress[id] = $0 })
                guard self.canRequest else { return }
                self.screenshots[id] = data
                self.trimScreenshots(id)
            } catch {
                if self.canRequest, !(error is CancellationError) { self.screenshotErrors[id] = error.localizedDescription }
            }
        }
        screenshotDownloads[key] = download
        await download.value
    }
    private func trimScreenshots(_ id: String) {
        screenshotOrder.removeAll { $0 == id }; screenshotOrder.append(id)
        while screenshotOrder.count > 1 && (screenshotOrder.count > 4
            || screenshots.values.reduce(0, { $0 + $1.count }) > 32 * 1024 * 1024) {
            let old = screenshotOrder.removeFirst()
            screenshots.removeValue(forKey: old); screenshotPreviews.removeValue(forKey: old)
        }
    }
    private func call<T: Decodable>(_ method: String, params: [String: Any] = [:], as type: T.Type) async throws -> T {
        guard canRequest else { throw CancellationError() }
        return try await client.invokeAgent(agent, method: method, version: 1, params: params, as: type)
    }
    private func fail(_ error: Error) {
        guard canRequest, !(error is CancellationError) else { return }
        self.error = error.localizedDescription
    }
}
