import CryptoKit
import Darwin
import Foundation

public enum CryptStoreError: Error, LocalizedError, Equatable, Sendable {
    case passwordRequired, helperUnavailable, helperProtocol, authenticationOrCorruption, uploadInProgress

    public var errorDescription: String? {
        switch self {
        case .passwordRequired: "An encryption password is required."
        case .helperUnavailable: "The bundled rclone encryption helper is unavailable."
        case .helperProtocol: "The encryption helper stopped or returned an invalid response."
        case .authenticationOrCorruption: "The encryption password or salt is incorrect, or the encrypted vault is damaged."
        case .uploadInProgress: "An operation on this encrypted file is already in progress."
        }
    }
}

/// rclone crypt: standard/base32 encrypted names, encrypted directory names and authenticated data.
/// Passwords are supplied from the caller's Keychain; this store never persists them.
public actor CryptStore: RemoteStore {
    public nonisolated let publicationMode: PublicationMode
    public nonisolated let supportsDirectoryMove: Bool
    public nonisolated let supportsConditionalReplacement: Bool
    private let base: any RemoteStore
    private let bridge: CryptBridge
    private var uploads: [String: CryptUpload] = [:]
    private var operating: Set<String> = []
    private let chunkSize = 1024 * 1024

    public init(base: any RemoteStore, password: String, password2: String = "", helperURL: URL) throws {
        guard !password.isEmpty else { throw CryptStoreError.passwordRequired }
        guard helperURL.isFileURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw CryptStoreError.helperUnavailable
        }
        self.base = base
        publicationMode = base.publicationMode
        supportsDirectoryMove = base.supportsDirectoryMove
        supportsConditionalReplacement = base.supportsConditionalReplacement
        bridge = CryptBridge(executable: helperURL, password: password, password2: password2)
    }

    public func list(path: String) async throws -> [RemoteEntry] {
        let path = try PathRules.normalize(path)
        let encrypted = try await encryptedPath(path)
        let children = try await base.list(path: encrypted)
        var entries: [RemoteEntry] = []
        for child in children {
            try Task.checkCancellation()
            let response = try await bridge.command(.init(op: "decode", path: child.name))
            guard let name = response.name, !name.contains("/"), name != ".", name != ".." else {
                throw CryptStoreError.authenticationOrCorruption
            }
            let childPath = try PathRules.normalize((path == "/" ? "" : path) + "/" + name)
            guard !PathRules.isTemporary(name) else { continue }
            entries.append(try await mapped(child, path: childPath))
        }
        return entries.sorted { $0.name < $1.name }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let path = try PathRules.normalize(path), encrypted = try await encryptedPath(path)
        let entry = try await snapshot(encrypted)
        return try await mapped(entry, path: path)
    }

    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        try PathRules.validateRange(offset: offset, length: length)
        let path = try PathRules.normalize(path), encrypted = try await encryptedPath(path)
        let before = try await snapshot(encrypted)
        guard !before.isDirectory else { throw CoreKitError.unsafePath(path) }
        let size = try await plaintextSize(before.size)
        let data = try await decrypted(encrypted, size: size, offset: offset, length: length)
        guard try await snapshot(encrypted).version == before.version else { throw CoreKitError.itemChanged(path) }
        return data
    }

    public func checksum(path: String) async throws -> String {
        let path = try PathRules.normalize(path), encrypted = try await encryptedPath(path)
        let before = try await snapshot(encrypted)
        guard !before.isDirectory else { throw CoreKitError.unsafePath(path) }
        let size = try await plaintextSize(before.size)
        var hash = SHA256(), offset: Int64 = 0
        // Even empty files must have a valid rclone header.
        if size == 0 { _ = try await decryptHeader(encrypted) }
        while offset < size {
            try Task.checkCancellation()
            let data = try await decrypted(encrypted, size: size, offset: offset, length: Int(min(Int64(chunkSize), size - offset)))
            guard !data.isEmpty else { throw CryptStoreError.authenticationOrCorruption }
            hash.update(data: data)
            offset += Int64(data.count)
        }
        guard try await snapshot(encrypted).version == before.version else { throw CoreKitError.itemChanged(path) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func prepareUpload(path: String) async throws {
        let path = try PathRules.normalize(path)
        try beginOperation(path)
        defer { operating.remove(path) }
        if let previous = uploads.removeValue(forKey: path) {
            _ = try? await bridge.command(.init(op: "abort", session: previous.id))
        }
        let encrypted = try await encryptedPath(path)
        let original: RemoteEntry?
        do { original = try await snapshot(encrypted) } catch CoreKitError.notFound { original = nil }
        guard original?.isDirectory != true else { throw CoreKitError.unsafePath(path) }
        let size = if let original { try await plaintextSize(original.size) } else { Int64(0) }
        let upload = try CryptUpload(original: original, originalSize: size)
        _ = try await bridge.command(.init(op: "begin", path: upload.ciphertext.path, session: upload.id))
        uploads[path] = upload
    }

    public func write(path: String, offset: Int64, data: Data) async throws {
        try PathRules.validateRange(offset: offset, length: data.count)
        let path = try PathRules.normalize(path)
        let standalone = uploads[path] == nil
        if standalone { try await prepareUpload(path: path) }
        do {
            try beginOperation(path)
            do {
                guard let upload = uploads[path], !upload.finished else { throw CryptStoreError.uploadInProgress }
                let encrypted = try await encryptedPath(path)
                if !upload.started {
                    try await copyOriginal(upload, encrypted: encrypted, through: min(offset, upload.originalSize))
                    var gap = offset - upload.offset
                    while gap > 0 {
                        let count = Int(min(Int64(chunkSize), gap))
                        try await append(Data(count: count), upload: upload)
                        gap -= Int64(count)
                    }
                    upload.started = true
                }
                guard upload.offset == offset else { throw CoreKitError.invalidRange }
                try await append(data, upload: upload)
                operating.remove(path)
            } catch { operating.remove(path); throw error }
            if standalone { try await finishUpload(path: path) }
        } catch {
            if standalone { await discardUpload(path) }
            throw error
        }
    }

    public func finishUpload(path: String) async throws {
        let path = try PathRules.normalize(path)
        try beginOperation(path)
        defer { operating.remove(path) }
        guard let upload = uploads[path] else { return }
        let encrypted = try await encryptedPath(path)
        if !upload.finished {
            // RemoteStore writes preserve the existing tail; resumable upload prefixes are re-encrypted.
            try await copyOriginal(upload, encrypted: encrypted, through: upload.originalSize)
            if let original = upload.original {
                guard try await snapshot(encrypted).version == original.version else { throw CoreKitError.itemChanged(path) }
            } else {
                do { _ = try await base.stat(path: encrypted); throw CoreKitError.alreadyExists(path) }
                catch CoreKitError.notFound { }
            }
            _ = try await bridge.command(.init(op: "finish", session: upload.id))
            upload.finished = true
        }
        // Only encrypted bytes reach the underlying driver's own upload spool or remote transport.
        try await base.prepareUpload(path: encrypted)
        let file = try FileHandle(forReadingFrom: upload.ciphertext)
        defer { try? file.close() }
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            // Avoid Foundation autoreleased read buffers accumulating over a multi-gigabyte upload.
            let count = Darwin.read(file.fileDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CoreKitError.remote("Cannot read encrypted upload staging file.") }
            if count == 0 { break }
            try await base.write(path: encrypted, offset: offset, data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        try await base.finishUpload(path: encrypted)
        uploads.removeValue(forKey: path)
    }

    public func createDirectory(path: String) async throws {
        try await base.createDirectory(path: encryptedPath(path))
    }

    public func move(from: String, to: String) async throws {
        let source = try PathRules.normalize(from), target = try PathRules.normalize(to)
        try beginPublication(source, target)
        defer { operating.remove(source); operating.remove(target) }
        try await base.move(from: encryptedPath(source), to: encryptedPath(target))
    }

    public func publish(from: String, to: String) async throws {
        let source = try PathRules.normalize(from), target = try PathRules.normalize(to)
        try beginPublication(source, target)
        defer { operating.remove(source); operating.remove(target) }
        try await base.publish(from: encryptedPath(source), to: encryptedPath(target))
    }

    public func replace(from: String, to: String, expectedVersion: String) async throws {
        let source = try PathRules.normalize(from), target = try PathRules.normalize(to)
        try beginPublication(source, target)
        defer { operating.remove(source); operating.remove(target) }
        let encryptedSource = try await encryptedPath(source), encryptedTarget = try await encryptedPath(target)
        let raw = try await base.stat(path: encryptedTarget)
        let verified = try await snapshot(encryptedTarget, initial: raw)
        guard try await mapped(verified, path: target).version == expectedVersion else { throw CoreKitError.itemChanged(target) }
        // The backend compares its own ciphertext version atomically, not the plaintext view's version.
        try await base.replace(from: encryptedSource, to: encryptedTarget, expectedVersion: raw.version)
    }

    public func verifyWritePreconditions(path: String) async throws {
        try await base.verifyWritePreconditions(path: encryptedPath(PathRules.normalize(path)))
    }

    public func remove(path: String) async throws {
        let path = try PathRules.normalize(path)
        try beginOperation(path)
        defer { operating.remove(path) }
        await discardUpload(path)
        try await base.remove(path: encryptedPath(path))
    }

    private func beginOperation(_ path: String) throws {
        guard operating.insert(path).inserted else { throw CryptStoreError.uploadInProgress }
    }

    private func beginPublication(_ source: String, _ target: String) throws {
        guard uploads[source] == nil, uploads[target] == nil,
              !operating.contains(source), !operating.contains(target) else { throw CryptStoreError.uploadInProgress }
        operating.insert(source); operating.insert(target)
    }

    private func discardUpload(_ path: String) async {
        if let upload = uploads.removeValue(forKey: path), !upload.finished {
            _ = try? await bridge.command(.init(op: "abort", session: upload.id))
        }
    }

    private func encryptedPath(_ path: String) async throws -> String {
        let path = try PathRules.normalize(path)
        if path == "/" { return path }
        let response = try await bridge.command(.init(op: "encode", path: String(path.dropFirst())))
        guard let name = response.name else { throw CryptStoreError.helperProtocol }
        return try PathRules.normalize("/" + name)
    }

    private func plaintextSize(_ size: Int64) async throws -> Int64 {
        guard size >= 0 else { throw CryptStoreError.authenticationOrCorruption }
        return try await bridge.command(.init(op: "size", size: size)).size ?? 0
    }

    private func mapped(_ entry: RemoteEntry, path: String) async throws -> RemoteEntry {
        let size = entry.isDirectory ? entry.size : try await plaintextSize(entry.size)
        // Ciphertext hashes are revision evidence, never a claimed plaintext checksum.
        return RemoteEntry(name: PathRules.name(of: path), path: path, isDirectory: entry.isDirectory,
                           size: size, modifiedAt: entry.modifiedAt,
                           remoteRevision: entry.remoteRevision.map { "rclone-crypt-v1:" + $0 })
    }

    private func snapshot(_ encrypted: String, initial: RemoteEntry? = nil) async throws -> RemoteEntry {
        var entry: RemoteEntry
        if let initial { entry = initial } else { entry = try await base.stat(path: encrypted) }
        if !entry.isDirectory, entry.remoteRevision == nil {
            let hash = try await base.checksum(path: encrypted)
            let after = try await base.stat(path: encrypted)
            guard entry.version == after.version else { throw CoreKitError.itemChanged(encrypted) }
            entry.remoteRevision = "ciphertext-sha256:" + hash
        }
        return entry
    }

    private func decrypted(_ encrypted: String, size: Int64, offset: Int64, length: Int) async throws -> Data {
        guard offset < size, length > 0 else { return Data() }
        let count = Int(min(Int64(length), size - offset)), base = base
        let response = try await bridge.command(.init(op: "decrypt", offset: offset, length: Int64(count))) { start, length in
            var bytes = Data(), cursor = start
            while bytes.count < length {
                try Task.checkCancellation()
                let part = try await base.read(path: encrypted, offset: cursor, length: min(1024 * 1024, length - bytes.count))
                if part.isEmpty { break }
                guard part.count <= length - bytes.count else { throw CryptStoreError.helperProtocol }
                bytes.append(part); cursor += Int64(part.count)
            }
            return bytes
        }
        let data = response.data ?? Data()
        guard data.count == count else { throw CryptStoreError.authenticationOrCorruption }
        return data
    }

    private func decryptHeader(_ encrypted: String) async throws -> Data {
        let base = base
        let response = try await bridge.command(.init(op: "decrypt", offset: 0, length: 0)) { offset, length in
            try await base.read(path: encrypted, offset: offset, length: length)
        }
        return response.data ?? Data()
    }

    private func append(_ data: Data, upload: CryptUpload) async throws {
        _ = try await bridge.command(.init(op: "append", data: data, session: upload.id))
        upload.offset += Int64(data.count)
    }

    private func copyOriginal(_ upload: CryptUpload, encrypted: String, through end: Int64) async throws {
        while upload.offset < end {
            let data = try await decrypted(encrypted, size: upload.originalSize, offset: upload.offset,
                                           length: Int(min(Int64(chunkSize), end - upload.offset)))
            guard !data.isEmpty else { throw CryptStoreError.authenticationOrCorruption }
            try await append(data, upload: upload)
        }
    }
}

private final class CryptUpload {
    let id = UUID().uuidString
    let directory: URL
    let ciphertext: URL
    let original: RemoteEntry?
    let originalSize: Int64
    var offset: Int64 = 0
    var started = false
    var finished = false

    init(original: RemoteEntry?, originalSize: Int64) throws {
        var template = Array((FileManager.default.temporaryDirectory.path + "/syncophant-crypt-XXXXXX").utf8CString)
        guard let path = mkdtemp(&template) else { throw CoreKitError.remote("Cannot create encrypted upload staging directory.") }
        directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        ciphertext = directory.appendingPathComponent("ciphertext")
        self.original = original
        self.originalSize = originalSize
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
