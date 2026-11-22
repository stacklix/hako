import Foundation

@main struct TaskProgressTests {
    static func main() throws {
        let source = #"{"tasks":[{"id":"a","name":"App A","project":"a","platform":"iOS","status":"running","createdAt":1000,"updatedAt":2000,"stages":[{"id":"build","name":"编译","status":"running"}]},{"id":"b","name":"App B","project":"b","platform":"iOS","status":"succeeded","createdAt":1000,"updatedAt":2000,"stages":[],"release":{"bundleId":"com.example.b","version":"1.0.0","build":"123","metadataUrl":"https://example.com/b/latest.json"}}]}"#
        let snapshot = try JSONDecoder().decode(TaskProgressSnapshot.self, from: Data(source.utf8))
        precondition(snapshot.tasks.count == 2 && snapshot.tasks[0].id != snapshot.tasks[1].id)
        let summarySource = source.replacingOccurrences(of: "\"name\":\"App A\"", with: "\"name\":\"App A\",\"summary\":\"Improve scrolling\"")
        let withSummary = try JSONDecoder().decode(TaskProgressSnapshot.self, from: Data(summarySource.utf8))
        precondition(withSummary.tasks[0].summary == "Improve scrolling" && withSummary.tasks[1].summary == nil)
        precondition(snapshot.tasks[0].stale(at: Date(timeIntervalSince1970: 63)))
        precondition(!snapshot.tasks[1].stale(at: Date(timeIntervalSince1970: 63)))
        precondition(snapshot.tasks[0].completedStages == 0 && snapshot.tasks[0].currentStage?.name == "编译")
        func message(_ id: String, _ text: String, user: Bool = false) -> TaskProgressPlacement.Message {
            .init(id: id, text: text, isUser: user)
        }
        // Both builds belong to the triggering turn. New messages and changed
        // progress must not drag the card to the newest turn.
        let messages = [message("u1", "build", user: true), message("tool", "a b"), message("answer", "submitted"),
                        message("u2", "another question", user: true), message("later", "new answer")]
        let placement = TaskProgressPlacement(tasks: snapshot.tasks, messages: messages)
        precondition(placement.after["answer"]?.map(\.id) == ["a", "b"])
        precondition(placement.after["later"] == nil)
        let extended = TaskProgressPlacement(tasks: snapshot.tasks, messages: messages + [message("newer", "more output")])
        precondition(extended.after["answer"]?.map(\.id) == ["a", "b"])
        let separate = TaskProgressPlacement(tasks: snapshot.tasks, messages: [message("u1", "build a", user: true),
            message("one", "submitted"), message("u2", "build b", user: true), message("two", "submitted")])
        precondition(separate.after["one"] == nil && separate.after["two"]?.map(\.id) == ["b"])
        let missing = TaskProgressPlacement(tasks: snapshot.tasks, messages: [])
        precondition(missing.after.isEmpty)
        let outsideHistory = TaskProgressPlacement(tasks: snapshot.tasks, messages: [message("u", "new conversation text", user: true)])
        precondition(outsideHistory.after.isEmpty)
        let xkodeSource = source.replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"xkode-0123456789abcdef0123456789abcdef\"")
        let xkode = try JSONDecoder().decode(TaskProgressSnapshot.self, from: Data(xkodeSource.utf8)).tasks[0]
        let alias = TaskProgressPlacement(tasks: [xkode], messages: [message("u", "build", user: true),
            message("submit", "task 0123456789abcdef0123456789abcdef"), message("answer", "submitted"),
            message("next", "question", user: true)])
        precondition(alias.after["answer"]?.first?.id == xkode.id)
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
        print("PASS: task turn placement and history boundaries, separate identities, stale status, numeric versions and secure installation")
    }
}
