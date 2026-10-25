import SwiftUI
import CoreKit

/// Shared answers the window shell, the menu bar panel and the setup flows all ask for.
extension AppModel {
    // MARK: Windows

    /// Opens a setup window. The action is captured from the first SwiftUI view that appeared.
    func open(_ window: SetupWindow) {
        NSApp.activate()
        if let openWindowAction { openWindowAction(id: window.rawValue) }
        else { diagnostics.add("Could not open the \(window.rawValue) window: no window action yet.") }
    }

    /// Shows the main window on a section.
    func show(_ section: Destination) {
        destination = section
        NSApp.activate()
        if let openWindowAction { openWindowAction(id: "browser") }
    }

    // MARK: Storage identity

    func avatarColor(for c: StorageConnection) -> AvatarColor {
        if let picked = settings.storageColors?[c.id.uuidString] { return picked }
        let index = connections.firstIndex(of: c) ?? 0
        return AvatarColor.allCases[index % AvatarColor.allCases.count]
    }

    func setAvatarColor(_ color: AvatarColor, for c: StorageConnection) {
        var s = settings
        var colors = s.storageColors ?? [:]
        colors[c.id.uuidString] = color
        s.storageColors = colors
        save(s)
    }

    /// "Hetzner · SFTP", the provider line under a storage name. Never the hostname.
    func providerLine(for c: StorageConnection) -> String {
        if isDemo, c.id == demo?.connection.id { return "Demo · local files" }
        if let e = connectionErrors[c.id], !e.isEmpty { return "Can’t reach it right now" }
        switch c.provider {
        case .hetzner: return "Hetzner Storage Box"
        case .sftp: return "SFTP server"
        case .webdav: return "WebDAV"
        case .s3: return c.region.map { "S3 · \($0)" } ?? "S3-compatible"
        case .smb: return "SMB share"
        case .dropbox, .onedrive, .box, .googledrive: return c.provider.oauthService?.label ?? ""
        }
    }

    // MARK: Health

    func health(for c: StorageConnection) -> Health {
        if connectionErrors[c.id] != nil { return .offline }
        let mine = issues.filter { issueBelongs($0, to: c) }
        if mine.contains(where: { $0.severity == .failure }) { return .failing }
        if !mine.isEmpty { return .needsYou }
        if transfers.contains(where: { $0.connectionID == c.id && $0.phase.isActive }) { return .syncing }
        if lastChecked[c.id] != nil || isDemo { return .healthy }
        return .syncing
    }

    private func issueBelongs(_ issue: Issue, to c: StorageConnection) -> Bool {
        switch issue.fix {
        case .reviewHostKey(let id), .compareHostKey(let id), .enterPassword(let id), .retryListing(let id), .addToFinder(let id),
             .recoverMutation(let id), .freeUpSpace(let id), .showSnapshotFolder(let id):
            return id == c.id
        case .retryTransfer(let id), .showConflict(let id): return transfers.first { $0.id == id }?.connectionID == c.id
        case .reconnectStorage: return c.id == activeID
        }
    }

    /// Problems ranked for "the one thing that needs you".
    var rankedIssues: [Issue] { issues.sorted { $0.rank < $1.rank } }

    // MARK: Capacity

    /// Used and total bytes, only when the provider reported both. Never estimated.
    func capacity(for c: StorageConnection) -> (used: Int64, snapshots: Int64?, total: Int64)? {
        guard let box = snapshots.box, box.server == c.host || c.id == activeID && c.provider == .hetzner,
              let used = box.diskUsage, let total = box.diskQuota, total > 0 else { return nil }
        return (used, nil, total)
    }

    func reloadCacheStatus() {
        guard !isDemo else { return }
        for c in connections {
            if let status = try? CachePolicy.loadStatus(domainID: c.id.uuidString) { cacheStatus[c.id] = status }
        }
    }

    // MARK: Pinned folders

    func pinnedFolders(for c: StorageConnection) -> [String] { settings.pinnedFolders?[c.id.uuidString] ?? [] }

    func setPinned(_ path: String, pinned: Bool, for c: StorageConnection) {
        var s = settings
        var all = s.pinnedFolders ?? [:]
        var list = all[c.id.uuidString] ?? []
        list.removeAll { $0 == path }
        if pinned { list.append(path) }
        all[c.id.uuidString] = list
        s.pinnedFolders = all
        save(s)
    }

    /// Shows a folder of the active storage in Files.
    func openFolder(_ path: String) {
        currentFolder = path
        destination = .files
        selection = []
    }
}

// MARK: - Links from Finder

extension AppModel {
    /// `syncophant://<route>?storage=<connection id>&path=<remote path>`, sent by the Finder extension's actions.
    /// Only known routes and saved storages are honoured; anything else is ignored.
    func handle(_ url: URL) {
        guard url.scheme == "syncophant", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary((parts.queryItems ?? []).compactMap { q in q.value.map { (q.name, $0) } }, uniquingKeysWith: { a, _ in a })
        guard let id = query["storage"].flatMap(UUID.init), connections.contains(where: { $0.id == id }) else { return }
        let path = query["path"].flatMap { (try? PathRules.normalize($0)) } ?? "/"
        if id != activeID { select(id) }
        let route = url.host ?? ""
        switch route {
        case "retry-upload":
            let failed = transfers.last { t in
                guard t.connectionID == id, (t.publishedPath ?? t.remotePath) == path else { return false }
                if case .failed = t.phase { return true }
                return false
            }
            if let failed { retry(failed.id); say("Retrying \(failed.name).") }
            show(.activity)
        case "activity":
            show(.activity)
        case "time-travel":
            openFolder(PathRules.parent(of: path))
            show(.timeTravel)
        case "compare", "share":
            openFolder(PathRules.parent(of: path))
            show(.files)
            Task {
                // The folder lists asynchronously; wait briefly for the row to exist, then select it.
                for _ in 0..<30 {
                    if let node = browser?.find(path: path) {
                        selection = [node]
                        if route == "compare" { filesUI.showInspector = true } else { beginSharing() }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                say("Couldn’t find \(PathRules.name(of: path)) in \(PathRules.name(of: PathRules.parent(of: path))).", error: true)
            }
        default:
            return
        }
    }
}
