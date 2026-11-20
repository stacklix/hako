import Foundation

enum CloudPreferenceValue: Codable, Equatable {
    case text(String), flag(Bool), bytes(Data)

    var object: Any {
        switch self { case .text(let value): return value; case .flag(let value): return value; case .bytes(let value): return value }
    }
}

struct CloudPreferenceRecord: Codable, Equatable {
    let key: String
    let value: CloudPreferenceValue?
    let modifiedAt: Date
    let writer: String
    var isSeed: Bool { modifiedAt.timeIntervalSince1970 < 0 }
}

struct CloudPreferenceState: Codable {
    static let textKeys: Set<String> = ["hako.appearance", "console.serverURL", "console.username", "crypto.watchlist.customSymbols", "buildStatus.githubWorkflow"]
    static let flagKeys: Set<String> = ["investment.showArchived", "investment.showZeroPositions"]
    static let dataKeys: Set<String> = ["hako.applicationOrder", "github.settings", "github.private.settings", "hako.network.configuration", "hako.workshop.network.endpoints", "crypto.wallets"]
    static var allowedKeys: Set<String> { textKeys.union(flagKeys).union(dataKeys) }
    static let maximumRecordBytes = 64 * 1024
    static let maximumTotalBytes = 768 * 1024
    var records: [String: CloudPreferenceRecord] = [:]
    var pending: [String] = []

    static func value(_ object: Any, key: String) -> CloudPreferenceValue? {
        if textKeys.contains(key), let value = object as? String { return .text(value) }
        if dataKeys.contains(key), let value = object as? Data { return .bytes(value) }
        if flagKeys.contains(key), let value = object as? Bool { return .flag(value) }
        return nil
    }

    static func valid(_ record: CloudPreferenceRecord) -> Bool {
        guard allowedKeys.contains(record.key), record.modifiedAt.timeIntervalSince1970.isFinite,
              !record.writer.isEmpty, record.writer.utf8.count <= 64,
              record.writer.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return false }
        guard let value = record.value else { return true }
        switch value {
        case .text: return textKeys.contains(record.key)
        case .flag: return flagKeys.contains(record.key)
        case .bytes: return dataKeys.contains(record.key)
        }
    }

    mutating func observe(_ values: [String: CloudPreferenceValue], now: Date, writer: String, seedMissing: Bool = false) {
        for key in Self.allowedKeys {
            let value = values[key]
            if let previous = records[key] {
                if previous.value != value {
                    records[key] = CloudPreferenceRecord(key: key, value: value,
                        modifiedAt: max(now, previous.modifiedAt.addingTimeInterval(0.000_001)), writer: writer)
                    markPending(key)
                }
            } else if value != nil {
                // Existing local preferences seed an empty cloud store but never beat
                // values already saved by another device during first synchronization.
                // Reverse the creation time below the epoch: every deliberate edit
                // beats a seed, and earlier seeds beat a later installation's defaults.
                let timestamp = seedMissing ? Date(timeIntervalSince1970: -max(1, now.timeIntervalSince1970)) : now
                records[key] = CloudPreferenceRecord(key: key, value: value, modifiedAt: timestamp, writer: writer)
                markPending(key)
            }
        }
    }

    mutating func merge(_ remote: [String: CloudPreferenceRecord]) -> [CloudPreferenceRecord] {
        var applied: [CloudPreferenceRecord] = []
        for (key, record) in remote where key == record.key && Self.valid(record) {
            if let local = records[key] {
                if record == local { pending.removeAll { $0 == key }; continue }
                guard record.modifiedAt > local.modifiedAt || (record.modifiedAt == local.modifiedAt && record.writer > local.writer) else { continue }
            }
            records[key] = record
            pending.removeAll { $0 == key }
            applied.append(record)
        }
        return applied
    }

    private mutating func markPending(_ key: String) {
        if !pending.contains(key) { pending.append(key); pending.sort() }
    }
}
