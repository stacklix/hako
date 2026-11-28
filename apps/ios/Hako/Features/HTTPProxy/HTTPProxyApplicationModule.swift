import SwiftUI

enum HTTPProxyApplicationModule {
    static let module = HakoApplicationModule(register: { registration in
        registration.registerSetting(.httpProxy) { AnyView(HTTPProxySettingsSheet()) }
    })
}
