import Foundation

enum WorkshopArchivedImageCleanup {
    static func previousFiles(_ snapshots: [WorkshopTranscript], accountFile: URL, projectDirectory: URL,
                              applications: [String: String], hash: (Data) -> String) -> Set<URL> {
        var files: Set<URL> = []
        for snapshot in snapshots {
            for entry in snapshot.entries {
                let count = entry.kind == "imageGeneration" ? 1 : min(3, WorkshopImageCaption(entry.text).count)
                for index in 0..<count {
                    let identity = "\(snapshot.key.agentId)\n\(snapshot.key.threadId)\n\(entry.id)\n\(index)"
                    files.insert(accountFile.deletingPathExtension().appendingPathExtension("images")
                        .appendingPathComponent(hash(Data(identity.utf8)) + ".image"))
                }
                for part in WorkshopMessage.parts(entry.text) {
                    guard case let .image(_, url) = part else { continue }
                    if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        files.insert(accountFile.deletingPathExtension().appendingPathExtension("remote-images")
                            .appendingPathComponent(hash(Data(url.absoluteString.utf8)) + ".image"))
                    } else if let root = applications[snapshot.key.applicationId], let link = WorkshopProjectLink(url: url, projectPath: root) {
                        let identity = try! JSONEncoder().encode([accountFile.deletingPathExtension().lastPathComponent,
                            snapshot.key.agentId, snapshot.key.applicationId, root, link.path])
                        files.insert(projectDirectory.appendingPathComponent(hash(identity) + ".image"))
                    }
                }
            }
        }
        return files
    }

    static func remove(attachments: [URL], uploads: [URL], protecting references: Set<String>, draftDirectory: URL) throws {
        var protected = references
        let drafts = (try? FileManager.default.contentsOfDirectory(at: draftDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in drafts where file.lastPathComponent.hasSuffix(".draft.json") {
            // A corrupt draft cannot prove that its photos are unused; retain uploads in that case.
            guard let draft = try? WorkshopDraftDisk.read(file) else { protected.formUnion(uploads.map { $0.deletingPathExtension().lastPathComponent }); continue }
            protected.formUnion(draft.input.imageIds)
            protected.formUnion(draft.originalInput?.imageIds ?? [])
        }
        var failure: Error?
        let removable = attachments + uploads.filter { !protected.contains($0.deletingPathExtension().lastPathComponent) }
        for file in Set(removable) {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { failure = error }
        }
        if let failure { throw failure }
    }
}
