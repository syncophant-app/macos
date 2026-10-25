import Foundation
import FileProvider
import QuickLookThumbnailing
import UniformTypeIdentifiers

final class SyncophantProvider: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching, NSFileProviderThumbnailing, NSFileProviderCustomAction {
    let runtime: Result<ProviderRuntime, Error>

    required init(domain: NSFileProviderDomain) {
        runtime = Result { try ProviderRuntime(domain: domain) }
        super.init()
    }

    func invalidate() {
        if case let .success(runtime) = runtime { Task { await runtime.stop() } }
    }

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completion = ActionCompletion(completionHandler)
        let progress = perform { _ in
            do {
                try await self.runtime.get().performAction(actionIdentifier.rawValue, identifiers: itemIdentifiers)
                completion.finish(nil)
            } catch { completion.finish(providerError(error)) }
        }
        let cancelTask = progress.cancellationHandler
        progress.cancellationHandler = {
            cancelTask?()
            completion.finish(CocoaError(.userCancelled))
        }
        return progress
    }

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        Task {
            if case let .success(runtime) = runtime {
                await CacheBudget.enforce(domain: runtime.domain, metadata: runtime.metadata)
            }
        }
        completionHandler()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw CocoaError(.featureUnsupported) }
        let runtime = try runtime.get()
        if containerItemIdentifier == .workingSet {
            Task { await CacheBudget.enforce(domain: runtime.domain, metadata: runtime.metadata) }
        }
        return ProviderEnumerator(runtime: runtime, identifier: containerItemIdentifier)
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        perform { progress in
            do { completionHandler(try await self.runtime.get().item(identifier), nil) }
            catch { completionHandler(nil, providerError(error)) }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        perform { progress in
            do {
                let (url, item, _) = try await self.runtime.get().download(itemIdentifier, range: nil, version: requestedVersion, strict: false, progress: progress)
                completionHandler(url, item, nil)
            } catch { completionHandler(nil, nil, providerError(error)) }
        }
    }

    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange: NSRange, aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        perform { progress in
            do {
                let runtime = try self.runtime.get()
                let (url, item, range) = try await runtime.download(itemIdentifier, range: minimalRange, alignment: alignment, version: version, strict: options.contains(.strictVersioning), progress: progress)
                completionHandler(url, item, range, [], nil)
            } catch { completionHandler(nil, nil, .init(location: 0, length: 0), [], providerError(error)) }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        perform { progress in
            do { completionHandler(try await self.runtime.get().create(template: itemTemplate, contents: url, progress: progress), [], false, nil) }
            catch { completionHandler(nil, fields, false, providerError(error)) }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let supported: NSFileProviderItemFields = [.contents, .filename, .parentItemIdentifier]
        let pending = changedFields.subtracting(supported)
        return perform { progress in
            do { completionHandler(try await self.runtime.get().modify(item, version: version, fields: changedFields, contents: newContents, progress: progress), pending, false, nil) }
            catch { completionHandler(nil, changedFields, false, providerError(error)) }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        perform { _ in
            do { try await self.runtime.get().delete(identifier, version: version); completionHandler(nil) }
            catch { completionHandler(providerError(error)) }
        }
    }

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        perform { progress in
            for identifier in itemIdentifiers {
                do {
                    try Task.checkCancellation()
                    let runtime = try self.runtime.get()
                    let item = try await runtime.item(identifier)
                    guard item.contentType.conforms(to: .image) || item.contentType.conforms(to: .pdf)
                            || item.contentType.conforms(to: .movie) else { throw CocoaError(.featureUnsupported) }
                    let (url, latest) = try await runtime.thumbnailContents(identifier, progress: progress)
                    defer { try? FileManager.default.removeItem(at: url) }
                    let output = url.appendingPathExtension("jpg")
                    defer { try? FileManager.default.removeItem(at: output) }
                    let width = requestedSize.width.isFinite ? min(1024, max(1, requestedSize.width)) : 256
                    let height = requestedSize.height.isFinite ? min(1024, max(1, requestedSize.height)) : 256
                    let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: width, height: height), scale: 1, representationTypes: .thumbnail)
                    request.contentType = latest.contentType
                    try await ThumbnailRequest(request).save(to: output)
                    try Task.checkCancellation()
                    // The output is bounded independently of the source and generated one item at a time.
                    guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1_048_576 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    perThumbnailCompletionHandler(identifier, try Data(contentsOf: output), nil)
                } catch { perThumbnailCompletionHandler(identifier, nil, providerError(error)) }
            }
            completionHandler(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }
    }

    private func perform(_ body: @escaping (Progress) async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task { await body(progress) }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

/// Cancellation and the asynchronous action may finish together; Finder receives one completion.
final class ActionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?

    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }

    func finish(_ error: Error?) {
        let callback = lock.withLock {
            let callback = self.callback
            self.callback = nil
            return callback
        }
        callback?(error)
    }
}

/// Serializes start/cancel so cancellation just before registration cannot miss the native request.
final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let request: QLThumbnailGenerator.Request
    private var cancelled = false
    private var started = false

    init(_ request: QLThumbnailGenerator.Request) { self.request = request }

    func save(to output: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    started = true
                    QLThumbnailGenerator.shared.saveBestRepresentation(for: request, to: output, as: .jpeg) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        } onCancel: {
            self.lock.withLock {
                self.cancelled = true
                if self.started { QLThumbnailGenerator.shared.cancel(self.request) }
            }
        }
    }
}

func providerError(_ error: Error) -> Error {
    if error is CancellationError { return CocoaError(.userCancelled) }
    let ns = error as NSError
    if ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain { return error }
    return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue,
                   userInfo: [NSUnderlyingErrorKey: error, NSLocalizedDescriptionKey: "Your storage is unavailable. Syncophant will retry without discarding local changes."])
}
