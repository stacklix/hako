import Foundation

// A later durable send must not be overwritten by an older background acknowledgement.
final class WorkshopPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.stackli.hako.workshop.state", qos: .utility)
    private struct Pending {
        let save: () throws -> Void
        var completions: [@Sendable (Result<Void, Error>) -> Void]
    }
    private var pending: [URL: Pending] = [:]
    private var scheduled = false
    private let delay: TimeInterval
    private let writeData: @Sendable (Data, URL) throws -> Void

    init(delay: TimeInterval = 0.25,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { try WorkshopPersistence.save($0, to: $1) }) {
        self.delay = delay
        self.writeData = writeData
    }

    func read<Value: Decodable>(_ type: Value.Type, from file: URL) throws -> Value {
        try queue.sync { drain(file); return try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
    }

    func readAsync<Value: Decodable & Sendable>(_ type: Value.Type, from file: URL) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.drain(file)
                continuation.resume(with: Result { try JSONDecoder().decode(type, from: Data(contentsOf: file)) })
            }
        }
    }

    func write<Value: Encodable & Sendable>(_ value: Value, to file: URL) throws {
        try queue.sync {
            drain(file)
            try writeData(JSONEncoder().encode(value), file)
        }
    }

    func schedule<Value: Encodable & Sendable>(_ value: Value, to file: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            let callbacks = (self.pending[file]?.completions ?? []) + [completion]
            self.pending[file] = Pending(save: { try self.writeData(JSONEncoder().encode(value), file) }, completions: callbacks)
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + self.delay) {
                self.scheduled = false
                self.drain()
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { self.drain(); continuation.resume() }
        }
    }

    func remove(_ file: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.drain(file)
                continuation.resume(with: Result {
                    do { try FileManager.default.removeItem(at: file) }
                    catch let error as CocoaError where error.code == .fileNoSuchFile { }
                })
            }
        }
    }

    private func drain(_ file: URL? = nil) {
        let writes: [Pending]
        if let file { writes = pending.removeValue(forKey: file).map { [$0] } ?? [] }
        else { writes = Array(pending.values); pending.removeAll() }
        for write in writes {
            let result = Result { try write.save() }
            for completion in write.completions { completion(result) }
        }
    }

    private static func save(_ bytes: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: file, options: .atomic)
        #endif
        var url = file
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
    }
}
