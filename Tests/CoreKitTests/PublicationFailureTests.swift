import Foundation
import Testing
@testable import CoreKit

private struct PublicationFixture {
    let directory: URL
    let store: LocalRemoteStore
    let metadata: MetadataStore
    let observer: MetadataStore
    let source: URL
    let incoming = Data("incoming bytes".utf8)
    let original = Data("original".utf8)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PublicationFailure-" + UUID().uuidString)
        let remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        store = try LocalRemoteStore(root: remote)
        let database = directory.appendingPathComponent("metadata.sqlite")
        metadata = try MetadataStore(url: database)
        observer = try MetadataStore(url: database)
        source = directory.appendingPathComponent("source")
        try incoming.write(to: source)
    }

    func seed() async throws -> StoredItem {
        try await store.write(path: "/file", offset: 0, data: original)
        return try #require(await observer.refresh(store: store, path: "/").first)
    }

    func requireRefreshAvailable() async throws {
        try await store.write(path: "/probe", offset: 0, data: Data("probe".utf8))
        let refreshed = try await observer.refresh(store: store, path: "/")
        // Fail promptly instead of attempting a second upload behind a retained 120-second lease.
        _ = try #require(refreshed.first { $0.entry.path == "/probe" })
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// All bytes, hashes and renames are real; faults occur at the publication boundaries only.
private actor PublicationFaultStore: RemoteStore {
    enum Fault: Sendable {
        case preflightMutation
        case afterBackupMutation(rollbackFails: Bool)
        case verificationStat, verificationReplacement
        case lostAcknowledgement(cancelled: Bool)
        case backupRejected(notFound: Bool), newFileRejected, matchedUpdateRejected
    }

    let base: LocalRemoteStore
    let source: URL
    let fault: Fault
    private var fired = false
    private(set) var publicationCommitted = false
    private(set) var moves = 0

    init(_ base: LocalRemoteStore, source: URL, fault: Fault) {
        self.base = base; self.source = source; self.fault = fault
    }

    private func mutateSource() throws {
        let file = try FileHandle(forWritingTo: source)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("changed".utf8))
    }

    func waitForCommittedRename() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !publicationCommitted {
            guard ContinuousClock.now < deadline else { throw CoreKitError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func stat(path: String) async throws -> RemoteEntry {
        if publicationCommitted, !fired, case .matchedUpdateRejected = fault {
            fired = true
            throw CoreKitError.timeout
        }
        if path == "/file", !fired {
            if case .preflightMutation = fault { fired = true; try mutateSource() }
            if publicationCommitted, case .verificationStat = fault { fired = true; throw CoreKitError.timeout }
        }
        return try await base.stat(path: path)
    }
    func move(from: String, to: String) async throws {
        moves += 1
        if from == "/file", case .backupRejected(let notFound) = fault {
            if notFound { try await base.remove(path: from) }
            else { try await base.write(path: to, offset: 0, data: Data("occupied backup".utf8)) }
        }
        if to == "/file", from.hasPrefix("/.synco-upload.partial-") {
            switch fault {
            case .newFileRejected:
                try await base.write(path: to, offset: 0, data: Data("intervening writer".utf8))
                try mutateSource()
            case .matchedUpdateRejected:
                try await base.write(path: to, offset: 0, data: Data("intervening writer".utf8))
            default: break
            }
        }
        if case .afterBackupMutation(rollbackFails: true) = fault, fired, to == "/file" {
            throw CoreKitError.timeout
        }
        try await base.move(from: from, to: to)
        if from == "/file", case .afterBackupMutation = fault {
            fired = true
            try mutateSource()
        }
        if from.hasPrefix("/.synco-upload.partial-") {
            publicationCommitted = true
            switch fault {
            case .lostAcknowledgement(cancelled: false): throw CoreKitError.timeout
            case .lostAcknowledgement(cancelled: true): try await Task.sleep(for: .seconds(30))
            case .verificationReplacement where !fired:
                fired = true
                try await base.write(path: to, offset: 0, data: Data("other contents".utf8))
            default: break
            }
        }
    }
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
}

private final class PublicationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var verified = false
    func record(_ progress: UploadProgress) {
        lock.lock(); defer { lock.unlock() }
        if case .verified = progress { verified = true }
    }
    var hasVerifiedReceipt: Bool {
        lock.lock(); defer { lock.unlock() }
        return verified
    }
}

@Suite struct PublicationFailureTests {
    @Test(arguments: [true, false])
    func sourceMutationDuringFencedPreflightDoesNotBlockLaterWork(withMetadata: Bool) async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let original = try await f.seed()
        let store = PublicationFaultStore(f.store, source: f.source, fault: .preflightMutation)
        let engine = TransferEngine(store: store, metadata: withMetadata ? f.metadata : nil)
        let progress = PublicationProgress()
        await #expect(throws: CoreKitError.sourceChanged) {
            try await engine.upload(localURL: f.source, remotePath: "/file", expectedVersion: original.entry.version,
                                    progress: { progress.record($0) })
        }
        #expect(await store.moves == 0)
        #expect(!progress.hasVerifiedReceipt)
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == f.original)
        try await f.requireRefreshAvailable()
        let receipt = try await engine.upload(localURL: f.source, remotePath: "/next")
        #expect(receipt.verified)
        #expect(try await f.store.read(path: "/next", offset: 0, length: 100) == Data(contentsOf: f.source))
        #expect(try await f.observer.item(id: original.id)?.entry.path == "/file")
    }

    @Test(arguments: [true, false])
    func confirmedPublishVerificationFailureReleasesFenceWithoutReceipt(statFails: Bool) async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let original = try await f.seed()
        let store = PublicationFaultStore(f.store, source: f.source, fault: statFails ? .verificationStat : .verificationReplacement)
        let engine = TransferEngine(store: store, metadata: f.metadata)
        let progress = PublicationProgress()
        await #expect(throws: statFails ? CoreKitError.timeout : .itemChanged("/file")) {
            try await engine.upload(localURL: f.source, remotePath: "/file", expectedVersion: original.entry.version,
                                    progress: { progress.record($0) })
        }
        #expect(await store.publicationCommitted)
        #expect(!progress.hasVerifiedReceipt)
        let bytes = statFails ? f.incoming : Data("other contents".utf8)
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == bytes)
        try await f.requireRefreshAvailable()
        let receipt = try await engine.upload(localURL: f.source, remotePath: "/next")
        #expect(receipt.verified)
        #expect(try await f.observer.item(id: original.id)?.entry.path == "/file")
    }

    @Test(arguments: [true, false])
    func sourceMutationInBackupGapRequiresConfirmedRollback(rollbackFails: Bool) async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let original = try await f.seed()
        let store = PublicationFaultStore(f.store, source: f.source, fault: .afterBackupMutation(rollbackFails: rollbackFails))
        await #expect(throws: CoreKitError.sourceChanged) {
            try await TransferEngine(store: store, metadata: f.metadata)
                .upload(localURL: f.source, remotePath: "/file", expectedVersion: original.entry.version)
        }
        #expect(await store.moves == 2)
        #expect(await store.publicationCommitted == false)
        if rollbackFails {
            await #expect(throws: (any Error).self) { try await f.observer.reconcile([], parentPath: "/") }
            let backup = try #require(await f.store.list(path: "/").first)
            #expect(backup.path != "/file")
            #expect(try await f.store.read(path: backup.path, offset: 0, length: 100) == f.original)
            #expect(try await f.observer.item(id: original.id)?.entry.path == "/file")
        } else {
            #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == f.original)
            try await f.requireRefreshAvailable()
            #expect(try await f.store.list(path: "/").count == 2)
        }
    }

    @Test(arguments: [true, false])
    func rejectedFirstBackupRenameReleasesFence(notFound: Bool) async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let original = try await f.seed()
        let store = PublicationFaultStore(f.store, source: f.source, fault: .backupRejected(notFound: notFound))
        do {
            _ = try await TransferEngine(store: store, metadata: f.metadata)
                .upload(localURL: f.source, remotePath: "/file", expectedVersion: original.entry.version)
            Issue.record("A rejected backup rename unexpectedly succeeded")
        } catch {
            switch error {
            case CoreKitError.notFound(let path): #expect(notFound && path == "/file")
            case CoreKitError.alreadyExists: #expect(!notFound)
            default: Issue.record("Unexpected error: \(error)")
            }
        }
        try await f.requireRefreshAvailable()
        #expect(try Data(contentsOf: f.source) == f.incoming)
    }

    @Test func rejectedNewFileRenameThenSourceMutationReleasesFence() async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let store = PublicationFaultStore(f.store, source: f.source, fault: .newFileRejected)
        await #expect(throws: CoreKitError.sourceChanged) {
            try await TransferEngine(store: store, metadata: f.metadata).upload(localURL: f.source, remotePath: "/file")
        }
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == Data("intervening writer".utf8))
        try await f.requireRefreshAvailable()
    }

    @Test func occupiedOriginalAndConfirmedConflictPublishReleaseFenceAfterStatFailure() async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let original = try await f.seed()
        let store = PublicationFaultStore(f.store, source: f.source, fault: .matchedUpdateRejected)
        let progress = PublicationProgress()
        await #expect(throws: CoreKitError.timeout) {
            try await TransferEngine(store: store, metadata: f.metadata)
                .upload(localURL: f.source, remotePath: "/file", expectedVersion: original.entry.version,
                        progress: { progress.record($0) })
        }
        #expect(!progress.hasVerifiedReceipt)
        #expect(await store.moves == 4)
        let files = try await f.store.list(path: "/")
        var contents: Set<Data> = []
        for entry in files { contents.insert(try await f.store.read(path: entry.path, offset: 0, length: 100)) }
        #expect(contents == [f.original, f.incoming, Data("intervening writer".utf8)])
        try await f.requireRefreshAvailable()
        #expect(try await f.observer.item(id: original.id)?.entry.path == "/file")
    }

    @Test(arguments: [true, false], [true, false])
    func renameCommitWithLostAcknowledgementRetainsFence(cancelled: Bool, withMetadata: Bool) async throws {
        let f = try PublicationFixture(); defer { f.cleanup() }
        let original = try await f.seed()
        let store = PublicationFaultStore(f.store, source: f.source, fault: .lostAcknowledgement(cancelled: cancelled))
        let engine = TransferEngine(store: store, metadata: withMetadata ? f.metadata : nil)
        let progress = PublicationProgress()
        let task = Task {
            try await engine.upload(localURL: f.source, remotePath: "/file", expectedVersion: original.entry.version,
                                    progress: { progress.record($0) })
        }
        defer { task.cancel() }
        try await store.waitForCommittedRename()
        if cancelled {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: CoreKitError.timeout) { try await task.value }
        }
        #expect(!progress.hasVerifiedReceipt)
        #expect(try Data(contentsOf: f.source) == f.incoming)
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == f.incoming)
        let files = try await f.store.list(path: "/")
        let backup = try #require(files.first { $0.path != "/file" })
        #expect(files.count == 2)
        #expect(try await f.store.read(path: backup.path, offset: 0, length: 100) == f.original)
        if withMetadata {
            await #expect(throws: (any Error).self) { try await f.observer.reconcile([], parentPath: "/") }
            let cached = try #require(await f.observer.refresh(store: f.store, path: "/").first)
            #expect(cached.id == original.id && cached.entry.contentHash == original.entry.contentHash)
        } else {
            try await f.requireRefreshAvailable()
        }
    }
}
