import Foundation

public struct StorageAccessSettings: Codable, Sendable, Equatable {
    public var sshEnabled: Bool?
    public var reachableExternally: Bool?
    public var sambaEnabled: Bool?
    public var webdavEnabled: Bool?
    public var zfsEnabled: Bool?
    public var readonly: Bool?

    public init(sshEnabled: Bool? = nil, reachableExternally: Bool? = nil, sambaEnabled: Bool? = nil,
                webdavEnabled: Bool? = nil, zfsEnabled: Bool? = nil, readonly: Bool? = nil) {
        self.sshEnabled = sshEnabled; self.reachableExternally = reachableExternally; self.sambaEnabled = sambaEnabled
        self.webdavEnabled = webdavEnabled; self.zfsEnabled = zfsEnabled; self.readonly = readonly
    }

    enum CodingKeys: String, CodingKey {
        case sshEnabled = "ssh_enabled", reachableExternally = "reachable_externally"
        case sambaEnabled = "samba_enabled", webdavEnabled = "webdav_enabled"
        case zfsEnabled = "zfs_enabled", readonly
    }
}

public struct StorageBox: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    /// Empty while Hetzner is initializing the box. Never use an empty host to connect.
    public let server: String
    public let username: String
    public let diskQuota: Int64?
    public let diskUsage: Int64?
    public let status: String?
    public let accessSettings: StorageAccessSettings?
    /// Plan name such as "bx11", when Hetzner reports it.
    public var typeName: String? = nil
    /// Location city (or code) such as "Falkenstein", when Hetzner reports it.
    public var locationName: String? = nil
    public var isReady: Bool { status == "active" && !server.isEmpty && !username.isEmpty }

    public init(id: Int, name: String, server: String, username: String,
                diskQuota: Int64? = nil, diskUsage: Int64? = nil,
                status: String? = nil, accessSettings: StorageAccessSettings? = nil) {
        self.id = id; self.name = name; self.server = server; self.username = username
        self.diskQuota = diskQuota; self.diskUsage = diskUsage
        self.status = status; self.accessSettings = accessSettings
    }

    enum CodingKeys: String, CodingKey {
        case id, name, server, username, status
        case diskQuota = "disk_quota", diskUsage = "disk_usage"
        case storageBoxType = "storage_box_type", stats, accessSettings = "access_settings", location
    }
    private struct Size: Decodable { let size: Int64? }
    private struct Kind: Decodable { let name: String? }
    private struct Place: Decodable { let name: String?; let city: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
        accessSettings = try c.decodeIfPresent(StorageAccessSettings.self, forKey: .accessSettings)
        diskQuota = try c.decodeIfPresent(Size.self, forKey: .storageBoxType)?.size
            ?? c.decodeIfPresent(Int64.self, forKey: .diskQuota)
        diskUsage = try c.decodeIfPresent(Size.self, forKey: .stats)?.size
            ?? c.decodeIfPresent(Int64.self, forKey: .diskUsage)
        typeName = (try? c.decodeIfPresent(Kind.self, forKey: .storageBoxType))?.flatMap(\.name)
        let place = try? c.decodeIfPresent(Place.self, forKey: .location)
        locationName = place?.city ?? place?.name
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(server, forKey: .server); try c.encode(username, forKey: .username)
        try c.encodeIfPresent(diskQuota, forKey: .diskQuota)
        try c.encodeIfPresent(diskUsage, forKey: .diskUsage)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(accessSettings, forKey: .accessSettings)
    }
}

public struct StorageSnapshot: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let createdAt: Date?
    public let description: String?
    /// Made by the box's snapshot plan rather than by a person. Nil when Hetzner did not say.
    public let isAutomatic: Bool?

    public init(id: Int, name: String, createdAt: Date? = nil, description: String? = nil, isAutomatic: Bool? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.description = description; self.isAutomatic = isAutomatic
    }

    enum CodingKeys: String, CodingKey { case id, name, createdAt = "created", description, isAutomatic = "is_automatic" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        isAutomatic = try c.decodeIfPresent(Bool.self, forKey: .isAutomatic)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = parser.date(from: raw)
            parser.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? parser.date(from: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .createdAt, in: c, debugDescription: "Invalid RFC3339 date")
            }
            createdAt = date
        } else { createdAt = nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(isAutomatic, forKey: .isAutomatic)
        if let createdAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(formatter.string(from: createdAt), forKey: .createdAt)
        }
    }
}

public struct StorageSubaccount: Codable, Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let server: String?
    public let name: String?
    public let homeDirectory: String?
    public let accessSettings: StorageAccessSettings?

    public init(id: Int, username: String, server: String? = nil, name: String? = nil,
                homeDirectory: String? = nil, accessSettings: StorageAccessSettings? = nil) {
        self.id = id; self.username = username; self.server = server; self.name = name
        self.homeDirectory = homeDirectory; self.accessSettings = accessSettings
    }

    enum CodingKeys: String, CodingKey {
        case id, username, server, name, homeDirectory = "home_directory", accessSettings = "access_settings"
    }

    /// A sub-account name Hetzner accepts: ASCII letters, digits and single dashes, at most 50 characters,
    /// and not already used on the box (names are unique per box), so `-2`, `-3`… is added when needed.
    public static func availableName(_ raw: String, taken: some Sequence<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        let slug = raw.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.joined(separator: "-")
        let base = slug.isEmpty ? "subaccount" : String(slug.prefix(50))
        var name = base, n = 2
        while taken.contains(name) {
            let suffix = "-\(n)"
            name = String(base.prefix(50 - suffix.count)) + suffix
            n += 1
        }
        return name
    }
}
