import SwiftUI
import CoreKit

/// A folder the person uploaded into, remembered per storage so the drop panel can offer it again.
struct UploadDestinationRecord: Codable, Equatable {
    var path: String
    var count: Int
    var lastUsed: Date
}

/// One drop on the panel, from the moment a tile receives it until Done goes away.
struct DropBatch: Equatable {
    let id = UUID()
    let connectionID: UUID
    let folder: String
    let urls: [URL]
    /// Transfers that existed before the drop; everything new for these URLs belongs to this batch.
    let preexisting: Set<UUID>
    let started = Date()
    var size: Int64?
    var hasFolder: Bool
    var share: Bool
    var move: Bool
    var finished: Date?
    var landed = 0
    var failed = 0
    var movedOriginals = false

    /// Undo trashes exactly the files this batch published. Folder drops may merge into existing folders,
    /// and moved originals would leave nothing behind, so neither offers Undo.
    var undoable: Bool { !hasFolder && !movedOriginals && landed > 0 }
}

extension AppModel {
    private static let destinationsFile = "upload-destinations.json"

    // MARK: Remembered destinations (per storage, last 10, most recent first)

    func loadUploadDestinations() {
        guard !isDemo else { return }
        panelUI.destinations = SharedJSON.load([String: [UploadDestinationRecord]].self, name: Self.destinationsFile) ?? [:]
    }

    func uploadDestinations(for connectionID: UUID) -> [UploadDestinationRecord] {
        panelUI.destinations[connectionID.uuidString] ?? []
    }

    func recordUploadDestination(_ path: String, for connectionID: UUID) {
        var list = uploadDestinations(for: connectionID)
        let count = (list.first { $0.path == path }?.count ?? 0) + 1
        list.removeAll { $0.path == path }
        list.insert(UploadDestinationRecord(path: path, count: count, lastUsed: Date()), at: 0)
        panelUI.destinations[connectionID.uuidString] = Array(list.prefix(10))
        guard !isDemo else { return }
        do { try SharedJSON.save(panelUI.destinations, name: Self.destinationsFile) }
        catch { diagnostics.add("Could not save upload destinations: \(message(for: error))") }
    }

    func recentUploadFolders(for connectionID: UUID) -> [String] {
        var folders = uploadDestinations(for: connectionID).map(\.path)
        for transfer in transfers.reversed() where transfer.connectionID == connectionID && transfer.phase != .cancelled {
            let folder = PathRules.parent(of: transfer.publishedPath ?? transfer.remotePath)
            if !folders.contains(folder) { folders.append(folder) }
            if folders.count == 10 { break }
        }
        return folders
    }

    func uploadSubfolders(in path: String, connectionID: UUID) async throws -> [RemoteEntry] {
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
            throw AppError.unavailable("This storage connection was removed.")
        }
        let path = try PathRules.normalize(path)
        let store = try remoteStore(for: connection)
        noteContact(connection)
        guard try await store.stat(path: path).isDirectory else { throw AppError.unavailable("This folder is no longer available.") }
        let entries = try await store.list(path: path)
        try Task.checkCancellation()
        return entries.filter { $0.isDirectory && $0.name != "." && $0.name != ".." && PathRules.isVisible(path: $0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func chooseFilesForUpload(to folder: String, connectionID: UUID) {
        guard activeID == connectionID else { say("The active storage changed. Choose an upload destination again.", error: true); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(folder)."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                do {
                    guard let connection = self.connections.first(where: { $0.id == connectionID }), self.activeID == connectionID else {
                        throw AppError.unavailable("The active storage changed. Choose an upload destination again.")
                    }
                    let path = try PathRules.normalize(folder)
                    let store = try self.remoteStore(for: connection)
                    self.noteContact(connection)
                    guard try await store.stat(path: path).isDirectory else { throw AppError.unavailable("The upload destination is no longer a folder.") }
                    guard self.activeID == connectionID else { throw AppError.unavailable("The active storage changed. Choose an upload destination again.") }
                    self.recordUploadDestination(path, for: connectionID)
                    self.upload(urls, to: path)
                } catch { self.say("Could not choose the upload destination: \(message(for: error))", error: true) }
            }
        }
    }

