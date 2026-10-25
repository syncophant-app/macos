import SwiftUI
import FileProvider
import ServiceManagement
import CoreKit

struct UncheckedManager: @unchecked Sendable {
    let value: NSFileProviderManager
    init(_ value: NSFileProviderManager) { self.value = value }
}

extension AppModel {
    var canUseFinder: Bool {
        !isDemo && active.map { mountedIDs.contains($0.id) } == true
    }

    var finderUnavailableReason: String {
        if isDemo { return "Not available in demo mode." }
        if Bundle.main.bundleURL.pathExtension != "app" { return "Needs the signed Syncophant.app bundle." }
        return "Add this storage to Finder first."
    }

    func refreshMounted() async {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let domains = try? await NSFileProviderManager.domains() else { return }
        let known = Set(connections.map(\.id.uuidString))
        mountedIDs = Set(domains.map(\.identifier.rawValue).filter(known.contains).compactMap(UUID.init))
        for domain in domains where domain.supportsSyncingTrash {
            guard let c = connections.first(where: { $0.id.uuidString == domain.identifier.rawValue }) else { continue }
            do { try await DriveManager.mount(c) }
            catch { diagnostics.add("Finder configuration update failed: \(message(for: error))") }
        }
    }

    func mount(_ c: StorageConnection) async {
        do {
            try await DriveManager.mount(c)
            mountedIDs.insert(c.id)
            say("\(c.name) is now in Finder under Locations.")
            await applyStorageBoxLink()
        } catch { say("Could not add \(c.name) to Finder: \(message(for: error))", error: true) }
    }

    func openInFinder() {
        guard let c = active else { return }
        Task {
            do { try await DriveManager.open(c) }
            catch { say("Could not open Finder: \(message(for: error))", error: true) }
        }
    }

    /// NSFileProviderManager is not Sendable; it is only ever used from this main-actor model.
    private func manager() -> UncheckedManager? {
        guard let c = active, canUseFinder, let m = NSFileProviderManager(for: DriveManager.domain(c)) else { return nil }
        return UncheckedManager(m)
    }

    func visibleURL(for node: FileNode) async throws -> URL {
        guard let manager = manager() else { throw AppError.unavailable(finderUnavailableReason) }
        return try await manager.value.getUserVisibleURL(for: NSFileProviderItemIdentifier(node.item.id))
    }

    // MARK: Finder actions

