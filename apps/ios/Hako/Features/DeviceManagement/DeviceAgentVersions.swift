import Foundation

struct DeviceAgentVersions: Decodable {
    static let command = "admin.agent.versions"
    enum LatestCheckState: String, Decodable { case available, noRelease = "no_release", unavailable }
    let currentVersion: String
    let currentBuild: String
    let minimumServerVersion: String
    let latestVersion: String?
    let latestBuildId: Int64?
    let latestCheckedAt: String
    let latestCheckState: LatestCheckState

    var isValid: Bool {
        guard Self.versionParts(currentVersion) != nil, Self.versionParts(minimumServerVersion) != nil,
              !currentBuild.isEmpty, !latestCheckedAt.isEmpty else { return false }
        switch latestCheckState {
        case .available:
            return latestVersion.flatMap(Self.versionParts) != nil && (latestBuildId ?? 0) > 0
        case .noRelease, .unavailable:
            return latestVersion == nil && latestBuildId == nil
        }
    }
    var expectedServerVersion: String {
        guard let parts = Self.versionParts(minimumServerVersion) else { return "版本信息无效" }
        return "\(parts[0]).\(parts[1]).x（最低 \(minimumServerVersion)）"
    }
    var latestVersionLabel: String {
        switch latestCheckState {
        case .available: latestVersion ?? "版本信息无效"
        case .noRelease: "暂无发布版本"
        case .unavailable: "暂时无法查询"
        }
    }
    private static func versionParts(_ value: String) -> [Int32]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int32($0) }
        return numbers.count == 3 ? numbers : nil
    }
}
