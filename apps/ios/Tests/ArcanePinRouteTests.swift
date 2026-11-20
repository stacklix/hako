import Foundation

@main struct ArcanePinRouteTests {
    static func main() throws {
        let route = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-a", containerID: "container-a", tab: "logs")
        let page = route.page(name: "hako-server", environmentName: "生产环境")
        precondition(page.title == "hako-server" && page.subtitle == "生产环境 · 日志")
        precondition(ArcanePinRoute(page: page) == route)
        let renamed = route.page(name: "new-name", environmentName: "生产环境")
        precondition(renamed.id == page.id)
        let otherEnvironment = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-b", containerID: "container-a", tab: "logs")
        precondition(otherEnvironment.page(name: "hako-server", environmentName: "另一个环境").id != page.id)
        let otherConnection = ArcanePinRoute(connectionID: "arcane-b", environmentID: "environment-a", containerID: "container-a", tab: "logs")
        precondition(otherConnection.page(name: "hako-server", environmentName: "生产环境").id != page.id)
        let replacement = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-a", containerID: "container-b", tab: "logs")
        precondition(replacement.page(name: "hako-server", environmentName: "生产环境").id != page.id)
        var invalid = page; invalid.parameters["containerID"] = ""
        precondition(ArcanePinRoute(page: invalid) == nil)
        invalid = page; invalid.parameters["tab"] = "unknown"
        precondition(ArcanePinRoute(page: invalid) == nil)
        let restored = try JSONDecoder().decode(HakoPinnedPage.self, from: JSONEncoder().encode(page))
        precondition(ArcanePinRoute(page: restored) == route)
        precondition(Set(page.parameters.keys) == Set(["connectionID", "environmentID", "containerID", "tab"]))
        print("PASS: container pins restore exact connection/environment/container/tab and use container names")
    }
}
