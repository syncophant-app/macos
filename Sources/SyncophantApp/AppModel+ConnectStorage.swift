import Foundation
import CoreKit

/// What the Connect server form holds for WebDAV, S3, SMB and cloud drives. Validation mirrors the stores so errors show before
/// any network use.
struct StorageDraft: Equatable {
    var provider: StorageProvider = .webdav
    var name = ""
    var endpoint = ""
    var username = ""
    var password = ""
    var bucket = ""
    var region = ""
    var share = ""
    var rootPath = "/"
    var encryptionPassword = ""
    /// Cloud drives: the person's own OAuth app, and the sign-in it produced.
    var clientID = ""
    var clientSecret = ""
    var token: OAuthToken?
    var account = ""

    /// Problems a person can fix in the form, in plain words. Empty when the draft can be checked.
    var problems: [String] {
        var list: [String] = []
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider != .smb, !address.isEmpty, !Self.isPlainHTTPS(address) {
            list.append(address.lowercased().hasPrefix("http://")
                        ? "Use https://. Plain http:// would send your password unprotected."
                        : "Enter an https:// address without a user name, password, query or fragment.")
        }
        if provider == .smb, !address.isEmpty, address.contains(where: { $0 == "/" || $0 == "@" || $0.isWhitespace }) {
            list.append("Enter only the server name or address, such as nas.local.")
        }
        if provider == .smb, share.contains("/") { list.append("Enter the share name only, without slashes.") }
        if (try? PathRules.normalize(rootPath.isEmpty ? "/" : rootPath)) == nil {
            list.append("Use a folder path such as /Backups, without “..” or backslashes.")
        }
        return list
    }

    var complete: Bool {
        if let service = provider.oauthService { return problems.isEmpty && token != nil && !clientID.isEmpty && (!service.requiresSecret || !clientSecret.isEmpty) }
        guard problems.isEmpty, !endpoint.trimmingCharacters(in: .whitespaces).isEmpty, !username.isEmpty, !password.isEmpty else { return false }
        switch provider {
        case .s3: return !bucket.isEmpty && !region.isEmpty
        case .smb: return !share.isEmpty
        default: return true
        }
    }

    static func isPlainHTTPS(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }

    /// Builds the connection and its Keychain credentials. Nothing is contacted.
    func make() throws -> (StorageConnection, StorageCredentials) {
        if let service = provider.oauthService {
            guard let token, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.unavailable("Sign in to \(service.title) first.") }
            let root = try PathRules.normalize(rootPath.isEmpty ? "/" : rootPath)
            return (StorageConnection(name: name, provider: provider, host: service.apiHost, port: 443, username: account, rootPath: root,
                                      encryptionEnabled: !encryptionPassword.isEmpty),
                    StorageCredentials(authentication: .oauth(service: service, client: OAuthClient(clientID: clientID, clientSecret: clientSecret), token: token),
                                       encryptionPassword: encryptionPassword.isEmpty ? nil : encryptionPassword))
        }
        guard [.webdav, .s3, .smb].contains(provider), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else { throw AppError.unavailable("Enter a name and credentials for your storage.") }
        let root = try PathRules.normalize(rootPath.isEmpty ? "/" : rootPath)
        let encrypted = !encryptionPassword.isEmpty
        let secret = encrypted ? encryptionPassword : nil
        if provider == .smb {
            let host = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains(where: \.isWhitespace),
                  !share.isEmpty, !share.contains("/"), !username.isEmpty else { throw AppError.unavailable("Enter a server name, share name and user name.") }
            return (StorageConnection(name: name, provider: provider, host: host, port: 445, username: username,
                                      rootPath: root, share: share, encryptionEnabled: encrypted),
                    StorageCredentials(authentication: .password(password), encryptionPassword: secret))
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), Self.isPlainHTTPS(url.absoluteString),
              let host = url.host else { throw AppError.unavailable("Enter an https:// address without credentials, a query or a fragment.") }
        if provider == .s3 {
            guard !bucket.isEmpty, !region.isEmpty, !username.isEmpty else { throw AppError.unavailable("Enter the bucket and access key ID.") }
            return (StorageConnection(name: name, provider: provider, host: host, port: url.port ?? 443, username: "",
                                      rootPath: root, endpoint: url, bucket: bucket, region: region, encryptionEnabled: encrypted),
                    StorageCredentials(authentication: .s3(accessKey: username, secretKey: password, sessionToken: nil), encryptionPassword: secret))
        }
        guard !username.isEmpty else { throw AppError.unavailable("Enter your WebDAV user name.") }
        let scopedURL = root == "/" ? url : url.appendingPathComponent(String(root.dropFirst()), isDirectory: true)
        return (StorageConnection(name: name, provider: provider, host: host, port: url.port ?? 443, username: username,
                                  endpoint: scopedURL, encryptionEnabled: encrypted),
                StorageCredentials(authentication: .password(password), encryptionPassword: secret))
    }
}

extension AppModel {
    /// Saves a storage whose connection check passed, then opens it and adds it to Finder.
    func saveStorage(_ connection: StorageConnection, credentials: StorageCredentials, store: any RemoteStore) async throws {
        guard !isDemo else { throw AppError.demoOnly }
        try credentials.save(for: connection.id)
        do { try SharedConfig.saveConnections(connections + [connection]) }
        catch { try? KeychainSecretStore.delete(for: connection.id); throw error }
        connections.append(connection)
        credentialPresent[connection.id] = true
        stores[connection.id] = store
        activeID = connection.id; destination = .files
        await openActive()
        await mount(connection)
    }
}
