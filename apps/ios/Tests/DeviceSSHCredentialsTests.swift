import Foundation

@main struct DeviceSSHCredentialsTests {
    static func main() throws {
        let fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        var credentials = DeviceSSHCredentials(username: "windows-user", password: "password")
        precondition(credentials.isValid) // First connection needs no manually entered key.
        credentials.fingerprint = fingerprint
        let saved = try JSONEncoder().encode(credentials)
        let restored = try JSONDecoder().decode(DeviceSSHCredentials.self, from: saved)
        precondition(restored.isValid && restored.fingerprint == fingerprint)
        for invalid in ["SHA256:bad", fingerprint + "=", "MD5:abcd", " "] {
            credentials.fingerprint = invalid
            precondition(!credentials.isValid)
        }
        credentials.fingerprint = ""
        credentials.username = "user\nname"
        precondition(!credentials.isValid)
        credentials.username = "user"
        credentials.password = ""
        precondition(!credentials.isValid)

        let offer = #"{"type":"ssh_host_key","fingerprint":"\#(fingerprint)"}"#
        precondition(DeviceSSHCredentials.offeredFingerprint(offer) == fingerprint)
        for invalid in ["ssh_ready", "{}", "null",
                        #"{"type":"ssh_ready","fingerprint":"\#(fingerprint)"}"#,
                        #"{"type":"ssh_host_key","fingerprint":"SHA256:bad"}"#] {
            precondition(DeviceSSHCredentials.offeredFingerprint(invalid) == nil)
        }
        print("Device SSH credentials: first connection, saved pin and malformed offers passed")
    }
}
