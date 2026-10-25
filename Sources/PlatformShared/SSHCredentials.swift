import Foundation
import CoreKit

enum SSHCredentials {
    private static let prefix = "syncophant-ssh-v1:"
    private static let macKeySlot = UUID(uuidString: "5F6C7A4E-0000-4000-8000-0000C0FFEE02")!
    private static let generationLock = NSLock()

    /// Keep the Mac's key durable before installing its public half on any server.
    static func generatedKeyPair() throws -> SSHKeyPair {
        generationLock.lock()
        defer { generationLock.unlock() }
        if let encoded = try KeychainSecretStore.get(for: macKeySlot) {
            return try JSONDecoder().decode(SSHKeyPair.self, from: Data(encoded.utf8))
        }
        let pair = try SSHLocalTools.generateKeyPair()
        let encoded = try JSONEncoder().encode(pair)
        try KeychainSecretStore.set(String(decoding: encoded, as: UTF8.self), for: macKeySlot)
        return pair
    }

    static func encode(_ authentication: SSHAuthentication) throws -> String {
        prefix + (try JSONEncoder().encode(authentication)).base64EncodedString()
    }

    static func decode(_ value: String) throws -> SSHAuthentication {
        guard value.hasPrefix(prefix) else { return .password(value) }
        guard let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(SSHAuthentication.self, from: data)
    }

    static func load(for id: UUID) throws -> SSHAuthentication? {
        try KeychainSecretStore.get(for: id).map(decode)
    }

    static func save(_ authentication: SSHAuthentication, for id: UUID) throws {
        try KeychainSecretStore.set(encode(authentication), for: id)
    }

    static func delete(for id: UUID) throws { try KeychainSecretStore.delete(for: id) }

    static func makeStore(connection: StorageConnection) throws -> SFTPStore {
        guard let authentication = try load(for: connection.id) else { throw CoreKitError.authenticationFailed }
        return try makeStore(connection: connection, authentication: authentication)
    }

    static func makeStore(connection: StorageConnection, authentication: SSHAuthentication) throws -> SFTPStore {
        let signer: (any SSHAgentSigner)?
        if case .agent = authentication, Bundle.main.bundleURL.pathExtension == "appex" {
            signer = SSHAgentBrokerClient(connectionID: connection.id)
        } else { signer = nil }
        return SFTPStore(connection: connection, authentication: authentication,
                         sessionBudgetURL: try SharedConfig.directory().appendingPathComponent("ssh-session-budget"), agentSigner: signer)
    }
}
