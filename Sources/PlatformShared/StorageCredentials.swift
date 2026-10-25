import Foundation
import CoreKit

struct StorageCredentials: Codable, Sendable {
    enum Authentication: Codable, Sendable {
        case ssh(SSHAuthentication)
        case password(String)
        case s3(accessKey: String, secretKey: String, sessionToken: String?)
    }
    let authentication: Authentication
    var encryptionPassword: String?
    var encryptionSalt: String?
    private static let prefix = "syncophant-storage-v2:"

    static func load(for id: UUID) throws -> StorageCredentials? {
        guard let value = try KeychainSecretStore.get(for: id) else { return nil }
        if value.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(Self.self, from: data)
        }
        return StorageCredentials(authentication: .ssh(try SSHCredentials.decode(value)))
    }

    func save(for id: UUID) throws {
        try KeychainSecretStore.set(Self.prefix + JSONEncoder().encode(self).base64EncodedString(), for: id)
    }

    func makeStore(connection c: StorageConnection) throws -> any RemoteStore {
        let base: any RemoteStore
        switch (c.provider, authentication) {
        case (.sftp, .ssh(let auth)), (.hetzner, .ssh(let auth)):
            base = try SSHCredentials.makeStore(connection: c, authentication: auth)
        case (.webdav, .password(let password)):
            guard let endpoint = c.endpoint else { throw CoreKitError.connection("The WebDAV address is missing.") }
            base = try WebDAVStore(endpoint: endpoint, username: c.username, password: password)
        case (.s3, .s3(let accessKey, let secretKey, let token)):
            guard let endpoint = c.endpoint, let bucket = c.bucket, let region = c.region else { throw CoreKitError.connection("S3 endpoint, bucket or region is missing.") }
            base = try S3Store(endpoint: endpoint, bucket: bucket, region: region, accessKey: accessKey,
                               secretKey: secretKey, sessionToken: token, rootPath: c.rootPath)
        case (.smb, .password(let password)):
            guard let share = c.share else { throw CoreKitError.connection("The SMB share is missing.") }
            base = try SMBStore(server: c.host, share: share, username: c.username, password: password, rootPath: c.rootPath)
        default: throw CoreKitError.authenticationFailed
        }
        if c.encryptionEnabled == true {
            guard let password = encryptionPassword, !password.isEmpty else { throw CoreKitError.authenticationFailed }
            return try CryptStore(base: base, password: password, password2: encryptionSalt ?? "", helperURL: SharedConfig.cryptHelperURL())
        }
        return base
    }

    static func makeStore(connection: StorageConnection) throws -> any RemoteStore {
        guard let credentials = try load(for: connection.id) else { throw CoreKitError.authenticationFailed }
        return try credentials.makeStore(connection: connection)
    }
}
