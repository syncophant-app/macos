import Foundation

/// A remote manifest travels with the deleted item, so another Mac can restore it too.
public struct TrashedItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let originalPath: String
    public let deletedAt: Date?
    public let isDirectory: Bool
    public let size: Int64
    public let storedPath: String
    public var name: String { PathRules.name(of: originalPath) }
}

public struct RemoteTrash: Sendable {
    public static let root = "/.syncophant-trash"
    public static let retention: TimeInterval = 30 * 86_400
    private let store: any RemoteStore
    private let metadata: MetadataStore

    public init(store: any RemoteStore, metadata: MetadataStore) {
        self.store = store; self.metadata = metadata
    }

    public func delete(_ item: StoredItem, expectedVersion: String) async throws {
        let current = try await store.stat(path: item.entry.path)
        guard current.version == expectedVersion else { throw CoreKitError.itemChanged(current.path) }
        try await ensureDirectory(Self.root)
        let id = UUID(), folder = Self.root + "/" + id.uuidString
        try await store.createDirectory(path: folder)
        let record = TrashedItem(id: id, originalPath: current.path, deletedAt: Date(),
                                 isDirectory: current.isDirectory, size: current.size, storedPath: folder + "/item")
        let manifest = try JSONEncoder().encode(record)
        try await store.write(path: folder + "/manifest.json", offset: 0, data: manifest)
        guard try await store.read(path: folder + "/manifest.json", offset: 0, length: manifest.count + 1) == manifest else {
            throw CoreKitError.checksumMismatch
        }
        try await metadata.move(store: store, id: item.id, to: record.storedPath, trash: true)
    }

    public func items() async throws -> [TrashedItem] {
        let folders: [RemoteEntry]
        do { folders = try await store.list(path: Self.root) }
        catch CoreKitError.notFound { return [] }
        var result: [TrashedItem] = []
        for folder in folders {
            try Task.checkCancellation()
            if folder.isDirectory, let id = UUID(uuidString: folder.name) {
                do {
                    let data = try await store.read(path: folder.path + "/manifest.json", offset: 0, length: 65_537)
                    guard data.count <= 65_536 else { continue }
                    let record = try JSONDecoder().decode(TrashedItem.self, from: data)
                    guard record.id == id, record.storedPath == folder.path + "/item",
                          try PathRules.normalize(record.originalPath) == record.originalPath,
                          record.originalPath != "/", PathRules.isVisible(path: record.originalPath),
                          record.size >= 0, record.deletedAt?.timeIntervalSince1970.isFinite == true else { continue }
                    _ = try await store.stat(path: record.storedPath)
                    result.append(record)
                } catch CoreKitError.notFound { continue }
                catch is DecodingError { continue }
            } else if folder.name.count > 37, let id = UUID(uuidString: String(folder.name.prefix(36))),
                      folder.name.dropFirst(36).first == "-" {
                // Older builds did not record the original folder or deletion date; never auto-expire those files.
                let path = "/" + folder.name.dropFirst(37)
                guard (try? PathRules.normalize(path)) == path, PathRules.isVisible(path: path) else { continue }
                result.append(TrashedItem(id: id, originalPath: path, deletedAt: nil,
                                          isDirectory: folder.isDirectory, size: folder.size, storedPath: folder.path))
            }
        }
        return result.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// No-clobber restore; missing original parents are reported instead of choosing a surprising location.
    public func restore(_ item: TrashedItem) async throws {
        try validate(item)
        let store = store
        try await metadata.withPublication {
            do { try await store.move(from: item.storedPath, to: item.originalPath) }
            catch {
                let settled: Bool
                switch error { case CoreKitError.alreadyExists, CoreKitError.notFound: settled = true; default: settled = false }
                throw PublicationFailure(cause: error, namespaceSettled: settled)
            }
        }
        // The restored data is already safe; orphan manifests may be cleaned on the next visit.
        if item.deletedAt != nil { try? await removeManifest(item) }
        _ = try await metadata.refresh(store: store, path: PathRules.parent(of: item.originalPath))
    }

    public func purgeExpired(now: Date = Date()) async throws -> Int {
        var count = 0
        for item in try await items() {
            guard let date = item.deletedAt, date <= now.addingTimeInterval(-Self.retention) else { continue }
            try validate(item)
            try await removeTree(item.storedPath, depth: 0)
            try await removeManifest(item)
            count += 1
        }
        return count
    }

    private func validate(_ item: TrashedItem) throws {
        let folder = Self.root + "/" + item.id.uuidString
        guard try PathRules.normalize(item.originalPath) == item.originalPath,
              item.originalPath != "/", PathRules.isVisible(path: item.originalPath),
              item.storedPath == folder + "/item" || (item.deletedAt == nil && item.storedPath.hasPrefix(folder + "-")),
              PathRules.parent(of: item.storedPath) == (item.deletedAt == nil ? Self.root : folder) else {
            throw CoreKitError.invalidPath(item.storedPath)
        }
    }

    private func ensureDirectory(_ path: String) async throws {
        do { try await store.createDirectory(path: path) }
        catch CoreKitError.alreadyExists {
            guard try await store.stat(path: path).isDirectory else { throw CoreKitError.unsafePath(path) }
        }
    }

    private func removeManifest(_ item: TrashedItem) async throws {
        let folder = PathRules.parent(of: item.storedPath)
        try await store.remove(path: folder + "/manifest.json")
        try await store.remove(path: folder)
    }

    private func removeTree(_ path: String, depth: Int) async throws {
        guard depth < 128, path.hasPrefix(Self.root + "/") else { throw CoreKitError.unsafePath(path) }
        try Task.checkCancellation()
        let entry = try await store.stat(path: path)
        if entry.isDirectory {
            for child in try await store.list(path: path) {
                guard PathRules.parent(of: child.path) == path else { throw CoreKitError.unsafePath(child.path) }
                try await removeTree(child.path, depth: depth + 1)
            }
        }
        // A server-side new/filtered child leaves the directory nonempty; it is never forcibly removed.
        try await store.remove(path: path)
    }
}
