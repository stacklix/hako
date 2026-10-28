import Foundation

@main struct ConsoleAgentRegistrationTests {
    static func main() throws {
        // Only the PEM envelope is validated locally; RSA validation is covered by server tests.
        let pem = "-----BEGIN PUBLIC KEY-----\nMAA=\n-----END PUBLIC KEY-----"
        let request = try ConsoleAgentRegistration(name: " 我的设备 ", publicKeyPEM: "\n" + pem + "\n")
        precondition(request.name == "我的设备" && request.publicKeyPEM == pem)
        precondition(request.body["publicKeyPem"] as? String == pem && request.body.count == 2 && request.body["id"] == nil)
        let reply = try JSONDecoder().decode(ConsoleAgentRegistrationReply.self,
                                             from: Data("{\"id\":\"A1B2C\",\"keyId\":\"fingerprint\"}".utf8))
        precondition(reply.id == "A1B2C" && reply.keyId == "fingerprint")
        _ = try ConsoleAgentRegistration(name: String(repeating: "n", count: 100), publicKeyPEM: pem)
        _ = try ConsoleAgentRegistration.validatePublicKey(pem.replacingOccurrences(of: "PUBLIC KEY", with: "RSA PUBLIC KEY"))
        _ = try ConsoleAgentRegistration.validatePublicKey(pem.replacingOccurrences(of: "\n", with: "\r\n"))
        for name in ["  ", String(repeating: "中", count: 34), String(repeating: "n", count: 101)] {
            do { _ = try ConsoleAgentRegistration(name: name, publicKeyPEM: pem); fatalError("Invalid name accepted") }
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
        let large = pem.replacingOccurrences(of: "MAA=", with: String(repeating: "A", count: 16240))
        do { _ = try ConsoleAgentRegistration(name: String(repeating: "n", count: 100), publicKeyPEM: large); fatalError("Large JSON accepted") }
        catch ConsoleAgentRegistrationError.tooLarge { }
        print("PASS: Agent form validation, PEM imports, private-key rejection and request limits")
    }
}
