import Foundation

struct ArcanePinRoute: Equatable {
    let connectionID: String
    let environmentID: String
    let containerID: String
    let tab: String

    static let tabs = ["overview", "logs", "files", "commands"]

    init(connectionID: String, environmentID: String, containerID: String, tab: String) {
        self.connectionID = connectionID; self.environmentID = environmentID
        self.containerID = containerID; self.tab = tab
    }

    init?(page: HakoPinnedPage) {
        guard page.applicationID == "容器管理", page.route == "container",
              let connection = page.parameters["connectionID"], !connection.isEmpty,
              let environment = page.parameters["environmentID"], !environment.isEmpty,
              let container = page.parameters["containerID"], !container.isEmpty,
              let tab = page.parameters["tab"], Self.tabs.contains(tab) else { return nil }
        self.init(connectionID: connection, environmentID: environment, containerID: container, tab: tab)
    }

    func page(name: String, environmentName: String) -> HakoPinnedPage {
        let tabName: String
        switch tab { case "logs": tabName = "日志"; case "files": tabName = "文件"; case "commands": tabName = "操作"; default: tabName = "概览" }
        return HakoPinnedPage(applicationID: "容器管理", route: "container",
            key: [connectionID, environmentID, containerID, tab].joined(separator: ":"),
            title: name, subtitle: environmentName + " · " + tabName, symbol: "shippingbox",
            parameters: ["connectionID": connectionID, "environmentID": environmentID, "containerID": containerID, "tab": tab])
    }
}
