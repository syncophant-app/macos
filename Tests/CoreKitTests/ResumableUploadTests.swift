import Foundation
import CryptoKit
import Testing
@testable import CoreKit

private struct ResumeFixture {
    let directory: URL
    let remote: URL
    let store: LocalRemoteStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResumableUpload-" + UUID().uuidString)
        remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        store = try LocalRemoteStore(root: remote)
    }

    func source(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func partial(_ id: UUID) -> String { "/.synco-upload.partial-" + id.uuidString }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

// Real local storage owns all bytes, hashes, and renames; only network/lifecycle faults are injected.
private actor InterruptedUploadStore: RemoteStore {
    let base: LocalRemoteStore
    private var interruption: CoreKitError?
    private let suspendWrites: Bool
    private var mutateSourceOnChecksum: URL?
    private(set) var writeOffsets: [Int64] = []
    private(set) var started = false

    init(_ base: LocalRemoteStore, interruption: CoreKitError? = nil, suspendWrites: Bool = false,
         mutateSourceOnChecksum: URL? = nil) {
        self.base = base
        self.interruption = interruption
        self.suspendWrites = suspendWrites
        self.mutateSourceOnChecksum = mutateSourceOnChecksum
    }

    func waitForWrite() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !started {
            guard ContinuousClock.now < deadline else { throw CoreKitError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry { try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data {
        try await base.read(path: path, offset: offset, length: length)
    }
    func write(path: String, offset: Int64, data: Data) async throws {
        if !data.isEmpty {
            writeOffsets.append(offset)
            if let error = interruption {
                interruption = nil
                try await base.write(path: path, offset: offset, data: Data(data.prefix(128 * 1024 + 7)))
                throw error
            }
        }
        try await base.write(path: path, offset: offset, data: data)
        if !data.isEmpty, suspendWrites {
            started = true
            try await Task.sleep(for: .seconds(30))
        }
    }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String {
        let digest = try await base.checksum(path: path)
        if let source = mutateSourceOnChecksum {
            mutateSourceOnChecksum = nil
            let file = try FileHandle(forWritingTo: source)
            defer { try? file.close() }
            try file.write(contentsOf: Data("changed".utf8))
        }
        return digest
    }
}

@Suite struct ResumableUploadTests {
    @Test(arguments: [CoreKitError.connection("Interrupted network"), .timeout])
    func interruptedWriteResumesVerifiedPrefixAcrossEngines(_ failure: CoreKitError) async throws {
        let f = try ResumeFixture(); defer { f.cleanup() }
        let data = Data((0..<(2 * 1024 * 1024 + 77)).map { UInt8($0 % 251) })
        let source = try f.source(data), id = UUID()
        let store = InterruptedUploadStore(f.store, interruption: failure)
        await #expect(throws: failure) {
            try await TransferEngine(store: store).upload(localURL: source, remotePath: "/file", resumeID: id)
        }
        let retained = try await f.store.stat(path: f.partial(id))
        #expect(retained.size == 128 * 1024 + 7)
        #expect(try await f.store.list(path: "/").isEmpty)

        let receipt = try await TransferEngine(store: store).upload(localURL: source, remotePath: "/file", resumeID: id)
        let offsets = await store.writeOffsets
        #expect(offsets.first == 0)
        #expect(offsets.dropFirst().first == retained.size)
        #expect(offsets.dropFirst().allSatisfy { $0 >= retained.size })
        #expect(try await f.store.read(path: "/file", offset: 0, length: data.count) == data)
        let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let published = try await f.store.stat(path: "/file")
        #expect(receipt.verified && receipt.checksum == expectedHash)
        #expect(receipt.remoteVersion == published.version)
        #expect(try await f.store.checksum(path: "/file") == expectedHash)
        #expect(try Data(contentsOf: source) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["file"])
    }

    @Test(arguments: [0, 7, 15])
    func verifiedEmptyPrefixOrCompletePartialKeepsStrongReceipt(_ prefixSize: Int) async throws {
        let f = try ResumeFixture(); defer { f.cleanup() }
        let data = Data("valid new bytes".utf8), source = try f.source(data), id = UUID()
        try await f.store.write(path: f.partial(id), offset: 0, data: Data(data.prefix(prefixSize)))
        let store = InterruptedUploadStore(f.store)
        let metadata = try MetadataStore(url: f.directory.appendingPathComponent("metadata.sqlite"))
        let receipt = try await TransferEngine(store: store, metadata: metadata)
            .upload(localURL: source, remotePath: "/file", resumeID: id)
        let offsets = await store.writeOffsets
        #expect(offsets.allSatisfy { $0 >= Int64(prefixSize) })
        if prefixSize == data.count { #expect(offsets.isEmpty) }
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == data)
        #expect(receipt.verified)
        #expect(receipt.checksum == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(receipt.remoteVersion == (try await f.store.stat(path: "/file")).version)
    }

    @Test(arguments: [Data("wrong".utf8), Data("wrong old bytes".utf8), Data(repeating: 9, count: 100)])
    func staleOrOversizedPartialIsRejectedWithoutTouchingEitherCopy(_ stale: Data) async throws {
        let f = try ResumeFixture(); defer { f.cleanup() }
        let original = Data("original".utf8), data = Data("valid new bytes".utf8)
        let source = try f.source(data), id = UUID()
        try await f.store.write(path: "/file", offset: 0, data: original)
        try await f.store.write(path: f.partial(id), offset: 0, data: stale)
        let engine = TransferEngine(store: f.store)
        await #expect(throws: CoreKitError.checksumMismatch) {
            try await engine.upload(localURL: source, remotePath: "/file", resumeID: id)
        }
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == original)
        #expect(try Data(contentsOf: source) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["file"])
        let receipt = try await engine.upload(localURL: source, remotePath: "/file", resumeID: id)
        #expect(receipt.verified && receipt.remotePath != "/file")
        #expect(try await f.store.read(path: receipt.remotePath, offset: 0, length: 100) == data)
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == original)
    }

    @Test func cancellationCleansPartialAndDuplicateJobCannotDisturbActiveUpload() async throws {
        let f = try ResumeFixture(); defer { f.cleanup() }
        let original = Data("original".utf8), data = Data(repeating: 3, count: 2 * 1024 * 1024)
        let source = try f.source(data), id = UUID()
        try await f.store.write(path: "/file", offset: 0, data: original)
        let store = InterruptedUploadStore(f.store, suspendWrites: true)
        let engine = TransferEngine(store: store)
        let task = Task { try await engine.upload(localURL: source, remotePath: "/file", resumeID: id) }
        defer { task.cancel() }
        try await store.waitForWrite()
        await #expect(throws: CoreKitError.alreadyExists(f.partial(id))) {
            try await engine.upload(localURL: source, remotePath: "/file", resumeID: id)
        }
        #expect(try await f.store.stat(path: f.partial(id)).size == 1024 * 1024)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["file"])
        #expect(try await f.store.read(path: "/file", offset: 0, length: 100) == original)
        #expect(try Data(contentsOf: source) == data)
    }

    @Test func mutationDuringRemoteVerificationPreventsPublication() async throws {
        let f = try ResumeFixture(); defer { f.cleanup() }
        let source = try f.source(Data("initial".utf8)), id = UUID()
        let store = InterruptedUploadStore(f.store, mutateSourceOnChecksum: source)
        await #expect(throws: CoreKitError.sourceChanged) {
            try await TransferEngine(store: store).upload(localURL: source, remotePath: "/file", resumeID: id)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path).isEmpty)
        #expect(try Data(contentsOf: source) == Data("changed".utf8))
    }

    @Test func nonresumableConnectionFailureStillCleansPartial() async throws {
        let f = try ResumeFixture(); defer { f.cleanup() }
        let data = Data("keep source".utf8), source = try f.source(data)
        let store = InterruptedUploadStore(f.store, interruption: .connection("Interrupted network"))
        await #expect(throws: CoreKitError.connection("Interrupted network")) {
            try await TransferEngine(store: store).upload(localURL: source, remotePath: "/file")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path).isEmpty)
        #expect(try Data(contentsOf: source) == data)
    }
}
