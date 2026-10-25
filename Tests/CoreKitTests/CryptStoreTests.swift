import CryptoKit
import Foundation
import Testing
@testable import CoreKit

private struct CryptFixture {
    let directory: URL
    let remote: URL
    let base: LocalRemoteStore
    let store: CryptStore
    static let password = "syncophant-public-fixture-password"
    static let salt = "syncophant-public-fixture-salt"
    static var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var helper: URL {
        if let configured = ProcessInfo.processInfo.environment["SYNCOPHANT_CRYPT_HELPER"] { return URL(fileURLWithPath: configured) }
        return repository.appendingPathComponent(".build/syncophant-crypt")
    }

    init(independent: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CryptStoreTests-" + UUID().uuidString)
        remote = directory.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if independent {
            try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("scripts/integration/fixtures/rclone-crypt-v1.72.1"), to: remote)
        } else { try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true) }
        base = try LocalRemoteStore(root: remote)
        store = try CryptStore(base: base, password: Self.password, password2: Self.salt, helperURL: Self.helper)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func reopen(password: String = Self.password, salt: String = Self.salt) throws -> CryptStore {
        try CryptStore(base: base, password: password, password2: salt, helperURL: Self.helper)
    }

    static func data(_ count: Int) -> Data { Data((0..<count).map { UInt8(($0 * 37 + 11) % 251) }) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@Test func cryptIndependentRcloneFixtureAndRanges() async throws {
    let fixture = try CryptFixture(independent: true)
    defer { fixture.cleanup() }
    let expected = CryptFixture.data(3 * 65536 + 127)
    #expect(try await fixture.store.list(path: "/").map(\.name) == ["Archive"])
    let info = try await fixture.store.stat(path: "/Archive/independent.bin")
    #expect(info.size == Int64(expected.count))
    #expect(info.contentHash == nil)
    #expect(info.remoteRevision?.hasPrefix("rclone-crypt-v1:") == true)
    for (offset, length) in [(0, 1), (17, 1024), (65530, 45), (65536, 65536), (196605, 4096), (196735, 1)] {
        let result = try await fixture.store.read(path: info.path, offset: Int64(offset), length: length)
        #expect(result == expected.subdata(in: offset..<min(offset + length, expected.count)))
    }
    #expect(try await fixture.store.checksum(path: info.path) == CryptFixture.hash(expected))
}

@Test func cryptRoundTripNamesDataEmptyAndFiltering() async throws {
    let fixture = try CryptFixture()
    defer { fixture.cleanup() }
    try await fixture.store.createDirectory(path: "/Private ü")
    let data = CryptFixture.data(2 * 1024 * 1024 + 37), path = "/Private ü/Report.txt"
    try await fixture.store.prepareUpload(path: path)
    try await fixture.store.write(path: path, offset: 0, data: Data(data.prefix(1_000_003)))
    try await fixture.store.write(path: path, offset: 1_000_003, data: Data(data.dropFirst(1_000_003)))
    try await fixture.store.finishUpload(path: path)
    try await fixture.store.write(path: "/Private ü/empty", offset: 0, data: Data())
    try await fixture.store.write(path: "/Private ü/.synco-hidden.partial-one", offset: 0, data: Data("hidden".utf8))
    #expect(try await fixture.store.list(path: "/Private ü").map(\.name) == ["Report.txt", "empty"])
    #expect(try await fixture.store.stat(path: path).size == Int64(data.count))
    #expect(try await fixture.store.checksum(path: path) == CryptFixture.hash(data))
    #expect(try await fixture.store.checksum(path: "/Private ü/empty") == CryptFixture.hash(Data()))
    let encryptedDirectory = try #require(try await fixture.base.list(path: "/").first)
    #expect(encryptedDirectory.name != "Private ü")
    for child in try await fixture.base.list(path: encryptedDirectory.path) {
        #expect(!["Report.txt", "empty"].contains(child.name))
        let raw = try await fixture.base.read(path: child.path, offset: 0, length: Int(child.size))
        #expect(raw.prefix(8) == Data("RCLONE\0\0".utf8))
        #expect(raw.range(of: Data(data.prefix(64))) == nil)
    }
    try await fixture.store.createDirectory(path: "/.syncophant-trash")
    try await fixture.store.write(path: "/.syncophant-trash/saved", offset: 0, data: Data("trash".utf8))
    #expect(try await fixture.store.list(path: "/").map(\.name) == ["Private ü"])
    #expect(try await fixture.store.list(path: "/.syncophant-trash").map(\.name) == ["saved"])
}

@Test func cryptWrongPasswordSaltAndTamperingFailClosed() async throws {
    let fixture = try CryptFixture(independent: true)
    defer { fixture.cleanup() }
    for store in [try fixture.reopen(password: "incorrect"), try fixture.reopen(salt: "incorrect")] {
        await #expect(throws: CryptStoreError.authenticationOrCorruption) { try await store.list(path: "/") }
    }
    let directory = try #require(try await fixture.base.list(path: "/").first)
    let file = try #require(try await fixture.base.list(path: directory.path).first)
    let byte = try await fixture.base.read(path: file.path, offset: 80, length: 1)
    try await fixture.base.write(path: file.path, offset: 80, data: Data([byte[0] ^ 1]))
    await #expect(throws: CryptStoreError.authenticationOrCorruption) {
        try await fixture.store.read(path: "/Archive/independent.bin", offset: 1, length: 100)
    }
    await #expect(throws: CryptStoreError.authenticationOrCorruption) { try await fixture.store.checksum(path: "/Archive/independent.bin") }
}

