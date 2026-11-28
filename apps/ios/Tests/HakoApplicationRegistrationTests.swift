import Foundation
import CryptoKit

@main struct HakoApplicationRegistrationTests {
    @MainActor static func main() async throws {
        let expected: [[HakoApplications.Application]] = [
            [.codeWorkshop, .swissArmyKnife], [.headplane, .router, .qinglong, .cloudServers, .containers, .devices],
            [.investment, .crypto, .stockTrade], [.sports, .usage]
        ]
        for (category, applications) in zip(HakoApplications.Category.allCases, expected) {
            precondition(category.applications == applications, "Existing home categories/order must remain stable")
            for application in applications {
                precondition(!application.subtitle.isEmpty && application.icon != nil)
                _ = application.destination
            }
        }
        let visible = HakoApplications.modules.compactMap(\.application)
        precondition(visible.count == 13 && Set(visible).count == 13)
        precondition(HakoApplications.Application.qinglong.icon == .asset("QinglongIcon"))
        let shortcuts = HakoShortcutRegistry()
        HakoApplications.registerShortcuts(in: shortcuts)
        precondition(shortcuts.calls == ["investment", "crypto", "usage"])
        precondition(HakoApplications.pins.calls == ["workshop", "arcane"])
        precondition(HakoApplications.pins.calls.count == 2, "Cached registrations must not run twice")
        precondition(HakoApplications.notifications.calls == ["workshop"])
        let cloud = HakoCloudSettings()
        HakoApplications.registerBackupScopes(in: cloud)
        precondition(cloud.scopes == ["workshop", "qinglong", "investment"])
        _ = HakoApplications.agentSettings(); _ = HakoApplications.httpProxySettings(); _ = HakoApplications.webhookSettings()
        let definitions = try HakoTokenMetadata.load(declarations: HakoApplications.credentialDeclarations)
        try verifyExistingRecords(definitions)
        precondition(definitions.count == 6)
        for definition in definitions { precondition(HakoApplications.credentialValidators.supports(definition), definition.id) }
        precondition(HakoApplications.credentialValidators.identifiers.count == 6)
        try await providers()
        print("Application composition: 13 pages, order/icons, all capabilities and module credential declarations and existing v1 records passed")
    }

