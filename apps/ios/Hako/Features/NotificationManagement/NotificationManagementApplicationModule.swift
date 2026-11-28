import SwiftUI

enum NotificationManagementApplicationModule {
    static let module = HakoApplicationModule(register: { registration in
        registration.registerSetting(.webhooks) { AnyView(NotificationManagementView()) }
    })
}
