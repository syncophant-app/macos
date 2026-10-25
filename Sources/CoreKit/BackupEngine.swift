import Foundation

public struct BackupRecord: Codable, Sendable, Equatable {
    public let localVersion: String
    public let remotePath: String
    public let remoteVersion: String
    public let checksum: String
}

public struct BackupEntry: Sendable, Identifiable {
    public let relativePath: String
    public let localVersion: String
    public let remotePath: String
    public let remoteVersion: String?
    public let size: Int64
    public let needsUpload: Bool
    public let isDirectory: Bool
    public var id: String { relativePath }
}

public struct BackupPlan: Sendable {
    public let source: URL
    public let entries: [BackupEntry]
    public let skippedPaths: [String]
    public var uploadCount: Int { entries.filter { $0.needsUpload && !$0.isDirectory }.count }
    public var uploadBytes: Int64 { entries.filter { $0.needsUpload && !$0.isDirectory }.reduce(0) { $0 + $1.size } }
}

/// Skip rules a person can switch per backup. `.git` folders and Photos and Final Cut libraries are always skipped,
/// and temporary files (`PathRules.isTemporary`, which covers .DS_Store) never reach the engine at all.
public struct BackupExclusions: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Folders named Caches, and everything inside them.
    public static let caches = BackupExclusions(rawValue: 1 << 0)
    public static let nodeModules = BackupExclusions(rawValue: 1 << 1)
    /// Single files larger than `largeFileLimit`.
    public static let largeFiles = BackupExclusions(rawValue: 1 << 2)
    /// What every backup did before these rules could be switched.
    public static let legacy: BackupExclusions = .nodeModules
    public static let largeFileLimit: Int64 = 2 * 1024 * 1024 * 1024

    /// The switchable rule that matches this item, if any.
    public static func rule(for item: RemoteEntry) -> BackupExclusions? {
        let lower = item.name.lowercased()
        if lower == "node_modules" { return .nodeModules }
        if item.isDirectory, lower == "caches" { return .caches }
        if !item.isDirectory, item.size > largeFileLimit { return .largeFiles }
        return nil
    }

    static func alwaysSkipped(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".git" || lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".fcpbundle")
    }
}

/// One file found by `BackupEngine.scan`, tagged with the switchable rule that would skip it.
public struct BackupScanItem: Sendable {
    public let path: String
    public let size: Int64
    public let rule: BackupExclusions?
}

public struct BackupResult: Sendable {
    public var records: [String: BackupRecord]
    public var failures: [String: String]
    public var uploaded: Int
}

/// One-way, version-preserving backup. A missing local file never deletes its remote copy.
public struct BackupEngine: Sendable {
    private let store: any RemoteStore
    private let transfers: TransferEngine
    public init(store: any RemoteStore, transfers: TransferEngine) { self.store = store; self.transfers = transfers }

    /// Reads the source folder only, never the storage, and tags each file with the rule that would skip it instead of
    /// applying it, so a person can see what each rule saves before choosing. For a backup with no earlier records the
    /// files without a tag are exactly what `preview` would upload.
    public static func scan(source: URL, progress: (@Sendable (Int) -> Void)? = nil) async throws -> [BackupScanItem] {
        let local = try LocalRemoteStore(root: source)
        var pending: [(String, Int, BackupExclusions?)] = [("/", 0, nil)], files: [BackupScanItem] = []
        while let (folder, depth, inherited) = pending.popLast() {
            try Task.checkCancellation()
            guard depth < 128 else { throw CoreKitError.unsafePath(folder) }
            for item in try await local.list(path: folder) where !BackupExclusions.alwaysSkipped(item.name) {
                let rule = inherited ?? BackupExclusions.rule(for: item)
                if item.isDirectory { pending.append((item.path, depth + 1, rule)); continue }
                guard files.count < 1_000_000 else { throw CoreKitError.remote("Backup contains more than one million files; split it into smaller jobs.") }
                files.append(BackupScanItem(path: item.path, size: item.size, rule: rule))
                if files.count % 500 == 0 { progress?(files.count) }
            }
        }
        progress?(files.count)
        return files
    }

