import Foundation
import Security

/// A storage server that answers but breaks a promise the sync engine depends on.
public enum CompatibilityProblem: Error, LocalizedError, Equatable, Sendable {
    case overwritesExisting, acceptsStaleWrites, noRangeReads, noRevisions, folderDeleteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .overwritesExisting:
            "This server replaced a file it was told to keep, so it could overwrite your files. Syncophant can’t use it safely."
        case .acceptsStaleWrites:
            "This server accepted a change based on an outdated version, so two Macs could overwrite each other. Syncophant can’t use it safely."
        case .noRangeReads:
            "This server ignores partial downloads, so files couldn’t open without downloading them in full."
        case .noRevisions:
            "This server doesn’t report file versions, so Syncophant can’t tell when a file changed."
        case .folderDeleteFailed(let path):
            "Syncophant couldn’t delete its empty test folder \(path), so deleting folders here won’t work. Remove that folder, then check the server’s settings."
        }
    }
}

/// Proves, against the real server, the guarantees `TransferEngine` relies on: exact read-back, range reads,
/// file revisions, no-clobber publication, refused stale writes, conditional replacement and folder deletion.
/// Everything happens in a new test folder at the root, which is removed afterwards.
public enum StoreCompatibility {
    /// Returns the round-trip time of the 1 MiB write and read-back.
    public static func verify(_ store: any RemoteStore) async throws -> TimeInterval {
        let folder = "/.syncophant-check-" + UUID().uuidString.lowercased()
        let original = "\(folder)/original", candidate = "\(folder)/candidate"
        try await store.createDirectory(path: folder)
        let elapsed: TimeInterval
        do {
            let first = try random(1_048_576), second = try random(65_536)
            let started = ProcessInfo.processInfo.systemUptime
            try await put(store, original, first)
            guard try await store.read(path: original, offset: 0, length: first.count) == first else { throw CoreKitError.checksumMismatch }
            elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - started)

            let slice: Data
            do { slice = try await store.read(path: original, offset: 300_000, length: 4096) }
            catch is CancellationError { throw CancellationError() }
            catch { throw CompatibilityProblem.noRangeReads }
            guard slice == first.subdata(in: 300_000..<304_096) else { throw CompatibilityProblem.noRangeReads }

            let entry = try await store.stat(path: original)
            guard entry.size == Int64(first.count), !entry.version.isEmpty else { throw CompatibilityProblem.noRevisions }

            try await put(store, candidate, second)
            do {
                try await store.publish(from: candidate, to: original)
                throw CompatibilityProblem.overwritesExisting
            } catch CoreKitError.alreadyExists { } catch CoreKitError.itemChanged { }
            guard try await store.read(path: original, offset: 0, length: first.count) == first else { throw CompatibilityProblem.overwritesExisting }

            try await store.verifyWritePreconditions(path: original)
            guard try await store.read(path: original, offset: 0, length: first.count) == first else { throw CompatibilityProblem.acceptsStaleWrites }

            if store.supportsConditionalReplacement {
                try await store.replace(from: candidate, to: original, expectedVersion: try await store.stat(path: original).version)
                guard try await store.read(path: original, offset: 0, length: second.count + 1) == second else { throw CoreKitError.checksumMismatch }
            }
        } catch {
            for path in [candidate, original, folder] { try? await store.remove(path: path) }
            throw error
        }
        for path in [candidate, original] {
            do { try await store.remove(path: path) } catch CoreKitError.notFound { }
        }
        do { try await store.remove(path: folder) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CompatibilityProblem.folderDeleteFailed(folder) }
        return elapsed
    }

    /// Writes the way uploads do: an upload session where the store has one, then range writes.
    private static func put(_ store: any RemoteStore, _ path: String, _ data: Data) async throws {
        try await store.prepareUpload(path: path)
        try await store.write(path: path, offset: 0, data: data)
        try await store.finishUpload(path: path)
    }

    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw CoreKitError.remote("Could not generate test bytes.") }
        return Data(bytes)
    }
}
