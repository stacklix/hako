import Combine
import Foundation

struct HakoShortcutRun: Codable, Identifiable {
    enum TriggerSource: String, Codable, Sendable {
        case manual, shortcuts

        var title: String {
            switch self {
            case .manual: "App 内触发"
            case .shortcuts: "快捷指令触发"
            }
        }
    }

    enum Status: String, Codable {
        case pending = "待执行", running = "执行中", succeeded = "成功", failed = "失败", cancelled = "已取消", interrupted = "已中断", skipped = "已跳过"

        var canRetry: Bool { self == .failed || self == .cancelled || self == .interrupted }
    }

    struct Step: Codable, Identifiable {
        let name: String
        var status: Status
        var startedAt: Date? = nil
        var finishedAt: Date? = nil
        var message: String? = nil
        var events: [HakoExecutionEvent]? = nil
        var attemptID: UUID? = nil
        var attempts: Int? = nil
        var id: String { name }
    }

    let id: UUID
    let name: String
    let startedAt: Date
    var finishedAt: Date? = nil
    var status: Status = .running
    var steps: [Step] = []
    var triggerSource: TriggerSource? = nil
    var lastRetrySource: TriggerSource? = nil
}

@MainActor final class HakoShortcutHistory: ObservableObject {
    static let capacity = 100
    static let eventCapacity = 200
    static let shared = HakoShortcutHistory(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ShortcutHistory", isDirectory: true).appendingPathComponent("runs.json"))

    @Published private(set) var runs: [HakoShortcutRun] = []
    @Published private(set) var storageIssue: String?
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            runs = Array(try JSONDecoder().decode([HakoShortcutRun].self, from: Data(contentsOf: fileURL)).prefix(Self.capacity))
            let interrupted = runs.indices.filter { runs[$0].status == .running }
            if !interrupted.isEmpty {
                for index in interrupted {
                    runs[index].status = .interrupted
                    for step in runs[index].steps.indices where runs[index].steps[step].status == .running {
                        runs[index].steps[step].status = .interrupted
                    }
                }
                save()
            }
        } catch {
            storageIssue = "无法读取本机的快捷指令记录。"
        }
    }

    func start(_ name: String, steps: [String] = [], source: HakoShortcutRun.TriggerSource? = nil) -> UUID {
        let run = HakoShortcutRun(id: UUID(), name: name, startedAt: .now,
                                  steps: steps.map { HakoShortcutRun.Step(name: $0, status: .pending) }, triggerSource: source)
        runs.insert(run, at: 0)
        if runs.count > Self.capacity { runs.removeLast() }
        save()
        return run.id
    }

    @discardableResult
    func recordStep(_ name: String, status: HakoShortcutRun.Status, runID: UUID, message: String? = nil) -> UUID? {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return nil }
        var step = runs[index].steps.first(where: { $0.name == name }) ?? HakoShortcutRun.Step(name: name, status: status)
        step.status = status
        step.message = message.map { HakoLog.sanitize($0) }
        if status == .running {
            step.startedAt = .now
            step.finishedAt = nil
            step.attemptID = UUID()
            step.attempts = (step.attempts ?? 0) + 1
        } else {
            step.finishedAt = .now
        }
        if let stepIndex = runs[index].steps.firstIndex(where: { $0.name == name }) {
            runs[index].steps[stepIndex] = step
        } else {
            runs[index].steps.append(step)
        }
        save()
        return step.attemptID
    }

    func appendEvent(_ event: HakoExecutionEvent, step name: String, runID: UUID, attemptID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }), runs[index].status == .running,
              let step = runs[index].steps.firstIndex(where: { $0.name == name }),
              runs[index].steps[step].status == .running, runs[index].steps[step].attemptID == attemptID else { return }
        let safe = HakoExecutionEvent(id: event.id, time: event.time, stage: HakoLog.sanitize(event.stage, limit: 256),
                                      state: event.state, detail: HakoLog.sanitize(event.detail))
        var events = runs[index].steps[step].events ?? []
        events.append(safe)
        runs[index].steps[step].events = Array(events.suffix(Self.eventCapacity))
        save()
    }

    func beginRetry(_ id: UUID) -> Bool {
        guard !runs.contains(where: { $0.status == .running }),
              let index = runs.firstIndex(where: { $0.id == id }), runs[index].status.canRetry else { return false }
        runs[index].status = .running
        runs[index].finishedAt = nil
        runs[index].lastRetrySource = .manual
        save()
        return true
    }

    func recordCancellation(_ context: HakoExecutionCancellation) {
        guard let id = context.runID, let reason = context.reason,
              let index = runs.firstIndex(where: { $0.id == id }) else { return }
        let attempts = context.attempts
        for step in runs[index].steps.indices {
            let value = runs[index].steps[step]
            guard let attemptID = attempts[value.name], value.attemptID == attemptID else { continue }
            var events = value.events ?? []
            let event = HakoExecutionEvent(id: context.id, stage: "快捷指令取消原因", state: .info, detail: HakoLog.sanitize(reason))
            if let position = events.firstIndex(where: { $0.id == context.id }) { events[position] = event }
            else { events.append(event) }
            runs[index].steps[step].events = Array(events.suffix(Self.eventCapacity))
            if value.status == .cancelled { runs[index].steps[step].message = HakoLog.sanitize(reason) }
        }
        save()
    }

    func finish(_ id: UUID, status: HakoShortcutRun.Status) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].finishedAt = .now
        runs[index].status = status
        save()
    }

    private func save() {
        guard let fileURL else {
            storageIssue = "本机存储不可用。"
            return
        }
        do {
            var directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = !UserDefaults.standard.bool(forKey: "hako.icloud.includeHistory")
            try? directory.setResourceValues(flags)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            #endif
            try JSONEncoder().encode(runs).write(to: fileURL, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
            #endif
            storageIssue = nil
        } catch {
            storageIssue = "快捷指令记录暂时无法保存到本机。"
        }
    }
}
