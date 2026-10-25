#if !PROVIDER_RUNTIME_CHECK
import Foundation
import Testing
import CSQLite
@testable import CoreKit

/// Suspends after the remote operation actually ran, exposing the network/metadata gap.
private actor SuspendedRemoteStore: RemoteStore {
    enum Operation { case list, move }
    let base: LocalRemoteStore
    let operation: Operation
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ base: LocalRemoteStore, operation: Operation) { self.base = base; self.operation = operation }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
    private func pause() async {
        paused = true
        await withCheckedContinuation {
            continuation = $0
            waiter?.resume(); waiter = nil
        }
    }
    func list(path: String) async throws -> [RemoteEntry] {
        let entries = try await base.list(path: path)
        if operation == .list { await pause() }
        return entries
    }
    func move(from: String, to: String) async throws {
        try await base.move(from: from, to: to)
        if operation == .move { await pause() }
    }
    func stat(path: String) async throws -> RemoteEntry { try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
}

private actor PublicationGate {
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func pause() async {
        paused = true
        await withCheckedContinuation {
            continuation = $0
            waiter?.resume(); waiter = nil
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private struct MetadataFixture {
    let directory: URL
    let url: URL
    let store: LocalRemoteStore
    let provider: MetadataStore
    let app: MetadataStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataConcurrency-" + UUID().uuidString)
        let remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        store = try LocalRemoteStore(root: remote)
        url = directory.appendingPathComponent("metadata.sqlite")
        provider = try MetadataStore(url: url)
        app = try MetadataStore(url: url)
    }
    func seed() async throws -> (folder: StoredItem, child: StoredItem) {
        try await store.createDirectory(path: "/folder")
        try await store.write(path: "/folder/file", offset: 0, data: Data("keep".utf8))
        let folder = try #require(await provider.refresh(store: store, path: "/").first)
        let child = try #require(await provider.refresh(store: store, path: "/folder").first)
        return (folder, child)
    }
    func expireLease() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE metadata_state SET lease_until=0 WHERE singleton=1", nil, nil, nil) == SQLITE_OK)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct MetadataConcurrencyTests {
    @Test func concurrentPublicationsWaitForTheExistingOwner() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let gate = PublicationGate()
        let first = Task { try await fixture.provider.withPublication { await gate.pause(); return 1 } }
        await gate.waitUntilPaused()
        let second = Task { try await fixture.app.withPublication { 2 } }
        try await Task.sleep(for: .milliseconds(30))
        await gate.resume()
        let firstValue = try await first.value
        let secondValue = try await second.value
        #expect(firstValue == 1 && secondValue == 2)
        _ = try await fixture.app.refresh(store: fixture.store, path: "/")
    }
    @Test func crossConnectionRenameRejectsOverlappingAndPreMutationListings() async throws {
        let f = try MetadataFixture(); defer { f.cleanup() }
        let (folder, child) = try await f.seed()
        let staleList = SuspendedRemoteStore(f.store, operation: .list)
        let refresh = Task { try await f.app.refresh(store: staleList, path: "/") }
        await staleList.waitUntilPaused()
        let remoteMove = SuspendedRemoteStore(f.store, operation: .move)
        let move = Task { try await f.provider.move(store: remoteMove, id: folder.id, to: "/renamed") }
        await remoteMove.waitUntilPaused()
        // The app sees a completed remote rename through its own SQLite connection.
        #expect(try await f.store.list(path: "/").map(\.path) == ["/renamed"])
        #expect(try await f.app.refresh(store: f.store, path: "/").map(\.id) == [folder.id])
        await #expect(throws: (any Error).self) { try await f.app.reconcile([], parentPath: "/") }
        // Independent writes remain available: no SQLite write transaction spans the suspended move.
        try await f.app.setPinned(id: child.id, true)
        await remoteMove.resume()
        try await move.value
        await staleList.resume()
        #expect(try await refresh.value.first?.entry.path == "/renamed")
        #expect(try await f.app.item(id: child.id)?.entry.path == "/renamed/file")
        #expect(try await f.app.item(id: child.id)?.isPinned == true)
        #expect(try await f.app.refresh(store: f.store, path: "/").first?.id == folder.id)
    }

    @Test func expiredDurableLeaseFailsClosedAndOwnerCanFinish() async throws {
        let f = try MetadataFixture(); defer { f.cleanup() }
        let (folder, child) = try await f.seed()
        let remoteMove = SuspendedRemoteStore(f.store, operation: .move)
        let move = Task { try await f.provider.move(store: remoteMove, id: folder.id, to: "/renamed") }
        await remoteMove.waitUntilPaused()
        try f.expireLease()
        // Reopening models a new process after a crash; expiry must not authorize reconciliation.
        let reopened = try MetadataStore(url: f.url)
        await #expect(throws: (any Error).self) { try await reopened.refresh(store: f.store, path: "/") }
        await #expect(throws: (any Error).self) { try await reopened.reconcile([], parentPath: "/") }
        #expect(try await reopened.item(id: child.id)?.entry.path == "/folder/file")
        await remoteMove.resume()
        try await move.value
        #expect(try await reopened.refresh(store: f.store, path: "/").first?.id == folder.id)
        #expect(try await reopened.item(id: child.id)?.entry.path == "/renamed/file")
    }

    @Test func publicationGapPreservesRequestedPathIdentityAcrossConnections() async throws {
        let f = try MetadataFixture(); defer { f.cleanup() }
        let (_, child) = try await f.seed()
        try await f.app.setPinned(id: child.id, true)
        try await f.store.write(path: "/.synco-upload.partial-test", offset: 0, data: Data("updated".utf8))
        let gate = PublicationGate()
        let publication = Task {
            try await f.provider.withPublication {
                try await f.store.move(from: "/folder/file", to: "/folder/backup")
                await gate.pause()
                try await f.store.move(from: "/.synco-upload.partial-test", to: "/folder/file")
            }
        }
        await gate.waitUntilPaused()
        // The remote original is absent; the independent app connection must retain its UUID/pin.
        #expect(try await f.store.list(path: "/folder").map(\.path) == ["/folder/backup"])
        let during = try await f.app.refresh(store: f.store, path: "/folder")
        #expect(during.first?.id == child.id)
        #expect(during.first?.entry.path == "/folder/file")
        #expect(during.first?.isPinned == true)
        await #expect(throws: (any Error).self) { try await f.app.reconcile([], parentPath: "/folder") }
        await gate.resume()
        try await publication.value
        let after = try await f.app.refresh(store: f.store, path: "/folder")
        #expect(after.first { $0.entry.path == "/folder/file" }?.id == child.id)
        #expect(after.first { $0.entry.path == "/folder/file" }?.isPinned == true)
        let backup = try #require(after.first { $0.entry.path == "/folder/backup" })
        #expect(backup.id != child.id)
        #expect(backup.isPinned == false)
        #expect(try await f.store.read(path: "/folder/file", offset: 0, length: 100) == Data("updated".utf8))
        #expect(try await f.store.read(path: "/folder/backup", offset: 0, length: 100) == Data("keep".utf8))
    }

    @Test func refreshUsesStrongVersionsForSameSizeSameTimestampExternalChanges() async throws {
        let f = try MetadataFixture(); defer { f.cleanup() }
        let (_, child) = try await f.seed()
        let file = f.directory.appendingPathComponent("remote/folder/file")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let before = try #require(await f.app.refresh(store: f.store, path: "/folder").first)
        #expect(before.entry.remoteRevision != nil)
        try Data("edit".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: before.entry.modifiedAt], ofItemAtPath: file.path)
        let after = try #require(await f.app.refresh(store: f.store, path: "/folder").first)
        #expect(after.id == child.id)
        #expect(after.entry.size == before.entry.size)
        #expect(after.entry.modifiedAt == before.entry.modifiedAt)
        #expect(after.entry.remoteRevision != before.entry.remoteRevision)
        #expect(after.entry.version != before.entry.version)
    }

    @Test func snapshotsNeverSplitTransactionalSubtreeMoves() async throws {
        let f = try MetadataFixture(); defer { f.cleanup() }
        let (folder, child) = try await f.seed()
        let writer = Task {
            for i in 0..<100 { try await f.provider.move(id: folder.id, to: i.isMultiple(of: 2) ? "/renamed" : "/folder") }
        }
        var last: Int64 = -1
        for _ in 0..<100 {
            let snapshot = try await f.app.snapshot()
            let parent = try #require(snapshot.items.first { $0.id == folder.id })
            let file = try #require(snapshot.items.first { $0.id == child.id })
            #expect(file.entry.path == parent.entry.path + "/file")
            #expect(snapshot.revision >= last)
            last = snapshot.revision
        }
        try await writer.value
        _ = try await f.provider.reconcile([], parentPath: "/")
        let empty = try await f.app.snapshot()
        #expect(empty.items.isEmpty)
        #expect(empty.revision > last)
    }
}