    func keepOnThisMac(_ nodes: [FileNode]) {
        guard let c = active, let manager = manager(), let meta = try? metadataStore(for: c) else { say(finderUnavailableReason, error: true); return }
        Task {
            var failed = 0
            for n in nodes {
                do {
                    try await meta.setPinned(id: n.item.id, true)
                    n.item.isPinned = true
                    // File Provider must ingest the new content policy before the download is requested.
                    try await manager.value.signalEnumerator(for: NSFileProviderItemIdentifier(n.item.id))
                    try await manager.value.signalEnumerator(for: .workingSet)
                    // NSNotFound location asks for the whole file. A folder is only listed one level here;
                    // its children follow the folder's keep-downloaded policy in the extension.
                    try await manager.value.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(n.item.id),
                                                             requestedRange: NSRange(location: NSNotFound, length: 0))
                } catch { failed += 1; diagnostics.add("Keep failed: \(message(for: error))") }
            }
            say(failed == 0 ? "Keeping \(nodes.count) item\(nodes.count == 1 ? "" : "s") on this Mac." : "\(failed) item\(failed == 1 ? "" : "s") could not be kept.", error: failed > 0)
            browser?.refreshStamp()
            try? await Task.sleep(for: .seconds(2))
            await refreshLocalStates()
        }
    }

    /// Evicts local copies. The toast names the space freed only when every item's size is known.
    func removeDownload(_ nodes: [FileNode]) {
        guard let c = active, let manager = manager(), let meta = try? metadataStore(for: c) else { say(finderUnavailableReason, error: true); return }
        let freed: Int64? = nodes.allSatisfy { !$0.isDirectory && filesUI.local[$0.path] == true }
            ? nodes.reduce(0) { $0 + $1.item.entry.size } : nil
        Task {
            var failed = 0
            for n in nodes {
                do {
                    try await meta.setPinned(id: n.item.id, false)
                    n.item.isPinned = false
                    try await manager.value.signalEnumerator(for: NSFileProviderItemIdentifier(n.item.id))
                    try await manager.value.signalEnumerator(for: .workingSet)
                    try await manager.value.evictItem(identifier: NSFileProviderItemIdentifier(n.item.id))
                } catch { failed += 1; diagnostics.add("Remove download failed: \(message(for: error))") }
            }
            if failed > 0 {
                say("\(failed) item\(failed == 1 ? "" : "s") could not be removed from this Mac.", error: true)
            } else if let freed, freed > 0 {
                say("Freed \(Format.bytes(freed)) on this Mac.")
            } else {
                say("Removed the download. It’s still on \(c.name).")
            }
            await refreshLocalStates()
            reloadCacheStatus()
        }
    }

    /// Un-keeps: the copy stays on this Mac but macOS may free it when space runs low.
    func stopKeeping(_ nodes: [FileNode]) {
        guard let c = active, let manager = manager(), let meta = try? metadataStore(for: c) else { say(finderUnavailableReason, error: true); return }
        Task {
            var failed = 0
            for n in nodes {
                do {
                    try await meta.setPinned(id: n.item.id, false)
                    n.item.isPinned = false
                    try await manager.value.signalEnumerator(for: NSFileProviderItemIdentifier(n.item.id))
                    try await manager.value.signalEnumerator(for: .workingSet)
                } catch { failed += 1; diagnostics.add("Stop keeping failed: \(message(for: error))") }
            }
            if failed > 0 { say("\(failed) item\(failed == 1 ? "" : "s") could not be changed.", error: true) }
            browser?.refreshStamp()
        }
    }

    /// Opens a folder in Files, or a file in its app. File Provider downloads it first when needed.
    func open(_ node: FileNode) {
        if node.isDirectory { searchText = ""; openFolder(node.path); return }
        Task {
            do { NSWorkspace.shared.open(try await visibleURL(for: node)) }
            catch { say("Could not open \(node.displayName): \(message(for: error))", error: true) }
        }
    }

    // MARK: Which files are on this Mac

    /// Reads, for files in the shown folder, whether the Finder drive holds their data (no SF_DATALESS flag).
    /// Only walks folders that are already materialized, so a lookup never makes the drive list the network.
    func refreshLocalStates() async {
        guard let c = active, let browser, canUseFinder, let manager = manager() else {
            if !filesUI.local.isEmpty { filesUI.local = [:]; filesUI.localStamp &+= 1 }
            return
        }
        if filesUI.driveRoot == nil {
            filesUI.driveRoot = try? await manager.value.getUserVisibleURL(for: .rootContainer)
        }
        guard let root = filesUI.driveRoot, c.id == activeID else { return }
        let folder = browser.folder
        let files = browser.roots.filter { !$0.isDirectory }.map { ($0.path, $0.displayName) }
        let found = await Task.detached(priority: .utility) { () -> [String: Bool] in
            let dataless: UInt32 = 0x4000_0000 // SF_DATALESS
            func flags(_ url: URL) -> UInt32? {
                var st = stat()
                return lstat(url.path, &st) == 0 ? st.st_flags : nil
            }
            var url = root
            guard let rootFlags = flags(url), rootFlags & dataless == 0 else { return [:] }
            for part in folder.split(separator: "/") {
                url.appendPathComponent(String(part))
                guard let f = flags(url), f & dataless == 0 else { return [:] }
            }
            var result: [String: Bool] = [:]
            for (path, name) in files {
                if let f = flags(url.appendingPathComponent(name)) { result[path] = f & dataless == 0 }
            }
            return result
        }.value
        guard browser.folder == folder else { return }
        if found != filesUI.local { filesUI.local = found; filesUI.localStamp &+= 1 }
    }

    func copyPath(_ node: FileNode) {
        Task {
            do {
                let url = try await visibleURL(for: node)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                say("Copied \(url.path)")
            } catch { say("Could not copy the path: \(message(for: error))", error: true) }
        }
    }

    func showInFinder(_ node: FileNode) {
        Task {
            do { NSWorkspace.shared.activateFileViewerSelecting([try await visibleURL(for: node)]) }
            catch { say("Could not show it in Finder: \(message(for: error))", error: true) }
        }
    }

    func openInTerminal(_ node: FileNode) {
        Task {
            do {
                let url = try await visibleURL(for: node)
                let folder = node.isDirectory ? url : url.deletingLastPathComponent()
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw AppError.unavailable("Terminal was not found.")
                }
                try await NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            } catch { say("Could not open Terminal: \(message(for: error))", error: true) }
        }
    }

    // MARK: ~/StorageBox shortcut

    /// A symlink in the home folder to the active drive. Never replaces anything that is not already a link.
    func applyStorageBoxLink() async {
        guard !isDemo else { return }
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("StorageBox")
        let isLink = (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if !settings.storageBoxLink {
            if isLink { try? FileManager.default.removeItem(at: link) }
            return
        }
        guard let manager = manager() else { return }
        do {
            let target = try await manager.value.getUserVisibleURL(for: .rootContainer)
            if isLink { try FileManager.default.removeItem(at: link) }
            else if FileManager.default.fileExists(atPath: link.path) { throw AppError.unavailable("~/StorageBox already exists and is not a link, so it was left alone.") }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        } catch { say("Could not create ~/StorageBox: \(message(for: error))", error: true) }
    }

    func requestCacheCheck() {
        guard !isDemo else { return }
        Task {
            for connection in connections where mountedIDs.contains(connection.id) {
                if let manager = NSFileProviderManager(for: DriveManager.domain(connection)) {
                    try? await manager.signalEnumerator(for: .workingSet)
                }
            }
        }
    }

    // MARK: Open at login

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        guard !isDemo else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { say("Could not change the login item: \(message(for: error))", error: true) }
    }
}
