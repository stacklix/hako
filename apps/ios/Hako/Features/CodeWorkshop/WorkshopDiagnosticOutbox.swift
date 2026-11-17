import Foundation

struct WorkshopDiagnosticRecord: Codable, Sendable {
    let id: UUID
    let time: Date
    let event: String
    let detail: String
}

// Per-account spool, bounded independently of the visible app log. Only generated
// transport metadata is admitted; no messages, URLs or exception descriptions.
actor WorkshopDiagnosticOutbox {
    static let shared = WorkshopDiagnosticOutbox()
    private var records: [URL: [WorkshopDiagnosticRecord]] = [:]

    private func load(_ file: URL) -> [WorkshopDiagnosticRecord] {
        if let values = records[file] { return values }
        let values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([WorkshopDiagnosticRecord].self, from: $0) } ?? []
        records[file] = Array(values.suffix(512))
        return records[file]!
    }
    func append(_ event: String, detail: String, file: URL) throws {
        var values = load(file)
        values.append(WorkshopDiagnosticRecord(id: UUID(), time: .now, event: event, detail: String(detail.prefix(1800))))
        values = Array(values.suffix(512))
        try save(values, file: file)
    }
    func batch(file: URL) -> [WorkshopDiagnosticRecord] { Array(load(file).prefix(8)) }
    func acknowledge(_ ids: Set<UUID>, file: URL) throws { try save(load(file).filter { !ids.contains($0.id) }, file: file) }
    private func save(_ values: [WorkshopDiagnosticRecord], file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        records[file] = values
        var location = file
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try? location.setResourceValues(flags)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
    }
}
