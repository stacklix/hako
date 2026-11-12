import Foundation
import Combine
import CryptoKit

struct WorkshopSavedCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var command = ""
    var note = ""
    var timeoutSeconds = 3600

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf8.count <= 8000
            && (1...86400).contains(timeoutSeconds)
    }
}

struct WorkshopCommandTask: Codable, Identifiable {
    let id: String
    let applicationId: String
    let name: String
    let command: String
    let directory: String
    let state: String
    let startedAt: Int64
    let finishedAt: Int64?
    let exitCode: Int?
    let error: String?
    let canStop: Bool
    var active: Bool { ["starting", "running", "stopping"].contains(state) }
    var status: String { Self.status(state) }
    static func status(_ state: String) -> String {
        switch state {
        case "starting": "正在启动"
        case "running": "执行中"
        case "stopping": "正在停止"
        case "succeeded": "已完成"
        case "cancelled": "已取消"
        case "timed_out": "已超时"
        case "interrupted": "已中断"
        default: "失败"
        }
    }
}

struct WorkshopCommandSummary: Decodable, Identifiable {
    let id: String
    let applicationId: String
    let name: String
    let state: String
    let startedAt: Int64
    var status: String { WorkshopCommandTask.status(state) }
}

@MainActor final class WorkshopCommands: ObservableObject {
    private struct Endpoint: Codable { let port: Int; let token: String }
    private struct StoredEndpoint: Codable { let ip: String; let endpoint: Endpoint }
    private struct Pending: Codable { let requestId: String; let command: WorkshopSavedCommand }
    private struct Snapshot: Codable {
        var commands: [WorkshopSavedCommand] = []
        var pending: Pending?
        var taskID: String?
    }
    private struct Listing: Decodable { let tasks: [WorkshopCommandSummary] }
    private struct Page: Decodable { let task: WorkshopCommandTask; let cursor: Int64; let output: String; let hasMore: Bool }
    let store: WorkshopStore
    let agent: WorkshopAgent
    let application: WorkshopApplication
    private let file: URL
    private let key: String
    private var snapshot = Snapshot()
    private var context = ""
    private var socket: WorkshopRequestSocket?
    private var cursor: Int64 = 0
    @Published private(set) var commands: [WorkshopSavedCommand] = []
    @Published private(set) var tasks: [WorkshopCommandSummary] = []
    @Published private(set) var task: WorkshopCommandTask?
    @Published private(set) var taskID: String?
    @Published private(set) var observationID = UUID()
    @Published private(set) var output = ""
    @Published private(set) var busy = false
    @Published var error: String?
    var pendingCommand: WorkshopSavedCommand? { snapshot.pending?.command }