@Test func cryptResumeUsesNewNonceAndPreservesTailForDirectWrites() async throws {
    let fixture = try CryptFixture()
    defer { fixture.cleanup() }
    let prefix = CryptFixture.data(65536 + 13), suffix = Data("resumed suffix".utf8)
    try await fixture.store.write(path: "/.synco-resume", offset: 0, data: prefix)
    let rawPath = try #require(try await fixture.base.list(path: "/").first?.path)
    let firstHeader = try await fixture.base.read(path: rawPath, offset: 0, length: 32)
    let reopened = try fixture.reopen()
    try await reopened.prepareUpload(path: "/.synco-resume")
    try await reopened.write(path: "/.synco-resume", offset: Int64(prefix.count), data: suffix)
    try await reopened.finishUpload(path: "/.synco-resume")
    #expect(try await fixture.base.read(path: rawPath, offset: 0, length: 32) != firstHeader)
    let combined = prefix + suffix
    #expect(try await reopened.checksum(path: "/.synco-resume") == CryptFixture.hash(combined))
    try await reopened.write(path: "/.synco-resume", offset: 7, data: Data([1, 2, 3]))
    var replaced = combined
    replaced.replaceSubrange(7..<10, with: [1, 2, 3])
    #expect(try await reopened.read(path: "/.synco-resume", offset: 0, length: replaced.count) == replaced)
    // A fully resumed upload has no further write calls.
    try await reopened.prepareUpload(path: "/.synco-resume")
    try await reopened.finishUpload(path: "/.synco-resume")
    #expect(try await reopened.checksum(path: "/.synco-resume") == CryptFixture.hash(replaced))
}