    public func preview(source: URL, destination: String, previous: [String: BackupRecord],
                        exclusions: BackupExclusions = .legacy) async throws -> BackupPlan {
        let destination = try PathRules.normalize(destination)
        let local = try LocalRemoteStore(root: source)
        var pending = [("/", 0)], entries: [BackupEntry] = [], skipped: [String] = []
        while let (folder, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard depth < 128 else { throw CoreKitError.unsafePath(folder) }
            for item in try await local.list(path: folder) {
                if BackupExclusions.alwaysSkipped(item.name) || BackupExclusions.rule(for: item).map(exclusions.contains) == true {
                    skipped.append(item.path); continue
                }
                if item.isDirectory { pending.append((item.path, depth + 1)) }
                guard entries.count < 1_000_000 else { throw CoreKitError.remote("Backup contains more than one million files; split it into smaller jobs.") }
                let target = try PathRules.normalize((destination == "/" ? "" : destination) + item.path)
                let record = previous[item.path]
                let path = record?.localVersion == item.version ? record!.remotePath : target
                let remote: RemoteEntry?
                do { remote = try await store.stat(path: path) }
                catch CoreKitError.notFound { remote = nil }
                if let remote, remote.isDirectory != item.isDirectory { throw CoreKitError.alreadyExists(target) }
                let unchanged = item.isDirectory ? remote?.isDirectory == true : record.map { $0.localVersion == item.version && $0.remoteVersion == remote?.version } ?? false
                entries.append(BackupEntry(relativePath: item.path, localVersion: item.version, remotePath: unchanged ? path : target,
                                            remoteVersion: path == target ? remote?.version : nil, size: item.isDirectory ? 0 : item.size, needsUpload: !unchanged, isDirectory: item.isDirectory))
            }
        }
        return BackupPlan(source: source, entries: entries.sorted { $0.relativePath < $1.relativePath }, skippedPaths: skipped.sorted())
    }

    public func run(_ plan: BackupPlan, previous: [String: BackupRecord],
                    progress: (@Sendable (Int, Int, String) -> Void)? = nil) async throws -> BackupResult {
        let local = try LocalRemoteStore(root: plan.source)
        var records = previous, failures: [String: String] = [:], uploaded = 0, completed = 0
        var directories: Set<String> = ["/"]
        for entry in plan.entries where entry.needsUpload {
            try Task.checkCancellation()
            do {
                let source = entry.isDirectory ? nil : try await local.openUploadSource(path: entry.relativePath)
                guard entry.isDirectory || source?.version == entry.localVersion else { throw CoreKitError.sourceChanged }
                let parent = entry.isDirectory ? entry.remotePath : PathRules.parent(of: entry.remotePath)
                var path = ""
                for component in parent.split(separator: "/") {
                    path += "/" + component
                    if directories.contains(path) { continue }
                    do { try await store.createDirectory(path: path) }
                    catch CoreKitError.alreadyExists {
                        guard try await store.stat(path: path).isDirectory else { throw CoreKitError.alreadyExists(path) }
                    }
                    directories.insert(path)
                }
                if entry.isDirectory { continue }
                guard let source else { throw CoreKitError.sourceChanged }
                let receipt = try await transfers.upload(source: source, remotePath: entry.remotePath, expectedVersion: entry.remoteVersion)
                records[entry.relativePath] = BackupRecord(localVersion: entry.localVersion, remotePath: receipt.remotePath,
                                                          remoteVersion: receipt.remoteVersion, checksum: receipt.checksum)
                uploaded += 1
            } catch is CancellationError { throw CancellationError() }
            catch { failures[entry.relativePath] = error.localizedDescription }
            completed += 1
            progress?(completed, plan.uploadCount, entry.relativePath)
        }
        return BackupResult(records: records, failures: failures, uploaded: uploaded)
    }
}
