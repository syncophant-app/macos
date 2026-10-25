import Foundation
import FileProvider
import UniformTypeIdentifiers
import CoreKit

final class ProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating, @unchecked Sendable {
    let stored: StoredItem
    let parentIdentifier: NSFileProviderItemIdentifier
    let displayName: String?
    let allowsMoving: Bool
    let allowsDeletion: Bool
    let context: FinderContext

    init(_ stored: StoredItem, parent: NSFileProviderItemIdentifier, displayName: String? = nil, allowsMoving: Bool = true, allowsDeletion: Bool = true,
         context: FinderContext = FinderContext()) {
        self.stored = stored
        self.parentIdentifier = parent
        self.displayName = displayName
        self.allowsMoving = allowsMoving; self.allowsDeletion = allowsDeletion
        self.context = context
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .init(rawValue: stored.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parentIdentifier }
    var filename: String { displayName ?? stored.entry.name }
    var contentType: UTType {
        stored.entry.isDirectory ? .folder : UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }
    var documentSize: NSNumber? { NSNumber(value: stored.entry.size) }
    var contentModificationDate: Date? { stored.entry.modifiedAt }
    var itemVersion: NSFileProviderItemVersion {
        .init(contentVersion: Data(stored.entry.version.utf8), metadataVersion: Data("\(stored.entry.path)|\(context.tag(stored))".utf8))
    }
    var capabilities: NSFileProviderItemCapabilities {
        var result: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting]
        if stored.entry.isDirectory { result.insert(.allowsAddingSubItems); result.insert(.allowsContentEnumerating) }
        if allowsMoving { result.formUnion([.allowsRenaming, .allowsReparenting]) }
        if allowsDeletion { result.insert(.allowsDeleting) }
        return result
    }
    /// Keep Downloaded and the app's Keep switch both write `MetadataStore.setPinned`; this is how the system learns it.
    var contentPolicy: NSFileProviderContentPolicy { stored.isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited }
    var userInfo: [AnyHashable: Any]? { context.userInfo(stored) }
    var decorations: [NSFileProviderItemDecorationIdentifier]? { context.decoration(stored).map { [.init(rawValue: $0)] } }
}

/// What Finder cannot work out itself. Published as `userInfo` for the action rules in Provider-Info.plist
/// and as decorations. Every value comes from the shared metadata, the app's upload queue or the storage kind.
struct FinderContext: Equatable, Sendable {
    /// "failed", "uploading" (the app's upload queue) or "conflict"; "synced" otherwise.
    var transfer: String?
    var canShare = false
    var hasVersions = false
    /// Settings › General › Status badges in Finder (`finderBadges` in settings.json; missing means on).
    var badges = true

    static let decorationPrefix = "app.syncophant.mac.provider."

    func state(_ stored: StoredItem) -> String {
        if let transfer { return transfer }
        return stored.entry.name.contains(" (conflict ") ? "conflict" : "synced"
    }

    func userInfo(_ stored: StoredItem) -> [AnyHashable: Any] {
        ["state": state(stored), "kept": stored.isPinned, "canShare": canShare, "hasVersions": hasVersions]
    }

    /// Finder shows only the first badge, so the most urgent state wins. Verified stays app-only (spec: noisy in Finder).
    func decoration(_ stored: StoredItem) -> String? {
        guard badges else { return nil }
        switch state(stored) {
        case "failed": return Self.decorationPrefix + "failed"
        case "conflict": return Self.decorationPrefix + "two-versions"
        default: return stored.isPinned ? Self.decorationPrefix + "kept" : nil
        }
    }

    /// Changes whenever anything Finder shows for the item changes, so a signalled enumerator re-reads it.
    func tag(_ stored: StoredItem) -> String {
        "pinned:\(stored.isPinned)|verified:\(stored.isVerified)|state:\(state(stored))|share:\(canShare)|versions:\(hasVersions)|badges:\(badges)"
    }

    /// Latest non-cancelled transfer per remote path in the app's `transfers.json`, as the app's own status does.
    static func transferStates(_ data: Data?, connection: UUID) -> [String: String] {
        struct Any_: Decodable { init(from decoder: Decoder) {} }
        struct Transfer: Decodable {
            let connectionID: UUID
            let remotePath: String
            let publishedPath: String?
            let phase: [String: Any_]
        }
        struct Queue: Decodable { let transfers: [Transfer] }
        guard let data, let queue = try? JSONDecoder().decode(Queue.self, from: data) else { return [:] }
        var latest: [String: String] = [:]
        for transfer in queue.transfers where transfer.connectionID == connection {
            guard let phase = transfer.phase.keys.first, phase != "cancelled" else { continue }
            latest[transfer.publishedPath ?? transfer.remotePath] = phase
        }
        return latest.compactMapValues {
            switch $0 {
            case "failed": "failed"
            case "queued", "working": "uploading"
            default: nil
            }
        }
    }

    static func badgesEnabled(_ settings: Data?) -> Bool {
        struct Settings: Decodable { let finderBadges: Bool? }
        guard let settings, let decoded = try? JSONDecoder().decode(Settings.self, from: settings) else { return true }
        return decoded.finderBadges ?? true
    }
}
