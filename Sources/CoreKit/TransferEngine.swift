import Foundation
import CryptoKit
import Darwin

/// Only the publication owner can distinguish a safe failure from an unacknowledged rename.
struct PublicationFailure: Error {
    let cause: any Error
    let namespaceSettled: Bool
}

public actor TransferEngine {
    private let store: any RemoteStore
    private let metadata: MetadataStore?
    private let chunkSize = 1024 * 1024
    private var paused = false
    private var bandwidthLimit: Int64?
    private var pendingBytes: Double = 0
    private var bandwidthUpdatedAt = ContinuousClock.now
    private var activeResumeIDs: Set<UUID> = []
    private var heldResumeIDs: Set<UUID> = []
    private var adaptiveBandwidth = false
    private var baselineLatency: Double?
    private var bytesSinceProbe = 0
    private var probingLatency = false

    public init(store: any RemoteStore, metadata: MetadataStore? = nil) {
        self.store = store
        self.metadata = metadata
    }

    public func setPaused(_ paused: Bool) { self.paused = paused }

    /// Holds one resumable upload between chunks, keeping its partial and its connection, until released.
    public func setHeld(_ held: Bool, resumeID: UUID) {
        if held { heldResumeIDs.insert(resumeID) } else { heldResumeIDs.remove(resumeID) }
    }
    public var bandwidthLimitBytesPerSecond: Int64? { bandwidthLimit }

    public func setAdaptiveBandwidth(_ enabled: Bool) {
        guard enabled != adaptiveBandwidth else { return }
        adaptiveBandwidth = enabled
        baselineLatency = nil; bytesSinceProbe = 0
        if enabled { setBandwidthLimit(bytesPerSecond: 20_000_000) }
    }

    private func sampleResponsiveness(parent: String) async throws {
        guard adaptiveBandwidth, !probingLatency else { return }
        probingLatency = true
        defer { probingLatency = false }
        let start = ContinuousClock.now
        _ = try await store.stat(path: parent)
        let elapsed = start.duration(to: .now).components
        let seconds = max(0.000_001, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        if let baseline = baselineLatency {
            let current = bandwidthLimit ?? 20_000_000
            if seconds > max(0.1, baseline * 2) {
                setBandwidthLimit(bytesPerSecond: max(256_000, current * 7 / 10))
            } else {
                setBandwidthLimit(bytesPerSecond: min(100_000_000, current + max(64_000, current / 10)))
            }
            baselineLatency = min(baseline, seconds)
        } else { baselineLatency = seconds }
        bytesSinceProbe = 0
    }

    /// Nil (or a nonpositive value) removes the limit. The budget is shared by all uploads in this engine.
    public func setBandwidthLimit(bytesPerSecond: Int64?) {
        drainBandwidthBudget()
        bandwidthLimit = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        if bandwidthLimit == nil { pendingBytes = 0 }
    }

    private func drainBandwidthBudget() {
        let now = ContinuousClock.now
        let elapsed = bandwidthUpdatedAt.duration(to: now).components
        if let bandwidthLimit {
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            pendingBytes = max(0, pendingBytes - seconds * Double(bandwidthLimit))
        }
        bandwidthUpdatedAt = now
    }

    private func waitForTransferPermission(_ resumeID: UUID? = nil) async throws {
        while true {
            try Task.checkCancellation()
            drainBandwidthBudget()
            let stopped = paused || resumeID.map { heldResumeIDs.contains($0) } == true
            if !stopped, pendingBytes <= 0 { return }
            var delay = 0.05
            if !stopped, let bandwidthLimit { delay = min(delay, pendingBytes / Double(bandwidthLimit)) }
            try await Task.sleep(for: .seconds(delay))
        }
    }

    /// A resume ID retains partials on connection/timeouts and reuses only a verified local prefix.
    /// Cancellation or an invalid partial removes it; retry an invalid partial from scratch.
    public func upload(localURL: URL, remotePath: String, expectedVersion: String? = nil,
                       resumeID: UUID? = nil,
                       progress: (@Sendable (UploadProgress) -> Void)? = nil) async throws -> UploadReceipt {
        guard localURL.isFileURL else { throw CoreKitError.invalidPath(localURL.absoluteString) }
        let fd = Darwin.open(localURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CoreKitError.unsafePath(localURL.path) }
        defer { Darwin.close(fd) }
        return try await upload(fd: fd, remotePath: remotePath, expectedVersion: expectedVersion, resumeID: resumeID, progress: progress)
    }

    public func upload(source: LocalUploadSource, remotePath: String, expectedVersion: String? = nil,
                       resumeID: UUID? = nil, progress: (@Sendable (UploadProgress) -> Void)? = nil) async throws -> UploadReceipt {
        let fd = fcntl(source.descriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw CoreKitError.remote("Could not retain the local upload file.") }
        defer { Darwin.close(fd) }
        return try await upload(fd: fd, remotePath: remotePath, expectedVersion: expectedVersion, resumeID: resumeID, progress: progress)
    }

    private func upload(fd: Int32, remotePath: String, expectedVersion: String?, resumeID: UUID?,
                        progress: (@Sendable (UploadProgress) -> Void)?) async throws -> UploadReceipt {
        let path = try PathRules.normalize(remotePath)
        guard path != "/" else { throw CoreKitError.invalidPath(path) }
        guard PathRules.isVisible(path: path) else { throw CoreKitError.filteredFile(path) }
        var initial = Darwin.stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else { throw CoreKitError.unsafePath("Local upload") }
        let parent = PathRules.parent(of: path)
        let partial = (parent == "/" ? "" : parent) + "/.synco-upload.partial-" + (resumeID ?? UUID()).uuidString
        _ = try PathRules.normalize(partial)
        if let resumeID, !activeResumeIDs.insert(resumeID).inserted {
            throw CoreKitError.alreadyExists(partial)
        }
        defer { if let resumeID { activeResumeIDs.remove(resumeID) } }
        do {
            if adaptiveBandwidth, baselineLatency == nil { try await sampleResponsiveness(parent: parent) }
            var hash = SHA256(), offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            try await waitForTransferPermission(resumeID)
            if resumeID != nil, let previous = try await existing(partial) {
                guard !previous.isDirectory, previous.size >= 0, previous.size <= Int64(initial.st_size) else {
                    throw CoreKitError.checksumMismatch
                }
                // Rebuild the full hash from the local prefix; size alone never proves resumability.
                while offset < previous.size {
                    try await waitForTransferPermission(resumeID)
                    let count = Darwin.pread(fd, &buffer, Int(min(Int64(chunkSize), previous.size - offset)), offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw CoreKitError.sourceChanged }
                    hash.update(data: Data(buffer.prefix(count)))
                    offset += Int64(count)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard try await store.checksum(path: partial).lowercased() == digest else {
                    throw CoreKitError.checksumMismatch
                }
                try await store.prepareUpload(path: partial)
            } else {
                // Create zero-byte uploads too; writes do not truncate existing files.
                try await store.prepareUpload(path: partial)
                try await store.write(path: partial, offset: 0, data: Data())
            }
            progress?(.uploading(completed: offset, total: Int64(initial.st_size)))
            while true {
                try await waitForTransferPermission(resumeID)
                // Keep each limited write to roughly 50 ms of traffic; unlimited uploads retain 1 MiB chunks.
                let readSize = bandwidthLimit.map { Int(min(Int64(chunkSize), max(1, $0 / 20))) } ?? chunkSize
                let count = Darwin.pread(fd, &buffer, readSize, offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CoreKitError.remote("The local file could not be read.")
                }
                if count == 0 { break }
                guard offset <= Int64(initial.st_size) - Int64(count) else { throw CoreKitError.sourceChanged }
                let data = Data(buffer.prefix(count))
                hash.update(data: data)
                try await store.write(path: partial, offset: offset, data: data)
                drainBandwidthBudget()
                if bandwidthLimit != nil { pendingBytes += Double(count) }
                offset += Int64(count)
                bytesSinceProbe += count
                if adaptiveBandwidth, bytesSinceProbe >= 4 * 1024 * 1024 { try await sampleResponsiveness(parent: parent) }
                progress?(.uploading(completed: offset, total: Int64(initial.st_size)))
            }
            try Self.validateSource(fd: fd, initial: initial, size: offset)
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            progress?(.verifying)
            try await store.finishUpload(path: partial)
            let remoteDigest = try await store.checksum(path: partial)
            guard remoteDigest.lowercased() == digest else { throw CoreKitError.checksumMismatch }
            let uploaded = try await store.stat(path: partial)
            guard uploaded.size == offset, !uploaded.isDirectory else { throw CoreKitError.checksumMismatch }
            try await waitForTransferPermission(resumeID)
            let receipt: UploadReceipt
            if let metadata {
                let size = offset
                let sourceSnapshot = initial
                receipt = try await metadata.withPublication {
                    try await self.publishVerified(partial: partial, path: path, expectedVersion: expectedVersion,
                                                   digest: digest, size: size, sourceFD: fd, initial: sourceSnapshot)
                }
            } else {
                do {
                    receipt = try await publishVerified(partial: partial, path: path, expectedVersion: expectedVersion,
                                                        digest: digest, size: offset, sourceFD: fd, initial: initial)
                } catch let failure as PublicationFailure { throw failure.cause }
            }
            try await metadata?.recordVerification(receipt)
            if store.publicationMode == .copyPreservingSource { try? await store.remove(path: partial) }
            progress?(.verified(receipt))
            return receipt
        } catch {
            if resumeID != nil, !Task.isCancelled {
                switch error {
                case CoreKitError.connection, CoreKitError.timeout: throw error
                default: break
                }
            }
            let store = self.store
            // Cleanup must run outside the cancelled task; the source is never removed.
            await Task.detached { try? await store.remove(path: partial) }.value
            throw error
        }
    }

    private static func validateSource(fd: Int32, initial: Darwin.stat, size: Int64) throws {
        try Task.checkCancellation()
        var final = Darwin.stat()
        guard fstat(fd, &final) == 0, initial.st_size == final.st_size, size == Int64(final.st_size),
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else { throw CoreKitError.sourceChanged }
    }

    private func publishVerified(partial: String, path: String, expectedVersion: String?,
                                 digest: String, size: Int64, sourceFD: Int32, initial: Darwin.stat) async throws -> UploadReceipt {
        var namespaceSettled = true
        do {
            try Task.checkCancellation()
            try Self.validateSource(fd: sourceFD, initial: initial, size: size)
            let destination = try await publish(partial: partial, path: path, expectedVersion: expectedVersion,
                                                sourceFD: sourceFD, initial: initial, namespaceSettled: &namespaceSettled)
            let before = try await store.stat(path: destination)
            let checksum = try await store.checksum(path: destination)
            let published = try await store.stat(path: destination)
            guard before.version == published.version, checksum == digest, published.size == size, !published.isDirectory else {
                throw CoreKitError.itemChanged(destination)
            }
            return UploadReceipt(remotePath: destination, checksum: digest, verified: true, remoteVersion: published.version)
        } catch {
            throw PublicationFailure(cause: error, namespaceSettled: namespaceSettled)
        }
    }

    private func existing(_ path: String) async throws -> RemoteEntry? {
        do { return try await store.stat(path: path) }
        catch CoreKitError.notFound { return nil }
    }

    private func conflictPath(_ path: String) throws -> String {
        let name = PathRules.name(of: path)
        let ext = (name as NSString).pathExtension
        let machine = String((Host.current().localizedName ?? "Mac").map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(24))
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let marker = " (conflict \(machine) \(date) \(UUID().uuidString.prefix(6)))"
        let extensionSuffix = ext.isEmpty ? "" : "." + ext
        let keepExtension = (marker + extensionSuffix).utf8.count < 255
        let stem = keepExtension && !ext.isEmpty ? (name as NSString).deletingPathExtension : name
        let suffix = marker + (keepExtension ? extensionSuffix : "")
        let parent = PathRules.parent(of: path)
        // Keep the final component within POSIX NAME_MAX even for long UTF-8 names.
        var shortened = stem
        while (shortened + suffix).utf8.count > 255, !shortened.isEmpty { shortened.removeLast() }
        return try PathRules.normalize((parent == "/" ? "" : parent) + "/" + shortened + suffix)
    }

    private static func renameWasRejected(_ error: any Error) -> Bool {
        switch error {
        case CoreKitError.alreadyExists, CoreKitError.notFound: true
        default: false
        }
    }

    private func moveForPublication(from: String, to: String, namespaceSettled: inout Bool) async throws {
        let previouslySettled = namespaceSettled
        namespaceSettled = false
        do { try await store.publish(from: from, to: to) }
        catch {
            if Self.renameWasRejected(error) { namespaceSettled = previouslySettled }
            throw error
        }
    }

    private func publish(partial: String, path: String, expectedVersion: String?,
                         sourceFD: Int32, initial: Darwin.stat, namespaceSettled: inout Bool) async throws -> String {
        let current = try await existing(path)
        try Self.validateSource(fd: sourceFD, initial: initial, size: Int64(initial.st_size))
        if store.supportsConditionalReplacement, let current, let expectedVersion, current.version == expectedVersion, !current.isDirectory {
            let digest = try await store.checksum(path: path)
            guard try await store.stat(path: path).version == current.version else { throw CoreKitError.itemChanged(path) }
            let backup = try conflictPath(path)
            try await moveForPublication(from: path, to: backup, namespaceSettled: &namespaceSettled)
            let before = try await store.stat(path: backup)
            let backupDigest = try await store.checksum(path: backup)
            let after = try await store.stat(path: backup)
            guard before.version == after.version, backupDigest == digest, after.size == current.size else { throw CoreKitError.itemChanged(backup) }
            namespaceSettled = true
            try Self.validateSource(fd: sourceFD, initial: initial, size: Int64(initial.st_size))
            do {
                namespaceSettled = false
                try await store.replace(from: partial, to: path, expectedVersion: current.version)
                namespaceSettled = true
                return path
            } catch CoreKitError.itemChanged {
                // A rejected conditional write leaves the intervening writer and our previous copy intact.
                namespaceSettled = true
                let conflict = try conflictPath(path)
                try await moveForPublication(from: partial, to: conflict, namespaceSettled: &namespaceSettled)
                namespaceSettled = true
                return conflict
            }
        }
        if store.publicationMode == .atomicMove, let current, let expectedVersion, current.version == expectedVersion, !current.isDirectory {
            let previous = try conflictPath(path)
            try await moveForPublication(from: path, to: previous, namespaceSettled: &namespaceSettled)
            var publicationAttempted = false
            do {
                try Task.checkCancellation()
                try Self.validateSource(fd: sourceFD, initial: initial, size: Int64(initial.st_size))
                publicationAttempted = true
                try await moveForPublication(from: partial, to: path, namespaceSettled: &namespaceSettled)
                namespaceSettled = true
                return path
            } catch {
                // An intervening writer keeps its destination; restore only into a free name.
                let store = self.store
                let restored = await Task.detached {
                    do { try await store.move(from: previous, to: path); return true }
                    catch CoreKitError.alreadyExists { return true }
                    catch { return false }
                }.value
                // A late, unacknowledged publication can still run after a successful rollback.
                namespaceSettled = restored && (!publicationAttempted || Self.renameWasRejected(error))
                if case CoreKitError.alreadyExists = error {
                    let conflict = try conflictPath(path)
                    try Self.validateSource(fd: sourceFD, initial: initial, size: Int64(initial.st_size))
                    try await moveForPublication(from: partial, to: conflict, namespaceSettled: &namespaceSettled)
                    namespaceSettled = restored
                    return conflict
                }
                throw error
            }
        }
        let destination = current == nil ? path : try conflictPath(path)
        do {
            try await moveForPublication(from: partial, to: destination, namespaceSettled: &namespaceSettled)
            namespaceSettled = true
            return destination
        }
        catch CoreKitError.alreadyExists {
            let conflict = try conflictPath(path)
            try Self.validateSource(fd: sourceFD, initial: initial, size: Int64(initial.st_size))
            try await moveForPublication(from: partial, to: conflict, namespaceSettled: &namespaceSettled)
            namespaceSettled = true
            return conflict
        }
    }
}
