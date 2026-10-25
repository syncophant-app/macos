import Foundation
import CoreKit

@main struct SSHCredentialSelfCheck {
    static func main() throws {
        let credentials: [SSHAuthentication] = [.password("fixture-password"), .privateKey(contents: "fixture-key", passphrase: "fixture-passphrase"), .agent(socketPath: "/tmp/fixture-agent")]
        for credential in credentials {
            let decoded = try SSHCredentials.decode(SSHCredentials.encode(credential))
            precondition(decoded == credential)
        }
        let legacy = try SSHCredentials.decode("legacy-password")
        precondition(legacy == .password("legacy-password"))
        do {
            _ = try SSHCredentials.decode("syncophant-ssh-v1:not-base64")
            preconditionFailure("Corrupt credentials must not become passwords")
        } catch { }
        print("SSH credential self-check passed: password/key/agent envelopes, legacy passwords, corrupt-envelope rejection. No Keychain writes.")
    }
}
