import Foundation
import Testing
@testable import CoreKit

private actor CongestedStore: RemoteStore {
    let base: LocalRemoteStore
    private var probes = 0
    init(_ base: LocalRemoteStore) { self.base = base }
    func stat(path: String) async throws -> RemoteEntry {
        if path == "/" {
            probes += 1
            if probes > 1 { try await Task.sleep(for: .milliseconds(150)) }
        }
        return try await base.stat(path: path)
    }
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
}

@Suite struct AdaptiveBandwidthTests {
    @Test func metadataLatencyReducesAutoTargetWithoutWeakeningVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try LocalRemoteStore(root: remote), store = CongestedStore(base)
        let source = root.appendingPathComponent("source")
        try Data(repeating: 7, count: 5 * 1024 * 1024).write(to: source)
        let engine = TransferEngine(store: store)
        await engine.setAdaptiveBandwidth(true)
        let receipt = try await engine.upload(localURL: source, remotePath: "/file")
        let target = try #require(await engine.bandwidthLimitBytesPerSecond)
        #expect(target < 20_000_000 && target >= 256_000)
        #expect(receipt.verified)
        #expect(try await base.checksum(path: "/file") == receipt.checksum)
        await engine.setAdaptiveBandwidth(false)
        await engine.setBandwidthLimit(bytesPerSecond: nil)
        #expect(await engine.bandwidthLimitBytesPerSecond == nil)
    }
}
