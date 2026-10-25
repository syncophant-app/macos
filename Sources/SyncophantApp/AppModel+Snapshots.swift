import SwiftUI
import CoreKit
import HetznerKit

struct SnapshotsState {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }
    var phase: Phase = .idle
    /// Storage the list belongs to, so switching storage reloads it.
    var connectionID: UUID?
    var box: StorageBox?
    /// Home folder of a sub-account login, relative to the box. Empty for the main account.
    var accountHome = ""
    /// Newest first.
    var list: [StorageSnapshot] = []
    var selected: Int?
    var isCreating = false
    var isRestoring = false
    /// "Asking Hetzner…" while the snapshot folder is being turned on.
    var isRevealing = false
    /// Set when SFTP shows no /.zfs/snapshot even though the API did not report the flag.
    var listingHidden = false
}

/// One entry of the selected snapshot's copy of a folder, compared with the folder as it is now.
struct VersionRow: Identifiable, Hashable {
    enum Diff: Hashable { case same, changed, gone, folderSame }
    var id: String { then.name }
    let then: RemoteEntry
    let now: RemoteEntry?
    let diff: Diff
    /// From Recently deleted, when the gone item was deleted through Syncophant.
    let deletedAt: Date?
}

extension AppModel {
    var hasHetznerToken: Bool { !isDemo && HetznerToken.load() != nil }
    var canUseSnapshots: Bool { active?.provider == .hetzner && !isDemo }

    /// The box keeps snapshots but its snapshot folder is not visible over SFTP. Read-only for other screens.
    var snapshotsHidden: Bool {
        canUseSnapshots && (snapshots.box?.accessSettings?.zfsEnabled == false || snapshots.listingHidden)
    }

    var selectedSnapshot: StorageSnapshot? { snapshots.list.first { $0.id == snapshots.selected } }

