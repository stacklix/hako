import Combine
import Foundation

struct HakoShortcutRun: Codable, Identifiable {
    enum Status: String, Codable {
        case running = "执行中", succeeded = "成功", failed = "失败", cancelled = "已取消", interrupted = "已中断"
    }

    struct Step: Codable, Identifiable {
        let name: String
        let status: Status
        var id: String { name }
    }

    let id: UUID
    let name: String
    let startedAt: Date
    var finishedAt: Date? = nil
    var status: Status = .running
    var steps: [Step] = []
}

@MainActor final class HakoShortcutHistory: ObservableObject {
    static let capacity = 100
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
                for index in interrupted { runs[index].status = .interrupted }
                save()
            }
        } catch {
            storageIssue = "无法读取本机的快捷指令记录。"
        }
    }

    func start(_ name: String) -> UUID {
        let run = HakoShortcutRun(id: UUID(), name: name, startedAt: .now)
        runs.insert(run, at: 0)
        if runs.count > Self.capacity { runs.removeLast() }
        save()
        return run.id
    }

    func recordStep(_ name: String, status: HakoShortcutRun.Status, runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].steps.append(.init(name: name, status: status))
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
            flags.isExcludedFromBackup = true
            try? directory.setResourceValues(flags)
            try JSONEncoder().encode(runs).write(to: fileURL, options: .atomic)
            storageIssue = nil
        } catch {
            storageIssue = "快捷指令记录暂时无法保存到本机。"
        }
    }
}