    init(store: WorkshopStore, agent: WorkshopAgent, application: WorkshopApplication) {
        self.store = store; self.agent = agent; self.application = application
        key = SHA256.hash(data: Data((store.authentication.serverURL + "\n" + agent.id + "\n" + application.id).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkshopCommands", isDirectory: true)
        file = directory.appendingPathComponent(key + ".json")
        do {
            if FileManager.default.fileExists(atPath: file.path) { snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file)) }
            commands = snapshot.commands; taskID = snapshot.taskID ?? snapshot.pending?.requestId
        } catch { self.error = "手机保存的快捷命令暂时无法读取。" }
    }
    private func save(_ value: Snapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protectedFile = file
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try protectedFile.setResourceValues(resources)
        snapshot = value; commands = value.commands
    }
    func saveCommand(_ command: WorkshopSavedCommand) throws {
        guard command.valid else { throw HakoError(message: "请填写命令名称和内容，命令最长为 8,000 字节。") }
        var value = snapshot
        if let index = value.commands.firstIndex(where: { $0.id == command.id }) { value.commands[index] = command }
        else { value.commands.append(command) }
        try save(value)
    }
    func delete(_ command: WorkshopSavedCommand) throws {
        var value = snapshot; value.commands.removeAll { $0.id == command.id }; try save(value)
    }
    private func request<Value: Decodable>(_ method: String, _ params: [String: Any]) async throws -> Value {
        let ticket = store.scope
        guard context == ticket, let socket else { throw HakoError(message: "请先连接命令执行器。") }
        let data = try await socket.send(method, computerID: agent.id, params: params)
        guard context == ticket, store.scope == ticket else { throw CancellationError() }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    func prepare() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await connect(); error = nil }
        catch is CancellationError { }
        catch { socket?.close(); socket = nil; self.error = error.localizedDescription }
    }
    private func connect() async throws {
        let ticket = store.scope
        if context == ticket, socket != nil {
            let listing: Listing = try await request("commands.list", ["applicationId": application.id]); tasks = listing.tasks; return
        }
        context = ticket; socket?.close(); socket = nil
        if let direct = store.localEndpoint {
            let storage = SecureStorage.namespace("me.stackli.hako.commands")
            var cached: StoredEndpoint?
            if let data = try storage.read(account: key) { cached = try JSONDecoder().decode(StoredEndpoint.self, from: data) }
            if let cached, cached.ip == direct.ip {
                try useEndpoint(cached, ticket: ticket)
                do { let listing: Listing = try await request("commands.list", ["applicationId": application.id]); tasks = listing.tasks; return }
                catch is CancellationError { throw CancellationError() }
                catch { socket?.close(); socket = nil }
            }
            let endpoint: Endpoint = try await store.call(agent, "commands.open")
            guard store.scope == ticket else { throw CancellationError() }
            let value = StoredEndpoint(ip: direct.ip, endpoint: endpoint)
            try storage.save(JSONEncoder().encode(value), account: key, accessibility: .afterFirstUnlock)
            try useEndpoint(value, ticket: ticket)
        } else {
            socket = WorkshopRequestSocket(authentication: store.authentication, logSource: .codeWorkshop)
            do { let listing: Listing = try await request("commands.list", ["applicationId": application.id]); tasks = listing.tasks; return }
            catch let failure as WorkshopFailure where failure.code == "computer_offline" {
                let _: Endpoint = try await store.call(agent, "commands.open")
            }
        }
        for attempt in 0..<12 {
            do {
                let listing: Listing = try await request("commands.list", ["applicationId": application.id])
                tasks = listing.tasks; return
            } catch let failure as WorkshopFailure where failure.code == "computer_offline" && attempt < 11 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private func useEndpoint(_ value: StoredEndpoint, ticket: String) throws {
        guard value.endpoint.token.count == 64, let endpoint = LocalNetworkEndpoint(ip: value.ip, port: value.endpoint.port) else { throw CocoaError(.coderReadCorrupt) }
        socket = WorkshopRequestSocket(context: { [weak self] in self?.store.scope ?? "" }, open: { [weak self] in
            guard let self, self.store.scope == ticket else { throw CancellationError() }
            return try await WorkshopLocalSocket.open(endpoint, path: "/workshop/v1", commandToken: value.endpoint.token)
        })
    }
    func execute(_ command: WorkshopSavedCommand) async {
        guard !busy, command.valid else { return }
        if let pending = snapshot.pending, pending.command != command { error = "上一条命令的结果尚未确认，请先查看该任务。"; return }
        busy = true; defer { busy = false }
        do {
            if socket == nil || context != store.scope { try await connect() }
            let pending = snapshot.pending ?? Pending(requestId: UUID().uuidString.lowercased(), command: command)
            var saved = snapshot; saved.pending = pending; saved.taskID = pending.requestId; try save(saved)
            taskID = pending.requestId; observationID = UUID(); cursor = 0; output = ""; task = nil
            let result: WorkshopCommandTask = try await request("commands.start", ["requestId": pending.requestId, "applicationId": application.id,
                "name": pending.command.name, "command": pending.command.command, "timeoutSeconds": pending.command.timeoutSeconds])
            task = result; saved = snapshot; saved.pending = nil; try save(saved); error = nil
        } catch is CancellationError { }
        catch let failure as WorkshopFailure where ["command_busy", "invalid_params", "invalid_request", "unsupported_method", "codex_application_missing", "command_shell_missing", "command_request_conflict", "command_context_changed", "command_result_large"].contains(failure.code) {
            var value = snapshot; value.pending = nil; value.taskID = nil
            do { try save(value); taskID = nil; task = nil } catch { self.error = error.localizedDescription; return }
            self.error = failure.localizedDescription
        }
        catch { socket?.close(); socket = nil; self.error = error.localizedDescription }
    }
    func select(_ task: WorkshopCommandSummary) {
        self.task = nil; taskID = task.id; observationID = UUID(); cursor = 0; output = ""
        var value = snapshot; value.taskID = task.id
        do { try save(value) } catch { self.error = error.localizedDescription }
    }
    func stop() async {
        guard !busy, let taskID else { return }
        busy = true; defer { busy = false }
        do { let result: WorkshopCommandTask = try await request("commands.stop", ["taskId": taskID]); task = result; error = nil }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func observe() async {
        guard let id = taskID else { return }
        while !Task.isCancelled, taskID == id {
            do {
                if busy { try await Task.sleep(for: .milliseconds(100)); continue }
                if socket == nil || context != store.scope { try await connect() }
                let page: Page = try await request("commands.read", ["taskId": id, "cursor": cursor])
                guard taskID == id else { return }
                task = page.task; cursor = page.cursor
                output += page.output
                if output.count > 160_000 { output = "[手机仅显示最近的日志]\n" + String(output.suffix(140_000)) }
                error = nil
                if snapshot.pending?.requestId == id { var value = snapshot; value.pending = nil; try save(value) }
                if !page.task.active && !page.hasMore { return }
                try await Task.sleep(for: page.hasMore ? .milliseconds(20) : .seconds(1))
            } catch is CancellationError { return }
            catch let failure as WorkshopFailure where failure.code == "command_not_found" {
                error = pendingCommand == nil ? "执行器没有该任务记录，请返回快捷命令查看历史。" : "任务启动结果尚未确认，可重试原请求，使用同一个请求 ID。"; return
            }
            catch {
                socket?.close(); socket = nil
                self.error = "正在重新连接执行器，已收到的日志会保留。\n" + error.localizedDescription
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
