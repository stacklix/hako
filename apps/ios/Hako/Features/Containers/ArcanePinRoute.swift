import Foundation

struct ArcanePinRoute: Equatable {
    let connectionID: String
    let environmentID: String
    let containerName: String
    let tab: String

    static let tabs = ["overview", "logs", "files", "commands"]

    init(connectionID: String, environmentID: String, containerName: String, tab: String) {
        self.connectionID = connectionID; self.environmentID = environmentID
        self.containerName = containerName; self.tab = tab
    }

    init?(page: HakoPinnedPage) {
        guard page.applicationID == "容器管理", page.route == "container",
              let connection = page.parameters["connectionID"], !connection.isEmpty,
              let environment = page.parameters["environmentID"], !environment.isEmpty,
              let tab = page.parameters["tab"], Self.tabs.contains(tab) else { return nil }
        // Previously saved pins already display the complete Docker name as their title.
        // Ignore their obsolete ID when restoring them into the name-based route.
        let name = page.parameters["containerName"] ?? page.title
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.init(connectionID: connection, environmentID: environment, containerName: name, tab: tab)
    }

    func page(environmentName: String) -> HakoPinnedPage {
        let tabName: String
        switch tab { case "logs": tabName = "日志"; case "files": tabName = "文件"; case "commands": tabName = "操作"; default: tabName = "概览" }
        return HakoPinnedPage(applicationID: "容器管理", route: "container",
            key: [connectionID, environmentID, containerName, tab].joined(separator: ":"),
            title: containerName, subtitle: environmentName + " · " + tabName, symbol: "shippingbox",
            parameters: ["connectionID": connectionID, "environmentID": environmentID, "containerName": containerName, "tab": tab])
    }
}
