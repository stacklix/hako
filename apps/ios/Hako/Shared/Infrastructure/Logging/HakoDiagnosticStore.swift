import Foundation

struct HakoDiagnosticBreadcrumb: Codable, Sendable {
    let time: Date
    let event: String
    let detail: String
    var text: String { "\(ISO8601DateFormatter().string(from: time)) · \(event)" + (detail.isEmpty ? "" : " · \(detail)") }
}

struct HakoDiagnosticReport: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case localHang, systemHang, crash, presentation
        var title: String {
            switch self {
            case .localHang: "主线程响应检测"
            case .systemHang: "系统卡顿报告"
            case .crash: "系统崩溃报告"
            case .presentation: "弹层切换异常"
            }
        }
    }
    let id: UUID
    let time: Date
    let updatedAt: Date
    let kind: Kind
    let detail: String
    let fingerprint: String?
    let version: String
    let build: String
    let breadcrumbs: [HakoDiagnosticBreadcrumb]

    var entry: HakoLogEntry {
        HakoLogEntry(id: id, time: time, source: .hako, level: kind == .crash ? .error : .warning,
            message: kind.title, detail: detail + "\n\n接收/检测版本：\(version) (\(build))\n最后更新：\(updatedAt)" +
                (breadcrumbs.isEmpty ? "" : "\n\n相关操作轨迹（当前进程；系统报告不保证与这些操作属于同一次故障）：\n" + breadcrumbs.map(\.text).joined(separator: "\n")))
    }
}

/// Independent from the rolling HTTP log. Only this serial queue touches the
/// files; a blocked main thread is never needed to persist a detected stall.
final class HakoDiagnosticStore: @unchecked Sendable {
    static let shared = HakoDiagnosticStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("HakoLogs/Diagnostics", isDirectory: true))
    static let capacity = 100
    static let byteLimit = 8 * 1_024 * 1_024
    static let breadcrumbCapacity = 100
    private let queue = DispatchQueue(label: "me.stackli.hako.diagnostic-storage", qos: .utility)
    private let directory: URL?
    private let capacity: Int
    private let byteLimit: Int
    private let version: String
    private let build: String
    private var reports: [UUID: HakoDiagnosticReport] = [:]
    private var sizes: [UUID: Int] = [:]
    private var breadcrumbs: [HakoDiagnosticBreadcrumb] = []
    private var issue: String?
    private var breadcrumbSavePending = false

    init(directory: URL?, capacity: Int = HakoDiagnosticStore.capacity, byteLimit: Int = HakoDiagnosticStore.byteLimit) {
        self.directory = directory; self.capacity = max(1, capacity); self.byteLimit = max(1_024, byteLimit)
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        queue.async { self.load() }
    }

    func breadcrumb(_ event: String, detail: String = "") {
        let value = HakoDiagnosticBreadcrumb(time: .now, event: HakoLog.sanitize(event, limit: 160), detail: HakoLog.sanitize(detail, limit: 1_024))
        queue.async {
            self.breadcrumbs.append(value)
            self.breadcrumbs = Array(self.breadcrumbs.suffix(Self.breadcrumbCapacity))
            guard !self.breadcrumbSavePending else { return }
            self.breadcrumbSavePending = true
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                guard self.breadcrumbSavePending else { return }
                self.breadcrumbSavePending = false
                self.saveBreadcrumbs()
            }
        }
    }

    func record(_ kind: HakoDiagnosticReport.Kind, detail: String, id: UUID = UUID(), time: Date = .now, fingerprint: String? = nil) {
        let cleaned = HakoLog.sanitize(detail, limit: 512 * 1_024)
        let clipped = cleaned + (detail.utf8.count > 512 * 1_024 ? "\n[诊断正文超出 512 KiB，已截断]" : "")
        queue.async {
            if let fingerprint, self.reports.values.contains(where: { $0.fingerprint == fingerprint }) { return }
            let previous = self.reports[id]
            let report = HakoDiagnosticReport(id: id, time: previous?.time ?? time, updatedAt: .now,
                kind: kind, detail: clipped, fingerprint: fingerprint, version: self.version, build: self.build,
                breadcrumbs: previous?.breadcrumbs ?? self.breadcrumbs)
            self.reports[id] = report
            do {
                let data = try JSONEncoder().encode(report)
                self.sizes[id] = data.count
                try self.write(data, named: id.uuidString + ".report.json")
            } catch { self.issue = "诊断记录无法保存到本机；当前进程中的记录仍可查看。" }
            self.trim()
        }
    }

    func snapshot() async -> (reports: [HakoDiagnosticReport], breadcrumbs: [HakoDiagnosticBreadcrumb], issue: String?) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.sortedReports(), self.breadcrumbs, self.issue))
            }
        }
    }

    func clear() async {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    if let directory = self.directory, FileManager.default.fileExists(atPath: directory.path) {
                        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        where file.lastPathComponent == "breadcrumbs.json" || self.reportID(file) != nil {
                            try FileManager.default.removeItem(at: file)
                        }
                    }
                    self.reports.removeAll(); self.sizes.removeAll(); self.breadcrumbs.removeAll(); self.issue = nil
                    self.breadcrumbSavePending = false
                } catch { self.issue = "诊断记录未能全部清除，请重试。" }
                continuation.resume()
            }
        }
    }

    // Tests can wait for actual disk completion without depending on a sleep.
    func flush() { queue.sync { breadcrumbSavePending = false; saveBreadcrumbs() } }

    private func sortedReports() -> [HakoDiagnosticReport] { reports.values.sorted { $0.time > $1.time } }

    private func reportID(_ file: URL) -> UUID? {
        let name = file.lastPathComponent
        guard name.hasSuffix(".report.json") else { return nil }
        return UUID(uuidString: String(name.dropLast(".report.json".count)))
    }

    private func load() {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 2 * 1_024 * 1_024 else { continue }
                do {
                    if let id = reportID(file) {
                        let data = try Data(contentsOf: file)
                        let report = try JSONDecoder().decode(HakoDiagnosticReport.self, from: data)
                        guard report.id == id else { continue }
                        reports[id] = report; sizes[id] = data.count
                    } else if file.lastPathComponent == "breadcrumbs.json" {
                        breadcrumbs = Array(try JSONDecoder().decode([HakoDiagnosticBreadcrumb].self, from: Data(contentsOf: file)).suffix(Self.breadcrumbCapacity))
                    }
                } catch { issue = "部分诊断记录无法读取，其余记录仍可查看。" }
            }
            trim()
        } catch { issue = "无法读取之前的诊断记录。" }
    }

    private func trim() {
        for report in sortedReports().reversed() {
            guard reports.count > capacity || sizes.values.reduce(0, +) > byteLimit else { break }
            do {
                if let directory {
                    let file = directory.appendingPathComponent(report.id.uuidString + ".report.json")
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            } catch { issue = "较早的诊断记录暂时无法清理。" }
            // Storage errors must not cause an unbounded in-memory diagnostic log.
            reports[report.id] = nil; sizes[report.id] = nil
        }
    }

    private func saveBreadcrumbs() {
        do { try write(JSONEncoder().encode(breadcrumbs), named: "breadcrumbs.json") }
        catch { issue = "操作轨迹无法保存到本机。" }
    }

    private func write(_ data: Data, named name: String) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var file = directory.appendingPathComponent(name)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = !UserDefaults.standard.bool(forKey: "hako.icloud.includeHistory")
        try file.setResourceValues(flags)
    }
}
