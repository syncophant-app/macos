import Foundation

struct CachePolicy: Codable, Sendable {
    let sizeGB: Int
    var budgetBytes: Int64 { Int64(sizeGB) * 1_000_000_000 }
    static let idleLimit: TimeInterval = 30 * 24 * 60 * 60

    init(sizeGB: Int = 5) throws {
        guard (1...500).contains(sizeGB) else { throw NSError(domain: "CachePolicy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cache size must be between 1 and 500 GB."]) }
        self.sizeGB = sizeGB
    }

    private enum CodingKeys: String, CodingKey { case sizeGB }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sizeGB: values.decode(Int.self, forKey: .sizeGB))
    }

    static func load() throws -> CachePolicy {
        let url = try SharedConfig.directory().appendingPathComponent("cache-policy.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return try CachePolicy() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save() throws {
        try Self.write(self, to: SharedConfig.directory().appendingPathComponent("cache-policy.json"))
    }

    static func loadStatus(domainID: String) throws -> CacheStatus? {
        let url = try statusURL(domainID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CacheStatus.self, from: Data(contentsOf: url))
    }

    static func saveStatus(_ status: CacheStatus, domainID: String) throws {
        try write(status, to: statusURL(domainID))
    }

    private static func statusURL(_ domainID: String) throws -> URL {
        guard !domainID.isEmpty, !domainID.contains("/"), !domainID.contains("\0"),
              domainID != ".", domainID != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        return try SharedConfig.directory().appendingPathComponent("cache-status-\(domainID).json")
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Allocated bytes only. Pinned and blocked bytes are disjoint subsets of cachedBytes.
/// A partial snapshot is a lower bound, never evidence that the budget was met.
struct CacheStatus: Codable, Sendable {
    var timestamp = Date()
    var budgetBytes: Int64 = 0
    var cachedBytes: Int64 = 0
    var pinnedBytes: Int64 = 0
    var blockedBytes: Int64 = 0
    var unknownItemCount = 0
    var measurementComplete = false
    var enforced = false
    var diagnostics: [String] = []
}
