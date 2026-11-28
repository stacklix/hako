import SwiftUI

/// One child-owned entry describes its page and registers all host integrations.
/// Entries without a home page can contribute host settings only.
struct HakoApplicationModule {
    var application: HakoApplications.Application? = nil
    var category: HakoApplications.Category? = nil
    var subtitle = ""
    var icon: HakoApplicationIconSource? = nil
    var applicationID: String? = nil
    var credentials: [HakoCredentialDefinition] = []
    var destination: (@MainActor () -> AnyView)? = nil
    var register: @MainActor (HakoApplicationRegistration) -> Void = { _ in }
}

@MainActor final class HakoApplicationRegistration {
    enum Setting: Hashable { case agents, httpProxy, webhooks }
    var shortcuts: [@MainActor (HakoShortcutRegistry) -> Void] = []
    var notifications: [@MainActor (ApplicationNotificationRegistry<WorkshopPushNotice, AnyView>) -> Void] = []
    var pins: [@MainActor (HakoPinRegistry) -> Void] = []
    var backups: [@MainActor (HakoCloudSettings) -> Void] = []
    let credentialValidators = HakoCredentialValidatorRegistry()
    private var settings: [Setting: @MainActor () -> AnyView] = [:]

    func registerSetting(_ setting: Setting, content: @escaping @MainActor () -> AnyView) {
        precondition(settings[setting] == nil, "Host setting already registered")
        settings[setting] = content
    }
    func setting(_ setting: Setting) -> AnyView {
        settings[setting]?() ?? AnyView(ContentUnavailableView("设置不可用", systemImage: "exclamationmark.triangle"))
    }
}
