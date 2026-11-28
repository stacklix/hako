import SwiftUI

enum InvestmentApplicationModule {
    static let module = HakoApplicationModule(
        application: .investment, category: .finance, subtitle: "账户 · 持仓 · 定投", icon: .asset("InvestmentIcon"),
        applicationID: "investment",
        credentials: [
            .init(title: "Tushare Pro", fields: [.init(key: "tushare.token", title: "API Token")], validatorID: TushareCredentialValidator.identifier),
            .init(title: "Twelve Data", fields: [.init(key: "twelve-data.api-key", title: "API Key")], validatorID: TwelveDataCredentialValidator.identifier)
        ],
        destination: { AnyView(InvestmentView()) }, register: { registration in
        registration.shortcuts.append(InvestmentShortcutContributor.registerShortcuts)
        registration.backups.append { $0.registerBackupScopes(InvestmentBackup.scopes) }
        registration.credentialValidators.register(TushareCredentialValidator.self)
        registration.credentialValidators.register(TwelveDataCredentialValidator.self)
    })
}
