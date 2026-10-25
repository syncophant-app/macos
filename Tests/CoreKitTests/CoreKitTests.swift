import Foundation
import Testing
@testable import CoreKit

private struct Fixture {
    let directory: URL
    let remote: URL
    let store: LocalRemoteStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoreKitTests-" + UUID().uuidString)
        remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        store = try LocalRemoteStore(root: remote)
    }
    func source(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct CorruptChecksumStore: RemoteStore {
    let base: LocalRemoteStore
    var corruptChecksum = true
    var replaceAfterPublish = false
    var fixedTimestamp: Date?
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry {
        var entry = try await base.stat(path: path)
        if let fixedTimestamp { entry.modifiedAt = fixedTimestamp }
        return entry
    }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws {
        try await base.move(from: from, to: to)
        if replaceAfterPublish, to == "/replaced" {
            try await base.write(path: to, offset: 0, data: Data("other".utf8))
        }
    }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String {
        if corruptChecksum { return String(repeating: "0", count: 64) }
        return try await base.checksum(path: path)
    }
}

private actor CancellationStore: RemoteStore {
    let base: LocalRemoteStore
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    init(_ base: LocalRemoteStore) { self.base = base }
    func waitForWrite() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry { try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws {
        try await base.write(path: path, offset: offset, data: data)
        if !data.isEmpty {
            started = true; waiter?.resume(); waiter = nil
            try await Task.sleep(for: .seconds(30))
        }
    }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UploadProgress] = []
    func append(_ value: UploadProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [UploadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite struct CoreKitTests {
    @Test func rangesAndNoClobberMoves() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.store.write(path: "/file", offset: 0, data: Data("abcdef".utf8))
        #expect(try await f.store.read(path: "/file", offset: 2, length: 3) == Data("cde".utf8))
        #expect(try await f.store.read(path: "/file", offset: 5, length: 50) == Data("f".utf8))
        #expect(try await f.store.read(path: "/file", offset: 99, length: 0).isEmpty)
        #expect(try await f.store.read(path: "/file", offset: 99, length: 4).isEmpty)
        await #expect(throws: CoreKitError.invalidRange) { try await f.store.read(path: "/file", offset: -1, length: 4) }
        await #expect(throws: CoreKitError.invalidRange) { try await f.store.read(path: "/file", offset: 0, length: PathRules.maximumReadLength + 1) }
        try await f.store.write(path: "/other", offset: 0, data: Data("keep".utf8))
        await #expect(throws: CoreKitError.alreadyExists("/other")) { try await f.store.move(from: "/file", to: "/other") }
        #expect(try await f.store.read(path: "/other", offset: 0, length: 99) == Data("keep".utf8))
        try await f.store.write(path: "/file", offset: 2, data: Data("XY".utf8))
        #expect(try await f.store.read(path: "/file", offset: 0, length: 99) == Data("abXYef".utf8))
    }

    @Test func pathConfinementRejectsTraversalAndSymlinks() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let outside = f.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret")
        try Data("private".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: f.remote.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: f.remote.appendingPathComponent("leaf"), withDestinationURL: secret)
        for path in ["/../outside/secret", "/link/secret", "/leaf", "/link/../secret"] {
            await #expect(throws: (any Error).self) { try await f.store.read(path: path, offset: 0, length: 100) }
            await #expect(throws: (any Error).self) { try await f.store.write(path: path, offset: 0, data: Data("bad".utf8)) }
        }
        await #expect(throws: (any Error).self) { try await f.store.createDirectory(path: "/link/new") }
        try await f.store.write(path: "/safe", offset: 0, data: Data("safe".utf8))
        await #expect(throws: (any Error).self) { try await f.store.move(from: "/safe", to: "/link/new") }
        #expect(try Data(contentsOf: secret) == Data("private".utf8))
        #expect(try await f.store.list(path: "/").map(\.name) == ["safe"])
    }

    @Test func filtersAndCaseCollisionNames() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        for name in [".DS_Store", ".syncophant-trash", "._file", "~$office.docx", ".~lock.file#", "photo.idlk", "x.partial-123", "x.crdownload", "x.part", "x.tmp", "readme"] {
            try await f.store.write(path: "/" + name, offset: 0, data: Data())
        }
        let list = try await f.store.list(path: "/")
        #expect(Set(list.map(\.name)) == ["readme"])
        #expect(!PathRules.isVisible(path: "/.syncophant-trash/deleted.txt"))
        let collision = RemoteEntry(name: "README", path: "/README", isDirectory: false, size: 0, modifiedAt: Date(timeIntervalSince1970: 1))
        let names = PathRules.displayNames(for: list + [collision])
        #expect(Set(names.values).count == 2)
        #expect(names.values.allSatisfy { $0.contains("case conflict") })
        await #expect(throws: CoreKitError.filteredFile("/.DS_Store")) {
            try await TransferEngine(store: f.store).upload(localURL: f.source(Data()), remotePath: "/.DS_Store")
        }
        #expect(PathRules.shellQuote("/a'b;$(touch nope)") == "'/a'\\''b;$(touch nope)'")
    }

    @Test func hashMismatchNeverPublishesOrReplaces() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.store.write(path: "/document", offset: 0, data: Data("original".utf8))
        let source = try f.source(Data("new content".utf8))
        let engine = TransferEngine(store: CorruptChecksumStore(base: f.store))
        await #expect(throws: CoreKitError.checksumMismatch) { try await engine.upload(localURL: source, remotePath: "/document") }
        #expect(try await f.store.read(path: "/document", offset: 0, length: 99) == Data("original".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["document"])
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func chunkedAndEmptyUploadsAreVerified() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let data = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        let engine = TransferEngine(store: f.store)
        let receipt = try await engine.upload(localURL: f.source(data), remotePath: "/large")
        #expect(receipt.verified)
        #expect(receipt.checksum == (try await f.store.checksum(path: "/large")))
        #expect(try await f.store.read(path: "/large", offset: 0, length: data.count) == data)
        let empty = try await engine.upload(localURL: f.source(Data()), remotePath: "/empty")
        #expect(empty.verified)
        #expect(empty.checksum == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func staleVersionAndMatchedUpdatePreserveBothCopies() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let engine = TransferEngine(store: f.store)
        try await f.store.write(path: "/document.txt", offset: 0, data: Data("original".utf8))
        let old = try await f.store.stat(path: "/document.txt")
        let conflict = try await engine.upload(localURL: f.source(Data("conflicting".utf8)), remotePath: "/document.txt", expectedVersion: "stale")
        #expect(conflict.remotePath != "/document.txt")
        #expect(try await f.store.read(path: "/document.txt", offset: 0, length: 99) == Data("original".utf8))
        #expect(try await f.store.read(path: conflict.remotePath, offset: 0, length: 99) == Data("conflicting".utf8))
        let update = try await engine.upload(localURL: f.source(Data("updated".utf8)), remotePath: "/document.txt", expectedVersion: old.version)
        #expect(update.remotePath == "/document.txt")
        let entries = try await f.store.list(path: "/")
        #expect(entries.count == 3)
        var contents = Set<Data>()
        for entry in entries { contents.insert(try await f.store.read(path: entry.path, offset: 0, length: 99)) }
        #expect(contents == [Data("original".utf8), Data("conflicting".utf8), Data("updated".utf8)])
    }

    @Test func concurrentPublishKeepsEveryUpload() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = TransferEngine(store: f.store), b = TransferEngine(store: f.store)
        let first = try f.source(Data("first".utf8)), second = try f.source(Data("second".utf8))
        async let one = a.upload(localURL: first, remotePath: "/same")
        async let two = b.upload(localURL: second, remotePath: "/same")
        let receipts = try await [one, two]
        #expect(Set(receipts.map(\.remotePath)).count == 2)
        var contents = Set<Data>()
        for receipt in receipts { contents.insert(try await f.store.read(path: receipt.remotePath, offset: 0, length: 99)) }
        #expect(contents == [Data("first".utf8), Data("second".utf8)])
    }

    @Test func cancellationCleansPartialAndKeepsSourceAndDestination() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.store.write(path: "/file", offset: 0, data: Data("original".utf8))
        let source = try f.source(Data(repeating: 3, count: 2 * 1024 * 1024))
        let store = CancellationStore(f.store), engine = TransferEngine(store: store)
        let task = Task { try await engine.upload(localURL: source, remotePath: "/file") }
        await store.waitForWrite()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["file"])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await f.store.read(path: "/file", offset: 0, length: 99) == Data("original".utf8))
    }

    @Test func metadataStableIDsSubtreeMovePinsSearchAndPersistence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let url = f.directory.appendingPathComponent("metadata.sqlite")
        let db = try MetadataStore(url: url)
        let date = Date(timeIntervalSince1970: 1700000000)
        let folder = RemoteEntry(name: "folder", path: "/folder", isDirectory: true, size: 0, modifiedAt: date)
        let file = RemoteEntry(name: "report.txt", path: "/folder/report.txt", isDirectory: false, size: 7, modifiedAt: date)
        let root = try await db.reconcile([folder], parentPath: "/")
        let children = try await db.reconcile([file], parentPath: "/folder")
        let folderID = try #require(root.first?.id), fileID = try #require(children.first?.id)
        try await db.setPinned(id: fileID, true)
        #expect(try await db.reconcile([folder], parentPath: "/").first?.id == folderID)
        try await db.move(id: folderID, to: "/renamed")
        #expect(try await db.item(id: fileID)?.entry.path == "/renamed/report.txt")
        #expect(try await db.item(id: fileID)?.isPinned == true)
        #expect(try await db.items(parentPath: "/renamed").first?.id == fileID)
        #expect(try await db.search("repo").first?.id == fileID)
        let reopened = try MetadataStore(url: url)
        #expect(try await reopened.item(id: folderID)?.entry.path == "/renamed")
        #expect(try await reopened.item(id: fileID)?.id == fileID)
        _ = try await db.reconcile([], parentPath: "/")
        #expect(try await db.item(id: fileID) == nil)
        #expect(try await db.search("report").isEmpty)
    }

    @Test func metadataRejectsInvalidListingsAndMoveCollisionsAtomically() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let db = try MetadataStore(url: f.directory.appendingPathComponent("metadata.sqlite"))
        func entry(_ path: String) -> RemoteEntry { RemoteEntry(name: PathRules.name(of: path), path: path, isDirectory: false, size: 1, modifiedAt: Date(timeIntervalSince1970: 1)) }
        let rows = try await db.reconcile([entry("/a"), entry("/b"), entry("/.DS_Store")], parentPath: "/")
        #expect(rows.count == 2)
        let a = try #require(rows.first { $0.entry.path == "/a" })
        await #expect(throws: CoreKitError.alreadyExists("/b")) { try await db.move(id: a.id, to: "/b") }
        await #expect(throws: (any Error).self) { try await db.reconcile([entry("/a"), entry("/wrong/child")], parentPath: "/") }
        #expect(try await db.items(parentPath: "/").count == 2)
        #expect(try await db.item(id: a.id)?.entry.path == "/a")
        #expect(try await db.search("\" OR *").isEmpty)
    }

    @Test func metadataListsRecentFilesNewestFirst() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let db = try MetadataStore(url: f.directory.appendingPathComponent("metadata.sqlite"))
        func entry(_ path: String, _ t: TimeInterval, dir: Bool = false) -> RemoteEntry {
            RemoteEntry(name: PathRules.name(of: path), path: path, isDirectory: dir, size: 1, modifiedAt: Date(timeIntervalSince1970: t))
        }
        _ = try await db.reconcile([entry("/old", 100), entry("/new", 300), entry("/mid", 200), entry("/dir", 400, dir: true)], parentPath: "/")
        #expect(try await db.recent(since: Date(timeIntervalSince1970: 150)).map(\.entry.path) == ["/new", "/mid"])
        #expect(try await db.recent(since: Date(timeIntervalSince1970: 0), limit: 1).map(\.entry.path) == ["/new"])
    }

    @Test func missingPinFailsBeforeNetworking() async throws {
        let connection = StorageConnection(name: "Untrusted", host: "invalid.invalid", username: "user")
        let store = SFTPStore(connection: connection, password: "never-sent", privateKey: nil)
        await #expect(throws: CoreKitError.hostKeyRequired) { try await store.list(path: "/") }
    }

    @Test func progressReportsAcknowledgedBytesThenVerificationAndPublication() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let data = Data(repeating: 9, count: 1024 * 1024 + 5)
        let log = ProgressLog()
        let receipt = try await TransferEngine(store: f.store).upload(localURL: f.source(data), remotePath: "/progress", progress: { log.append($0) })
        let expected: [UploadProgress] = [
            .uploading(completed: 0, total: Int64(data.count)),
            .uploading(completed: 1024 * 1024, total: Int64(data.count)),
            .uploading(completed: Int64(data.count), total: Int64(data.count)),
            .verifying, .verified(receipt)
        ]
        #expect(log.snapshot() == expected)
        let failed = ProgressLog()
        await #expect(throws: CoreKitError.checksumMismatch) {
            try await TransferEngine(store: CorruptChecksumStore(base: f.store)).upload(localURL: f.source(Data("bad".utf8)), remotePath: "/failed", progress: { failed.append($0) })
        }
        #expect(failed.snapshot().last == .verifying)
        #expect(!failed.snapshot().contains { if case .verified = $0 { true } else { false } })
    }

    @Test func maximumLengthNamesCanUploadAndConflict() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = "/" + String(repeating: "a", count: 255)
        let engine = TransferEngine(store: f.store)
        _ = try await engine.upload(localURL: f.source(Data("first".utf8)), remotePath: path)
        let conflict = try await engine.upload(localURL: f.source(Data("second".utf8)), remotePath: path)
        #expect(PathRules.name(of: conflict.remotePath).utf8.count <= 255)
        #expect(try await f.store.list(path: "/").count == 2)
    }

    @Test func receiptVersionCannotVerifySameSizeSameMtimeReplacement() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        // Coarse mtime does not hide a replacement from the filesystem's high-resolution revision.
        let store = CorruptChecksumStore(base: f.store, corruptChecksum: false, fixedTimestamp: Date(timeIntervalSince1970: 1700000000))
        let receipt = try await TransferEngine(store: store).upload(localURL: f.source(Data("first".utf8)), remotePath: "/file")
        let original = try await store.stat(path: "/file")
        #expect(try await store.checksum(path: "/file") == receipt.checksum)
        #expect(original.version == receipt.remoteVersion)
        try await f.store.write(path: "/file", offset: 0, data: Data("other".utf8))
        let replacement = try await store.stat(path: "/file")
        #expect(original.size == replacement.size)
        #expect(original.modifiedAt == replacement.modifiedAt)
        #expect(original.remoteRevision != replacement.remoteRevision)
        #expect(original.version != replacement.version)
        #expect(receipt.remoteVersion != replacement.version)
        let listing = try #require(try await f.store.list(path: "/").first)
        #expect(listing.contentHash == nil)
        #expect(listing.version != receipt.remoteVersion)
    }

    @Test func replacementDuringPublishNeverProducesVerifiedReceiptOrProgress() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = CorruptChecksumStore(base: f.store, corruptChecksum: false, replaceAfterPublish: true)
        let log = ProgressLog()
        await #expect(throws: CoreKitError.itemChanged("/replaced")) {
            try await TransferEngine(store: store).upload(localURL: f.source(Data("first".utf8)), remotePath: "/replaced", progress: { log.append($0) })
        }
        #expect(log.snapshot().last == .verifying)
        #expect(try await f.store.read(path: "/replaced", offset: 0, length: 99) == Data("other".utf8))
    }
}
