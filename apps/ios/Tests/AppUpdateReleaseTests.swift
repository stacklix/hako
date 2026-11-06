import Foundation

@main struct AppUpdateReleaseTests {
    static func main() throws {
        let installed = AppBuildVersion(version: "0.1.0", build: "2160.9.99")!
        precondition(AppBuildVersion(version: "0.1.0", build: "2160.10.0")! > installed)
        precondition(AppBuildVersion(version: "0.2.0", build: "1")! > installed)
        precondition(AppBuildVersion(version: "0.0.9", build: "3000.0.0")! < installed)
        precondition(AppBuildVersion(version: "0.1.0", build: "192")! < installed)
        precondition(AppBuildVersion(version: "0.1", build: "192") == AppBuildVersion(version: "0.1.0", build: "192.0.0"))
        for invalid in ["", "-1", "1..2", "1.2.3.4", "a.b", " 1"] {
            precondition(AppBuildVersion(version: "0.1.0", build: invalid) == nil)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(AppUpdateRelease.self, from: Data(
            #"{"version":"0.1.0","build":"2160.10.0","builtAt":"2026-11-05T17:09:12+08:00","manifest":"manifest-0123456789abcdef.plist","summary":"显示构建变更摘要"}"#.utf8))
        let legacy = try decoder.decode(AppUpdateRelease.self, from: Data(
            #"{"version":"0.1.0","build":"192","builtAt":"2026-11-05T08:56:08Z"}"#.utf8))
        precondition(current.manifestName == "manifest-0123456789abcdef.plist" && legacy.manifestName == "manifest.plist")
        precondition(current.summary == "显示构建变更摘要" && legacy.summary == nil)
        let unsafe = AppUpdateRelease(version: "0.1.0", build: "2160.10.0", builtAt: .now, manifest: "../manifest.plist", summary: nil)
        precondition(unsafe.manifestName == nil)
        print("App update: numeric version ordering, legacy metadata and pinned manifests passed")
    }
}
