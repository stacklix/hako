import Foundation

@main struct HakoApplicationOrderTests {
    static func main() {
        var order = HakoApplicationOrder(data: Data())
        precondition(order.applications(in: "IT", available: ["a", "b", "c"]) == ["a", "b", "c"])
        order.set(["c", "a", "b"], in: "IT")
        order.set(["fund", "crypto"], in: "finance")
        let restored = HakoApplicationOrder(data: order.data)
        precondition(restored.applications(in: "IT", available: ["a", "b", "c"]) == ["c", "a", "b"])
        precondition(restored.applications(in: "finance", available: ["crypto", "fund"]) == ["fund", "crypto"])
        precondition(restored.applications(in: "life", available: ["sports", "usage"]) == ["sports", "usage"])
        precondition(restored.applications(in: "IT", available: ["a", "c", "new"]) == ["c", "a", "new"])
        order.set(["b", "b", "crypto", "a"], in: "IT")
        precondition(order.applications(in: "IT", available: ["a", "b", "c"]) == ["b", "a", "c"])
        print("PASS: per-category order persists independently and contains every available application exactly once")
    }
}