private struct CryptCopyStore: RemoteStore {
    let base: LocalRemoteStore
    var publicationMode: PublicationMode { .copyPreservingSource }
    var supportsConditionalReplacement: Bool { true }
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry { try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { throw CoreKitError.remote("Atomic move unavailable.") }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
    func publish(from: String, to: String) async throws {
        let size = try await base.stat(path: from).size
        let temporary = "/.synco-copy-" + UUID().uuidString
        try await base.write(path: temporary, offset: 0, data: base.read(path: from, offset: 0, length: Int(size)))
        do { try await base.move(from: temporary, to: to) }
        catch { try? await base.remove(path: temporary); throw error }
    }
    func replace(from: String, to: String, expectedVersion: String) async throws {
        // This fixture checks the wrapper's version mapping; it is not a production CAS implementation.
        guard try await base.stat(path: to).version == expectedVersion else { throw CoreKitError.itemChanged(to) }
        let size = try await base.stat(path: from).size
        try await base.remove(path: to)
        try await base.write(path: to, offset: 0, data: base.read(path: from, offset: 0, length: Int(size)))
    }
}

@Test func cryptPublicationNoClobberAndCopySourcePreservation() async throws {
    let fixture = try CryptFixture()
    defer { fixture.cleanup() }
    try await fixture.store.write(path: "/source", offset: 0, data: Data("source".utf8))
    try await fixture.store.write(path: "/occupied", offset: 0, data: Data("keep".utf8))
    await #expect(throws: (any Error).self) { try await fixture.store.publish(from: "/source", to: "/occupied") }
    #expect(try await fixture.store.read(path: "/occupied", offset: 0, length: 10) == Data("keep".utf8))
    #expect(try await fixture.store.read(path: "/source", offset: 0, length: 10) == Data("source".utf8))
    let copy = try CryptStore(base: CryptCopyStore(base: fixture.base), password: CryptFixture.password,
                             password2: CryptFixture.salt, helperURL: CryptFixture.helper)
    #expect(copy.publicationMode == .copyPreservingSource)
    try await copy.publish(from: "/source", to: "/copied")
    #expect(try await copy.checksum(path: "/source") == copy.checksum(path: "/copied"))
    try await fixture.store.move(from: "/copied", to: "/moved")
    #expect(try await fixture.store.checksum(path: "/moved") == CryptFixture.hash(Data("source".utf8)))
    #expect(copy.supportsConditionalReplacement)
    let expected = try await copy.stat(path: "/occupied").version
    try await copy.replace(from: "/source", to: "/occupied", expectedVersion: expected)
    #expect(try await copy.checksum(path: "/occupied") == CryptFixture.hash(Data("source".utf8)))
    #expect(try await copy.checksum(path: "/source") == CryptFixture.hash(Data("source".utf8)))
    await #expect(throws: CoreKitError.itemChanged("/occupied")) {
        try await copy.replace(from: "/source", to: "/occupied", expectedVersion: expected)
    }
}

@Test func cryptRangesAndStagingValidation() async throws {
    let fixture = try CryptFixture()
    defer { fixture.cleanup() }
    let marker = Data("public-test-only-plaintext-marker-must-never-appear-in-staging".utf8)
    let existing = Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil))
    try await fixture.store.prepareUpload(path: "/.synco-staging")
    try await fixture.store.write(path: "/.synco-staging", offset: 0, data: marker)
    for directory in try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
        where !existing.contains(directory) && directory.lastPathComponent.hasPrefix("syncophant-crypt-") {
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let ciphertext = directory.appendingPathComponent("ciphertext")
        if FileManager.default.fileExists(atPath: ciphertext.path) {
            #expect((try FileManager.default.attributesOfItem(atPath: ciphertext.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let file = try FileHandle(forReadingFrom: ciphertext)
            defer { try? file.close() }
            #expect(try file.read(upToCount: 4096)?.range(of: marker) == nil)
        }
    }
    try await fixture.store.finishUpload(path: "/.synco-staging")
    await #expect(throws: CoreKitError.invalidRange) { try await fixture.store.read(path: "/.synco-staging", offset: -1, length: 1) }
    await #expect(throws: CoreKitError.invalidRange) { try await fixture.store.read(path: "/.synco-staging", offset: 0, length: PathRules.maximumReadLength + 1) }
    #expect(try await fixture.store.read(path: "/.synco-staging", offset: Int64.max, length: 0).isEmpty)
    #expect(try await fixture.store.read(path: "/.synco-staging", offset: Int64(marker.count + 10), length: 10).isEmpty)
}

