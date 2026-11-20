import Foundation

struct HakoBackupScope {
    let root: String
    var includedFileSuffixes: [String]? = nil
    var requiresHistory = false
}

enum HakoBackupPolicy {
    static let historyKey = "hako.icloud.includeHistory"

    static func included(_ relativePath: String, directory: Bool, history: Bool, scopes: [HakoBackupScope]) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let root = parts.first, let scope = scopes.first(where: { $0.root == root }) else { return false }
        if scope.requiresHistory { return history }
        if directory { return true }
        guard let suffixes = scope.includedFileSuffixes else { return true }
        return parts.last.map { name in suffixes.contains { name.hasSuffix($0) } } ?? false
    }

    static func prepareExistingFiles(at base: URL, history: Bool, scopes: [HakoBackupScope]) throws {
        let files = FileManager.default
        for scope in scopes {
            let root = scope.root
            guard !root.isEmpty, root != ".", root != "..", !root.contains("/"), !root.contains("\\") else { throw CocoaError(.fileReadInvalidFileName) }
            let folder = base.appendingPathComponent(root, isDirectory: true)
            guard files.fileExists(atPath: folder.path) else { continue }
            try mark(folder, included: included(root, directory: true, history: history, scopes: scopes))
            var enumerationError: Error?
            guard let items = files.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    enumerationError = error; return false
                }) else { continue }
            for case let file as URL in items {
                let attributes = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if attributes.isSymbolicLink == true { items.skipDescendants(); continue }
                let relative = file.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
                try mark(file, included: included(relative, directory: attributes.isDirectory == true, history: history, scopes: scopes))
            }
            if let enumerationError { throw enumerationError }
        }
    }

    private static func mark(_ file: URL, included: Bool) throws {
        var file = file
        var flags = URLResourceValues(); flags.isExcludedFromBackup = !included
        try file.setResourceValues(flags)
    }
}
