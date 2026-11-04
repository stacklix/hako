import Foundation

@main struct ConsoleApplicationTests {
    static func main() throws {
        var draft = ConsoleApplicationDraft()
        draft.name = "  Example  "; draft.origin = "https://app.example.com/"
        let body = try draft.creationBody()
        precondition(body["name"] as? String == "Example" && body["origin"] as? String == "https://app.example.com")
        precondition(body["oidc"] == nil, "New applications must not implicitly enable OIDC")
        draft.oidcEnabled = true; draft.redirects = "https://app.example.com/callback\nhttps://app.example.com/alternate?fixed=1"
        let enabled = try draft.validatedOIDC()!
        precondition(enabled.enabled && enabled.requirePKCE && enabled.scopes == ["openid", "profile"])
        draft.profile = false; let minimal = try draft.validatedOIDC()!; precondition(minimal.scopes == ["openid"])
        for unsafe in ["https://app.example.com/*", "http://127.0.0.1/callback", "https://app.example.com/callback#", "https://user@app.example.com/callback", "https://app.example.com/callback?state=fixed", "https://app.example.com/callback?code=x", "https://app.example.com:0/callback", "https://app.example.com:/callback", "https://app.example.com/callback\nhttps://app.example.com/callback"] {
            draft.redirects = unsafe
            do { _ = try draft.validatedOIDC(); fatalError("Unsafe callback accepted") } catch ConsoleApplicationError.invalidOIDC { }
        }
        draft.oidcEnabled = false; draft.redirects = ""; draft.name = String(repeating: "中", count: 27)
        do { _ = try draft.creationBody(); fatalError("UTF-8 name limit ignored") } catch ConsoleApplicationError.invalidDetails { }
        let app = ConsoleApplication(id: "app_sample", name: "Example", origin: "https://app.example.com", enabled: true, createdAt: "", oidc: enabled)
        var edit = ConsoleApplicationDraft(application: app); edit.oidcEnabled = false
        let update = try edit.updateBody(); let config = update["oidc"] as! [String: Any]
        precondition(config["enabled"] as? Bool == false)
        precondition(config["redirectURIs"] as? [String] == enabled.redirectURIs, "Disabling must preserve registered callbacks")
        let secret = "test_secret_that_is_not_persisted"
        precondition(!app.configuration(issuer: "https://hako.example.com").contains(secret))
        precondition(app.configuration(issuer: "https://hako.example.com", secret: secret).contains("HAKO_CLIENT_SECRET=" + secret))
        let data = Data(#"{"applications":[{"id":"app_sample","name":"Example","origin":"https://app.example.com","enabled":false,"createdAt":"2026-11-04T00:00:00Z"}],"issuer":"https://hako.example.com"}"#.utf8)
        let list = try JSONDecoder().decode(ConsoleApplicationList.self, from: data)
        precondition(list.applications.count == 1 && list.applications[0].oidc == nil && list.applications[0].loginMethods == "扫码登录")
        print("PASS: application drafts, explicit OIDC enablement, callback policy, scope, UTF-8 limit, disable preservation and credential isolation")
    }
}
