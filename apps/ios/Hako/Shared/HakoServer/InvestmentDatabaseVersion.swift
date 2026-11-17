import Foundation

struct InvestmentDatabaseVersion: Decodable, Equatable, Sendable {
    let version: Int
    let expectedVersion: Int

    var versionLabel: String { "schema \(version)" }
    var expectedVersionLabel: String { "schema \(expectedVersion)" }
    var matchesExpected: Bool { version == expectedVersion }
    var statusLabel: String {
        if matchesExpected { return "已是目标版本" }
        return version < expectedVersion ? "数据库待升级" : "数据库版本高于目标"
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version > 0, value.expectedVersion > 0 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }
}
