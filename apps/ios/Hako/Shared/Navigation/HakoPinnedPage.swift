import Foundation

/// A restorable child-owned route. Parameters contain identifiers, never credentials.
struct HakoPinnedPage: Codable, Hashable, Identifiable, Sendable {
    let applicationID: String
    let route: String
    let key: String
    var title: String
    var subtitle: String
    var symbol: String
    var parameters: [String: String] = [:]

    var id: String { [applicationID, route, key].joined(separator: "\u{1f}") }
}

struct HakoPinnedPages {
    private(set) var pages: [HakoPinnedPage]

    init(data: Data = Data()) {
        let decoded = (try? JSONDecoder().decode([HakoPinnedPage].self, from: data)) ?? []
        var seen = Set<String>()
        pages = decoded.filter { seen.insert($0.id).inserted }
    }

    mutating func pin(_ page: HakoPinnedPage) {
        if let index = pages.firstIndex(where: { $0.id == page.id }) { pages[index] = page }
        else { pages.insert(page, at: 0) }
    }

    mutating func remove(_ ids: Set<String>) { pages.removeAll { ids.contains($0.id) } }

    mutating func replace(_ id: String, with page: HakoPinnedPage) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index] = page
        var seen = Set<String>()
        pages = pages.filter { seen.insert($0.id).inserted }
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        guard destination >= 0, destination <= pages.count,
              offsets.allSatisfy({ pages.indices.contains($0) }) else { return }
        let moving = offsets.sorted().map { pages[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        pages = pages.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        pages.insert(contentsOf: moving, at: insertion)
    }

    func encoded() throws -> Data { try JSONEncoder().encode(pages) }

    mutating func move(from offsets: IndexSet, to destination: Int, among visibleIDs: Set<String>) {
        let visible = pages.enumerated().filter { visibleIDs.contains($0.element.id) }
        guard destination >= 0, destination <= visible.count,
              offsets.allSatisfy({ visible.indices.contains($0) }) else { return }
        let source = IndexSet(offsets.map { visible[$0].offset })
        let target = destination < visible.count ? visible[destination].offset : pages.count
        move(from: source, to: target)
    }
}