private struct CryptWeakRevisionStore: RemoteStore {
    let base: LocalRemoteStore
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry {
        var entry = try await base.stat(path: path)
        entry.modifiedAt = Date(timeIntervalSince1970: 1)
        entry.remoteRevision = nil; entry.contentHash = nil
        return entry
    }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { try await base.checksum(path: path) }
}

@Test func cryptVersionFallsBackToActualCiphertextHash() async throws {
    let fixture = try CryptFixture()
    defer { fixture.cleanup() }
    let weak = try CryptStore(base: CryptWeakRevisionStore(base: fixture.base), password: CryptFixture.password,
                             password2: CryptFixture.salt, helperURL: CryptFixture.helper)
    try await weak.write(path: "/file", offset: 0, data: Data("first".utf8))
    let before = try await weak.stat(path: "/file")
    try await weak.write(path: "/file", offset: 0, data: Data("other".utf8))
    let after = try await weak.stat(path: "/file")
    #expect(before.size == after.size)
    #expect(before.modifiedAt == after.modifiedAt)
    #expect(before.version != after.version)
    #expect(after.remoteRevision?.contains("ciphertext-sha256:") == true)
    #expect(after.contentHash == nil)
}

private struct CryptStalledHelper {
    let directory: URL
    let executable: URL

    init(body: String = "exec /bin/sleep 60\n") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CryptHelperTests-" + UUID().uuidString)
        executable = directory.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let script = "#!/bin/sh\nIFS= read -r initial\nprintf '%s\\n' '{\"name\":\"rclone-crypt-v1.75.2\"}'\n" + body
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func bridge() -> CryptBridge { CryptBridge(executable: executable, password: "public-test-password", password2: "") }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Test func cryptStalledReadAndQueuedWaiterCancelPromptly() async throws {
    let helper = try CryptStalledHelper()
    defer { helper.cleanup() }
    let bridge = helper.bridge()
    let owner = Task { try await bridge.command(.init(op: "encode", path: "file")) }
    try await Task.sleep(for: .milliseconds(250))
    let waiter = Task { try await bridge.command(.init(op: "encode", path: "another")) }
    try await Task.sleep(for: .milliseconds(150))
    let start = ContinuousClock.now
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(start.duration(to: .now) < .seconds(2))
    owner.cancel()
    await #expect(throws: CancellationError.self) { try await owner.value }
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func cryptStalledWriteCancelsAndDeadHelperCannotSignalApp() async throws {
    let helper = try CryptStalledHelper()
    defer { helper.cleanup() }
    let bridge = helper.bridge(), data = Data(repeating: 7, count: 16 * 1024 * 1024)
    let write = Task { try await bridge.command(.init(op: "append", data: data, session: "fixture")) }
    try await Task.sleep(for: .milliseconds(250))
    let start = ContinuousClock.now
    write.cancel()
    await #expect(throws: CancellationError.self) { try await write.value }
    #expect(start.duration(to: .now) < .seconds(2))
    let dead = try CryptStalledHelper(body: "exit 0\n")
    defer { dead.cleanup() }
    await #expect(throws: CryptStoreError.helperProtocol) {
        try await dead.bridge().command(.init(op: "append", data: data, session: "fixture"))
    }
}

@Test func cryptStalledHelperHasThirtySecondDeadline() async throws {
    let helper = try CryptStalledHelper()
    defer { helper.cleanup() }
    let bridge = helper.bridge(), start = ContinuousClock.now
    await #expect(throws: CryptStoreError.helperProtocol) {
        try await bridge.command(.init(op: "encode", path: "file"))
    }
    let elapsed = start.duration(to: .now)
    #expect(elapsed >= .seconds(29))
    #expect(elapsed < .seconds(35))
}
