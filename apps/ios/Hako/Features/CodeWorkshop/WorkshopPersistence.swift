import Foundation

// A later durable send must not be overwritten by an older background acknowledgement.
final class WorkshopPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.stackli.hako.workshop.state", qos: .utility)

    func read<Value: Decodable>(_ type: Value.Type, from file: URL) throws -> Value {
        try queue.sync { try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
    }

    func write<Value: Encodable & Sendable>(_ value: Value, to file: URL) throws {
        try queue.sync { try Self.save(value, to: file) }
    }

    func schedule<Value: Encodable & Sendable>(_ value: Value, to file: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { completion(Result { try Self.save(value, to: file) }) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private static func save<Value: Encodable>(_ value: Value, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(value)
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
