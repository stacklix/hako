import Foundation

@main struct ConsoleAgentRegistrationTests {
    static func main() throws {
        // Only the PEM envelope is validated locally; RSA validation is covered by server tests.
        let pem = "-----BEGIN PUBLIC KEY-----\nMAA=\n-----END PUBLIC KEY-----"
        let request = try ConsoleAgentRegistration(id: " desktop-1 ", name: " 我的电脑 ", publicKeyPEM: "\n" + pem + "\n")
        precondition(request.id == "desktop-1" && request.name == "我的电脑" && request.publicKeyPEM == pem)
        precondition(request.body["publicKeyPem"] as? String == pem && request.body.count == 3)
        _ = try ConsoleAgentRegistration(id: String(repeating: "A", count: 80), name: String(repeating: "n", count: 100), publicKeyPEM: pem)
        _ = try ConsoleAgentRegistration.validatePublicKey(pem.replacingOccurrences(of: "PUBLIC KEY", with: "RSA PUBLIC KEY"))
        _ = try ConsoleAgentRegistration.validatePublicKey(pem.replacingOccurrences(of: "\n", with: "\r\n"))
        for id in ["", "../pc", "pc/id", "pc\nid", "中文", String(repeating: "A", count: 81)] {
            do { _ = try ConsoleAgentRegistration(id: id, name: "PC", publicKeyPEM: pem); fatalError("Unsafe ID accepted") }
            catch ConsoleAgentRegistrationError.invalidID { }
        }
        for name in ["  ", String(repeating: "中", count: 34), String(repeating: "n", count: 101)] {
            do { _ = try ConsoleAgentRegistration(id: "pc", name: name, publicKeyPEM: pem); fatalError("Invalid name accepted") }
            catch ConsoleAgentRegistrationError.invalidName { }
        }
        for value in [pem.replacingOccurrences(of: "PUBLIC KEY", with: "PRIVATE KEY"),
                      pem.replacingOccurrences(of: "PUBLIC KEY", with: "RSA PRIVATE KEY"),
                      pem + "\n-----BEGIN ENCRYPTED PRIVATE KEY-----"] {
            do { _ = try ConsoleAgentRegistration.validatePublicKey(value); fatalError("Private key reached request construction") }
            catch ConsoleAgentRegistrationError.privateKey { }
        }
        for value in ["", "MAA=", pem + "\n" + pem, "unexpected\n" + pem, pem + "\ntrailing text",
                      pem.replacingOccurrences(of: "MAA=", with: "%%%"),
                      pem.replacingOccurrences(of: "END PUBLIC KEY", with: "END RSA PUBLIC KEY")] {
            do { _ = try ConsoleAgentRegistration.validatePublicKey(value); fatalError("Malformed PEM accepted") }
            catch ConsoleAgentRegistrationError.invalidPublicKey { }
        }
        do { _ = try ConsoleAgentRegistration.validatePublicKey(String(repeating: "A", count: 16385)); fatalError("Large key accepted") }
        catch ConsoleAgentRegistrationError.tooLarge { }
        // A key can fit its own limit while the escaped JSON exceeds the HTTP limit.
        let large = pem.replacingOccurrences(of: "MAA=", with: String(repeating: "A", count: 16160))
        do { _ = try ConsoleAgentRegistration(id: String(repeating: "a", count: 80), name: String(repeating: "n", count: 100), publicKeyPEM: large); fatalError("Large JSON accepted") }
        catch ConsoleAgentRegistrationError.tooLarge { }
        print("PASS: Agent form validation, PEM imports, private-key rejection and request limits")
    }
}
