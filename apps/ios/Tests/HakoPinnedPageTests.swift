import Foundation

@main struct HakoPinnedPageTests {
    static func main() throws {
        let first = HakoPinnedPage(applicationID: "代码工坊", route: "conversation", key: "server-a:thread-a",
            title: "会话", subtitle: "项目", symbol: "terminal", parameters: ["threadID": "thread-a"])
        let second = HakoPinnedPage(applicationID: "代码工坊", route: "conversation", key: "server-b:thread-a",
            title: "另一账号的会话", subtitle: "项目", symbol: "terminal")
        let third = HakoPinnedPage(applicationID: "青龙面板", route: "tab", key: "tasks",
            title: "定时任务", subtitle: "", symbol: "checklist")
        var list = HakoPinnedPages()
        list.pin(first); list.pin(second); list.pin(third)
        precondition(list.pages.map(\.id) == [third.id, second.id, first.id])
        var renamed = first; renamed.title = "已重命名的会话"
        list.pin(renamed)
        precondition(list.pages.count == 3 && list.pages.last?.title == renamed.title)
        let restored = HakoPinnedPages(data: try list.encoded())
        precondition(restored.pages == list.pages && restored.pages.last?.parameters["threadID"] == "thread-a")
        list.move(from: IndexSet([0, 2]), to: 1)
        precondition(list.pages.map(\.id) == [third.id, first.id, second.id])
        list.move(from: IndexSet(integer: 0), to: 3)
        precondition(list.pages.map(\.id) == [first.id, second.id, third.id])
        let unchanged = list.pages
        list.move(from: IndexSet(integer: 99), to: 0)
        precondition(list.pages == unchanged)
        list.remove([second.id]); list.remove(["unknown"])
        precondition(list.pages.map(\.id) == [first.id, third.id])
        let duplicate = try JSONEncoder().encode([first, renamed, third])
        precondition(HakoPinnedPages(data: duplicate).pages.map(\.id) == [first.id, third.id])
        precondition(HakoPinnedPages(data: Data("invalid".utf8)).pages.isEmpty)
        var filtered = HakoPinnedPages(data: try JSONEncoder().encode([first, third, second]))
        let visible = Set([first.id, second.id])
        filtered.move(from: IndexSet(integer: 0), to: 2, among: visible)
        precondition(filtered.pages.filter { visible.contains($0.id) }.map(\.id) == [second.id, first.id])
        precondition(filtered.pages.contains { $0.id == third.id })
        filtered.move(from: IndexSet(integer: 1), to: 0, among: visible)
        precondition(filtered.pages.filter { visible.contains($0.id) }.map(\.id) == [first.id, second.id])
        let beforeInvalidMove = filtered.pages
        filtered.move(from: IndexSet(integer: 99), to: 0, among: visible)
        precondition(filtered.pages == beforeInvalidMove)
        var replacing = HakoPinnedPages(data: try JSONEncoder().encode([first, third, second]))
        let migrated = HakoPinnedPage(applicationID: "代码工坊", route: "conversation", key: "stable-name",
            title: "会话", subtitle: "项目", symbol: "terminal")
        replacing.replace(third.id, with: migrated)
        precondition(replacing.pages.map(\.id) == [first.id, migrated.id, second.id], "Replacing a pin must preserve its position")
        replacing.replace(second.id, with: migrated)
        precondition(replacing.pages.map(\.id) == [first.id, migrated.id], "Pins converging to one route must be deduplicated")
        replacing.replace("unknown", with: third)
        precondition(replacing.pages.count == 2, "Migration must not recreate removed pins")
        let migratedData = try replacing.encoded()
        precondition(HakoPinnedPages(data: migratedData).pages == replacing.pages)
        print("PASS: Pin persistence, route identity, deduplication, metadata refresh, reorder and removal")
    }
}
