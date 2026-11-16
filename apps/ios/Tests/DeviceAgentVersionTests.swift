import Foundation

@main struct DeviceAgentVersionTests {
    static func main() throws {
        let payload = #"{"currentVersion":"1.3.1","currentBuild":"1.3.1+abc","minimumServerVersion":"0.6.2","latestVersion":"1.3.9","latestBuildId":123,"latestCheckedAt":"2026-11-16T01:00:00Z","latestCheckState":"available"}"#
        func decode(_ text: String) throws -> DeviceAgentVersions {
            try JSONDecoder().decode(DeviceAgentVersions.self, from: Data(text.utf8))
        }
        let versions = try decode(payload)
        precondition(versions.isValid && versions.currentVersion == "1.3.1" && versions.latestVersionLabel == "1.3.9")
        precondition(versions.expectedServerVersion == "0.6.x（最低 0.6.2）")
        for invalid in [payload.replacingOccurrences(of: "0.6.2", with: "0.6"),
                        payload.replacingOccurrences(of: "0.6.2", with: "0.7.x"),
                        payload.replacingOccurrences(of: "1.3.1", with: "1.3.-1"),
                        payload.replacingOccurrences(of: "123", with: "0"),
                        payload.replacingOccurrences(of: "available", with: "unavailable")] {
            let decoded = try decode(invalid)
            precondition(!decoded.isValid)
        }
        let unknown = payload.replacingOccurrences(of: #""latestVersion":"1.3.9","latestBuildId":123,"#, with: "")
        let failed = try decode(unknown.replacingOccurrences(of: "available", with: "unavailable"))
        precondition(failed.isValid && failed.latestVersionLabel == "暂时无法查询" && failed.currentVersion == "1.3.1")
        let empty = try decode(unknown.replacingOccurrences(of: "available", with: "no_release"))
        precondition(empty.isValid && empty.latestVersionLabel == "暂无发布版本")
        print("Agent version payload, compatibility range, invalid metadata and release failure tests passed")
    }
}
