import Foundation
@preconcurrency import FileProvider
import CoreKit
import OSLog

/// Event-driven only: coalesces callbacks, including callbacks caused by our own evictions.
actor CacheBudget {
    private static let shared = CacheBudget()
    private var running = Set<String>()
    private var requested = Set<String>()
    private let logger = Logger(subsystem: "app.syncophant.mac.provider", category: "CacheBudget")

    static func enforce(domain: NSFileProviderDomain, metadata: MetadataStore) async {
        await shared.enforceDomain(domain, metadata: metadata)
    }

    private func enforceDomain(_ domain: NSFileProviderDomain, metadata: MetadataStore) async {
        let id = domain.identifier.rawValue
        requested.insert(id)
        guard running.insert(id).inserted else { return }
        defer { running.remove(id); requested.remove(id) }
        repeat {
            requested.remove(id)
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
            await sweep(domain, metadata: metadata)
        } while requested.contains(id)
    }

    struct Candidate {
        let id: String
        let bytes: Int64
        let lastUsed: Date?
        let pinned: Bool
        let safe: Bool
    }

    /// The total includes protected/unknown entries; they cannot make the budget look smaller.
    static func selection(_ items: [Candidate], total: Int64, budget: Int64, now: Date) -> [Candidate] {
        var remaining = total
        return eligible(items).filter { item in
            guard remaining > budget || now.timeIntervalSince(item.lastUsed!) > CachePolicy.idleLimit else { return false }
            remaining -= item.bytes
            return true
        }
    }

    private static func eligible(_ items: [Candidate]) -> [Candidate] {
        items.filter { $0.safe && !$0.pinned && $0.lastUsed != nil && $0.bytes > 0 }
            .sorted {
                if $0.lastUsed != $1.lastUsed { return $0.lastUsed! < $1.lastUsed! }
                return $0.id < $1.id
            }
    }

    /// Missing ancestors are ambiguous; an unobserved parent might be pinned.
    static func protection(_ item: StoredItem, in items: [String: StoredItem]) -> Bool? {
        var current = item
        while true {
            if current.isPinned { return true }
            let parent = PathRules.parent(of: current.entry.path)
            if parent == "/" { return false }
            guard let ancestor = items[parent], ancestor.entry.isDirectory,
                  ancestor.entry.path != current.entry.path else { return nil }
            current = ancestor
        }
    }

    private struct Inventory {
        var status: CacheStatus
        var candidates: [Candidate]
    }

    private func inventory(_ manager: NSFileProviderManager, metadata: MetadataStore,
                           budget: Int64) async throws -> Inventory {
        let snapshot = try await metadata.snapshot()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let byPath = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.entry.path, $0) })
        let pendingEnumerator = manager.enumeratorForPendingItems()
        let pending = Set(try await enumerate(pendingEnumerator).map { $0.itemIdentifier.rawValue })
        guard !pendingEnumerator.isMaximumSizeReached else {
            throw NSError(domain: "CacheBudget", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pending item enumeration was capped; eviction paused."])
        }
        let materialized = try await enumerate(manager.enumeratorForMaterializedItems())
        var status = CacheStatus(budgetBytes: budget)
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for info in materialized {
            try Task.checkCancellation()
            let id = info.itemIdentifier.rawValue
            guard seen.insert(id).inserted else { continue }
            if info.itemIdentifier == .rootContainer { continue }
            do {
                let url = try await manager.getUserVisibleURL(for: info.itemIdentifier)
                let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                                               .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                                               .contentAccessDateKey, .contentModificationDateKey,
                                                               .creationDateKey])
                guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize, allocated >= 0 else {
                    throw CocoaError(.fileReadUnknown)
                }
                let bytes = Int64(allocated)
                status.cachedBytes += bytes
                let stored = byID[id]
                let pinned = stored.flatMap { Self.protection($0, in: byPath) }
                let policy = info.contentPolicy
                let protectedBySystem = policy == .downloadEagerlyAndKeepDownloaded
                let isPinned = pinned == true || protectedBySystem
                // Count directories but never evict them: directory eviction is recursive.
                if values.isDirectory == true {
                    if isPinned { status.pinnedBytes += bytes }
                    else { status.blockedBytes += bytes }
                    if pinned == nil { status.unknownItemCount += 1 }
                    continue
                }
                let safe = stored != nil && pinned != nil && !pending.contains(id)
                    && values.isRegularFile == true && values.isSymbolicLink == false
                    && info.isUploaded == true && info.isUploading == false
                    && info.isDownloading == false
                    && (policy == .inherited || policy == .downloadLazily || policy == .downloadLazilyAndEvictOnRemoteUpdate)
                // Remote mtime is not cache age. Use local access and creation/modification dates,
                // taking the latest so a newly downloaded old remote file is never immediately aged out.
                let dates = [info.lastUsedDate ?? nil, values.contentAccessDate,
                             values.contentModificationDate, values.creationDate].compactMap { $0 }
                let lastUsed = dates.max()
                if isPinned { status.pinnedBytes += bytes }
                else if !safe || lastUsed == nil { status.blockedBytes += bytes }
                if stored == nil || pinned == nil || (!safe && !isPinned && !pending.contains(id)) || lastUsed == nil {
                    status.unknownItemCount += 1
                }
                candidates.append(Candidate(id: id, bytes: bytes, lastUsed: lastUsed, pinned: isPinned, safe: safe))
            } catch {
                status.unknownItemCount += 1
            }
        }
        status.measurementComplete = status.unknownItemCount == 0
        if status.unknownItemCount > 0 {
            status.diagnostics.append("Some materialized items have missing metadata, allocation, age, or ambiguous transfer flags; those items were retained.")
        }
        return Inventory(status: status, candidates: candidates)
    }

    private func sweep(_ domain: NSFileProviderDomain, metadata: MetadataStore) async {
        let id = domain.identifier.rawValue
        var status = CacheStatus()
        do {
            let policy = try CachePolicy.load()
            status.budgetBytes = policy.budgetBytes
            guard let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.fileNoSuchFile) }
            let before = try await inventory(manager, metadata: metadata, budget: policy.budgetBytes)
            status = before.status
            var errors: [String] = []
            var remaining = status.cachedBytes
            for item in Self.eligible(before.candidates) {
                try Task.checkCancellation()
                guard remaining > policy.budgetBytes || Date().timeIntervalSince(item.lastUsed!) > CachePolicy.idleLimit else { continue }
                // Recheck pins and pending work immediately before eviction. The system performs
                // the final atomic dirty/open-file check, closing races after these observations.
                let pins = try await metadata.snapshot()
                let paths = Dictionary(uniqueKeysWithValues: pins.items.map { ($0.entry.path, $0) })
                guard let stored = pins.items.first(where: { $0.id == item.id }),
                      Self.protection(stored, in: paths) == false else { continue }
                let pendingEnumerator = manager.enumeratorForPendingItems()
                let pending = try await enumerate(pendingEnumerator)
                guard !pendingEnumerator.isMaximumSizeReached else { throw CocoaError(.fileReadUnknown) }
                guard !pending.contains(where: { $0.itemIdentifier.rawValue == item.id }) else { continue }
                let identifier = NSFileProviderItemIdentifier(rawValue: item.id)
                var url = try await manager.getUserVisibleURL(for: identifier)
                let current = try url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey, .creationDateKey])
                let lastUsed = ([current.contentAccessDate, current.contentModificationDate, current.creationDate]
                    .compactMap { $0 } + [item.lastUsed!]).max()!
                guard remaining > policy.budgetBytes || Date().timeIntervalSince(lastUsed) > CachePolicy.idleLimit else { continue }
                do {
                    try await manager.evictItem(identifier: identifier)
                    // Count only measured reclaimed allocation; the dataless shell may retain bytes.
                    url.removeAllCachedResourceValues()
                    let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                    guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize, allocated >= 0 else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    remaining -= max(0, item.bytes - Int64(allocated))
                } catch {
                    let error = error as NSError
                    errors.append("Eviction or allocation verification failed (\(error.domain):\(error.code)); enforcement is unconfirmed.")
                }
            }
            // Report measured post-eviction allocation, never subtract an optimistic logical size.
            let after = try await inventory(manager, metadata: metadata, budget: policy.budgetBytes)
            status = after.status
            status.diagnostics.append(contentsOf: errors.prefix(10))
            status.enforced = status.measurementComplete && errors.isEmpty
                && status.cachedBytes <= policy.budgetBytes
                && Self.selection(after.candidates, total: status.cachedBytes,
                                  budget: policy.budgetBytes, now: Date()).isEmpty
            if status.cachedBytes > policy.budgetBytes {
                status.diagnostics.append("Budget remains exceeded; pinned, blocked, or busy data was retained.")
            }
        } catch {
            status.measurementComplete = false
            status.enforced = false
            let error = error as NSError
            status.diagnostics.append("Cache enforcement incomplete (\(error.domain):\(error.code)). No unsafe eviction was attempted.")
        }
        status.timestamp = Date()
        do { try CachePolicy.saveStatus(status, domainID: id) }
        catch { logger.error("Could not persist cache status: \(error.localizedDescription, privacy: .public)") }
    }

    private func enumerate(_ enumerator: NSFileProviderEnumerator) async throws -> [NSFileProviderItem] {
        defer { enumerator.invalidate() }
        var result: [NSFileProviderItem] = []
        // NSFileProviderManager.h requires empty NSData for the materialized initial page;
        // pending enumerators follow the same contract. Sorted page constants are ignored.
        var page = NSFileProviderPage(Data())
        var pages = Set<Data>()
        while true {
            try Task.checkCancellation()
            guard pages.insert(page.rawValue).inserted else { throw CocoaError(.fileReadCorruptFile) }
            let observer = CachePageObserver()
            let batch = try await observer.read(enumerator, page: page)
            result.append(contentsOf: batch.items)
            guard let next = batch.next else { return result }
            page = next
        }
    }
}

private final class CachePageObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    struct Batch {
        let items: [NSFileProviderItem]
        let next: NSFileProviderPage?
    }
    private let lock = NSLock()
    private var items: [NSFileProviderItem] = []
    private var continuation: CheckedContinuation<Batch, Error>?

    func read(_ enumerator: NSFileProviderEnumerator, page: NSFileProviderPage) async throws -> Batch {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            enumerator.enumerateItems(for: self, startingAt: page)
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        lock.lock(); defer { lock.unlock() }
        items.append(contentsOf: updatedItems)
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { finish(nil, next: nextPage) }
    func finishEnumeratingWithError(_ error: Error) { finish(error, next: nil) }

    private func finish(_ error: Error?, next: NSFileProviderPage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let batch = Batch(items: items, next: next)
        lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: batch) }
    }
}