    private static func verifyExistingRecords(_ definitions: [HakoTokenDefinition]) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let records = try JSONDecoder().decode([HakoTokenVault.Record].self, from: data)
        let storage = ExistingTokenStorage()
        for record in records { storage.items[record.id] = try JSONEncoder().encode(record) }
        let before = storage.items
        let vault = HakoTokenVault(storage: storage, definitions: { definitions })
        precondition(definitions.count == records.count)
        for record in records {
            let read = try vault.read(record.id)
            precondition(read == record, "Existing values and associations must remain unchanged")
            for (key, value) in record.values { precondition(try! vault.readKey(key) == value) }
        }
        precondition(storage.items == before && storage.writes == 0, "Changing declarations must not rewrite existing records")
    }

    private static func providers() async throws {
        let now = Date(timeIntervalSince1970: 0)
        let tushare = try await TushareCredentialValidator.check(["tushare.token": "fixture-token"], now: now) { request, values, _ in
            precondition(request.httpMethod == "POST" && request.url?.host == "api.tushare.pro")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["token"] as? String == values["tushare.token"] && body["api_name"] as? String == "trade_cal")
            precondition((body["params"] as? [String: String])?["start_date"] == "19691231")
            return .init(status: 200, body: ["code": 0, "data": ["fields": ["cal_date"], "items": [["19691231"]]]])
        }
        precondition(tushare.status == .passed)
        let noPermission = try await TushareCredentialValidator.check(["tushare.token": "fixture-token"]) { _, _, _ in
            .init(status: 200, body: ["code": 2002])
        }
        precondition(noPermission.status == .permissionDenied)
        let twelve = try await TwelveDataCredentialValidator.check(["twelve-data.api-key": "K+&"]) { request, _, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.first { $0.name == "apikey" }?.value == "K+&")
            return .init(status: 200, body: ["current_usage": 0, "plan_limit": 800])
        }
        precondition(twelve.status == .passed)
        let rateLimited = try await TwelveDataCredentialValidator.check(["twelve-data.api-key": "key"]) { _, _, _ in .init(status: 200, body: ["code": 429]) }
        precondition(rateLimited.status == .rateLimited)
        let htx = try await HTXCredentialValidator.check(["htx.api-key": "K+&", "htx.secret-key": "secret"], now: now) { request, _, _ in
            precondition(request.httpMethod == "GET" && request.url?.path == "/v1/account/accounts")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let canonical = "GET\napi.huobi.pro\n/v1/account/accounts\nAccessKeyId=K%2B%26&SignatureMethod=HmacSHA256&SignatureVersion=2&Timestamp=1970-01-01T00%3A00%3A00"
            let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: Data("secret".utf8)))).base64EncodedString()
            precondition(query.first { $0.name == "Signature" }?.value == signature)
            return .init(status: 200, body: ["status": "ok", "data": []])
        }
        precondition(htx.status == .passed)
        let binance = try await BinanceCredentialValidator.check(["binance.api-key": "key", "binance.secret-key": "secret"], now: now) { request, _, _ in
            precondition(request.httpMethod == "GET" && request.url?.path == "/sapi/v1/account/apiRestrictions")
            precondition(request.value(forHTTPHeaderField: "X-MBX-APIKEY") == "key")
            let expected = HMAC<SHA256>.authenticationCode(for: Data("recvWindow=10000&timestamp=0".utf8), using: SymmetricKey(data: Data("secret".utf8)))
                .map { String(format: "%02x", $0) }.joined()
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "signature" }?.value == expected)
            return .init(status: 200, body: ["enableReading": true])
        }
        precondition(binance.status == .passed)
        let clockError = try await BinanceCredentialValidator.check(["binance.api-key": "key", "binance.secret-key": "secret"]) { _, _, _ in .init(status: 400, body: ["code": -1021]) }
        precondition(clockError.status == .unavailable)
        var calls = 0
        let anonymous = try await TronscanCredentialValidator.check(["tronscan.api-key": "abc-123"]) { _, _, _ in
            calls += 1; return .init(status: 200, body: ["data": []])
        }
        precondition(calls == 2 && anonymous.status == .unavailable, "An anonymous success cannot verify a key")
        calls = 0
        let tron = try await TronscanCredentialValidator.check(["tronscan.api-key": "abc-123"]) { request, values, _ in
            calls += 1
            precondition(request.value(forHTTPHeaderField: "TRON-PRO-API-KEY") == values["tronscan.api-key"])
            if calls == 1 { return .init(status: 200, body: ["data": []]) }
            precondition(values["tronscan.api-key"] != "abc-123" && values["tronscan.api-key"]?.count == 7)
            return .init(status: 401, body: [:])
        }
        precondition(tron.status == .passed)
        let moralis = try await MoralisCredentialValidator.check(["moralis.api-key": "key"]) { request, _, _ in
            precondition(request.value(forHTTPHeaderField: "X-API-Key") == "key")
            return .init(status: 200, body: ["result": []])
        }
        precondition(moralis.status == .passed)
        print("Credential providers: Tushare/Twelve checks, HTX/Binance signatures, permissions/rate/time errors and TRONSCAN control passed")
    }
}

private final class ExistingTokenStorage: SecretStorage {
    var items: [String: Data] = [:]
    var writes = 0
    func read(account: String) throws -> Data? { items[account] }
    func save(_ data: Data, account: String, accessibility: SecretAccessibility) throws { writes += 1; items[account] = data }
    func delete(account: String) throws { items[account] = nil }
    func accounts() throws -> [String] { Array(items.keys) }
}
