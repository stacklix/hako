import Foundation

struct HakoApplicationOrder {
    static let storageKey = "hako.applicationOrder"
    private var categories: [String: [String]]

    init(data: Data) {
        categories = (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    func applications(in category: String, available: [String]) -> [String] {
        let allowed = Set(available)
        var seen = Set<String>()
        return ((categories[category] ?? []) + available).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    mutating func set(_ applications: [String], in category: String) {
        categories[category] = applications
    }

    var data: Data { (try? JSONEncoder().encode(categories)) ?? Data() }
}
