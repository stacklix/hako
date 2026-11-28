import Foundation

// Separate from the state writer: image IO and hashing must not stall conversation restoration.
actor WorkshopProjectImageDisk {
    private let maximumImageBytes: Int
    private let maximumDiskBytes: Int
    private let hash: @Sendable (Data) -> String
    private var archivedDirectories: Set<URL> = []

    private func permits(_ file: URL) -> Bool { !archivedDirectories.contains(file.deletingLastPathComponent()) }

    func allow(_ directory: URL) { archivedDirectories.remove(directory) }

    func removeSession(_ directory: URL) throws {
        archivedDirectories.insert(directory)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    init(maximumImageBytes: Int = 8 * 1024 * 1024, maximumDiskBytes: Int = 128 * 1024 * 1024,
         hash: @escaping @Sendable (Data) -> String) {
        self.maximumImageBytes = maximumImageBytes
        self.maximumDiskBytes = maximumDiskBytes
        self.hash = hash
    }

    func read(_ file: URL) -> (Data, String)? {
        guard permits(file) else { return nil }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 65, size <= maximumImageBytes + 65 else { throw CocoaError(.coderReadCorrupt) }
            let payload = try Data(contentsOf: file)
            guard payload.count == size, payload[64] == 10,
                  let revision = String(data: payload.prefix(64), encoding: .ascii), validRevision(revision) else {
                throw CocoaError(.coderReadCorrupt)
            }
            let bytes = Data(payload.dropFirst(65))
            guard hash(bytes) == revision else { throw CocoaError(.coderReadCorrupt) }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return (bytes, revision)
        } catch {
            // A cache miss or damaged entry must not prevent a fresh read from the computer.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    func write(_ bytes: Data, revision: String, to file: URL, budgetDirectory: URL? = nil) throws {
        guard permits(file) else { return }
        guard !bytes.isEmpty, bytes.count <= maximumImageBytes, bytes.count + 65 <= maximumDiskBytes,
              validRevision(revision), hash(bytes) == revision else { throw CocoaError(.coderInvalidValue) }
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
        var payload = Data((revision + "\n").utf8)
        payload.append(bytes)
        #if os(iOS)
        try payload.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try payload.write(to: file, options: .atomic)
        #endif
        try prune(budgetDirectory ?? directory, keeping: file)
    }

    func touch(_ file: URL) -> Bool {
        guard permits(file) else { return false }
        do {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    private func validRevision(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func prune(_ directory: URL, keeping file: URL) throws {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let entries = ((FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL]) ?? [])
            .filter { $0.pathExtension == "image" }
            .compactMap { url -> (url: URL, size: Int, used: Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.filter({ $0.url != file }).sorted(by: { $0.used < $1.used }) where total > maximumDiskBytes {
            try FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
