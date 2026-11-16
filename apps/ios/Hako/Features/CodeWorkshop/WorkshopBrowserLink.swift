import Foundation

struct WorkshopBrowserLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }

    init?(url: URL) {
        guard Self.allows(url) else { return nil }
        self.url = url
    }

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}