#else
import Foundation
import FileProvider
import CoreKit

/// The remote changes after File Provider's preflight and before TransferEngine publishes.
private actor ConflictingUploadStore: RemoteStore {
    let base: LocalRemoteStore
    private var changed = false
    private(set) var lists = 0
    init(_ base: LocalRemoteStore) { self.base = base }
    func list(path: String) async throws -> [RemoteEntry] { lists += 1; return try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry { try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String {
        if !changed {
            changed = true
            try await base.write(path: "/document", offset: 0, data: Data("external".utf8))
        }
        return try await base.checksum(path: path)
    }
}

@main struct ProviderRuntimeCheck {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderConflict-" + UUID().uuidString)
        let remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try LocalRemoteStore(root: remote)
        try await base.write(path: "/document", offset: 0, data: Data("original".utf8))
        let metadata = try MetadataStore(url: directory.appendingPathComponent("metadata.sqlite"))
        let stored = try await metadata.refresh(store: base, path: "/")[0]
        let entry = try await base.stat(path: "/document")
        let original = ProviderItem(StoredItem(id: stored.id, entry: entry), parent: .rootContainer)
        let connection = StorageConnection(name: "Local check", host: "unused.invalid", username: "unused")
        let domain = NSFileProviderDomain(identifier: .init(rawValue: connection.id.uuidString), displayName: connection.name)
        let store = ConflictingUploadStore(base)
        let runtime = try ProviderRuntime(domain: domain, connection: connection, store: store, metadata: metadata,
                                          journalURL: directory.appendingPathComponent("journal.json"))
        let beforeConflict = try await runtime.anchor()
        let source = directory.appendingPathComponent("source")
        let incoming = Data("incoming".utf8)
        try incoming.write(to: source)
        do {
            _ = try await runtime.modify(original, version: original.itemVersion, fields: .contents, contents: source)
            preconditionFailure("Conflict copy was acknowledged as replacing the original")
        } catch {
            let error = error as NSError
            precondition(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.versionNoLongerAvailable.rawValue)
        }
        let local = try Data(contentsOf: source)
        precondition(local == incoming)
        let files = try await base.list(path: "/")
        precondition(files.count == 2)
        var contents = Set<Data>()
        for file in files { contents.insert(try await base.read(path: file.path, offset: 0, length: 100)) }
        precondition(contents == [incoming, Data("external".utf8)])
        let (updated, deleted, next) = try await runtime.changes(from: beforeConflict, in: .rootContainer)
        precondition(updated.count == 2 && deleted.isEmpty)
        precondition(updated.contains { $0.stored.id == stored.id && $0.stored.entry.path == "/document" })
        for item in updated {
            let strong = try await base.stat(path: item.stored.entry.path)
            precondition(item.itemVersion.contentVersion == Data(strong.version.utf8))
        }
        let (again, removed, unchanged) = try await runtime.changes(from: next, in: .rootContainer)
        precondition(again.isEmpty && removed.isEmpty && unchanged == next)
        print("Provider runtime check passed: conflict rejects acknowledgement, retains local + both remote files, and emits strong versions with a coherent anchor.")
        try await metadata.setPinned(id: stored.id, true)
        let (pinned, _, pinnedAnchor) = try await runtime.changes(from: next, in: .workingSet)
        precondition(pinned.contains { $0.stored.id == stored.id && $0.contentPolicy == .downloadEagerlyAndKeepDownloaded })
        try await metadata.setPinned(id: stored.id, false)
        let (unpinned, _, _) = try await runtime.changes(from: pinnedAnchor, in: .init(rawValue: stored.id))
        precondition(unpinned.count == 1 && unpinned[0].stored.id == stored.id && unpinned[0].contentPolicy == .inherited)
        print("Provider pin check passed: pin-only metadata updates reach working-set and single-file observers.")
        let first = ProviderEnumerator(runtime: runtime, identifier: .rootContainer)
        let second = ProviderEnumerator(runtime: runtime, identifier: .rootContainer)
        let beforePoll = await store.lists
        first.invalidate()
        try await Task.sleep(for: .seconds(22))
        let afterFirstInvalidation = await store.lists
        precondition(afterFirstInvalidation > beforePoll, "Invalidating one enumerator stopped another subscriber's poll")
        second.invalidate()
        try await Task.sleep(for: .seconds(22))
        let afterLastInvalidation = await store.lists
        precondition(afterLastInvalidation == afterFirstInvalidation, "Poll continued after its final subscriber invalidated")
        await runtime.stop()
        print("Provider lifecycle check passed: one invalidated enumerator preserves the other subscriber; the final invalidation stops polling.")
    }
}

#endif
