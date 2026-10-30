import Foundation
import Combine

struct ArcaneCommandResult: Identifiable {
    let id: UUID
    let definitionID: String
    let name: String
    let container: String
    let began: Date
    var finished: Date?
    var exitCode: Int?
    var error: String?
    var uncertain = false
    var running = true
    var output = Data()
    var truncated = false
    var sensitiveOutput = false
    var text: String {
        let text = String(decoding: output, as: UTF8.self)
        return text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    var status: String { running ? "执行中" : uncertain ? "结果待确认" : exitCode == 0 ? "成功" : "失败" }
}

@MainActor final class ArcaneCommandLibrary: ObservableObject {
    static let shared = ArcaneCommandLibrary()
    @Published private(set) var results: [String: [ArcaneCommandResult]] = [:]
    @Published private(set) var revision = UUID()
    private let defaults: UserDefaults
    private var execution: Task<Void, Never>?
    private var redactions: [UUID: [String]] = [:]
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func definitions(_ context: ArcaneCommandContext) -> [ArcaneCommandDefinition] {
        guard let data = defaults.data(forKey: context.stableKey),
              let values = try? JSONDecoder().decode([ArcaneCommandDefinition].self, from: data) else { return [] }
        return values.compactMap { try? $0.validated() }
    }
    func save(_ definition: ArcaneCommandDefinition, context: ArcaneCommandContext) throws {
        var value = try definition.validated(); value.builtIn = false
        var values = definitions(context)
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else {
            guard values.count < 50 else { throw ArcaneFailure(message: "每个容器最多保存 50 个自定义操作。") }
            values.append(value)
        }
        defaults.set(try JSONEncoder().encode(values), forKey: context.stableKey); revision = UUID()
    }
    func remove(_ definition: ArcaneCommandDefinition, context: ArcaneCommandContext) throws {
        let values = definitions(context).filter { $0.id != definition.id }
        defaults.set(try JSONEncoder().encode(values), forKey: context.stableKey); revision = UUID()
    }
    func result(_ id: UUID, context: ArcaneCommandContext) -> ArcaneCommandResult? { results[context.stableKey]?.first { $0.id == id } }

    @discardableResult func run(_ definition: ArcaneCommandDefinition, values: [String: String], details: ArcaneContainerDetails,
                               context: ArcaneCommandContext, store: ArcaneStore) throws -> UUID {
        guard execution == nil, store.connection?.id == context.connection else { throw ArcaneFailure(message: "连接已变化或有操作正在执行。") }
        let command = try definition.resolve(values)
        _ = try ArcaneCommandExecutor.script(command, token: String(repeating: "0", count: 32))
        let client = try store.client()
        let lease = try store.beginTerminalSession()
        let id = UUID()
        var item = ArcaneCommandResult(id: id, definitionID: definition.id, name: definition.name, container: details.displayName, began: .now)
        item.sensitiveOutput = definition.parameters.contains { $0.kind == .password }
        let key = context.stableKey
        var history = results[key] ?? []; history.insert(item, at: 0)
        for old in history.dropFirst(20) { redactions.removeValue(forKey: old.id) }
        results[key] = Array(history.prefix(20))
        // Output is redacted from the complete accumulated byte stream, not
        // per frame: secrets and UTF-8 characters can cross socket boundaries.
        let secrets = definition.parameters.filter { $0.kind == .password }.compactMap { values[$0.key] }.filter { !$0.isEmpty } + [client.connection.apiKey]
        redactions[id] = secrets
        execution = Task {
            defer { store.endTerminalSession(lease); execution = nil }
            do {
                let current = try await client.details(context.environment, id: details.id)
                guard current.id == details.id, current.state?.status == "running", current.state?.running != false else {
                    throw ArcaneFailure(message: "当前容器不在运行中，请返回并刷新状态。")
                }
                let channel = try ArcaneSocketTerminal(client: client, environment: context.environment, container: details.id)
                let code = try await ArcaneCommandExecutor.run(channel: channel, command: command) { [weak self] bytes in
                    await self?.append(bytes, id: id, key: key)
                }
                update(id, key: key) { $0.exitCode = code }
            } catch {
                update(id, key: key) { $0.error = error.localizedDescription; $0.uncertain = (error as? ArcaneFailure)?.outcomeUnknown == true }
            }
            update(id, key: key) { result in
                result.running = false; result.finished = .now
                result.output = Data(ArcaneCommandRedaction.text(result.text, secrets: secrets).utf8)
                if let error = result.error {
                    result.error = secrets.filter { !$0.isEmpty }.reduce(error) { $0.replacingOccurrences(of: $1, with: "[已隐藏]") }
                }
            }
            // Keep the API-key mask for any SwiftUI view still holding an older
            // streaming snapshot. Password values are released on completion.
            redactions[id] = [client.connection.apiKey]
        }
        return id
    }
    func visibleOutput(_ result: ArcaneCommandResult) -> String {
        if result.running && result.sensitiveOutput { return "正在执行，敏感操作的输出将在结束后脱敏显示。" }
        return ArcaneCommandRedaction.text(result.text, secrets: redactions[result.id] ?? [])
    }
    // Only a redacted snapshot is exposed while receiving; the UI must mask
    // sensitive operation output until completion to avoid partial matches.
    private func append(_ bytes: Data, id: UUID, key: String) {
        update(id, key: key) { result in
            let available = max(0, 262_144 - result.output.count)
            result.output.append(bytes.prefix(available)); result.truncated = result.truncated || bytes.count > available
        }
    }
    private func update(_ id: UUID, key: String, _ mutate: (inout ArcaneCommandResult) -> Void) {
        guard var history = results[key], let index = history.firstIndex(where: { $0.id == id }) else { return }
        mutate(&history[index]); results[key] = history
    }
}
