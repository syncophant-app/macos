import Foundation
import Security
import CoreKit

// MARK: - JSON files in the shared directory

enum SharedJSON {
    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = try? SharedConfig.directory().appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String) throws {
        let url = try SharedConfig.directory().appendingPathComponent(name)
        try JSONEncoder.iso.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

// MARK: - Hetzner API token (Keychain, never settings)

enum HetznerToken {
    /// One fixed account slot in the shared Keychain service; the token is not tied to any connection.
    private static let slot = UUID(uuidString: "5F6C7A4E-0000-4000-8000-0000C0FFEE01")!
    static func load() -> String? { (try? KeychainSecretStore.get(for: slot)) ?? nil }
    static func save(_ token: String) throws { try KeychainSecretStore.set(token, for: slot) }
    static func forget() throws { try KeychainSecretStore.delete(for: slot) }
}

// MARK: - Passive ~/.ssh/config import

struct SSHHost: Identifiable, Hashable {
    var alias: String
    var hostName: String
    var user: String
    var port: Int
    var identityFiles: [String] = []
    var identityAgent: String?
    var id: String { alias }

    static func read() throws -> [SSHHost] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return try SSHConfiguration.aliases(configurationURL: url).map { alias in
            let config = try SSHConfiguration.resolve(alias: alias, configurationURL: url)
            return SSHHost(alias: alias, hostName: config.hostName, user: config.user, port: config.port,
                           identityFiles: config.identityFiles, identityAgent: config.identityAgent)
        }
    }
}

// MARK: - Version (updates themselves are Sparkle's job, see AppUpdater)

enum AppVersion {
    /// "0.2.0 (57)": marketing version from the release tag, build number from the release run.
    static var current: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "development build" }
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }
}

// MARK: - Local diagnostics (never uploaded)

struct DiagnosticsLog {
    private(set) var lines: [String] = []
    mutating func add(_ text: String) {
        lines.append("\(ISO8601DateFormatter().string(from: Date())) \(text)")
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    /// Replaces hostnames and user names with placeholders before anything leaves memory.
    func redacted(hosts: [String], users: [String]) -> String {
        var text = lines.joined(separator: "\n")
        for (i, h) in Set(hosts).filter({ !$0.isEmpty }).enumerated() { text = text.replacingOccurrences(of: h, with: "<host-\(i + 1)>") }
        for (i, u) in Set(users).filter({ !$0.isEmpty }).enumerated() { text = text.replacingOccurrences(of: u, with: "<user-\(i + 1)>") }
        let header = "Syncophant \(AppVersion.current) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        return header + text + "\n"
    }
}
