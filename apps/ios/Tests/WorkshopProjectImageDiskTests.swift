import Foundation

// The disk cache receives SHA-256 from WorkshopStore. A deterministic fixture digest keeps
// these IO, corruption and eviction tests runnable without Apple frameworks as well.
private func fixtureHash(_ bytes: Data) -> String {
    let sum = bytes.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
    return String(repeating: String(format: "%016llx", sum), count: 4)
}

@main struct WorkshopProjectImageDiskTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hako-image-cache-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("persist.image")
        let bytes = Data("image content".utf8), revision = fixtureHash(bytes)
        let disk = WorkshopProjectImageDisk(maximumImageBytes: 128, maximumDiskBytes: 1024, hash: { fixtureHash($0) })
        let missing = await disk.read(file)
        precondition(missing == nil)
        try await disk.write(bytes, revision: revision, to: file)
        let restarted = WorkshopProjectImageDisk(maximumImageBytes: 128, maximumDiskBytes: 1024, hash: { fixtureHash($0) })
        let restored = await restarted.read(file)
        precondition(restored?.0 == bytes && restored?.1 == revision, "App restart must retain bytes and the exact revision")
        let changed = Data("new image".utf8)
        try await disk.write(changed, revision: fixtureHash(changed), to: file)
        let latest = await restarted.read(file)
        precondition(latest?.0 == changed && latest?.1 == fixtureHash(changed), "Atomic replacement must retain one complete revision")

        var payload = try Data(contentsOf: file)
        payload[payload.count - 1] ^= 1
        try payload.write(to: file)
        let damaged = await disk.read(file)
        precondition(damaged == nil && !FileManager.default.fileExists(atPath: file.path), "Corrupted bytes must be discarded before reuse")
        for payload in [Data("truncated".utf8), Data(repeating: 0, count: 200)] {
            try payload.write(to: file)
            let invalid = await disk.read(file)
            precondition(invalid == nil && !FileManager.default.fileExists(atPath: file.path))
        }
        do { try await disk.write(bytes, revision: String(repeating: "0", count: 64), to: file); preconditionFailure("Wrong digest accepted") }
        catch is CocoaError { }
        let huge = Data(repeating: 7, count: 129)
        do { try await disk.write(huge, revision: fixtureHash(huge), to: file); preconditionFailure("Oversize image accepted") }
        catch is CocoaError { }

        let bounded = WorkshopProjectImageDisk(maximumImageBytes: 128, maximumDiskBytes: 330, hash: { fixtureHash($0) })
        let folder = root.appendingPathComponent("bounded", isDirectory: true)
        let first = folder.appendingPathComponent("a.image"), second = folder.appendingPathComponent("b.image"), third = folder.appendingPathComponent("c.image")
        let sample = Data(repeating: 1, count: 100)
        try await bounded.write(sample, revision: fixtureHash(sample), to: first)
        try await bounded.write(sample, revision: fixtureHash(sample), to: second)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: second.path)
        _ = await bounded.read(first)
        try await bounded.write(sample, revision: fixtureHash(sample), to: third)
        precondition(FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path) &&
            FileManager.default.fileExists(atPath: third.path), "Eviction must retain the newly written and recently read entries")
        let total = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        precondition(total <= 330, "Image cache exceeded its disk budget")
        print("PASS: project image disk persistence, revision replacement, corruption recovery, size bounds and LRU eviction")
    }
}
