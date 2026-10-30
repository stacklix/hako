import Foundation

enum HakoLogSource: String, Codable, CaseIterable, Sendable {
    case hako = "Hako", cloudServers = "云服务器", containers = "容器管理", devices = "设备监控", usage = "使用时间"
}

enum HakoLogLevel: String, Codable, CaseIterable, Sendable {
    case info = "信息", warning = "警告", error = "错误"
}

struct HakoLogEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let time: Date
    let source: HakoLogSource
    let level: HakoLogLevel
    let message: String
    let detail: String

    var text: String {
        "[\(time.formatted(date: .numeric, time: .standard))] [\(source.rawValue)] [\(level.rawValue)] \(message)"
            + (detail.isEmpty ? "" : "\n\(detail)")
    }
}

// A serial queue orders appends, reads and clears, and keeps disk writes off the UI thread.
// Only curated diagnostic fields are logged; HTTP bodies, headers and terminal I/O are excluded.
final class HakoLogStore: @unchecked Sendable {
    static let shared = HakoLogStore(fileURL: defaultFileURL())
    static let capacity = 1_000
    private let queue = DispatchQueue(label: "me.stackli.hako.logs", qos: .utility)
    private let fileURL: URL?
    private var values: [HakoLogEntry] = []
    private var pendingSave = false
    private var saveTicket = UUID()
    private var storageIssue: String?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            values = Array(try JSONDecoder().decode([HakoLogEntry].self, from: Data(contentsOf: fileURL)).suffix(Self.capacity))
        } catch { storageIssue = "无法读取之前的日志；本次日志仍可查看。" }
    }

    func append(source: HakoLogSource, level: HakoLogLevel, message: String, detail: String = "", secrets: [String] = []) {
        let entry = HakoLogEntry(id: UUID(), time: .now, source: source, level: level,
            message: HakoLog.sanitize(message, secrets: secrets, limit: 512),
            detail: HakoLog.sanitize(detail, secrets: secrets, limit: 3_072))
        queue.async {
            self.values.append(entry)
            if self.values.count > Self.capacity { self.values.removeFirst(self.values.count - Self.capacity) }
            guard !self.pendingSave else { return }
            self.pendingSave = true
            let ticket = UUID(); self.saveTicket = ticket
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                guard self.pendingSave, self.saveTicket == ticket else { return }
                self.pendingSave = false; self.save()
            }
        }
    }

    func snapshot() -> (entries: [HakoLogEntry], issue: String?) { queue.sync { (Array(values.reversed()), storageIssue) } }
    func clear() { queue.sync { pendingSave = false; saveTicket = UUID(); values.removeAll(); save() } }
    // Also used by deterministic storage tests.
    func flush() { queue.sync { pendingSave = false; saveTicket = UUID(); save() } }

    private func save() {
        guard var fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try fileURL.setResourceValues(flags)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
            #endif
            storageIssue = nil
        } catch { storageIssue = "日志无法保存到本机；当前会话中的日志仍可查看。" }
    }
    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HakoLogs", isDirectory: true).appendingPathComponent("events.json")
    }
}

enum HakoLog {
    static func record(_ source: HakoLogSource, _ level: HakoLogLevel = .info, _ message: String,
                       detail: String = "", secrets: [String] = []) {
        HakoLogStore.shared.append(source: source, level: level, message: message, detail: detail, secrets: secrets)
    }

    // All query values are hidden, even for unknown future credential parameter names.
    // Invalid URLs are never echoed: regex replacement alone cannot safely handle them.
    static func safeURL(_ text: String) -> String {
        guard text.count <= 16_384, var parts = URLComponents(string: text),
              let scheme = parts.scheme, ["http", "https", "ws", "wss"].contains(scheme.lowercased()),
              let host = parts.host, !host.isEmpty else { return "[连接地址缺失或格式无效]" }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        parts.queryItems = parts.queryItems?.map { URLQueryItem(name: $0.name, value: "[已隐藏]") }
        return parts.string ?? "[连接地址格式无效]"
    }

    static func sanitize(_ text: String, secrets: [String] = [], limit: Int = 4_096) -> String {
        var value = text
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: secret, with: "[已隐藏]")
            value = value.replacingOccurrences(of: secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret, with: "[已隐藏]")
        }
        // Defense in depth for accidental URL/header/key-value diagnostics.
        for pattern in [#"(?i)(bearer|dpop)\s+[A-Za-z0-9._~+/=-]+"#,
                        #"(?i)([?&][^=\s&]+)=([^&\s]+)"#,
                        #"(?i)(accesskeysecret|accesskeyid|securitytoken|password|api[ _-]?key|authorization|token|signature)\s*[=:]\s*[^\s,;]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "$1=[已隐藏]", options: .regularExpression)
        }
        // Drop control bytes that otherwise expand to six-byte JSON escapes.
        value = value.replacingOccurrences(of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#, with: "", options: .regularExpression)
        return String(decoding: value.utf8.prefix(limit), as: UTF8.self)
    }
}