    func saveHetznerToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try HetznerToken.save(trimmed); Task { await loadSnapshots() } }
        catch { say("Could not save the token to your Keychain: \(message(for: error))", error: true) }
    }

    func forgetHetznerToken() {
        do { try HetznerToken.forget(); snapshots = SnapshotsState(); say("Removed the Hetzner token from your Keychain.") }
        catch { say("Could not remove the token: \(message(for: error))", error: true) }
    }

    /// Calls api.hetzner.com. Runs only after the person opens Time Travel or presses a button there.
    /// `quiet` keeps the current content on screen (used by the once-a-minute check).
    func loadSnapshots(quiet: Bool = false) async {
        guard let c = active, c.provider == .hetzner, let token = HetznerToken.load() else { snapshots = SnapshotsState(); return }
        if !quiet { snapshots.phase = .loading; snapshots.connectionID = c.id }
        noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
        do {
            let client = HetznerClient(token: token)
            let (box, home) = try await resolveHetznerBox(c, client: client)
            let list = try await client.snapshots(boxID: box.id).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            snapshots.connectionID = c.id
            snapshots.box = box
            snapshots.accountHome = home
            snapshots.list = list
            snapshots.listingHidden = false
            snapshots.phase = .loaded
            if !list.contains(where: { $0.id == snapshots.selected }) { snapshots.selected = list.first?.id }
        } catch {
            if !quiet { snapshots.phase = .failed(message(for: error)) }
            diagnostics.add("Snapshot list failed: \(message(for: error))")
        }
    }

    func createSnapshot(description: String) async {
        guard let c = active, let box = snapshots.box, let token = HetznerToken.load() else { return }
        snapshots.isCreating = true
        defer { snapshots.isCreating = false }
        noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
        do {
            let made = try await HetznerClient(token: token).createSnapshot(boxID: box.id, description: description)
            snapshots.list.insert(made, at: 0)
            snapshots.selected = made.id
            say("Snapshot taken. \(c.name) keeps it until you delete it.")
        } catch { say("Could not take the snapshot: \(message(for: error))", error: true) }
    }

    /// Turns on `access_settings.zfs_enabled` for the box, leaving every other setting as it is.
    func showSnapshotFolder() async {
        guard let box = snapshots.box, let token = HetznerToken.load() else { return }
        snapshots.isRevealing = true
        defer { snapshots.isRevealing = false }
        noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
        do {
            try await HetznerClient(token: token).updateAccessSettings(boxID: box.id, StorageAccessSettings(zfsEnabled: true))
            await loadSnapshots(quiet: true)
        } catch { say("Hetzner did not show the snapshot folder: \(message(for: error))", error: true) }
    }

    // MARK: Folder as it was

    static let snapshotRoot = "/.zfs/snapshot"

    private func snapshotPath(_ snapshot: StorageSnapshot, _ path: String) -> String {
        Self.snapshotRoot + "/" + snapshot.name + (path == "/" ? "" : path)
    }

    /// Lists `folder` in the selected snapshot and in the live storage, and compares each entry by size and date.
    func loadFolderAsItWas(_ folder: String) async {
        let ui = timeTravelUI
        guard let c = active, let snap = selectedSnapshot, let store = try? remoteStore(for: c) else {
            ui.rows = []; ui.folderPhase = .idle; return
        }
        ui.folderPhase = .loading
        noteContact(c)
        let visible: (RemoteEntry) -> Bool = { e in
            e.name != "." && e.name != ".." && PathRules.isVisible(path: e.path) && !(folder == "/" && e.name == ".zfs")
        }
        do {
            let then = try await store.list(path: snapshotPath(snap, folder)).filter(visible)
            let now: [RemoteEntry]
            do { now = try await store.list(path: folder).filter(visible) } catch CoreKitError.notFound { now = [] }
            guard !Task.isCancelled else { return }
            let deleted = Dictionary(ui.trash.compactMap { t in t.deletedAt.map { (t.originalPath, $0) } }, uniquingKeysWith: max)
            let (rows, added) = Self.compare(then: then, now: now, folder: folder, deleted: deleted)
            ui.rows = rows
            ui.addedSince = added
            ui.folderPhase = .loaded
            if !rows.contains(where: { $0.id == ui.selectedRow }) { ui.selectedRow = rows.first?.id }
        } catch CoreKitError.notFound {
            guard !Task.isCancelled else { return }
            if (try? await store.stat(path: Self.snapshotRoot)) == nil { snapshots.listingHidden = true }
            ui.rows = []; ui.addedSince = 0; ui.folderPhase = .missing
        } catch {
            guard !Task.isCancelled else { return }
            ui.rows = []; ui.folderPhase = .failed(message(for: error))
        }
    }

    /// Size plus modification time decide "same"; ZFS snapshots keep both exactly for untouched files.
    /// A folder's date only changes when items directly inside it are added, removed or renamed.
    nonisolated static func compare(then: [RemoteEntry], now: [RemoteEntry], folder: String,
                                    deleted: [String: Date]) -> (rows: [VersionRow], added: Int) {
        let live = Dictionary(now.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = then.map { old -> VersionRow in
            let path = folder == "/" ? "/" + old.name : folder + "/" + old.name
            guard let current = live[old.name], current.isDirectory == old.isDirectory else {
                return VersionRow(then: old, now: nil, diff: .gone, deletedAt: deleted[path])
            }
            let sameDate = abs(current.modifiedAt.timeIntervalSince(old.modifiedAt)) < 1
            let diff: VersionRow.Diff = old.isDirectory ? (sameDate ? .folderSame : .changed)
                : (sameDate && current.size == old.size ? .same : .changed)
            return VersionRow(then: old, now: current, diff: diff, deletedAt: nil)
        }
        let names = Set(then.map(\.name))
        let added = now.filter { !names.contains($0.name) }.count
        return (rows.sorted { $0.then.name.localizedStandardCompare($1.then.name) == .orderedAscending }, added)
    }

    // MARK: Restores

    /// Copies one snapshot item next to the live one as "Name (18 Oct).ext", or back to its own place
    /// when it is gone now. Nothing current is overwritten.
    func restoreCopy(_ row: VersionRow, folder: String) async {
        guard let c = active, let snap = selectedSnapshot, let store = try? remoteStore(for: c) else { return }
        snapshots.isRestoring = true
        defer { snapshots.isRestoring = false }
        do {
            let source = try await store.stat(path: snapshotPath(snap, join(folder, row.then.name)))
            let destination = try await freePath(in: folder, name: row.now == nil ? row.then.name : stamped(row.then.name, snap), store: store)
            let count = try await copy(source, to: destination, store: store, engine: TransferEngine(store: store))
            _ = try? await metadataStore(for: c).refresh(store: store, path: folder)
            let what = source.isDirectory ? "\(count) file\(count == 1 ? "" : "s") into “\(PathRules.name(of: destination))”" : "“\(PathRules.name(of: destination))”"
            say("Restored \(what). Each copy was checked against the snapshot.")
            await browser?.refreshOpenFolders()
            await loadFolderAsItWas(folder)
        } catch { say("Restore stopped: \(message(for: error)). Nothing was overwritten.", error: true) }
    }

    /// Moves the current file to Recently deleted, then writes the snapshot's version in its place.
    /// The snapshot copy is downloaded first, so the current file is only moved once its replacement is on this Mac.
    func replaceCurrent(_ row: VersionRow, folder: String) async {
        guard let c = active, let snap = selectedSnapshot, let current = row.now, !current.isDirectory,
              let store = try? remoteStore(for: c), store.publicationMode == .atomicMove else { return }
        snapshots.isRestoring = true
        defer { snapshots.isRestoring = false }
        let livePath = join(folder, current.name)
        var trashed = false
        do {
            let source = try await store.stat(path: snapshotPath(snap, livePath))
            let temp = try await download(source, store: store)
            defer { try? FileManager.default.removeItem(at: temp) }
            let meta = try metadataStore(for: c)
            let remote = try await store.stat(path: livePath)
            guard remote.size == current.size, abs(remote.modifiedAt.timeIntervalSince(current.modifiedAt)) < 1 else {
                throw CoreKitError.itemChanged(livePath)
            }
            guard let stored = try await meta.refresh(store: store, path: folder).first(where: { $0.entry.path == livePath }) else {
                throw CoreKitError.notFound(livePath)
            }
            try await RemoteTrash(store: store, metadata: meta).delete(stored, expectedVersion: remote.version)
            trashed = true
            let receipt = try await TransferEngine(store: store).upload(localURL: temp, remotePath: livePath)
            _ = try? await meta.refresh(store: store, path: folder)
            say("Replaced “\(PathRules.name(of: receipt.remotePath))”. The previous version is in Recently deleted.")
            await browser?.refreshOpenFolders()
            await loadTrash()
            await loadFolderAsItWas(folder)
        } catch {
            say(trashed ? "Could not write the old version: \(message(for: error)). The current version is safe in Recently deleted."
                        : "Nothing was replaced: \(message(for: error)).", error: true)
            if trashed { await loadTrash() }
        }
    }

    /// "Proposal draft.pages" → "Proposal draft (18 Oct).pages".
    private func stamped(_ name: String, _ snap: StorageSnapshot) -> String {
        let day = (snap.createdAt ?? Date()).formatted(.dateTime.day().month(.abbreviated))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return "\(base) (\(day))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// First of "Name", "Name 2", "Name 3"… that does not exist yet.
    private func freePath(in folder: String, name: String, store: any RemoteStore) async throws -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 1...50 {
            let candidate = join(folder, n == 1 ? name : "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            do { _ = try await store.stat(path: candidate) } catch CoreKitError.notFound { return candidate }
        }
        throw CoreKitError.alreadyExists(join(folder, name))
    }

    private func copy(_ entry: RemoteEntry, to destination: String, store: any RemoteStore, engine: TransferEngine) async throws -> Int {
        if entry.isDirectory {
            try await store.createDirectory(path: destination)
            var total = 0
            for child in try await store.list(path: entry.path) where child.name != "." && child.name != ".." && PathRules.isVisible(path: child.path) {
                total += try await copy(child, to: join(destination, child.name), store: store, engine: engine)
            }
            return total
        }
        // Stage in a temporary file so the same verified upload path is used for restores.
        let temp = try await download(entry, store: store)
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await engine.upload(localURL: temp, remotePath: destination)
        return 1
    }

    private func download(_ entry: RemoteEntry, store: any RemoteStore) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            var offset: Int64 = 0
            while offset < entry.size {
                let length = Int(min(Int64(8 * 1024 * 1024), entry.size - offset))
                let data = try await store.read(path: entry.path, offset: offset, length: length)
                guard !data.isEmpty else { throw CoreKitError.remote("The snapshot ended early.") }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
            }
            try handle.close()
            return temp
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: Recently deleted

    func loadTrash() async {
        let ui = timeTravelUI
        guard let c = active else { ui.trash = []; return }
        ui.trashLoading = true
        defer { ui.trashLoading = false }
        do {
            let trash = RemoteTrash(store: try remoteStore(for: c), metadata: try metadataStore(for: c))
            noteContact(c)
            _ = try await trash.purgeExpired()
            ui.trash = try await trash.items()
            ui.trashError = nil
            if !ui.trash.contains(where: { $0.id == ui.selectedTrash }) { ui.selectedTrash = ui.trash.first?.id }
        } catch { ui.trashError = message(for: error) }
    }

    /// Puts items back where they were. An item whose name is taken now is skipped, never replaced.
    func restoreFromTrash(_ items: [TrashedItem]) async {
        guard let c = active, !items.isEmpty else { return }
        timeTravelUI.trashLoading = true
        var restored = 0, failures: [String] = []
        for item in items {
            do {
                try await RemoteTrash(store: remoteStore(for: c), metadata: metadataStore(for: c)).restore(item)
                restored += 1
            } catch { failures.append("\(item.name): \(message(for: error))") }
        }
        if failures.isEmpty {
            say(restored == 1 ? "Restored \(items[0].name) to \(PathRules.parent(of: items[0].originalPath))." : "Restored \(restored) items.")
        } else {
            say("Restored \(restored) of \(items.count). \(failures.joined(separator: "; "))", error: true)
        }
        await browser?.refreshOpenFolders()
        await loadTrash()
    }
}
