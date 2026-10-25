import Foundation
import CoreKit
import Security

enum SharedConfig {
    static let appGroup = SSHAgentBrokerPolicy.appGroup

    static func directory() throws -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Syncophant", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return base
    }

    static func loadConnections() throws -> [StorageConnection] {
        let url = try directory().appendingPathComponent("connections.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([StorageConnection].self, from: Data(contentsOf: url))
    }

    static func saveConnections(_ connections: [StorageConnection]) throws {
        let url = try directory().appendingPathComponent("connections.json")
        try JSONEncoder().encode(connections).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func metadataURL(for id: UUID) throws -> URL {
        try directory().appendingPathComponent("metadata-\(id.uuidString).sqlite")
    }

    static func cryptHelperURL() throws -> URL {
        if let url = Bundle.main.url(forResource: "syncophant-crypt", withExtension: nil) { return url }
        if Bundle.main.bundleURL.pathExtension != "app" && Bundle.main.bundleURL.pathExtension != "appex" {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".deps/bin/syncophant-crypt")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw CoreKitError.connection("The encrypted-storage helper is missing. Reinstall Syncophant.")
    }
}

enum KeychainSecretStore {
    private static func query(for id: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.syncophant.mac.storage",
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
        // An unsigned developer build uses its default Keychain; signed targets share this access group.
        if let group = Bundle.main.object(forInfoDictionaryKey: "SyncophantKeychainAccessGroup") as? String,
           let prefix = group.split(separator: ".").first, prefix.count == 10,
           !group.contains("$(") {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    static func set(_ value: String, for connectionID: UUID) throws {
        let base = query(for: connectionID)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = base.merging(attributes) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(entry as CFDictionary, nil))
        } else { try check(status) }
    }

    static func get(for connectionID: UUID) throws -> String? {
        var request = query(for: connectionID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(request as CFDictionary, &result)
        var migrating = false
        if status == errSecItemNotFound, request[kSecAttrAccessGroup as String] != nil,
           Bundle.main.bundleURL.pathExtension == "app" {
            // A local unsigned build used the default Keychain group; retain its credentials after signing.
            request.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemCopyMatching(request as CFDictionary, &result)
            migrating = status == errSecSuccess
        }
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if migrating { try set(value, for: connectionID) }
        return value
    }

    static func delete(for connectionID: UUID) throws {
        let status = SecItemDelete(query(for: connectionID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain access failed."
            ])
        }
    }
}
