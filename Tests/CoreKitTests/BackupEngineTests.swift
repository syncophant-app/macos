import Foundation
import Testing
@testable import CoreKit

private actor BackupDirectoryGate: RemoteStore {
    let base: LocalRemoteStore
    private var paused = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ base: LocalRemoteStore) { self.base = base }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func createDirectory(path: String) async throws {
        if path == "/Backups" {
            paused = true
            await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil }
        }
        try await base.createDirectory(path: path)
    }
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry { try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
}

@Suite struct BackupEngineTests {
    @Test func swappingSourceRootForSymlinkCannotUploadOutsideBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), outside = root.appendingPathComponent("outside"), remote = root.appendingPathComponent("remote")
        for directory in [source, outside, remote] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("intended".utf8).write(to: source.appendingPathComponent("report.txt"))
        try Data("outside secret".utf8).write(to: outside.appendingPathComponent("report.txt"))
        let base = try LocalRemoteStore(root: remote), store = BackupDirectoryGate(base)
        let backup = BackupEngine(store: store, transfers: TransferEngine(store: store))
        let preview = try await backup.preview(source: source, destination: "/Backups", previous: [:])
        let task = Task { try await backup.run(preview, previous: [:]) }
        await store.waitUntilPaused()
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original-source"))
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        await store.resume()
        let result = try await task.value
        #expect(result.uploaded == 1 && result.failures.isEmpty)
        #expect(try await base.read(path: "/Backups/report.txt", offset: 0, length: 64) == Data("intended".utf8))
        #expect(try Data(contentsOf: outside.appendingPathComponent("report.txt")) == Data("outside secret".utf8))
    }

    @Test func incrementalBackupKeepsRemoteDeletesAndPreviousVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("report.txt")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        try Data("first".utf8).write(to: file)
        let store = try LocalRemoteStore(root: remote)
        let backup = BackupEngine(store: store, transfers: TransferEngine(store: store))
        let preview = try await backup.preview(source: source, destination: "/Backups/Mac", previous: [:])
        #expect(preview.uploadCount == 1 && preview.uploadBytes == 5)
        let first = try await backup.run(preview, previous: [:])
        #expect(first.uploaded == 1 && first.failures.isEmpty)
        #expect(try await store.stat(path: "/Backups/Mac/Empty").isDirectory)
        #expect(try await backup.preview(source: source, destination: "/Backups/Mac", previous: first.records).uploadCount == 0)
        try Data("other".utf8).write(to: file)
        let update = try await backup.preview(source: source, destination: "/Backups/Mac", previous: first.records)
        let second = try await backup.run(update, previous: first.records)
        #expect(second.uploaded == 1 && second.failures.isEmpty)
        #expect(try await store.read(path: "/Backups/Mac/report.txt", offset: 0, length: 16) == Data("other".utf8))
        var contents = Set<Data>()
        for entry in try await store.list(path: "/Backups/Mac") where !entry.isDirectory { contents.insert(try await store.read(path: entry.path, offset: 0, length: 16)) }
        #expect(contents == [Data("first".utf8), Data("other".utf8)])
        try FileManager.default.removeItem(at: file)
        let deleted = try await backup.preview(source: source, destination: "/Backups/Mac", previous: second.records)
        #expect(deleted.uploadCount == 0)
        _ = try await backup.run(deleted, previous: second.records)
        #expect(try await store.read(path: "/Backups/Mac/report.txt", offset: 0, length: 16) == Data("other".utf8))
    }

    @Test func scanTagsSwitchableRulesAndPreviewHonoursThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("remote")
        for folder in ["Caches/deep", "node_modules", ".git", "Docs"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["Caches/deep/a.bin", "node_modules/b.js", ".git/HEAD", "Docs/c.txt", ".DS_Store"] {
            try Data("x".utf8).write(to: source.appendingPathComponent(file))
        }
        let scan = try await BackupEngine.scan(source: source)
        #expect(Dictionary(uniqueKeysWithValues: scan.map { ($0.path, $0.rule) }) == ["/Caches/deep/a.bin": .caches, "/node_modules/b.js": .nodeModules, "/Docs/c.txt": nil])
        let store = try LocalRemoteStore(root: remote)
        let backup = BackupEngine(store: store, transfers: TransferEngine(store: store))
        #expect(try await backup.preview(source: source, destination: "/B", previous: [:], exclusions: [.caches, .nodeModules]).uploadCount == 1)
        #expect(try await backup.preview(source: source, destination: "/B", previous: [:], exclusions: []).uploadCount == 3)
    }
}
