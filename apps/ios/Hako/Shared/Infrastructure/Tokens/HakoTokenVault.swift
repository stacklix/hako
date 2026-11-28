import Foundation

struct HakoTokenField: Codable, Equatable, Identifiable {
    let key: String
    let title: String
    var id: String { key }
}

struct HakoTokenDefinition: Identifiable {
    let id: String
    let title: String
    let applications: [String]
    var applicationIDs: [String] = []
    let fields: [HakoTokenField]
    var validatorID = ""
}

enum HakoTokenError: LocalizedError {
    case unknown, invalidDeclaration, invalidRecord, incomplete, invalidValue
    var errorDescription: String? {
        switch self {
        case .unknown: "未找到此 API Token 的声明。"
        case .invalidDeclaration: "API Token 声明的标识或 key 重复、缺失。"
        case .invalidRecord: "无法读取主应用保存的 API Token 与关联信息，原数据已保留。"
        case .incomplete: "请填写这组凭据的全部字段；清除时请将全部字段留空。"
        case .invalidValue: "API Token 只能包含可见 ASCII 字符。"
        }
    }
}

/// One Keychain item holds a complete credential pair and its associations.
/// An explicit clear is persisted as an empty record with its associations intact.
final class HakoTokenVault {
    static let didSave = Notification.Name("hako.financial-tokens.saved")
    struct Record: Codable, Equatable {
        var version = 1
        let id: String
        var title: String
        var applications: [String]
        var applicationIDs: [String]
        var fields: [HakoTokenField]
        var values: [String: String]
        // Historical origin metadata in the persisted v1 format; no import logic.
        var migrated: Bool
    }

    private let storage: any SecretStorage
    private let declarations: () throws -> [HakoTokenDefinition]
    private let lock = NSRecursiveLock()

    init(storage: any SecretStorage, definitions: @escaping () throws -> [HakoTokenDefinition]) {
        self.storage = storage
        self.declarations = definitions
    }

    func definitions() throws -> [HakoTokenDefinition] {
        let definitions = try declarations()
        var ids = Set<String>(), keys = Set<String>()
        for definition in definitions {
            guard !definition.id.isEmpty, !definition.title.isEmpty, !definition.applications.isEmpty,
                  !definition.fields.isEmpty, ids.insert(definition.id).inserted else { throw HakoTokenError.invalidDeclaration }
            for field in definition.fields {
                guard !field.key.isEmpty, !field.title.isEmpty, keys.insert(field.key).inserted else {
                    throw HakoTokenError.invalidDeclaration
                }
            }
        }
        return definitions.sorted { $0.id < $1.id }
    }

    private func definition(_ id: String) throws -> HakoTokenDefinition {
        guard let definition = try definitions().first(where: { $0.id == id }) else { throw HakoTokenError.unknown }
        return definition
    }

    func read(_ id: String) throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        let definition = try definition(id)
        if let data = try storage.read(account: id) {
            guard var record = try? JSONDecoder().decode(Record.self, from: data),
                  record.version == 1, record.id == id,
                  Set(record.values.keys) == Set(definition.fields.map(\.key)) else { throw HakoTokenError.invalidRecord }
            // Refresh declaration metadata while preserving the stored values.
            if record.fields != definition.fields || record.applications != definition.applications || record.applicationIDs != definition.applicationIDs || record.title != definition.title {
                record.fields = definition.fields
                record.applications = definition.applications
                record.applicationIDs = definition.applicationIDs
                record.title = definition.title
                try persist(record)
            }
            return record
        }
        // Reading a missing item is side-effect free; only explicit saves create it.
        return Record(id: id, title: definition.title, applications: definition.applications,
                      applicationIDs: definition.applicationIDs, fields: definition.fields,
                      values: Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.key, "") }), migrated: false)
    }

    func readKey(_ key: String) throws -> String {
        let definition = try definition(containing: key)
        return try read(definition.id).values[key] ?? ""
    }

    func definition(containing key: String) throws -> HakoTokenDefinition {
        guard let definition = try definitions().first(where: { $0.fields.contains { $0.key == key } }) else { throw HakoTokenError.unknown }
        return definition
    }

    func saveKey(_ key: String, value: String) throws {
        guard let definition = try definitions().first(where: { $0.fields.map(\.key) == [key] }) else { throw HakoTokenError.incomplete }
        try save([key: value], for: definition.id)
    }

    func save(_ values: [String: String], for id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let definition = try definition(id)
        guard Set(values.keys) == Set(definition.fields.map(\.key)) else { throw HakoTokenError.invalidDeclaration }
        let cleaned = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cleaned.values.allSatisfy({ $0.isEmpty }) || cleaned.values.allSatisfy({ !$0.isEmpty }) else {
            throw HakoTokenError.incomplete
        }
        guard cleaned.values.allSatisfy({ $0.utf8.allSatisfy { (33...126).contains($0) } }) else {
            throw HakoTokenError.invalidValue
        }
        var record = try read(id)
        record.values = cleaned
        try persist(record)
        NotificationCenter.default.post(name: Self.didSave, object: nil, userInfo: ["id": id])
    }

    private func persist(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        try storage.save(data, account: record.id, accessibility: .afterFirstUnlock)
        guard try storage.read(account: record.id) == data else { throw HakoTokenError.invalidRecord }
    }
}
