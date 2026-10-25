import Foundation
import CryptoKit
import Testing
@testable import CoreKit

private struct FixtureState: Decodable {
    struct File: Decodable { let size: Int; let sha256: String; let etag: String }
    struct Request: Decodable {
        let method: String; let path: String
        let ifMatch: String?; let ifNoneMatch: String?; let overwrite: String?; let range: String?
        let uploadId: String?; let partNumber: String?
    }
    let files: [String: File]
    let history: [Request]
    let multipart: Int
}

private final class HTTPFixture: @unchecked Sendable {
    let process: Process
    let directory: URL
    let endpoint: URL
    init(process: Process, directory: URL, endpoint: URL) { self.process = process; self.directory = directory; self.endpoint = endpoint }
    deinit {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
    static func start() async throws -> HTTPFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("storage-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let ready = directory.appendingPathComponent("ready")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", root.appendingPathComponent("scripts/fixtures/storage_http.py").path, "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            for _ in 0..<100 {
                if let text = try? String(contentsOf: ready, encoding: .utf8), let endpoint = URL(string: text) {
                    return HTTPFixture(process: process, directory: directory, endpoint: endpoint)
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CoreKitError.connection("Local protocol fixture did not start.")
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    func webdav() throws -> WebDAVStore {
        try WebDAVStore(endpoint: endpoint.appendingPathComponent("dav"), username: "fixture", password: "test-password", allowInsecureLoopback: true)
    }
    func s3() throws -> S3Store {
        try S3Store(endpoint: endpoint.appendingPathComponent("s3"), bucket: "bucket", region: "us-east-1",
                    accessKey: "fixture-access", secretKey: "fixture-secret", rootPath: "/root", allowInsecureLoopback: true)
    }
    func control(_ values: [String: String]) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("__fixture/control")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
    func state() async throws -> FixtureState {
        let (data, response) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("__fixture/state"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode(FixtureState.self, from: data)
    }
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct NetworkStoreTests {
    @Test func endpointsAndPathsFailBeforeNetworkOrSecretDisclosure() throws {
        for endpoint in ["http://example.com/dav", "https://user:secret@example.com/", "https://example.com/dav?secret=one", "https://example.com/%2e%2e/", "file:///tmp"] {
            #expect(throws: CoreKitError.self) { try WebDAVStore(endpoint: URL(string: endpoint)!, username: "user", password: "secret") }
        }
        #expect(throws: CoreKitError.self) { try S3Store(endpoint: URL(string: "https://example.com")!, bucket: "../escape", region: "us-east-1", accessKey: "key", secretKey: "secret") }
        #expect(throws: CoreKitError.self) { try SMBStore(server: "host/share", share: "share", username: "user", password: "secret") }
        #expect(throws: CoreKitError.self) { try SMBStore(server: "host", share: "../share", username: "user", password: "secret") }
        #expect(throws: CoreKitError.self) { try parseStorageXML(Data("<!DOCTYPE x [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><x>&leak;</x>".utf8)) }
    }

    @Test func webdavExercisesActualMethodsAndProtectsRemoteData() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.webdav()
        try await store.createDirectory(path: "/folder")
        try await store.write(path: "/folder/unicode ü #%.txt", offset: 0, data: Data("abcdef".utf8))
        let first = try await store.stat(path: "/folder/unicode ü #%.txt")
        #expect(first.contentHash == nil && first.remoteRevision != nil)
        let beforeStat = try await fixture.state().history.count
        _ = try await store.stat(path: first.path)
        #expect(try await fixture.state().history.dropFirst(beforeStat).allSatisfy { $0.method != "GET" })
        try await store.write(path: first.path, offset: 2, data: Data("XY".utf8))
        #expect(try await store.read(path: first.path, offset: 2, length: 100) == Data("XYef".utf8))
        #expect(try await store.read(path: first.path, offset: 100, length: 10).isEmpty)
        #expect(try await store.checksum(path: first.path) == sha(Data("abXYef".utf8)))
        #expect(try await store.stat(path: first.path).version != first.version)
        try await store.write(path: "/folder/occupied", offset: 0, data: Data("retain".utf8))
        await #expect(throws: CoreKitError.alreadyExists("/folder/occupied")) { try await store.move(from: first.path, to: "/folder/occupied") }
        #expect(try await store.read(path: "/folder/occupied", offset: 0, length: 16) == Data("retain".utf8))
        try await store.move(from: first.path, to: "/folder/moved")
        #expect(try await store.list(path: "/folder").map(\.name) == ["moved", "occupied"])
        await #expect(throws: CoreKitError.self) { try await store.remove(path: "/folder") }
        #expect(try await fixture.state().files["/dav/folder/moved"] != nil)
        try await store.remove(path: "/folder/moved"); try await store.remove(path: "/folder/occupied")
        try await store.remove(path: "/folder")
        #expect(try await store.list(path: "/").isEmpty)
        let state = try await fixture.state()
        #expect(state.history.filter { $0.method == "MOVE" }.allSatisfy { $0.overwrite == "F" && $0.ifMatch != nil })
        #expect(state.history.contains { $0.method == "LOCK" })
    }

    @Test func stagedChunksFlushOnceAndAcceptEncryptedOpaqueNames() async throws {
        let fixture = try await HTTPFixture.start()
        let stores: [any RemoteStore] = [try fixture.webdav(), try fixture.s3()]
        for store in stores {
            try await store.prepareUpload(path: "/opaquebase32encryptedname")
            try await store.write(path: "/opaquebase32encryptedname", offset: 0, data: Data())
            for index in 0..<4 { try await store.write(path: "/opaquebase32encryptedname", offset: Int64(index * 1024), data: Data(repeating: 65, count: 1024)) }
            let prefix = store.publicationMode == .atomicMove ? "/dav/" : "/s3/bucket/root/"
            #expect(try await fixture.state().files[prefix + "opaquebase32encryptedname"] == nil)
            try await store.finishUpload(path: "/opaquebase32encryptedname")
            let state = try await fixture.state()
            #expect(state.files[prefix + "opaquebase32encryptedname"]?.size == 4096)
            #expect(state.history.filter { $0.path == prefix + "opaquebase32encryptedname" && $0.method == "PUT" }.count == 1)
            #expect(try await store.checksum(path: "/opaquebase32encryptedname") == sha(Data(repeating: 65, count: 4096)))
        }
    }

    @Test func failedFinishCanRestartFromTheCompletedRemoteCheckpoint() async throws {
        let fixture = try await HTTPFixture.start()
        for (store, prefix) in [(try fixture.webdav() as any RemoteStore, "/dav/"), (try fixture.s3() as any RemoteStore, "/s3/bucket/root/")] {
            try await store.write(path: "/checkpoint", offset: 0, data: Data("old".utf8))
            try await store.prepareUpload(path: "/checkpoint")
            try await store.write(path: "/checkpoint", offset: 3, data: Data("new".utf8))
            try await fixture.control(["path": prefix + "checkpoint", "fault": "reject-put-once"])
            await #expect(throws: CoreKitError.self) { try await store.finishUpload(path: "/checkpoint") }
            #expect(try await store.read(path: "/checkpoint", offset: 0, length: 6) == Data("old".utf8))
            try await store.prepareUpload(path: "/checkpoint")
            try await store.write(path: "/checkpoint", offset: 3, data: Data("new".utf8))
            try await store.finishUpload(path: "/checkpoint")
            #expect(try await store.read(path: "/checkpoint", offset: 0, length: 6) == Data("oldnew".utf8))
        }
    }

    @Test func explicitTrashBrowsingListsNormalChildrenWhileHidingTemporaryNames() async throws {
        let fixture = try await HTTPFixture.start()
        let folder = RemoteTrash.root + "/" + UUID().uuidString
        for store in [try fixture.webdav() as any RemoteStore, try fixture.s3() as any RemoteStore] {
            try await store.createDirectory(path: RemoteTrash.root)
            try await store.createDirectory(path: folder)
            try await store.write(path: folder + "/manifest.json", offset: 0, data: Data("manifest".utf8))
            try await store.write(path: folder + "/item", offset: 0, data: Data("saved".utf8))
            try await store.write(path: folder + "/.synco-upload.partial-hidden", offset: 0, data: Data("partial".utf8))
            #expect(try await store.list(path: "/").isEmpty)
            #expect(try await store.list(path: RemoteTrash.root).map(\.path) == [folder])
            #expect(try await store.list(path: folder).map(\.name) == ["item", "manifest.json"])
            #expect(try await store.read(path: folder + "/item", offset: 0, length: 5) == Data("saved".utf8))
        }
    }

    @Test func webdavRemoteTrashDiscoversAndRestoresSavedItem() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.webdav()
        let metadata = try MetadataStore(url: fixture.directory.appendingPathComponent("metadata.sqlite"))
        try await store.write(path: "/saved.txt", offset: 0, data: Data("saved".utf8))
        let item = try #require(await metadata.refresh(store: store, path: "/").first)
        let trash = RemoteTrash(store: store, metadata: metadata)
        try await trash.delete(item, expectedVersion: item.entry.version)
        #expect(try await store.list(path: "/").isEmpty)
        let saved = try #require(await trash.items().first)
        #expect(saved.originalPath == "/saved.txt")
        try await trash.restore(saved)
        #expect(try await trash.items().isEmpty)
        #expect(try await store.read(path: "/saved.txt", offset: 0, length: 5) == Data("saved".utf8))
    }

    @Test func s3RangeStatDirectoriesCopyAndPresignedGET() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.s3()
        try await store.createDirectory(path: "/folder")
        try await store.write(path: "/folder/file ü #%.txt", offset: 0, data: Data("abcdef".utf8))
        let before = try await fixture.state().history.count
        let entry = try await store.stat(path: "/folder/file ü #%.txt")
        #expect(entry.contentHash == nil && entry.remoteRevision != nil)
        #expect(try await fixture.state().history.dropFirst(before).allSatisfy { $0.method != "GET" })
        #expect(try await store.read(path: entry.path, offset: 1, length: 3) == Data("bcd".utf8))
        #expect(try await store.list(path: "/folder").map(\.path) == [entry.path])
        try await store.publish(from: entry.path, to: "/copy")
        #expect(try await store.checksum(path: "/copy") == sha(Data("abcdef".utf8)))
        #expect(try await store.read(path: entry.path, offset: 0, length: 6) == Data("abcdef".utf8))
        await #expect(throws: CoreKitError.self) { try await store.move(from: entry.path, to: "/move") }
        await #expect(throws: CoreKitError.self) { try await store.remove(path: "/folder") }
        let signed = try await store.presignedGET(path: entry.path, expires: 604800)
        let (bytes, response) = try await URLSession.shared.data(from: signed)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && bytes == Data("abcdef".utf8))
        await #expect(throws: CoreKitError.self) { try await store.presignedGET(path: entry.path, expires: 604801) }
        try await store.remove(path: entry.path); try await store.remove(path: "/folder")
    }

    @Test func conditionalPublicationAndReplacementNeverOverwriteAnInterveningWriter() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.s3()
        try await store.write(path: "/source", offset: 0, data: Data("new".utf8))
        try await fixture.control(["path": "/s3/bucket/root/raced", "fault": "race-put"])
        await #expect(throws: CoreKitError.alreadyExists("/raced")) { try await store.publish(from: "/source", to: "/raced") }
        #expect(try await store.read(path: "/raced", offset: 0, length: 100) == Data("external-writer".utf8))
        #expect(try await store.stat(path: "/source").size == 3)
        try await store.write(path: "/target", offset: 0, data: Data("old".utf8))
        let expected = try await store.stat(path: "/target").version
        try await store.replace(from: "/source", to: "/target", expectedVersion: expected)
        #expect(try await store.read(path: "/target", offset: 0, length: 20) == Data("new".utf8))
        let next = try await store.stat(path: "/target").version
        try await fixture.control(["path": "/s3/bucket/root/target", "fault": "race-put"])
        await #expect(throws: CoreKitError.itemChanged("/target")) { try await store.replace(from: "/source", to: "/target", expectedVersion: next) }
        #expect(try await store.read(path: "/target", offset: 0, length: 100) == Data("external-writer".utf8))
        #expect(try await fixture.state().history.contains { $0.path.hasSuffix("/target") && $0.method == "PUT" && $0.ifMatch != nil })
    }

