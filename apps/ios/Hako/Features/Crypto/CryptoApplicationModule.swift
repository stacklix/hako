import SwiftUI

enum CryptoApplicationModule {
    static let module = HakoApplicationModule(
        application: .crypto, category: .finance, subtitle: "HTX · Binance · 链上资产与私有归档", icon: .asset("CryptoIcon"),
        applicationID: "crypto",
        credentials: [
            .init(title: "Twelve Data", fields: [.init(key: "twelve-data.api-key", title: "API Key")], validatorID: "investment.twelve-data"),
            .init(title: "HTX", fields: [.init(key: "htx.api-key", title: "API Key"), .init(key: "htx.secret-key", title: "Secret Key")], validatorID: HTXCredentialValidator.identifier),
            .init(title: "Binance", fields: [.init(key: "binance.api-key", title: "API Key"), .init(key: "binance.secret-key", title: "Secret Key")], validatorID: BinanceCredentialValidator.identifier),
            .init(title: "TRONSCAN", fields: [.init(key: "tronscan.api-key", title: "API Token")], validatorID: TronscanCredentialValidator.identifier),
            .init(title: "Moralis", fields: [.init(key: "moralis.api-key", title: "API Token")], validatorID: MoralisCredentialValidator.identifier)
        ],
        destination: { AnyView(CryptoView()) }, register: { registration in
        registration.shortcuts.append(CryptoShortcutContributor.registerShortcuts)
        registration.credentialValidators.register(HTXCredentialValidator.self)
        registration.credentialValidators.register(BinanceCredentialValidator.self)
        registration.credentialValidators.register(TronscanCredentialValidator.self)
        registration.credentialValidators.register(MoralisCredentialValidator.self)
    })
}
