import Foundation
import CryptoKit
import Testing
@testable import CoreKit

struct SMBIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNCOPHANT_SMB_FIXTURE"] == "1",
                   "Requires the owned disposable Samba fixture; run scripts/test-smb-fixture.sh."))
    func nativeSMBNetworkRoundTripAndNoClobber() async throws {
        let store = try SMBStore(server: "127.0.0.1", share: "test", username: "fixture", password: "test-password")
        let directory = "/native-" + UUID().uuidString
        try await store.createDirectory(path: directory)
        let source = directory + "/source", target = directory + "/target"
        try await store.write(path: source, offset: 0, data: Data("abcdef".utf8))
        try await store.write(path: source, offset: 2, data: Data("XY".utf8))
        #expect(try await store.read(path: source, offset: 1, length: 3) == Data("bXY".utf8))
        let snapshot = try await store.stat(path: source)
        #expect(snapshot.size == 6 && snapshot.remoteRevision != nil)
        let hash = SHA256.hash(data: Data("abXYef".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(try await store.checksum(path: source) == hash)
        try await store.write(path: target, offset: 0, data: Data("retain".utf8))
        await #expect(throws: CoreKitError.alreadyExists(target)) { try await store.move(from: source, to: target) }
        #expect(try await store.read(path: target, offset: 0, length: 6) == Data("retain".utf8))
        #expect(try await store.read(path: source, offset: 0, length: 6) == Data("abXYef".utf8))
        try await store.remove(path: target)
        try await store.move(from: source, to: target)
        #expect(try await store.list(path: directory).map(\.name) == ["target"])
        await #expect(throws: CoreKitError.self) { try await store.remove(path: directory) }
        await #expect(throws: CoreKitError.self) { try await store.read(path: "/../outside", offset: 0, length: 1) }
        try await store.remove(path: target); try await store.remove(path: directory)
        let races = "/races-" + UUID().uuidString
        try await store.createDirectory(path: races)
        try await store.write(path: races + "/one", offset: 0, data: Data("one".utf8))
        try await store.write(path: races + "/two", offset: 0, data: Data("two".utf8))
        func claim(_ name: String) async throws -> Bool {
            do { try await store.move(from: races + "/" + name, to: races + "/winner"); return true }
            catch CoreKitError.alreadyExists { return false }
        }
        async let one = claim("one"), two = claim("two")
        let winners = try await (one, two)
        #expect(winners.0 != winners.1)
        let winner = try await store.read(path: races + "/winner", offset: 0, length: 3)
        #expect(winner == Data((winners.0 ? "one" : "two").utf8))
        #expect(try await store.read(path: races + (winners.0 ? "/two" : "/one"), offset: 0, length: 3) == Data((winners.0 ? "two" : "one").utf8))
        try await store.remove(path: races + "/winner")
        try await store.remove(path: races + (winners.0 ? "/two" : "/one"))
        try await store.move(from: races, to: races + "-moved")
        try await store.remove(path: races + "-moved")
        // Subdirectory roots are mounted by NetFS itself, so their root descriptor is the network security boundary.
        let nested = try SMBStore(server: "127.0.0.1", share: "test", username: "fixture", password: "test-password", rootPath: "/nested")
        try await nested.write(path: "/inside", offset: 0, data: Data("confined".utf8))
        #expect(try await nested.read(path: "/inside", offset: 0, length: 8) == Data("confined".utf8))
        #expect(try await store.read(path: "/nested/inside", offset: 0, length: 8) == Data("confined".utf8))
        try await nested.remove(path: "/inside")
        let rejected = try SMBStore(server: "127.0.0.1", share: "test", username: "fixture", password: "invalid-fixture-password")
        await #expect(throws: CoreKitError.authenticationFailed) { try await rejected.list(path: "/") }
    }
}
