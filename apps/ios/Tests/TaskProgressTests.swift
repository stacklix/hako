import Foundation

@main struct TaskProgressTests {
    static func main() throws {
        let source = #"{"tasks":[{"id":"a","name":"App A","project":"a","platform":"iOS","status":"running","createdAt":1000,"updatedAt":2000,"stages":[{"id":"build","name":"编译","status":"running"}]},{"id":"b","name":"App B","project":"b","platform":"iOS","status":"succeeded","createdAt":1000,"updatedAt":2000,"stages":[],"release":{"bundleId":"com.example.b","version":"1.0.0","build":"123","metadataUrl":"https://example.com/b/latest.json"}}]}"#
        let snapshot = try JSONDecoder().decode(TaskProgressSnapshot.self, from: Data(source.utf8))
        precondition(snapshot.tasks.count == 2 && snapshot.tasks[0].id != snapshot.tasks[1].id)
        let unchanged = try JSONDecoder().decode(TaskProgressSnapshot.self, from: Data(source.utf8))
        precondition(snapshot == unchanged)
        let summarySource = source.replacingOccurrences(of: "\"name\":\"App A\"", with: "\"name\":\"App A\",\"summary\":\"Improve scrolling\"")
        let withSummary = try JSONDecoder().decode(TaskProgressSnapshot.self, from: Data(summarySource.utf8))
        precondition(withSummary.tasks[0].summary == "Improve scrolling" && withSummary.tasks[1].summary == nil)
        precondition(snapshot.tasks[0].stale(at: Date(timeIntervalSince1970: 63)))
        precondition(!snapshot.tasks[1].stale(at: Date(timeIntervalSince1970: 63)))
        precondition(snapshot.tasks[0].completedStages == 0 && snapshot.tasks[0].currentStage?.name == "编译")
        func task(_ id: String, created: Int64, updated: Int64, status: String) -> TaskProgressItem {
            TaskProgressItem(id: id, name: id, project: "app", platform: "iOS", status: status,
                createdAt: created, updatedAt: updated, stages: [], message: nil, release: nil, summary: nil)
        }
        let old = task("old", created: 1, updated: 999, status: "running")
        let latest = task("latest", created: 2, updated: 3, status: "succeeded")
        precondition(TaskProgressSnapshot(tasks: [latest, old], warning: nil).latestTask == latest,
            "Recent updates to an older build must not replace the most recently created build")
        precondition(TaskProgressSnapshot(tasks: [old, latest], warning: nil).latestTask == latest,
            "The most recent build must not depend on response ordering or message history")
        precondition(TaskProgressSnapshot(tasks: [], warning: nil).latestTask == nil)
        precondition(snapshot.latestTask?.id == "b", "Equal creation times need a stable selection")
        let eligible = TaskProgressSnapshot(tasks: [old, latest], warning: nil)
        precondition(eligible.latestTask(references: ["old"]) == old, "An older build still in the last ten turns must remain visible")
        precondition(eligible.latestTask(references: ["old", "latest"]) == latest)
        precondition(eligible.latestTask(references: []) == nil)
        precondition(eligible.latestTask(references: ["old-suffix", "prefix-latest"]) == nil)
        let xkode = task("xkode-0123456789abcdef0123456789abcdef", created: 1, updated: 999, status: "running")
        precondition(TaskProgressSnapshot(tasks: [xkode], warning: nil).latestTask(references: ["0123456789abcdef0123456789abcdef"]) == xkode)
        precondition(TaskProgressVersion(version: "1.0.0", build: "10")! > TaskProgressVersion(version: "1.0.0", build: "9")!)
        precondition(TaskProgressVersion(version: "2.0.0", build: "1")! > TaskProgressVersion(version: "1.0.0", build: "999")!)
        precondition(TaskProgressVersion(version: "1..0", build: "1") == nil)
        let metadata = TaskProgressReleaseMetadata(version: "1.0.0", build: "123", manifest: "manifest-abcd.plist")
        let base = URL(string: "https://example.com/b/latest.json")!
        let manifest = metadata.manifestURL(relativeTo: base)!
        precondition(manifest.absoluteString == "https://example.com/b/manifest-abcd.plist")
        precondition(TaskProgressReleaseMetadata(version: "1.0.0", build: "123", manifest: "../a.plist").manifestURL(relativeTo: base) == nil)
        for value in ["http://example.com/a", "https://user:secret@example.com/a", "file:///a", "https://example.com/a#fragment"] {
            precondition(TaskProgressReleaseMetadata.secureURL(value) == nil)
        }
        let object: [String: Any] = ["items": [["metadata": ["bundle-identifier": "com.example.b", "bundle-version": "123", "kind": "software"],
                                               "assets": [["kind": "software-package", "url": "https://example.com/b/app.ipa"]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        precondition(metadata.validatesManifest(data, bundleId: "com.example.b"))
        precondition(!metadata.validatesManifest(data, bundleId: "com.example.a"))
        precondition(!TaskProgressReleaseMetadata(version: "1.0.0", build: "124", manifest: "manifest.plist").validatesManifest(data, bundleId: "com.example.b"))
        let install = TaskProgressReleaseMetadata.installationURL(manifest: manifest)!
        precondition(install.scheme == "itms-services")
        precondition(URLComponents(url: install, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "url" }?.value == manifest.absoluteString)
        print("PASS: latest build selection, recent-ten-turn references, full task IDs and provider aliases, snapshot equality, numeric versions and secure installation")
    }
}
