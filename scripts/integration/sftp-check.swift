import Foundation
import CryptoKit
import Darwin

@main
struct SFTPIntegrationCheck {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["SYNCOPHANT_TEST_ROOT"], let user = env["SYNCOPHANT_TEST_USER"],
              let keyFile = env["SYNCOPHANT_TEST_KEY"], let expectedFingerprint = env["SYNCOPHANT_TEST_FINGERPRINT"],
              let portText = env["SYNCOPHANT_TEST_PORT"], let port = Int(portText) else {
            fatalError("Run scripts/integration/sftp.sh, which supplies an isolated local server.")
        }
        let fingerprint = try await SFTPStore.probeHostKey(host: "127.0.0.1", port: port)
        precondition(fingerprint == expectedFingerprint, "SSH fingerprint must match independently generated host key")
        let privateKey = try String(contentsOfFile: keyFile, encoding: .utf8)
        let connection = StorageConnection(name: "Local integration test", host: "127.0.0.1", port: port,
                                           username: user, rootPath: root, hostKeyFingerprint: fingerprint)
        var untrusted = connection
        untrusted.hostKeyFingerprint = "SHA256:wrong"
        do {
            _ = try await SFTPStore(connection: untrusted, password: nil, privateKey: privateKey).list(path: "/")
            fatalError("Changed host key was trusted")
        } catch CoreKitError.hostKeyMismatch {}
        for authentication in [SSHAuthentication.password("unused-loopback-password"), .agent(socketPath: "/missing-loopback-agent")] {
            do {
                _ = try await SFTPStore(connection: untrusted, authentication: authentication).list(path: "/")
                fatalError("Host-key mismatch reached authentication")
            } catch CoreKitError.hostKeyMismatch {}
        }
        if let socket = env["SYNCOPHANT_TEST_AGENT_SOCKET"] {
            let agent = SFTPStore(connection: connection, authentication: .agent(socketPath: socket))
            let entries = try await agent.list(path: "/")
            precondition(entries.isEmpty)
            await agent.disconnect()
            let delegated = SFTPStore(connection: connection, authentication: .agent(socketPath: "/must-not-open-agent.sock"),
                                      agentSigner: SSHAgentSocketSigner(socketPath: socket))
            let delegatedEntries = try await delegated.list(path: "/")
            precondition(delegatedEntries.isEmpty, "Delegated agent transport could not authenticate")
            await delegated.disconnect()
        }
        let store = SFTPStore(connection: connection, authentication: .privateKey(contents: privateKey, passphrase: nil))
        let generated = try SSHLocalTools.generateKeyPair()
        try await store.installPublicKey(generated.publicKey, hetzner: false)
        let authorizedKeys = URL(fileURLWithPath: env["SYNCOPHANT_TEST_PROOF"]!).appendingPathComponent("home/.ssh/authorized_keys")
        let originalPublicKey = try String(contentsOfFile: keyFile + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = try String(contentsOf: authorizedKeys, encoding: .utf8)
        precondition(installed.contains(originalPublicKey) && installed.contains(generated.publicKey), "Installing a key replaced existing keys")
        let generatedStore = SFTPStore(connection: connection, authentication: .privateKey(contents: generated.privateKey, passphrase: nil))
        let generatedEntries = try await generatedStore.list(path: "/")
        precondition(generatedEntries.isEmpty)
        await generatedStore.disconnect()
        try await store.createDirectory(path: "/documents")
        let data = Data((0..<2_500_123).map { UInt8($0 % 251) })
        let source = URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("source.bin")
        try data.write(to: source)
        let name = "/documents/a 'quoted' $dollar.bin"
        let engine = TransferEngine(store: store)
        let receipt = try await engine.upload(localURL: source, remotePath: name)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        precondition(receipt.verified && receipt.checksum == digest && receipt.remotePath == name)
        let chunk = try await store.read(path: name, offset: 1_234_567, length: 100_003)
        precondition(chunk == data.subdata(in: 1_234_567..<1_334_570), "SFTP range contents differ")
        let firstList = try await store.list(path: "/documents")
        precondition(firstList.count == 1 && firstList[0].size == Int64(data.count))
        let duplicate = try await engine.upload(localURL: source, remotePath: name)
        precondition(duplicate.remotePath != name, "Existing file was overwritten")
        let originalHash = try await store.checksum(path: name)
        precondition(originalHash == digest)
        try await store.move(from: name, to: "/documents/renamed.bin")
        let renamed = try await store.stat(path: "/documents/renamed.bin")
        precondition(renamed.size == Int64(data.count))
        try await checkVersionsAndMetadata(store, root: URL(fileURLWithPath: root), environment: env)
        try await store.remove(path: "/documents/renamed.bin")
        try await store.remove(path: duplicate.remotePath)
        try await store.remove(path: "/documents")
        let remaining = try await store.list(path: "/")
        precondition(remaining.isEmpty, "Partial uploads or unexpected files were left behind")
        await store.disconnect()
        print("Local OpenSSH integration passed [\(env["SYNCOPHANT_TEST_STAT_MODE"] ?? "unknown")]: private-key/agent auth, key installation preserving existing keys, host-key rejection, quoted paths, verified upload, seek reads, no-clobber, revision replacement detection, rename and delete.")
    }

    static func commandCount(_ name: String, environment: [String: String]) throws -> Int {
        let url = URL(fileURLWithPath: environment["SYNCOPHANT_TEST_PROOF"]!).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
    }

