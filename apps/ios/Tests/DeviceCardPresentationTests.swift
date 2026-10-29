import Foundation
import CoreGraphics

@main struct DeviceCardPresentationTests {
    static func main() throws {
        // Agent reconnects and manifest changes must not lose or duplicate commands.
        let available = ["query.a", "query.b", "query.new"]
        precondition(DeviceCardOrder.arranged(available: available, saved: ["query.b", "missing", "query.b", "query.a"])
                     == ["query.b", "query.a", "query.new"])
        precondition(DeviceCardOrder.moving("query.a", to: "query.new", in: available) == ["query.b", "query.new", "query.a"])
        precondition(DeviceCardOrder.moving("query.new", to: "query.a", in: available) == ["query.new", "query.a", "query.b"])
        precondition(DeviceCardOrder.moving("outside", to: "query.a", in: available) == available)
        let persisted = DeviceCardOrder.saving(visible: ["query.b", "query.a", "query.new"], previous: ["query.a", "missing", "query.b", "query.a"])
        precondition(persisted == ["query.b", "missing", "query.a", "query.new"])
        precondition(DeviceCardOrder.arranged(available: ["query.a", "missing", "query.b", "query.new"], saved: persisted) == persisted)
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        precondition(decoded == persisted)
        let key = DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "A1", group: "query")
        precondition(key != DeviceCardOrder.storageKey(server: "https://two.example", account: "owner", agent: "A1", group: "query"))
        precondition(key != DeviceCardOrder.storageKey(server: "https://one.example", account: "other", agent: "A1", group: "query"))
        precondition(key != DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "B2", group: "query"))
        precondition(key != DeviceCardOrder.storageKey(server: "https://one.example", account: "owner", agent: "A1", group: "action"))

        // Mixed heights, a full-width expanded card, an incomplete final row, and
        // accessibility's single column must never overlap or clip card content.
        for count in 1...64 {
            for columns in [1, 2] {
                for expandedIndex in [0, count / 2, count - 1] {
                    let heights = (0..<count).map { CGFloat(100 + ($0 % 3) * 30) }
                    let spans = (0..<count).map { $0 == expandedIndex }
                    let frames = DeviceCardPlacement.frames(width: 350, columns: columns, spacing: 12, heights: heights, expanded: spans)
                    precondition(frames.count == count)
                    for index in frames.indices {
                        precondition(frames[index].height >= heights[index])
                        precondition(frames[index].minX >= 0 && frames[index].maxX <= 350)
                        if spans[index] { precondition(frames[index].width == 350) }
                        for next in frames.indices where next > index { precondition(!frames[index].intersects(frames[next])) }
                    }
                }
            }
        }
        precondition(DeviceCardPlacement.frames(width: 350, columns: 2, spacing: 12, heights: [], expanded: []).isEmpty)

        let geometry = DeviceCardScrollGeometry(offset: 200, viewportHeight: 500, contentHeight: 1800)
        precondition(geometry.fitting(CGRect(x: 0, y: 230, width: 350, height: 180)) == nil)
        let below = geometry.fitting(CGRect(x: 0, y: 620, width: 350, height: 240))!
        precondition(below > geometry.offset && below <= 620)
        precondition(geometry.fitting(CGRect(x: 0, y: 620, width: 350, height: 900)) == 596)
        precondition(geometry.clamped(-30) == 0 && geometry.clamped(9999) == 1300)
        precondition(DeviceCardScrollGeometry(offset: 0, viewportHeight: 500, contentHeight: 100).maximumOffset == 0)

        let collapsed = ["left": CGRect(x: 0, y: 180, width: 169, height: 120),
                         "right": CGRect(x: 181, y: 180, width: 169, height: 120),
                         "next": CGRect(x: 0, y: 312, width: 169, height: 120)]
        let bookmark = DeviceCardBookmark.capture(frames: collapsed, offset: 210)
        precondition(bookmark.name == "left" && bookmark.relativeY == -30)
        precondition(bookmark.restoredOffset(frames: collapsed, geometry: geometry) == 210)
        var moved = collapsed
        moved["left"] = CGRect(x: 0, y: 280, width: 169, height: 120)
        precondition(bookmark.restoredOffset(frames: moved, geometry: geometry) == 310)
        moved.removeValue(forKey: "left")
        precondition(bookmark.restoredOffset(frames: moved, geometry: geometry) == 210)
        print("PASS: device/group order persistence, manifest changes, 1–64 card layouts, expansion fitting and scroll bookmark restoration")
    }
}