    @Test func unstableSourcesWeakValidatorsBadRangesAndRedirectsAreRefused() async throws {
        let fixture = try await HTTPFixture.start()
        for (store, prefix) in [(try fixture.webdav() as any RemoteStore, "/dav/"), (try fixture.s3() as any RemoteStore, "/s3/bucket/root/")] {
            try await store.write(path: "/file", offset: 0, data: Data("data".utf8))
            try await fixture.control(["path": prefix + "file", "fault": "mutate-after-get"])
            await #expect(throws: CoreKitError.itemChanged("/file")) { try await store.checksum(path: "/file") }
            try await fixture.control(["path": prefix + "file", "fault": "weak-etag"])
            await #expect(throws: CoreKitError.self) { try await store.stat(path: "/file") }
            try await fixture.control(["path": prefix + "file", "fault": "ignore-range"])
            await #expect(throws: CoreKitError.self) { try await store.read(path: "/file", offset: 1, length: 2) }
            try await fixture.control(["path": prefix + "file", "fault": "redirect"])
            await #expect(throws: CoreKitError.self) { try await store.stat(path: "/file") }
        }
        try await fixture.control(["path": "/dav/", "fault": "escaping-href"])
        await #expect(throws: CoreKitError.self) { try await fixture.webdav().list(path: "/") }
        #expect(try await fixture.state().history.allSatisfy { $0.path != "/__fixture/capture" })
    }