    static func checkVersionsAndMetadata(_ store: SFTPStore, root: URL, environment: [String: String]) async throws {
        let mode = environment["SYNCOPHANT_TEST_STAT_MODE"]!
        let url = root.appendingPathComponent("versions.bin")
        let bytes = Data(repeating: 42, count: 5 * 1024 * 1024)
        try bytes.write(to: url)
        var info = Darwin.stat()
        precondition(url.path.withCString { lstat($0, &info) } == 0)
        let times = [info.st_atimespec, info.st_mtimespec]
        let before = try await store.stat(path: "/versions.bin")
        precondition((before.remoteRevision != nil) == (mode != "fallback"))
        precondition((before.contentHash != nil) == (mode == "fallback"))
        let warm = try await store.read(path: "/versions.bin", offset: 123, length: 4096)
        precondition(warm == bytes.subdata(in: 123..<4219))
        let handle = try FileHandle(forWritingTo: url)
        let changed = Data(repeating: 84, count: bytes.count)
        try handle.write(contentsOf: changed)
        precondition(futimens(handle.fileDescriptor, times) == 0)
        try handle.close()
        let rewritten = try await store.stat(path: "/versions.bin")
        precondition(before.size == rewritten.size && before.modifiedAt == rewritten.modifiedAt && before.version != rewritten.version)
        let reread = try await store.read(path: "/versions.bin", offset: 123, length: 4096)
        precondition(reread == changed.subdata(in: 123..<4219), "Warm bytes survived a same-size/same-mtime rewrite")
        let replacement = root.appendingPathComponent("replacement.bin")
        let third = Data(repeating: 126, count: bytes.count)
        try third.write(to: replacement)
        let fd = Darwin.open(replacement.path, O_WRONLY)
        precondition(fd >= 0 && futimens(fd, times) == 0)
        Darwin.close(fd)
        precondition(rename(replacement.path, url.path) == 0)
        let replaced = try await store.stat(path: "/versions.bin")
        precondition(replaced.size == before.size && replaced.modifiedAt == before.modifiedAt && replaced.version != rewritten.version)
        let replacedRead = try await store.read(path: "/versions.bin", offset: 123, length: 4096)
        precondition(replacedRead == third.subdata(in: 123..<4219), "Warm bytes survived an inode replacement")
        let tail = try await store.read(path: "/versions.bin", offset: Int64(bytes.count - 5), length: 999)
        precondition(tail == Data(repeating: 126, count: 5))
        let beyond = try await store.read(path: "/versions.bin", offset: Int64(bytes.count + 1), length: 99)
        precondition(beyond.isEmpty)
        try await store.remove(path: "/versions.bin")

        let race = root.appendingPathComponent("race.bin")
        let marker = URL(fileURLWithPath: environment["SYNCOPHANT_TEST_PROOF"]!).appendingPathComponent("read-race")
        for warmCache in [false, true] {
            try Data("first".utf8).write(to: race)
            _ = try await store.stat(path: "/race.bin") // Finish format detection before arming the checkpoint barrier.
            if warmCache { _ = try await store.read(path: "/race.bin", offset: 0, length: 5) }
            try Data("0".utf8).write(to: marker)
            do {
                _ = try await store.read(path: "/race.bin", offset: 0, length: 5)
                fatalError("A \(warmCache ? "warm" : "cold") read returned bytes across observed revisions")
            } catch CoreKitError.itemChanged("/race.bin") {}
            let checkpoints = try String(contentsOf: marker, encoding: .utf8)
            precondition(checkpoints == "2")
            try FileManager.default.removeItem(at: marker)
        }
        try await store.remove(path: "/race.bin")

        let outside = root.deletingLastPathComponent().appendingPathComponent("sentinel")
        try Data("outside root".utf8).write(to: outside)
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        do {
            _ = try await store.read(path: "/escape", offset: 0, length: 10)
            fatalError("SFTP followed a symlink outside its root")
        } catch CoreKitError.unsafePath {}
        let visible = try await store.list(path: "/")
        precondition(!visible.contains { $0.name == "escape" })
        try FileManager.default.removeItem(at: escape)
        try FileManager.default.removeItem(at: outside)

        if mode != "fallback" {
            let large = root.appendingPathComponent("large-sparse.bin")
            FileManager.default.createFile(atPath: large.path, contents: nil)
            let largeHandle = try FileHandle(forWritingTo: large)
            let size: UInt64 = 16 * 1024 * 1024 * 1024
            try largeHandle.truncate(atOffset: size)
            try largeHandle.close()
            let checksums = try commandCount("checksums", environment: environment)
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<10 {
                let entry = try await store.stat(path: "/large-sparse.bin")
                precondition(entry.size == Int64(size) && entry.remoteRevision != nil && entry.contentHash == nil)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let checksumCount = try commandCount("checksums", environment: environment)
            precondition(checksumCount == checksums, "Metadata hashed a 16 GiB file")
            print("[\(mode)] 10 metadata stats of a 16 GiB sparse file: \(String(format: "%.3f", elapsed)) s, zero checksum commands.")
            try await store.remove(path: "/large-sparse.bin")
        }

        try await store.createDirectory(path: "/batch")
        for index in 0..<40 { try Data([UInt8(index)]).write(to: root.appendingPathComponent("batch/\(index)")) }
        let stats = try commandCount("stats", environment: environment)
        let checksums = try commandCount("checksums", environment: environment)
        let entries = try await store.list(path: "/batch")
        precondition(entries.count == 40 && entries.allSatisfy { $0.contentHash == nil })
        if mode != "fallback" {
            precondition(entries.allSatisfy { $0.remoteRevision != nil })
            let calls = try commandCount("stats", environment: environment) - stats
            precondition(calls == 3, "40 regular files should use three batched stat commands")
            print("[\(mode)] 40-file listing: \(calls) stat execs, zero checksum commands.")
        }
        let finalChecksums = try commandCount("checksums", environment: environment)
        precondition(finalChecksums == checksums)
        for entry in entries { try await store.remove(path: entry.path) }
        try await store.remove(path: "/batch")
    }
}
