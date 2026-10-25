import Foundation

public enum StorageProvider: String, Codable, CaseIterable, Sendable {
    case hetzner, sftp, webdav, s3, smb
    case dropbox, onedrive, box, googledrive

    /// The cloud drive this provider signs in to, if it is one.
    public var oauthService: OAuthService? { OAuthService(rawValue: rawValue) }
}

public struct StorageConnection: Identifiable, Codable, Hashable, Sendable {
    public var usesSSH: Bool { provider == .hetzner || provider == .sftp }
    public var id: UUID
    public var name: String
    public var provider: StorageProvider
    public var host: String
    public var port: Int
    public var username: String
    public var rootPath: String
    public var hostKeyFingerprint: String?
    public var endpoint: URL?
    public var bucket: String?
    public var region: String?
    public var share: String?
    public var encryptionEnabled: Bool?

    public init(id: UUID = UUID(), name: String, provider: StorageProvider = .sftp,
                host: String, port: Int = 22, username: String, rootPath: String = "/",
                hostKeyFingerprint: String? = nil, endpoint: URL? = nil,
                bucket: String? = nil, region: String? = nil, share: String? = nil, encryptionEnabled: Bool? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.host = host
        self.port = port; self.username = username; self.rootPath = rootPath
        self.hostKeyFingerprint = hostKeyFingerprint
        self.endpoint = endpoint; self.bucket = bucket; self.region = region; self.share = share
        self.encryptionEnabled = encryptionEnabled
    }
}

public struct RemoteEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Date
    /// Present only when this entry's content was hashed, never inferred from a listing.
    public var contentHash: String?
    /// Opaque filesystem revision evidence; never a content checksum. Listings may omit it.
    public var remoteRevision: String?
    public var version: String {
        let metadata = "\(modifiedAt.timeIntervalSince1970.bitPattern)-\(size)"
        if let remoteRevision { return metadata + "-revision:" + remoteRevision }
        return contentHash.map { metadata + "-sha256:" + $0 } ?? metadata
    }

    public init(id: String? = nil, name: String, path: String, isDirectory: Bool,
                size: Int64, modifiedAt: Date, contentHash: String? = nil, remoteRevision: String? = nil) {
        self.id = id ?? path; self.name = name; self.path = path
        self.isDirectory = isDirectory; self.size = size; self.modifiedAt = modifiedAt
        self.contentHash = contentHash; self.remoteRevision = remoteRevision
    }
}

public enum PublicationMode: Sendable { case atomicMove, copyPreservingSource }

public protocol RemoteStore: Sendable {
    var publicationMode: PublicationMode { get }
    var supportsDirectoryMove: Bool { get }
    var supportsConditionalReplacement: Bool { get }
    func list(path: String) async throws -> [RemoteEntry]
    func stat(path: String) async throws -> RemoteEntry
    func read(path: String, offset: Int64, length: Int) async throws -> Data
    func write(path: String, offset: Int64, data: Data) async throws
    func createDirectory(path: String) async throws
    /// Atomic no-clobber rename. An existing destination must never be replaced.
    func move(from: String, to: String) async throws
    /// Removes a file or an empty directory; nonempty directories are refused.
    func remove(path: String) async throws
    func checksum(path: String) async throws -> String
    /// Optional disk-backed upload session for protocols without in-place range writes.
    func prepareUpload(path: String) async throws
    func finishUpload(path: String) async throws
    /// No-clobber destination publication. Copy-only backends retain the source until verification.
    func publish(from: String, to: String) async throws
    func replace(from: String, to: String, expectedVersion: String) async throws
    /// Sends deliberately conflicting conditional writes to the existing file at `path` and requires the
    /// server to refuse each one, leaving the file unchanged. Throws `CompatibilityProblem` otherwise.
    func verifyWritePreconditions(path: String) async throws
}

extension RemoteStore {
    public var publicationMode: PublicationMode { .atomicMove }
    public var supportsDirectoryMove: Bool { true }
    public var supportsConditionalReplacement: Bool { false }
    public func prepareUpload(path: String) async throws { }
    public func finishUpload(path: String) async throws { }
    public func publish(from: String, to: String) async throws { try await move(from: from, to: to) }
    public func replace(from: String, to: String, expectedVersion: String) async throws {
        throw CoreKitError.remote("This storage does not support conditional replacement.")
    }
    /// Protocols whose no-clobber rename is enforced by the filesystem have no server preconditions to probe.
    public func verifyWritePreconditions(path: String) async throws { }
}

public enum CoreKitError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath(String), notFound(String), alreadyExists(String), unsafePath(String)
    case invalidRange, filteredFile(String), checksumMismatch, sourceChanged, itemChanged(String)
    case hostKeyRequired, hostKeyMismatch, authenticationFailed, timeout
    case connection(String), remote(String), database(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let p): "Invalid storage path: \(p)"
        case .notFound(let p): "Item not found: \(p)"
        case .alreadyExists(let p): "An item already exists: \(p)"
        case .unsafePath(let p): "Symlink or unsupported item refused: \(p)"
        case .invalidRange: "Invalid or oversized byte range."
        case .filteredFile(let p): "Temporary file excluded: \(p)"
        case .checksumMismatch: "Upload checksum did not match; nothing was published."
        case .sourceChanged: "The local file changed during upload; nothing was published."
        case .itemChanged(let path): "The item changed while its content was being verified: \(path)"
        case .hostKeyRequired: "Approve and pin the server's SSH host key before connecting."
        case .hostKeyMismatch: "The server's SSH host key does not match the approved key."
        case .authenticationFailed: "Storage authentication failed. Check the credentials for this connection."
        case .timeout: "The storage operation timed out."
        case .connection(let m), .remote(let m), .database(let m): m
        }
    }
}

public struct StoredItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var entry: RemoteEntry
    public var isPinned: Bool
    public var verifiedVersion: String?
    public var isVerified: Bool { verifiedVersion == entry.version }
    public init(id: String, entry: RemoteEntry, isPinned: Bool = false, verifiedVersion: String? = nil) {
        self.id = id; self.entry = entry; self.isPinned = isPinned; self.verifiedVersion = verifiedVersion
    }
}

public struct UploadReceipt: Sendable, Equatable {
    public let remotePath: String
    public let checksum: String
    public let verified: Bool
    public let remoteVersion: String
    public init(remotePath: String, checksum: String, verified: Bool, remoteVersion: String) {
        self.remotePath = remotePath; self.checksum = checksum; self.verified = verified
        self.remoteVersion = remoteVersion
    }
}

public enum UploadProgress: Sendable, Equatable {
    case uploading(completed: Int64, total: Int64)
    case verifying
    case verified(UploadReceipt)
}