    @Test func transferEngineVerifiesCopyOnlyUpdatesAndPreservesConflicts() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.s3()
        let source = fixture.directory.appendingPathComponent("source")
        try Data("new-source".utf8).write(to: source)
        try await store.write(path: "/original.txt", offset: 0, data: Data("old-source".utf8))
        let expected = try await store.stat(path: "/original.txt").version
        let receipt = try await TransferEngine(store: store).upload(localURL: source, remotePath: "/original.txt", expectedVersion: expected)
        #expect(receipt.verified && receipt.remotePath == "/original.txt" && receipt.checksum == sha(Data("new-source".utf8)))
        let state = try await fixture.state()
        #expect(state.files["/s3/bucket/root/original.txt"]?.sha256 == sha(Data("new-source".utf8)))
        #expect(state.files.contains { $0.key.contains("conflict") && $0.value.sha256 == sha(Data("old-source".utf8)) })
        #expect(!state.files.keys.contains { $0.contains(".synco-upload.partial-") })
    }

    @Test func transferEnginePreservesWriterArrivingAfterVerifiedBackup() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.s3()
        let source = fixture.directory.appendingPathComponent("source")
        try Data("new-source".utf8).write(to: source)
        try await store.write(path: "/original.txt", offset: 0, data: Data("old-source".utf8))
        let expected = try await store.stat(path: "/original.txt").version
        // The target changes at the conditional PUT, after the engine has made and verified its old-content backup.
        try await fixture.control(["path": "/s3/bucket/root/original.txt", "fault": "race-put"])
        let receipt = try await TransferEngine(store: store).upload(localURL: source, remotePath: "/original.txt", expectedVersion: expected)
        #expect(receipt.verified && receipt.remotePath != "/original.txt" && receipt.remotePath.contains("conflict"))
        let state = try await fixture.state()
        #expect(state.files["/s3/bucket/root/original.txt"]?.sha256 == sha(Data("external-writer".utf8)))
        #expect(state.files.contains { $0.key.contains("conflict") && $0.value.sha256 == sha(Data("old-source".utf8)) })
        #expect(state.files.contains { $0.key.contains("conflict") && $0.value.sha256 == sha(Data("new-source".utf8)) })
    }

    @Test func multipartCompletionIsConditionalAndEmbeddedErrorsAbortOwnedUpload() async throws {
        let fixture = try await HTTPFixture.start(), store = try fixture.s3()
        let chunk = Data(repeating: 42, count: 1024 * 1024)
        for (path, failure) in [("/large", false), ("/failed-large", true)] {
            try await store.prepareUpload(path: path)
            for index in 0..<65 { try await store.write(path: path, offset: Int64(index * chunk.count), data: chunk) }
            if failure { try await fixture.control(["path": "/s3/bucket/root" + path, "fault": "multipart-error"]) }
            if failure {
                await #expect(throws: CoreKitError.self) { try await store.finishUpload(path: path) }
                await #expect(throws: CoreKitError.notFound(path)) { try await store.remove(path: path) }
            } else { try await store.finishUpload(path: path) }
        }
        let state = try await fixture.state()
        #expect(state.files["/s3/bucket/root/large"]?.size == 65 * 1024 * 1024)
        #expect(state.files["/s3/bucket/root/failed-large"] == nil && state.multipart == 0)
        #expect(state.history.contains { $0.method == "POST" && $0.uploadId != nil && $0.ifNoneMatch == "*" })
        #expect(state.history.contains { $0.method == "DELETE" && $0.uploadId != nil })
        // Replacing an existing multipart object must use its ETag at completion, including a late-writer rejection.
        try await store.prepareUpload(path: "/large")
        try await store.write(path: "/large", offset: 0, data: Data("edit".utf8))
        try await fixture.control(["path": "/s3/bucket/root/large", "fault": "race-complete"])
        await #expect(throws: CoreKitError.itemChanged("/large")) { try await store.finishUpload(path: "/large") }
        #expect(try await store.read(path: "/large", offset: 0, length: 100) == Data("external-writer".utf8))
        let raced = try await fixture.state()
        #expect(raced.multipart == 0)
        #expect(raced.history.contains { $0.method == "POST" && $0.uploadId != nil && $0.ifMatch != nil })
    }
}
