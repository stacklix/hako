import Foundation

@main struct ArcanePinRouteTests {
    static func main() throws {
        let route = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-a", containerName: "hako-server", tab: "logs")
        let page = route.page(environmentName: "生产环境")
        precondition(page.title == "hako-server" && page.subtitle == "生产环境 · 日志")
        precondition(ArcanePinRoute(page: page) == route)
        let otherEnvironment = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-b", containerName: "hako-server", tab: "logs")
        precondition(otherEnvironment.page(environmentName: "另一个环境").id != page.id)
        let otherConnection = ArcanePinRoute(connectionID: "arcane-b", environmentID: "environment-a", containerName: "hako-server", tab: "logs")
        precondition(otherConnection.page(environmentName: "生产环境").id != page.id)
        let otherName = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-a", containerName: "hako-server-copy", tab: "logs")
        precondition(otherName.page(environmentName: "生产环境").id != page.id)
        let otherTab = ArcanePinRoute(connectionID: "arcane-a", environmentID: "environment-a", containerName: "hako-server", tab: "files")
        precondition(otherTab.page(environmentName: "生产环境").id != page.id)
        var invalid = page; invalid.parameters["containerName"] = ""
        precondition(ArcanePinRoute(page: invalid) == nil)
        invalid = page; invalid.parameters["tab"] = "unknown"
        precondition(ArcanePinRoute(page: invalid) == nil)
        let restored = try JSONDecoder().decode(HakoPinnedPage.self, from: JSONEncoder().encode(page))
        precondition(ArcanePinRoute(page: restored) == route)
        precondition(Set(page.parameters.keys) == Set(["connectionID", "environmentID", "containerName", "tab"]))
        var previous = page
        previous.parameters.removeValue(forKey: "containerName")
        previous.parameters["containerID"] = "old-docker-id"
        precondition(ArcanePinRoute(page: previous) == route)
        previous.parameters["containerID"] = "new-docker-id"
        precondition(ArcanePinRoute(page: previous) == route, "Docker IDs must not affect pin resolution or identity")
        for name in ["../sora", "/sora", "sora/child", "sora?query", "sora#fragment", "", ".", ".."] {
            invalid = previous; invalid.title = name
            precondition(ArcanePinRoute(page: invalid) == nil)
        }
        print("PASS: pins use exact container names, preserve connection/environment/tab scope, and restore existing pins without Docker IDs")
    }
}
