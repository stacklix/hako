import Foundation
import Combine
import CryptoKit

@MainActor final class WorkshopCommands: ObservableObject {
    private struct Endpoint: Codable { let port: Int; let token: String }
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
    private var connected = false
    private var cursor: Int64 = 0
    @Published private(set) var commands: [WorkshopSavedCommand] = []
    @Published private(set) var prompts: [WorkshopQuickPrompt] = []
    private var promptFile: URL { file.deletingPathExtension().appendingPathExtension("prompts.json") }
    @Published private(set) var tasks: [WorkshopCommandSummary] = []
    @Published private(set) var task: WorkshopCommandTask?
    @Published private(set) var taskID: String?
    @Published private(set) var observationID = UUID()
    @Published private(set) var output = ""
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var commandLoadError: String?
    @Published private(set) var promptLoadError: String?
    var pendingCommand: WorkshopSavedCommand? { snapshot.pending?.command }

    init(store: WorkshopStore, agent: WorkshopAgent, application: WorkshopApplication) {
        self.store = store; self.agent = agent; self.application = application
        key = SHA256.hash(data: Data((store.authentication.serverURL + "\n" + agent.id + "\n" + application.id).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkshopCommands", isDirectory: true)
        file = directory.appendingPathComponent(key + ".json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let bytes = try Data(contentsOf: file)
                snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
            }
            commands = snapshot.commands; taskID = snapshot.taskID ?? snapshot.pending?.requestId
        } catch { commandLoadError = "手机保存的快捷命令暂时无法读取。" }
        reloadPrompts()
    }
    func reloadPrompts() {
        do {
            if FileManager.default.fileExists(atPath: promptFile.path) {
                prompts = try JSONDecoder().decode([WorkshopQuickPrompt].self, from: Data(contentsOf: promptFile))
            } else { prompts = [] }
            promptLoadError = nil
        } catch { promptLoadError = "手机保存的快捷提示词暂时无法读取。" }
    }
    func savePrompt(_ prompt: WorkshopQuickPrompt) throws {
        guard prompt.valid else { throw HakoError(message: "请填写名称和提示词内容，内容最多 4,000 个字符。") }
        var values = prompts
        if let index = values.firstIndex(where: { $0.id == prompt.id }) { values[index] = prompt }
        else { values.append(prompt) }
        try writePrompts(values)
    }
    func deletePrompt(_ id: UUID) throws { try writePrompts(prompts.filter { $0.id != id }) }
    private func writePrompts(_ values: [WorkshopQuickPrompt]) throws {
        try FileManager.default.createDirectory(at: promptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: promptFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prompts = values; promptLoadError = nil
    }
    private func save(_ value: Snapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protectedFile = file
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try protectedFile.setResourceValues(resources)
        snapshot = value; commands = value.commands; commandLoadError = nil
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
        let ticket = store.commandContext(for: agent.id)
        guard context == ticket else { throw HakoError(message: "请先连接命令执行器。") }
        let result: Value
        if store.localEndpoint(for: agent.id) != nil {
            result = try await store.call(agent, method, params)
        } else {
            guard let socket else { throw HakoError(message: "请先连接命令执行器。") }
            let data = try await socket.send(method, computerID: agent.id, params: params)
            result = try JSONDecoder().decode(Value.self, from: data)
        }
        guard context == ticket, store.commandContext(for: agent.id) == ticket else { throw CancellationError() }
        return result
    }
    func prepare() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await connect(); error = nil }
        catch is CancellationError { }
        catch { disconnect(); self.error = error.localizedDescription }
    }
    private func connect() async throws {
        let ticket = store.commandContext(for: agent.id)
        if context == ticket, connected {
            let listing: Listing = try await request("commands.list", ["applicationId": application.id]); tasks = listing.tasks; return
        }
        context = ticket; disconnect()
        if store.localEndpoint(for: agent.id) != nil {
            let _: Endpoint = try await store.call(agent, "commands.open")
            guard store.commandContext(for: agent.id) == ticket else { throw CancellationError() }
        } else {
            socket = WorkshopRequestSocket(authentication: store.authentication, logSource: .codeWorkshop)
            do { let listing: Listing = try await request("commands.list", ["applicationId": application.id]); tasks = listing.tasks; connected = true; return }
            catch let failure as WorkshopFailure where failure.code == "computer_offline" {
                let _: Endpoint = try await store.call(agent, "commands.open")
            }
        }
        for attempt in 0..<12 {
            do {
                let listing: Listing = try await request("commands.list", ["applicationId": application.id])
                tasks = listing.tasks; connected = true; return
            } catch let failure as WorkshopFailure where failure.code == "computer_offline" && attempt < 11 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private func disconnect() {
        socket?.close(); socket = nil; connected = false
    }
    func execute(_ command: WorkshopSavedCommand) async {
        guard !busy, command.valid else { return }
        if let pending = snapshot.pending, pending.command != command { error = "上一条命令的结果尚未确认，请先查看该任务。"; return }
        busy = true; defer { busy = false }
        do {
            if !connected || context != store.commandContext(for: agent.id) { try await connect() }
            let pending = snapshot.pending ?? Pending(requestId: UUID().uuidString.lowercased(), command: command)
            var saved = snapshot; saved.pending = pending; saved.taskID = pending.requestId; try save(saved)
            taskID = pending.requestId; observationID = UUID(); cursor = 0; output = ""; task = nil
            let result: WorkshopCommandTask = try await request("commands.start", ["requestId": pending.requestId, "applicationId": application.id,
                "name": pending.command.name, "command": pending.command.command, "timeoutSeconds": pending.command.timeoutSeconds,
                "allowBackgroundProcesses": pending.command.allowBackgroundProcesses])
            task = result; saved = snapshot; saved.pending = nil; try save(saved); error = nil
        } catch is CancellationError { }
        catch let failure as WorkshopFailure where ["command_busy", "invalid_params", "invalid_request", "unsupported_method", "codex_application_missing", "command_shell_missing", "command_request_conflict", "command_context_changed", "command_result_large"].contains(failure.code) {
            var value = snapshot; value.pending = nil; value.taskID = nil
            do { try save(value); taskID = nil; task = nil } catch { self.error = error.localizedDescription; return }
            self.error = failure.localizedDescription
        }
        catch { disconnect(); self.error = error.localizedDescription }
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
                if !connected || context != store.commandContext(for: agent.id) { try await connect() }
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
                disconnect()
                self.error = "正在重新连接执行器，已收到的日志会保留。\n" + error.localizedDescription
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
