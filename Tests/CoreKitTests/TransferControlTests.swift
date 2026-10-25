import Foundation
import Testing
@testable import CoreKit

private struct ControlFixture {
    let directory: URL
    let remote: URL
    let store: LocalRemoteStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TransferControls-" + UUID().uuidString)
        remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        store = try LocalRemoteStore(root: remote)
    }

    func source(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func waitForPartial() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let urls = try FileManager.default.contentsOfDirectory(at: remote, includingPropertiesForKeys: nil)
            for url in urls where url.lastPathComponent.hasPrefix(".synco-upload.partial-") {
                if try Data(contentsOf: url).count > 0 { return }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Upload did not write a partial within 10 seconds")
        throw CancellationError()
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct TransferControlTests {
    @Test func pausedUploadDoesNotWriteOrPublishUntilResumed() async throws {
        let f = try ControlFixture(); defer { f.cleanup() }
        let data = Data("resume me".utf8), source = try f.source(data)
        let metadata = try MetadataStore(url: f.directory.appendingPathComponent("metadata.sqlite"))
        let engine = TransferEngine(store: f.store, metadata: metadata)
        await engine.setPaused(true)
        let task = Task { try await engine.upload(localURL: source, remotePath: "/file") }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path).isEmpty)
        await engine.setPaused(false)
        let receipt = try await task.value
        #expect(receipt.verified)
        #expect(try await f.store.read(path: "/file", offset: 0, length: 99) == data)
    }

    @Test func heldUploadWaitsWhileOthersFinish() async throws {
        let f = try ControlFixture(); defer { f.cleanup() }
        let data = Data("held".utf8), source = try f.source(data)
        let engine = TransferEngine(store: f.store)
        let id = UUID()
        await engine.setHeld(true, resumeID: id)
        let held = Task { try await engine.upload(localURL: source, remotePath: "/held", resumeID: id) }
        defer { held.cancel() }
        #expect(try await engine.upload(localURL: source, remotePath: "/other").verified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["other"])
        await engine.setHeld(false, resumeID: id)
        #expect(try await held.value.verified)
        #expect(try await f.store.read(path: "/held", offset: 0, length: 99) == data)
    }

    @Test func cancellationWhilePausedCleansPartialAndPreservesBothCopies() async throws {
        let f = try ControlFixture(); defer { f.cleanup() }
        let original = Data("original".utf8), data = Data(repeating: 7, count: 100)
        try await f.store.write(path: "/file", offset: 0, data: original)
        let source = try f.source(data), engine = TransferEngine(store: f.store)
        await engine.setBandwidthLimit(bytesPerSecond: 1)
        let task = Task { try await engine.upload(localURL: source, remotePath: "/file") }
        defer { task.cancel() }
        try await f.waitForPartial()
        await engine.setPaused(true)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(0.5))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.remote.path) == ["file"])
        #expect(try Data(contentsOf: source) == data)
        #expect(try await f.store.read(path: "/file", offset: 0, length: 99) == original)
    }

    @Test func fixedLimitPacesAggregateConcurrentUploads() async throws {
        let f = try ControlFixture(); defer { f.cleanup() }
        let data = Data(repeating: 3, count: 300), source = try f.source(data)
        let engine = TransferEngine(store: f.store)
        await engine.setBandwidthLimit(bytesPerSecond: 1_000)
        let start = ContinuousClock.now
        async let first = engine.upload(localURL: source, remotePath: "/first")
        async let second = engine.upload(localURL: source, remotePath: "/second")
        let receipts = try await [first, second]
        // Separate per-upload budgets would finish in about 300 ms, rather than 600 ms.
        #expect(start.duration(to: .now) >= .milliseconds(550))
        #expect(receipts.allSatisfy { $0.verified })
        for path in ["/first", "/second"] {
            #expect(try await f.store.read(path: path, offset: 0, length: 400) == data)
        }
    }

    @Test func removingLimitReleasesAnAlreadyWaitingUpload() async throws {
        let f = try ControlFixture(); defer { f.cleanup() }
        let source = try f.source(Data(repeating: 4, count: 100))
        let engine = TransferEngine(store: f.store)
        await engine.setBandwidthLimit(bytesPerSecond: 1)
        let task = Task { try await engine.upload(localURL: source, remotePath: "/file") }
        defer { task.cancel() }
        try await f.waitForPartial()
        let start = ContinuousClock.now
        await engine.setBandwidthLimit(bytesPerSecond: nil)
        #expect(try await task.value.verified)
        #expect(start.duration(to: .now) < .seconds(0.5))
    }
}
