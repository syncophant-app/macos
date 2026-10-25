import Foundation
import Testing
import CSQLite
@testable import CoreKit

@Suite struct RecoveryAndBudgetTests {
    @Test func verifiedEvidenceSurvivesReopenAndExpiresOnSameSizeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalRemoteStore(root: remote), url = root.appendingPathComponent("metadata.sqlite")
        let meta = try MetadataStore(url: url), source = root.appendingPathComponent("source")
        try Data("first".utf8).write(to: source)
        let receipt = try await TransferEngine(store: store, metadata: meta).upload(localURL: source, remotePath: "/file")
        let first = try #require(await meta.refresh(store: store, path: "/").first)
        #expect(first.isVerified && first.verifiedVersion == receipt.remoteVersion)
        let reopened = try MetadataStore(url: url)
        #expect(try await reopened.item(id: first.id)?.isVerified == true)
        let revision = try await reopened.snapshot().revision
        _ = try await reopened.refresh(store: store, path: "/")
        #expect(try await reopened.snapshot().revision == revision)
        try await store.write(path: "/file", offset: 0, data: Data("other".utf8))
        let changed = try #require(await reopened.refresh(store: store, path: "/").first)
        #expect(changed.id == first.id && !changed.isVerified)
    }

    @Test func explicitRecoveryPreservesRenamedSubtreeAndRejectsStaleAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalRemoteStore(root: remote), url = root.appendingPathComponent("metadata.sqlite")
        let metadata = try MetadataStore(url: url)
        try await store.createDirectory(path: "/folder")
        try await store.write(path: "/folder/data", offset: 0, data: Data("original".utf8))
        let folder = try #require(await metadata.refresh(store: store, path: "/").first)
        let child = try #require(await metadata.refresh(store: store, path: "/folder").first)
        try await metadata.setPinned(id: child.id, true)
        try await store.move(from: "/folder", to: "/renamed")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        // Simulate a terminated owner after the remote commit and before the metadata commit.
        #expect(sqlite3_exec(db, "UPDATE metadata_state SET mutation='interrupted',lease_until=0,source='/folder',destination='/renamed'", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: (any Error).self) { _ = try await metadata.refresh(store: store, path: "/") }
        await #expect(throws: (any Error).self) { try await metadata.recoverMutation(token: "stale", outcome: .acceptMovedPaths) }
        try await metadata.recoverMutation(token: "interrupted", outcome: .acceptMovedPaths)
        #expect(try await metadata.item(id: folder.id)?.entry.path == "/renamed")
        #expect(try await metadata.item(id: child.id)?.entry.path == "/renamed/data")
        #expect(try await metadata.item(id: child.id)?.isPinned == true)
        #expect(try await metadata.interruptedMutation() == nil)
        #expect(try await store.read(path: "/renamed/data", offset: 0, length: 32) == Data("original".utf8))
    }

    @Test func sixSharedSlotsReleaseAndWaitingReservationCanBeCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var leases: [SSHConnectionLease] = try (0..<6).map { _ in try SSHConnectionLease(directory: directory, host: "u123.your-storagebox.de") }
        let waiting = Task.detached { try SSHConnectionLease(directory: directory, host: "u123-sub1.your-storagebox.de") }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        leases.removeLast()
        let replacement = try SSHConnectionLease(directory: directory, host: "u123-sub2.your-storagebox.de")
        withExtendedLifetime(replacement) { #expect(leases.count == 5) }
    }
}
