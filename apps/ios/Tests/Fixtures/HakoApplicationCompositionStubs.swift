// Isolated composition test doubles; production module entry files remain real.
import SwiftUI
import Foundation

struct HeadplaneView: View { var body: some View { EmptyView() } }
struct RouterView: View { var body: some View { EmptyView() } }
struct QinglongView: View { var body: some View { EmptyView() } }
struct CloudServersView: View { var body: some View { EmptyView() } }
struct ContainersView: View { var body: some View { EmptyView() } }
struct DeviceMonitorView: View { var body: some View { EmptyView() } }
struct CodeWorkshopView: View { var body: some View { EmptyView() } }
struct SwissArmyKnifeView: View { var body: some View { EmptyView() } }
struct SportsView: View { var body: some View { EmptyView() } }
struct UsageEntry: View { var body: some View { EmptyView() } }
struct InvestmentView: View { var body: some View { EmptyView() } }
struct CryptoView: View { var body: some View { EmptyView() } }
struct StockTradeView: View { var body: some View { EmptyView() } }
struct HTTPProxySettingsSheet: View { var body: some View { EmptyView() } }
struct AgentSettingsSheet: View { var body: some View { EmptyView() } }
struct NotificationManagementView: View { var body: some View { EmptyView() } }

struct WorkshopPushNotice {}
@MainActor final class HakoShortcutRegistry { var calls: [String] = [] }
@MainActor final class HakoPinRegistry { var calls: [String] = [] }
@MainActor final class HakoCloudSettings {
    var scopes: [String] = []
    func registerBackupScopes(_ values: [String]) { scopes += values }
}
@MainActor final class ApplicationNotificationRegistry<Notice, Preview> { var calls: [String] = [] }
@MainActor enum WorkshopNotificationContributor {
    static func registerNotifications(in registry: ApplicationNotificationRegistry<WorkshopPushNotice, AnyView>) { registry.calls.append("workshop") }
}
@MainActor enum WorkshopPinContributor { static func register(in registry: HakoPinRegistry) { registry.calls.append("workshop") } }
@MainActor enum ArcanePinContributor { static func register(in registry: HakoPinRegistry) { registry.calls.append("arcane") } }
@MainActor enum InvestmentShortcutContributor { static func registerShortcuts(in registry: HakoShortcutRegistry) { registry.calls.append("investment") } }
@MainActor enum CryptoShortcutContributor { static func registerShortcuts(in registry: HakoShortcutRegistry) { registry.calls.append("crypto") } }
@MainActor enum UsageShortcutContributor { static func registerShortcuts(in registry: HakoShortcutRegistry) { registry.calls.append("usage") } }
enum InvestmentBackup { static let scopes = ["investment"] }
enum WorkshopBackup { static let scopes = ["workshop"] }
enum QinglongBackup { static let scopes = ["qinglong"] }

enum HakoLogSource { case investment, crypto }
enum MarketAPIRequestContext {
    @TaskLocal static var reason: String?
}
enum HTTPTransport {
    static func data(for request: URLRequest, source: HakoLogSource, secrets: [String],
                     logBody: Bool, logErrorBody: Bool = false) async throws -> (Data, URLResponse) {
        preconditionFailure("Composition tests must not call the network")
    }
}
