import Foundation
import FileProvider
import CoreKit
import AppKit

actor ProviderRuntime {
    let connection: StorageConnection
    let store: any RemoteStore
    let metadata: MetadataStore
    let transfers: TransferEngine
    let domain: NSFileProviderDomain
    private var polls: [String: Task<Void, Never>] = [:]
    private var subscribers: [String: Set<UUID>] = [:]
    private var snapshotRevision: Int64 = -1
    private var stopped = false
    private var journal: ProviderJournal
    private let journalURL: URL
    private var trashCleanup: Task<Void, Never>?
    private var lastTrashCleanup = Date.distantPast
    private var shared: (stamps: [Date?], states: [String: String], badges: Bool)?

    init(domain: NSFileProviderDomain) throws {
        guard let id = UUID(uuidString: domain.identifier.rawValue),
              let connection = try SharedConfig.loadConnections().first(where: { $0.id == id }) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let store = LoggedRemoteStore(base: try StorageCredentials.makeStore(connection: connection), host: connection.host, port: connection.port, protocolName: connection.provider.rawValue.uppercased())
        try self.init(domain: domain, connection: connection, store: store,
                      metadata: MetadataStore(url: SharedConfig.metadataURL(for: id)),
                      journalURL: SharedConfig.directory().appendingPathComponent("journal-\(id.uuidString).json"))
    }

    init(domain: NSFileProviderDomain, connection: StorageConnection, store: any RemoteStore, metadata: MetadataStore, journalURL: URL) throws {
        self.domain = domain
        self.connection = connection
        self.store = store
        self.transfers = TransferEngine(store: store, metadata: metadata)
        self.metadata = metadata
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(ProviderJournal.self, from: Data(contentsOf: journalURL))
        } else { journal = ProviderJournal() }
    }

    func stop() {
        stopped = true
        polls.values.forEach { $0.cancel() }
        polls.removeAll()
        subscribers.removeAll()
        trashCleanup?.cancel(); trashCleanup = nil
    }

    func subscribe(_ identifier: NSFileProviderItemIdentifier, token: UUID) {
        guard !stopped, identifier != .workingSet else { return }
        let key = identifier.rawValue
        subscribers[key, default: []].insert(token)
        guard polls[key] == nil else { return }
        polls[key] = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self else { return }
                await self.refresh(identifier)
            }
        }
    }

    func unsubscribe(_ identifier: NSFileProviderItemIdentifier, token: UUID) {
        let key = identifier.rawValue
        subscribers[key]?.remove(token)
        if subscribers[key]?.isEmpty == true {
            subscribers.removeValue(forKey: key)
            polls.removeValue(forKey: key)?.cancel()
        }
    }

    func item(_ identifier: NSFileProviderItemIdentifier) async throws -> ProviderItem {
        if identifier == .rootContainer {
            let entry = RemoteEntry(name: connection.name, path: "/", isDirectory: true, size: 0, modifiedAt: .distantPast)
            return ProviderItem(StoredItem(id: NSFileProviderItemIdentifier.rootContainer.rawValue, entry: entry, isPinned: false), parent: .rootContainer)
        }
        guard let stored = try await metadata.item(id: identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        return try await makeItem(stored)
    }

    private func makeItem(_ stored: StoredItem) async throws -> ProviderItem {
        try makeItem(stored, in: await metadata.snapshot().items)
    }

    private func makeItem(_ stored: StoredItem, in snapshot: [StoredItem]) throws -> ProviderItem {
        let parentPath = PathRules.parent(of: stored.entry.path)
        let parent: NSFileProviderItemIdentifier
        if parentPath == "/" { parent = .rootContainer }
        else if let found = snapshot.first(where: { $0.entry.path == parentPath }) {
            parent = .init(rawValue: found.id)
        } else { throw NSFileProviderError(.noSuchItem) }
        return providerItem(stored, parent: parent)
    }

    private func providerItem(_ stored: StoredItem, parent: NSFileProviderItemIdentifier, displayName: String? = nil) -> ProviderItem {
        let movable = store.publicationMode == .atomicMove && (!stored.entry.isDirectory || store.supportsDirectoryMove)
        return ProviderItem(stored, parent: parent, displayName: displayName, allowsMoving: movable, allowsDeletion: movable, context: context(stored))
    }

    private func context(_ stored: StoredItem) -> FinderContext {
        let (states, badges) = sharedState()
        let plain = connection.encryptionEnabled != true
        return FinderContext(transfer: states[stored.entry.path],
                             canShare: plain && (connection.provider == .s3 ? !stored.entry.isDirectory : connection.provider == .hetzner && stored.entry.isDirectory),
                             hasVersions: connection.provider == .hetzner, badges: badges)
    }

    /// The app's upload queue and settings, re-read whenever either file changes. No time-based caching: the app
    /// signals the working set right after writing, and a stale read then would never be corrected.
    private func sharedState() -> ([String: String], Bool) {
        let urls = ["transfers.json", "settings.json"].map { try? SharedConfig.directory().appendingPathComponent($0) }
        let stamps = urls.map { try? $0?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if let shared, shared.stamps == stamps { return (shared.states, shared.badges) }
        let data = urls.map { $0.flatMap { try? Data(contentsOf: $0) } }
        let next = (stamps, FinderContext.transferStates(data[0], connection: connection.id), FinderContext.badgesEnabled(data[1]))
        shared = next
        return (next.1, next.2)
    }

    private func displayed(_ items: [StoredItem], parent: NSFileProviderItemIdentifier) -> [ProviderItem] {
        let groups = Dictionary(grouping: items, by: { $0.entry.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) })
        return items.map { stored in
            let collision = (groups[stored.entry.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))]?.count ?? 0) > 1
            return providerItem(stored, parent: parent, displayName: collision ? "\(stored.entry.name) (\(stored.id.prefix(6)))" : nil)
        }
    }

    func list(_ identifier: NSFileProviderItemIdentifier, refresh: Bool = false) async throws -> [ProviderItem] {
        scheduleTrashCleanup()
        if identifier == .workingSet {
            let snapshot = try await metadata.snapshot().items
            return try snapshot.map { try makeItem($0, in: snapshot) }
        }
        let folder = try await item(identifier)
        guard folder.stored.entry.isDirectory else { return [folder] }
        let path = folder.stored.entry.path
        let cached = try await metadata.items(parentPath: path)
        let items = refresh || cached.isEmpty ? try await metadata.refresh(store: store, path: path) : cached
        return displayed(items, parent: identifier)
    }

    private func scheduleTrashCleanup() {
        guard !stopped, trashCleanup == nil, Date().timeIntervalSince(lastTrashCleanup) >= 86_400 else { return }
        lastTrashCleanup = Date()
        let store = store, metadata = metadata
        trashCleanup = Task { [weak self] in
            _ = try? await RemoteTrash(store: store, metadata: metadata).purgeExpired()
            await self?.trashCleanupFinished()
        }
    }

    private func trashCleanupFinished() { trashCleanup = nil }

    /// Custom Finder actions declared in Provider-Info.plist. Download Now and Remove Download are the system's own.
    static let appRoutes = ["app.syncophant.retry": "retry-upload", "app.syncophant.why": "activity",
                            "app.syncophant.compare": "compare", "app.syncophant.share": "share",
                            "app.syncophant.versions": "time-travel"]
    static let actions: Set<String> = Set(appRoutes.keys).union(["app.syncophant.keep", "app.syncophant.unkeep", "app.syncophant.refresh",
                                                                 "app.syncophant.copy-path", "app.syncophant.terminal"])

    /// `syncophant://<route>?storage=<connection id>&path=<remote path>`; the app opens the matching screen.
    static func appURL(route: String, storage: UUID, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "syncophant"
        components.host = route
        components.queryItems = [.init(name: "storage", value: storage.uuidString), .init(name: "path", value: path)]
        return components.url
    }

    func performAction(_ action: String, identifiers: [NSFileProviderItemIdentifier]) async throws {
        guard Self.actions.contains(action), !identifiers.isEmpty,
              let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.featureUnsupported) }
        if action == "app.syncophant.copy-path" || action == "app.syncophant.terminal" {
            var urls: [URL] = []
            for identifier in identifiers {
                try Task.checkCancellation()
                let item = try await item(identifier)
                let url = try await manager.getUserVisibleURL(for: identifier)
                let target = action == "app.syncophant.terminal" && !item.stored.entry.isDirectory ? url.deletingLastPathComponent() : url
                if !urls.contains(target) { urls.append(target) }
            }
            try Task.checkCancellation()
            try await Self.performFinderAction(action, urls: urls)
            return
        }
        if let route = Self.appRoutes[action] {
            var urls: [URL] = []
            for identifier in identifiers {
                let path = try await item(identifier).stored.entry.path
                guard let url = Self.appURL(route: route, storage: connection.id, path: path) else { throw CocoaError(.fileReadInvalidFileName) }
                urls.append(url)
            }
            try Task.checkCancellation()
            try await Self.performFinderAction(action, urls: urls)
            return
        }
        for identifier in identifiers {
            try Task.checkCancellation()
            let item = try await item(identifier)
            switch action {
            case "app.syncophant.keep", "app.syncophant.unkeep":
                // Same store the app's Keep Downloaded switch writes; contentPolicy follows it.
                let keep = action == "app.syncophant.keep"
                try await metadata.setPinned(id: item.stored.id, keep)
                try await manager.signalEnumerator(for: identifier)
                try await manager.signalEnumerator(for: .workingSet)
                if keep { try await manager.requestDownloadForItem(withIdentifier: identifier, requestedRange: NSRange(location: NSNotFound, length: 0)) }
            default:
                _ = try await list(item.stored.entry.isDirectory ? identifier : item.parentItemIdentifier, refresh: true)
                try await manager.signalEnumerator(for: item.parentItemIdentifier)
                try await manager.signalEnumerator(for: .workingSet)
            }
        }
    }

    @MainActor private static func performFinderAction(_ action: String, urls: [URL]) async throws {
        try Task.checkCancellation()
        if action == "app.syncophant.copy-path" {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else if action == "app.syncophant.terminal" {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw CocoaError(.featureUnsupported)
            }
            try await NSWorkspace.shared.open(urls, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            for url in urls { try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) }
        }
    }

    /// Separate from materialization: fresh size checks bound both remote reads and temporary disk use.
    func thumbnailContents(_ identifier: NSFileProviderItemIdentifier, progress: Progress) async throws -> (URL, ProviderItem) {
        let known = try await item(identifier)
        let entry = try await store.stat(path: known.stored.entry.path)
        // shortcut: thumbnails download at most 32 MiB; larger media needs a range-backed asset reader.
        guard !entry.isDirectory, entry.size > 0, entry.size <= 32 * 1_048_576 else { throw CocoaError(.featureUnsupported) }
        let url = try temporaryURL()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: url) } }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        progress.totalUnitCount = entry.size
        var offset: Int64 = 0
        while offset < entry.size {
            try Task.checkCancellation()
            let count = Int(min(1_048_576, entry.size - offset))
            let data = try await store.read(path: entry.path, offset: offset, length: count)
            guard !data.isEmpty, data.count <= count else { throw CocoaError(.fileReadCorruptFile) }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress.completedUnitCount = offset
        }
        let latest = try await store.stat(path: entry.path)
        guard latest.version == entry.version, latest.size == entry.size else { throw NSFileProviderError(.versionNoLongerAvailable) }
        try Task.checkCancellation()
        try handle.close()
        succeeded = true
        return (url, ProviderItem(StoredItem(id: known.stored.id, entry: entry, isPinned: known.stored.isPinned), parent: known.parentItemIdentifier))
    }

    private func refresh(_ identifier: NSFileProviderItemIdentifier) async {
        do {
            let folder = try await item(identifier)
            guard folder.stored.entry.isDirectory else { return }
            let path = folder.stored.entry.path
            let before = try await metadata.items(parentPath: path)
            let after = try await metadata.refresh(store: store, path: path)
            try Task.checkCancellation()
            if before != after, let manager = NSFileProviderManager(for: domain) {
                try? await manager.signalEnumerator(for: identifier)
                try? await manager.signalEnumerator(for: .workingSet)
            }
        } catch { /* Leave cached metadata intact; the next access surfaces network errors. */ }
    }

    private func updateJournal(_ snapshot: MetadataStore.Snapshot) throws -> NSFileProviderSyncAnchor {
        // Actor reentrancy can deliver an older awaited snapshot after a newer callback finished.
        guard snapshot.revision >= snapshotRevision else { throw NSFileProviderError(.syncAnchorExpired) }
        let state = Dictionary(uniqueKeysWithValues: snapshot.items.map {
            ($0.id, ProviderJournal.Item(path: $0.entry.path, version: "\($0.entry.version)|\(context($0).tag($0))"))
        })
        var next = journal
        if next.update(state) { try JSONEncoder().encode(next).write(to: journalURL, options: .atomic) }
        journal = next
        snapshotRevision = snapshot.revision
        return .init(journal.anchor)
    }

    func anchor() async throws -> NSFileProviderSyncAnchor {
        try updateJournal(await metadata.snapshot())
    }

    func changes(from anchor: NSFileProviderSyncAnchor, in identifier: NSFileProviderItemIdentifier) async throws -> ([ProviderItem], [NSFileProviderItemIdentifier], NSFileProviderSyncAnchor) {
        if identifier != .workingSet {
            let folder = try await item(identifier)
            if folder.stored.entry.isDirectory { _ = try await metadata.refresh(store: store, path: folder.stored.entry.path) }
        }
        let snapshot = try await metadata.snapshot()
        // No awaits below: journal, returned items and anchor all describe this same read snapshot.
        let container: String?
        let current: [ProviderItem]
        if identifier == .workingSet {
            container = nil
            current = try snapshot.items.map { try makeItem($0, in: snapshot.items) }
        } else {
            if identifier == .rootContainer {
                container = "/"
                current = displayed(snapshot.items.filter { PathRules.parent(of: $0.entry.path) == "/" }, parent: identifier)
            } else {
                guard let folder = snapshot.items.first(where: { $0.id == identifier.rawValue }) else { throw NSFileProviderError(.noSuchItem) }
                if !folder.entry.isDirectory {
                    container = PathRules.parent(of: folder.entry.path)
                    current = [try makeItem(folder, in: snapshot.items)]
                } else {
                    container = folder.entry.path
                    current = displayed(snapshot.items.filter { PathRules.parent(of: $0.entry.path) == folder.entry.path }, parent: identifier)
                }
            }
        }
        let next = try updateJournal(snapshot)
        do {
            let changes = try journal.changes(since: anchor.rawValue, container: container)
            return (current.filter { changes.updated.contains($0.stored.id) }, changes.deleted.map { .init(rawValue: $0) }, next)
        } catch { throw NSFileProviderError(.syncAnchorExpired) }
    }

    func download(_ identifier: NSFileProviderItemIdentifier, range: NSRange?, alignment: Int = 1, version: NSFileProviderItemVersion?, strict: Bool, progress: Progress) async throws -> (URL, ProviderItem, NSRange) {
        let known = try await item(identifier)
        let entry = try await store.stat(path: known.stored.entry.path)
        if strict, let version, version.contentVersion != Data(entry.version.utf8) { throw NSFileProviderError(.versionNoLongerAvailable) }
        guard !entry.isDirectory, entry.size >= 0, entry.size <= Int64(Int.max) else { throw CocoaError(.fileReadInvalidFileName) }
        let size = Int(entry.size)
        let selected = try range.map { try DownloadRange.aligned($0, alignment: alignment, fileSize: size) }
            ?? NSRange(location: 0, length: size)
        let start = selected.location
        let requested = selected.length
        let url = try temporaryURL()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer { try? handle.close(); if !succeeded { try? FileManager.default.removeItem(at: url) } }
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: UInt64(start))
        progress.totalUnitCount = Int64(requested)
        var position = start
        while position < start + requested {
            try Task.checkCancellation()
            let count = min(1_048_576, start + requested - position)
            let data = try await store.read(path: entry.path, offset: Int64(position), length: count)
            guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try handle.write(contentsOf: data)
            position += data.count
            progress.completedUnitCount = Int64(position - start)
        }
        guard try await store.stat(path: entry.path).version == entry.version else { throw NSFileProviderError(.versionNoLongerAvailable) }
        succeeded = true
        let latest = providerItem(StoredItem(id: known.stored.id, entry: entry, isPinned: known.stored.isPinned, verifiedVersion: known.stored.verifiedVersion),
                                  parent: known.parentItemIdentifier, displayName: known.displayName)
        return (url, latest, NSRange(location: start, length: requested))
    }

    private func temporaryURL() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.serverUnreachable) }
        return try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
    }

    func create(template: NSFileProviderItem, contents: URL?, progress: Progress? = nil) async throws -> ProviderItem {
        let parent = try await item(template.parentItemIdentifier)
        let name = try safeName(template.filename)
        var path = join(parent.stored.entry.path, name)
        if template.contentType == .folder { try await store.createDirectory(path: path) }
        else {
            let file: URL
            if let contents { file = contents }
            else { file = try temporaryURL(); try Data().write(to: file) }
            defer { if contents == nil { try? FileManager.default.removeItem(at: file) } }
            path = try await transfers.upload(localURL: file, remotePath: path, progress: Self.report(progress)).remotePath
        }
        let children = try await list(template.parentItemIdentifier, refresh: true)
        guard let result = children.first(where: { $0.stored.entry.path == path }) else { throw NSFileProviderError(.noSuchItem) }
        return result
    }

    func modify(_ item: NSFileProviderItem, version: NSFileProviderItemVersion, fields: NSFileProviderItemFields, contents: URL?, progress: Progress? = nil) async throws -> ProviderItem {
        let current = try await self.item(item.itemIdentifier)
        var path = current.stored.entry.path
        let remote = try await store.stat(path: path)
        guard Data(remote.version.utf8) == version.contentVersion else { throw NSFileProviderError(.versionNoLongerAvailable) }
        if fields.contains(.filename) || fields.contains(.parentItemIdentifier) {
            guard store.publicationMode == .atomicMove, !current.stored.entry.isDirectory || store.supportsDirectoryMove else { throw CocoaError(.featureUnsupported) }
            let parent = try await self.item(item.parentItemIdentifier)
            let destination = join(parent.stored.entry.path, try safeName(item.filename))
            guard !destination.hasPrefix(path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
            if destination != path {
                try await metadata.move(store: store, id: current.stored.id, to: destination)
                path = destination
            }
        }
        if fields.contains(.contents), let contents {
            let receipt = try await transfers.upload(localURL: contents, remotePath: path, expectedVersion: remote.version, progress: Self.report(progress))
            if receipt.remotePath != path {
                // The upload is a separate conflict copy. Returning success would let Finder discard
                // the local edit as though it had replaced the original; report a stale base instead.
                _ = try? await metadata.refresh(store: store, path: PathRules.parent(of: path))
                throw NSFileProviderError(.versionNoLongerAvailable)
            }
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        _ = try await metadata.refresh(store: store, path: parentPath)
        return try await self.item(item.itemIdentifier)
    }

    func delete(_ identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion) async throws {
        let item = try await self.item(identifier)
        guard store.publicationMode == .atomicMove, !item.stored.entry.isDirectory || store.supportsDirectoryMove else { throw CocoaError(.featureUnsupported) }
        let remote = try await store.stat(path: item.stored.entry.path)
        guard Data(remote.version.utf8) == version.contentVersion else { throw NSFileProviderError(.versionNoLongerAvailable) }
        try await RemoteTrash(store: store, metadata: metadata).delete(item.stored, expectedVersion: remote.version)
        let parentPath = (remote.path as NSString).deletingLastPathComponent
        _ = try await metadata.refresh(store: store, path: parentPath)
    }

    /// Finder's per-item progress and the sidebar sync pie are driven by the Progress handed back to the system.
    private static func report(_ progress: Progress?) -> (@Sendable (UploadProgress) -> Void)? {
        guard let progress = UncheckedProgress(progress) else { return nil }
        return { update in
            guard case let .uploading(completed, total) = update, total > 0 else { return }
            progress.value.totalUnitCount = total
            progress.value.completedUnitCount = completed
        }
    }

    private func safeName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        return name
    }
    private func join(_ parent: String, _ child: String) -> String { parent == "/" ? "/" + child : parent + "/" + child }
}



/// NSProgress is thread-safe; the wrapper only tells the compiler so.
struct UncheckedProgress: @unchecked Sendable {
    let value: Progress
    init?(_ value: Progress?) { guard let value else { return nil }; self.value = value }
}
