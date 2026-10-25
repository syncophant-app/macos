import Foundation
import FileProvider

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    let runtime: ProviderRuntime
    let identifier: NSFileProviderItemIdentifier
    private let token = UUID()
    private var subscription: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false
    private let lock = NSLock()

    init(runtime: ProviderRuntime, identifier: NSFileProviderItemIdentifier) {
        self.runtime = runtime
        self.identifier = identifier
        super.init()
        let token = self.token
        subscription = Task { await runtime.subscribe(identifier, token: token) }
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        let active = tasks.values
        tasks.removeAll()
        let subscription = self.subscription
        self.subscription = nil
        lock.unlock()
        active.forEach { $0.cancel() }
        let runtime = self.runtime, identifier = self.identifier, token = self.token
        Task {
            // Registration and invalidation may race; always remove after registration finishes.
            await subscription?.value
            await runtime.unsubscribe(identifier, token: token)
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        run {
            do {
                let items = try await self.runtime.list(self.identifier)
                try Task.checkCancellation()
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        run {
            do {
                let (updated, deleted, anchor) = try await self.runtime.changes(from: syncAnchor, in: self.identifier)
                try Task.checkCancellation()
                observer.didUpdate(updated)
                observer.didDeleteItems(withIdentifiers: deleted)
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        run { completionHandler(try? await self.runtime.anchor()) }
    }

    private func run(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        let id = UUID()
        tasks[id] = Task {
            await operation()
            self.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        tasks.removeValue(forKey: id)
    }
}
