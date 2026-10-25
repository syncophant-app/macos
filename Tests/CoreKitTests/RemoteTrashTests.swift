import Foundation
import Testing
@testable import CoreKit

@Suite struct RemoteTrashTests {
    @Test func restoresOriginalFolderAndRefusesToReplaceNewFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalRemoteStore(root: root)
        let meta = try MetadataStore(url: root.appendingPathComponent("metadata.sqlite"))
        try await store.createDirectory(path: "/Documents")
        try await store.write(path: "/Documents/report.txt", offset: 0, data: Data("original".utf8))
        let item = try #require(await meta.refresh(store: store, path: "/Documents").first)
        let trash = RemoteTrash(store: store, metadata: meta)
        try await trash.delete(item, expectedVersion: item.entry.version)
        #expect(try await meta.items(parentPath: "/Documents").isEmpty)
        #expect(try await store.list(path: "/").allSatisfy { $0.name != ".syncophant-trash" })
        let deleted = try #require(await trash.items().first)
        #expect(deleted.originalPath == "/Documents/report.txt")
        try await store.write(path: "/Documents/report.txt", offset: 0, data: Data("new".utf8))
        await #expect(throws: CoreKitError.alreadyExists("/Documents/report.txt")) { try await trash.restore(deleted) }
        #expect(try await meta.interruptedMutation() == nil)
        #expect(try await store.read(path: deleted.storedPath, offset: 0, length: 32) == Data("original".utf8))
        #expect(try await store.read(path: "/Documents/report.txt", offset: 0, length: 32) == Data("new".utf8))
        try await store.remove(path: "/Documents/report.txt")
        try await trash.restore(deleted)
        #expect(try await store.read(path: "/Documents/report.txt", offset: 0, length: 32) == Data("original".utf8))
        #expect(try await trash.items().isEmpty)
    }

    @Test func retentionExpiresOnlyRecordedTrashAndKeepsLegacyItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalRemoteStore(root: root)
        let meta = try MetadataStore(url: root.appendingPathComponent("metadata.sqlite"))
        try await store.createDirectory(path: "/Folder")
        try await store.write(path: "/Folder/data", offset: 0, data: Data("kept".utf8))
        let item = try #require(await meta.refresh(store: store, path: "/").first { $0.entry.path == "/Folder" })
        let trash = RemoteTrash(store: store, metadata: meta)
        try await trash.delete(item, expectedVersion: item.entry.version)
        let legacy = "/.syncophant-trash/\(UUID().uuidString)-legacy"
        try await store.write(path: legacy, offset: 0, data: Data("old".utf8))
        #expect(try await trash.purgeExpired() == 0)
        #expect(try await trash.purgeExpired(now: Date().addingTimeInterval(31 * 86_400)) == 1)
        #expect(try await store.read(path: legacy, offset: 0, length: 32) == Data("old".utf8))
        #expect(try await trash.items().count == 1)
    }
}
