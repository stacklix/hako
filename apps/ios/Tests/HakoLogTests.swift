import Foundation

@main struct HakoLogTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hako-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.json")
        let store = HakoLogStore(fileURL: file)

        // Preserve precisely the endpoint fields needed to diagnose the Aliyun rejection.
        let raw = "wss://name:password@cn-chengdu.axt.aliyuncs.com:443/session?sessionId=s-private&token=private-token&newCredential=unknown-secret#fragment-secret"
        let safe = HakoLog.safeURL(raw)
        precondition(safe.contains("cn-chengdu.axt.aliyuncs.com:443/session"))
        for secret in ["name", "password", "s-private", "private-token", "unknown-secret", "fragment-secret"] {
            precondition(!safe.contains(secret))
        }
        store.append(source: .cloudServers, level: .info, message: "阿里云返回终端连接地址", detail: safe)
        store.append(source: .containers, level: .error, message: "API Key=private-key", detail: "Bearer private-bearer\nAccessKeySecret=private-ak\n?token=private-query&other=private-other")
        store.append(source: .devices, level: .warning, message: "已知凭据", detail: "raw+secret raw%2Bsecret", secrets: ["raw+secret"])
        store.flush()
        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for secret in ["private-key", "private-bearer", "private-ak", "private-query", "private-other", "raw+secret", "raw%2Bsecret"] {
            precondition(!saved.contains(secret))
        }
        let restored = HakoLogStore(fileURL: file).snapshot().entries
        precondition(restored.count == 3 && restored[0].source == .devices && restored[2].source == .cloudServers)
        precondition(restored[2].detail.contains(":443/session"))
        precondition(!HakoLog.safeURL("not a URL secret").contains("secret"))

        // Concurrent producers are serialized; retention and clear survive a restart.
        DispatchQueue.concurrentPerform(iterations: 1_100) { index in
            store.append(source: .hako, level: .info, message: "event \(index)", detail: String(repeating: "中", count: 5_000))
        }
        store.flush()
        let bounded = store.snapshot().entries
        precondition(bounded.count == HakoLogStore.capacity && Set(bounded.map(\.id)).count == bounded.count)
        precondition(bounded.allSatisfy { $0.detail.utf8.count <= 4_100 })
        precondition(HakoLogStore(fileURL: file).snapshot().entries.count == HakoLogStore.capacity)
        store.clear()
        precondition(store.snapshot().entries.isEmpty && HakoLogStore(fileURL: file).snapshot().entries.isEmpty)

        try Data("broken JSON".utf8).write(to: file)
        let damaged = HakoLogStore(fileURL: file)
        precondition(damaged.snapshot().issue != nil)
        damaged.append(source: .usage, level: .info, message: "recovered")
        damaged.flush()
        precondition(damaged.snapshot().issue == nil)
        precondition(HakoLogStore(fileURL: file).snapshot().entries.first?.message == "recovered")
        let blocked = HakoLogStore(fileURL: file.appendingPathComponent("events.json"))
        blocked.append(source: .hako, level: .error, message: "still available in memory")
        blocked.flush()
        precondition(blocked.snapshot().issue != nil && blocked.snapshot().entries.count == 1)
        print("Hako log URL redaction, credentials, persistence, retention, concurrency and clear checks passed")
    }
}
