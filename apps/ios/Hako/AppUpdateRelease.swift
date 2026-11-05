import Foundation

struct AppBuildVersion: Comparable {
    private let version: [Int]
    private let build: [Int]

    init?(version: String, build: String) {
        guard let version = Self.components(version), let build = Self.components(build) else { return nil }
        self.version = version
        self.build = build
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.version != rhs.version { return lhs.version.lexicographicallyPrecedes(rhs.version) }
        return lhs.build.lexicographicallyPrecedes(rhs.build)
    }

    private static func components(_ string: String) -> [Int]? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers = [Int]()
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

struct AppUpdateRelease: Decodable, Sendable {
    let version: String
    let build: String
    let builtAt: Date
    let manifest: String?

    var buildVersion: AppBuildVersion? { AppBuildVersion(version: version, build: build) }

    var manifestName: String? {
        guard let manifest else { return "manifest.plist" }
        return manifest.range(of: #"\Amanifest-[0-9a-f]{16}\.plist\z"#, options: .regularExpression) == nil ? nil : manifest
    }
}