    // MARK: Drop to upload: Pick

    /// The panel's Upload tile and the status item's "Upload to…" action: files first, then a destination tile.
    func chooseFilesForPanel() {
        guard active != nil else { open(.addStorage); return }
        panelUI.close()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose files or folders, then pick where they go."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self.beginPick(urls, live: false) }
        }
    }

    /// Turns the panel into destination tiles for these files. `live` while the pointer still carries them.
    func beginPick(_ urls: [URL], live: Bool) {
        let files = Self.fileURLs(urls)
        guard !files.isEmpty, let c = active else { return }
        let ui = panelUI
        if ui.mode == .pick, ui.pickURLs == files {
            ui.dragLive = live
            if live { watchDragEnd() }
            ui.open()
            return
        }
        endDrop()
        ui.openedForDrop = !ui.isOpen
        ui.pickURLs = files
        ui.pickSize = nil
        ui.pickHasFolder = files.contains(where: Self.isFolder)
        ui.dragLive = live
        ui.folderQuery = ""
        ui.mode = .pick
        ui.open()
        let measuring = Task.detached { Self.measure(files) }
        ui.sizeTask = measuring
        Task {
            let (size, hasFolder) = await measuring.value
            guard ui.pickURLs == files else { return }
            ui.pickSize = size; ui.pickHasFolder = hasFolder
        }
        if live { watchDragEnd() }
        Task {
            let folders = (try? await uploadSubfolders(in: "/", connectionID: c.id)) ?? []
            guard ui.pickURLs == files else { return }
            ui.pickFolders = folders.map(\.path)
        }
    }

    /// File URLs as paths. Finder drags carry file reference URLs (file:///.file/id=…), whose names are not the file's.
    nonisolated static func fileURLs(_ urls: [URL]) -> [URL] {
        urls.compactMap { $0.isFileURL ? ($0 as NSURL).filePathURL ?? $0 : nil }
    }

    nonisolated static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Total bytes of the dragged items, and whether any is a folder. Off the main actor; folders are walked.
    nonisolated static func measure(_ urls: [URL]) -> (Int64, Bool) {
        var total: Int64 = 0, hasFolder = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                hasFolder = true
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
                while let item = walker?.nextObject() as? URL {
                    let v = try? item.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory != true, v?.isSymbolicLink != true { total += Int64(v?.fileSize ?? 0) }
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return (total, hasFolder)
    }

    /// Releasing outside any tile cancels with no side effects. AppKit tells the drop target, not us, where a drag
    /// ended, so watch the button: once it is up and no tile took the files, the drag ended elsewhere.
    private func watchDragEnd() {
        let ui = panelUI
        ui.dragWatch?.cancel()
        ui.dragWatch = Task { [weak self] in
            while !Task.isCancelled, ui.dragLive, ui.mode == .pick {
                try? await Task.sleep(for: .milliseconds(150))
                guard NSEvent.pressedMouseButtons & 1 == 0 else { continue }
                try? await Task.sleep(for: .milliseconds(400))   // a drop on a tile or the status item lands first
                if !Task.isCancelled, ui.dragLive, ui.mode == .pick { self?.cancelPick() }
                return
            }
        }
    }

    func cancelPick() {
        guard panelUI.mode == .pick else { return }
        let close = panelUI.openedForDrop
        endDrop()
        if close { panelUI.close() }
    }

    /// Free space after the drop, only when the provider reports a quota.
    func dropFit(for c: StorageConnection, size: Int64?) -> (free: Int64, total: Int64, shortfall: Int64)? {
        guard let cap = capacity(for: c), let size else { return nil }
        let free = cap.total - cap.used
        return (free, cap.total, max(0, size - free))
    }

    /// "Upload and share" fits only what the provider can share on its own: one file on S3, one folder on a Storage Box.
    func canShareDrop(_ urls: [URL]) -> Bool {
        guard !isDemo, let c = active, c.encryptionEnabled != true, urls.count == 1, let url = urls.first else { return false }
        return (c.provider == .s3 && !Self.isFolder(url)) || (c.provider == .hetzner && Self.isFolder(url))
    }

    // MARK: Drop to upload: Upload

    /// Starts the upload straight away; no dialog in between. Refuses before any byte if it cannot fit.
    func dropUpload(_ urls: [URL], to folder: String, share: Bool = false) {
        let files = Self.fileURLs(urls)
        guard let c = active, !files.isEmpty else { return }
        let ui = panelUI
        let move = NSEvent.modifierFlags.contains(.option) && !share
        let preexisting = Set(transfers.map(\.id))
        let measuring = ui.pickURLs == files ? ui.sizeTask : nil
        ui.dragLive = false
        ui.dragWatch?.cancel()
        Task {
            var size: Int64? = ui.pickURLs == files ? ui.pickSize : nil
            var hasFolder = files.contains(where: Self.isFolder)
            // Only a known quota needs the total before sending; otherwise start now and count alongside.
            if capacity(for: c) != nil {
                let measured = await (measuring ?? Task.detached { Self.measure(files) }).value
                size = measured.0; hasFolder = measured.1
                if let fit = dropFit(for: c, size: size), fit.shortfall > 0 {
                    say("\(Format.bytes(size ?? 0)) won’t fit on \(c.name). Free up \(Format.bytes(fit.shortfall)) first.", error: true)
                    return
                }
            }
            if share, let url = files.first, Self.isFolder(url) {
                // Sharing a folder that already exists would expose more than what was dropped.
                let target = join(folder, url.lastPathComponent)
                if (try? await remoteStore(for: c).stat(path: target)) != nil {
                    say("A folder named \(url.lastPathComponent) is already there. Share it from Files instead.", error: true)
                    return
                }
            }
            guard ui.mode == .pick, activeID == c.id else { return }
            recordUploadDestination(folder, for: c.id)
            ui.batch = DropBatch(connectionID: c.id, folder: folder, urls: files, preexisting: preexisting,
                                 size: size, hasFolder: hasFolder, share: share, move: move)
            ui.mode = .upload
            upload(files, to: folder)
            if size == nil, let measuring {
                Task { let s = await measuring.value.0; if ui.batch?.urls == files { ui.batch?.size = s } }
            }
            watchBatch()
        }
    }

    /// Transfers that belong to a drop: new since the drop, for one of the dropped files or inside a dropped folder.
    func transfers(in batch: DropBatch) -> [Transfer] {
        transfers.filter { t in
            !batch.preexisting.contains(t.id) && t.connectionID == batch.connectionID
                && batch.urls.contains { t.localURL == $0 || t.localURL.path.hasPrefix($0.path + "/") }
        }
    }

    private func watchBatch() {
        let ui = panelUI
        guard let id = ui.batch?.id else { return }
        ui.batchWatch?.cancel()
        ui.batchWatch = Task { [weak self] in
            var waited = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                waited += 0.4
                guard let self, let batch = ui.batch, batch.id == id, ui.mode == .upload else { return }
                let mine = self.transfers(in: batch)
                // Nothing queued (only temporary files, or every item was refused): the upload call already said why.
                if mine.isEmpty { if waited > 8 { self.endDrop() }; continue }
                if mine.contains(where: { $0.phase.isActive }) { continue }
                await self.finishDrop(batch, mine)
                return
            }
        }
    }

    private func finishDrop(_ batch: DropBatch, _ mine: [Transfer]) async {
        var b = batch
        b.finished = Date()
        b.landed = mine.filter { $0.phase == .verified || $0.phase == .unverified }.count
        b.failed = mine.count - b.landed - mine.filter { $0.phase == .cancelled }.count
        guard b.landed > 0 else { endDrop(); return }   // cancelled or failed; Activity carries the failures
        if b.move { b.movedOriginals = moveOriginals(b, mine) }
        if b.share { await shareUploaded(b, mine) }
        guard panelUI.isOpen else { endDrop(); return }
        panelUI.batch = b
        panelUI.mode = .done
        startDoneCountdown()
    }

    /// Option-drop: originals go to the Trash only after every dropped file was verified on the storage.
    private func moveOriginals(_ b: DropBatch, _ mine: [Transfer]) -> Bool {
        guard !b.hasFolder,
              b.urls.allSatisfy({ url in mine.contains { $0.localURL == url && $0.phase == .verified } }) else {
            say(b.hasFolder ? "Kept the originals: folders are always copied." : "Kept the originals on this Mac: not every file could be verified.")
            return false
        }
        var moved = 0
        for url in b.urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); moved += 1 }
            catch { say("Could not move \(url.lastPathComponent) to the Trash: \(message(for: error))", error: true) }
        }
        return moved == b.urls.count
    }

    private func shareUploaded(_ b: DropBatch, _ mine: [Transfer]) async {
        guard let url = b.urls.first, let c = connections.first(where: { $0.id == b.connectionID }) else { return }
        let path = Self.isFolder(url) ? join(b.folder, url.lastPathComponent)
            : (mine.first { $0.localURL == url }?.publishedPath ?? join(b.folder, url.lastPathComponent))
        do {
            let entry = try await remoteStore(for: c).stat(path: path)
            sharingItem = FileNode(item: StoredItem(id: entry.path, entry: entry), displayName: entry.name)
            open(.share)
        } catch { say("Uploaded, but could not start sharing: \(message(for: error))", error: true) }
    }

    func reopenShare() {
        guard let b = panelUI.batch else { return }
        Task { await shareUploaded(b, transfers(in: b)) }
    }

    private func startDoneCountdown() {
        let ui = panelUI
        ui.doneLeft = 6
        ui.countdown?.cancel()
        ui.countdown = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard ui.mode == .done else { return }
                if !ui.isHovered { ui.doneLeft = max(0, ui.doneLeft - 0.1) }
                if ui.doneLeft <= 0 { self?.endDrop(); return }
            }
        }
    }

    // MARK: Pause, cancel, undo

    func cancelDropUpload() {
        guard let b = panelUI.batch else { return }
        for t in transfers(in: b) where t.phase.isActive { cancel(t.id) }
        endDrop()
    }

    /// Moves exactly the copies this drop published to Recently deleted. A file that changed since it was verified stays.
    func undoDropUpload() {
        guard let b = panelUI.batch, b.undoable, let c = connections.first(where: { $0.id == b.connectionID }) else { return }
        let published = transfers(in: b).compactMap { t -> String? in
            guard t.phase == .verified || t.phase == .unverified else { return nil }
            return t.publishedPath
        }
        endDrop()
        Task {
            do {
                let store = try remoteStore(for: c), meta = try metadataStore(for: c)
                let trash = RemoteTrash(store: store, metadata: meta)
                noteContact(c)
                var moved = 0, kept = 0
                for path in published {
                    guard let version = verifiedVersions[verifiedKey(c.id, path)],
                          let item = try await meta.refresh(store: store, path: PathRules.parent(of: path)).first(where: { $0.entry.path == path })
                    else { kept += 1; continue }
                    do { try await trash.delete(item, expectedVersion: version); moved += 1 }
                    catch CoreKitError.itemChanged { kept += 1 }
                }
                await browser?.refreshOpenFolders()
                let items = moved == 1 ? "1 uploaded item" : "\(moved) uploaded items"
                say(kept == 0 ? "Moved \(items) to Recently deleted."
                    : "Moved \(items) to Recently deleted. \(kept) changed or could not be verified and stayed.", error: kept > 0)
            } catch { say("Could not undo the upload: \(message(for: error))", error: true) }
        }
    }

    /// Back to the normal panel; never touches files.
    func endDrop() {
        let ui = panelUI
        ui.dragWatch?.cancel(); ui.batchWatch?.cancel(); ui.countdown?.cancel(); ui.sizeTask?.cancel()
        ui.mode = .normal
        ui.batch = nil
        ui.pickURLs = []
        ui.pickSize = nil
        ui.pickFolders = []
        ui.dragLive = false
        ui.openedForDrop = false
    }

    /// The panel went away: a pending pick or a finished drop ends; an upload keeps going.
    func panelDidClose() {
        if panelUI.mode == .pick || panelUI.mode == .done { endDrop() }
    }
}
