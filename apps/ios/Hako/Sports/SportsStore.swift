import Foundation
import SwiftUI
import CryptoKit

@MainActor final class SportsStore: ObservableObject {
    @Published private(set) var state = SportsState()
    @Published private(set) var syncing = false
    @Published private(set) var message: String?
    private let file: URL
    private var storageReady = false
    private let github: SportsGitHub

    init(repository: any GitHubRepositoryAccess = AppServices.gitHub(), directory: URL? = nil) {
        self.github = SportsGitHub(repository: repository)
        let scope = repository.storageScope
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = directory ?? URL.applicationSupportDirectory.appendingPathComponent("Hako/Sports", isDirectory: true)
        file = root.appendingPathComponent(name + ".json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(SportsState.self, from: Data(contentsOf: file))
                try saved.validate()
                state = saved
            }
            storageReady = true
        } catch { message = "本地运动数据无法读取，已停止同步以保留原文件：\(error.localizedDescription)" }
    }

    var records: [SportsRecord] { state.records.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date } }
    var pendingCount: Int { state.operations.count }
    func isPending(_ id: UUID) -> Bool { state.operations.contains { $0.recordID == id } }

    private func persist(_ value: SportsState) throws {
        guard storageReady else { throw SportsError(message: "本地运动数据尚未安全读取，不能覆盖。") }
        try value.validate()
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        state = value
    }

    func save(_ record: SportsRecord) throws {
        guard !syncing else { throw SportsError(message: "正在自动同步，请完成后再编辑。") }
        var value = state
        try value.save(record)
        try persist(value)
    }

    func delete(_ id: UUID) throws {
        guard !syncing else { throw SportsError(message: "正在自动同步，请完成后再删除。") }
        var value = state
        value.delete(id)
        try persist(value)
    }

    // Called on entry only. Local edits remain pending until the next entry.
    func synchronize() async {
        guard !syncing, storageReady else { return }
        syncing = true
        message = nil
        defer { syncing = false }
        do {
            for attempt in 0..<3 {
                try Task.checkCancellation()
                let years = Set(state.records.map(\.year)).union(state.operations.flatMap(\.years))
                let remote = try await github.sportsPull(localYears: years)
                let merged = try SportsMerge.apply(local: state, remote: remote)
                let files = SportsMerge.files(local: merged, remote: remote)
                // Keep a successful pull even when the subsequent upload fails.
                try persist(merged)
                if try await github.sportsCommit(files: files, head: remote.head) {
                    var confirmed = merged
                    confirmed.operations = []
                    confirmed.syncedAt = .now
                    try persist(confirmed)
                    return
                }
                if attempt == 2 { throw SportsError(message: "GitHub 分支持续变化，请下次进入时重试。") }
            }
        } catch is CancellationError {
            // Navigating away must not report an ordinary cancelled read as a network error.
        } catch {
            message = "同步失败：\(error.localizedDescription)\n本地数据与未同步变更已保留，下次进入时自动重试。"
        }
    }
}
