import Foundation
import CryptoKit
import CoreKit

@main
struct SSHAgentBrokerSelfCheck {
    static let fixtureID = UUID(uuidString: "D80197C7-7BFA-49DC-948B-7BE6C705909E")!
    static let username = "isolated-agent-fixture"

    static func main() throws {
        let mode = CommandLine.arguments[1]
        if mode == "--helper" { SSHAgentRendezvous.run(); return }
        if mode == "--app" { try app(); return }
        if mode == "--provider" {
            let signer = SSHAgentBrokerClient(connectionID: fixtureID)
            let keys = try signer.identities(deadline: deadline())
            precondition(keys.count == 1)
            let key = keys[0], challenge = challenge(key: key, user: username)
            let signature = try signer.sign(publicKey: key, challenge: challenge, deadline: deadline())
            let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key.suffix(32))
            precondition(verifier.isValidSignature(signature, for: challenge), "Agent signature does not verify")
            try rejected("wrong username") { _ = try signer.sign(publicKey: key, challenge: Self.challenge(key: key, user: "another-user"), deadline: deadline()) }
            try rejected("arbitrary message") { _ = try signer.sign(publicKey: key, challenge: Data("sign this arbitrary message".utf8), deadline: deadline()) }
            var differentKey = key; differentKey[differentKey.count - 1] ^= 1
            try rejected("different key") { _ = try signer.sign(publicKey: differentKey, challenge: challenge, deadline: deadline()) }
            try rejected("unknown connection") { _ = try SSHAgentBrokerClient(connectionID: UUID()).identities(deadline: deadline()) }
            try rejected("provider cannot register app endpoint") { try register(NSXPCListener.anonymous().endpoint) }
            print("Signed XPC provider: real agent signature verified; username/key/message/connection guards and role separation passed.")
            return
        }
        if mode == "--unavailable" || mode == "--foreign" {
            try rejected(mode) { _ = try SSHAgentBrokerClient(connectionID: fixtureID).identities(deadline: deadline()) }
            print("\(mode): rejected as expected."); return
        }
        if mode == "--bad-agent" || mode == "--timeout" {
            let started = ProcessInfo.processInfo.systemUptime
            let signer = SSHAgentSocketSigner(socketPath: CommandLine.arguments[2])
            if mode == "--timeout" {
                do { _ = try signer.identities(deadline: started + 0.2); fatalError("Stalled agent did not time out") }
                catch CoreKitError.timeout { }
            } else {
                try rejected("oversized agent response") { _ = try signer.identities(deadline: started + 1) }
            }
            precondition(ProcessInfo.processInfo.systemUptime - started < 1.5)
            print("\(mode): bounded agent response rejection passed."); return
        }
        if mode == "--parser" {
            let key = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let valid = challenge(key: key, user: username)
            let parsed = try SSHAgentAuthenticationRequest(challenge: valid)
            precondition(parsed.username == username && parsed.publicKey == key && parsed.algorithm == "ssh-ed25519")
            let sliced = (Data([0]) + valid).dropFirst()
            let parsedSlice = try SSHAgentAuthenticationRequest(challenge: sliced)
            precondition(parsedSlice.publicKey == key)
            for size in [0, 1, 3, 4, 30, valid.count - 1] {
                try rejected("truncated challenge") { _ = try SSHAgentAuthenticationRequest(challenge: valid.prefix(size)) }
            }
            try rejected("trailing data") { _ = try SSHAgentAuthenticationRequest(challenge: valid + Data([0])) }
            try rejected("oversized field") { _ = try SSHAgentAuthenticationRequest(challenge: Data([255, 255, 255, 255])) }
            print("SSH authentication parser: valid packet and malformed/truncated/oversized packet rejection passed.")
            return
        }
        fatalError("Unknown self-check mode")
    }

    static func app() throws {
        let path = ProcessInfo.processInfo.environment["SYNCOPHANT_TEST_AGENT_SOCKET"]!
        let service = SSHAgentAppService { id in
            guard id == fixtureID else { throw SSHAgentBrokerPolicy.unavailable }
            return (username, path)
        }
        let delegate = SSHAgentAppListener(service: service)
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(SSHAgentBrokerPolicy.providerRequirement)
        listener.delegate = delegate; listener.activate()
        let registration = try register(listener.endpoint)
        try Data("ready".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        withExtendedLifetime((registration, listener, delegate)) { RunLoop.current.run() }
    }

    @discardableResult static func register(_ endpoint: NSXPCListenerEndpoint) throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: SSHAgentBrokerPolicy.registrationService)
        connection.setCodeSigningRequirement(SSHAgentBrokerPolicy.rendezvousRequirement)
        connection.remoteObjectInterface = SSHAgentXPCInterface.registration(); connection.activate()
        do {
            let accepted: Bool = try SSHAgentXPC.call(connection, deadline: deadline()) { proxy, complete in
                (proxy as? SSHAgentEndpointRegistration)?.register(endpoint: endpoint) { complete(.success($0)) }
            }
            guard accepted else { throw SSHAgentBrokerPolicy.unavailable }
            return connection
        } catch { connection.invalidate(); throw error }
    }

    static func deadline() -> TimeInterval { ProcessInfo.processInfo.systemUptime + 5 }
    static func rejected(_ reason: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        fatalError("Accepted \(reason)")
    }
    static func challenge(key: Data, user: String) -> Data {
        func field(_ bytes: Data) -> Data {
            let size = UInt32(bytes.count)
            return Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + bytes
        }
        return field(Data(repeating: 42, count: 32)) + Data([50]) + field(Data(user.utf8))
            + field(Data("ssh-connection".utf8)) + field(Data("publickey".utf8)) + Data([1])
            + field(Data("ssh-ed25519".utf8)) + field(key)
    }
}
