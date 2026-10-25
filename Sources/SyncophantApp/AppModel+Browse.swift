import SwiftUI
import CoreKit

extension AppModel {
    /// Seconds between checks of the shown folder. The footer quotes this number, so keep them together.
    static let pollInterval = 30

    /// Builds (or reuses) the tree for the active connection and renders cached rows before asking the network.
    func openActive() async {
        guard let c = active else { browser = nil; return }
        if filesUI.storageID != c.id {
            filesUI.reset(for: c.id)
            // A new storage starts at its root, and the old storage's folder is not a Back step.
            if currentFolder != "/" { filesUI.travelling = true; currentFolder = "/" }
        }
        let loader: TreeLoader
        if let existing = loaders[c.id] {
            loader = existing
        } else {
            do {
                // The store maps the virtual "/" onto connection.rootPath; never prefix it here.
                loader = TreeLoader(store: try remoteStore(for: c), meta: try metadataStore(for: c), rootPath: "/")
            } catch {
                connectionErrors[c.id] = message(for: error)
                browser = nil
                return
            }
            let id = c.id
            loader.willList = { [weak self] in if let self, let c = self.connections.first(where: { $0.id == id }) { self.noteContact(c) } }
            loader.didList = { [weak self] in self?.lastChecked[id] = Date(); self?.connectionErrors[id] = nil }
            loader.didFail = { [weak self] error in
                self?.connectionErrors[id] = message(for: error)
                self?.diagnostics.add("Listing failed: \(message(for: error))")
            }
            loaders[c.id] = loader
        }
        browser = loader
        await showCurrentFolder()
    }

    /// Lists `currentFolder` and re-reads which of its files are on this Mac.
    func showCurrentFolder() async {
        guard let browser else { return }
        await browser.open(currentFolder)
        await refreshLocalStates()
    }

    func refresh() { Task { await browser?.refreshOpenFolders(); await refreshLocalStates() } }

    func startPolling() {
        browserVisible = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, !Task.isCancelled, self.browserVisible, self.destination == .files,
                      !self.isSearching, self.connectionErrors[self.activeID ?? UUID()] == nil else { continue }
                await self.browser?.refreshOpenFolders()
                await self.refreshLocalStates()
            }
        }
    }

    func stopPolling() { browserVisible = false; pollTask?.cancel() }

    // MARK: Search (cached listings only)

    /// Searches every folder of the active storage this Mac has listed. Results land in `searchResults`.
    func searchChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let c = active, let meta = try? metadataStore(for: c) else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let items = (try? await meta.search(query)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = browser?.nodes(from: items, reusing: []) ?? []
            // Search rows show the whole path so identical names stay distinguishable.
            for n in searchResults { n.displayName = n.path }
        }
    }

    func focusSearch() {
        destination = .files
        searchFocusTick += 1
    }

    // MARK: Status

    func status(of node: FileNode) -> FileStatus {
        guard let c = active else { return .none }
        let key = verifiedKey(c.id, node.path)
        if let t = transfer(for: node), t.phase != .verified { return t.status }
        if isConflictCopy(node) { return .conflict }
        // A stored receipt counts only while the server still shows exactly the version the engine verified.
        if node.item.isVerified || verifiedVersions[key] == node.item.entry.version { return .verified }
        if node.item.isPinned { return .kept }
        return node.isDirectory ? .none : .onBox
    }

    /// Badge state for a row. "On this Mac" only when the Finder drive reports the file's data as present.
    func fileState(of node: FileNode) -> FileState? {
        let state = FileState(status(of: node))
        if state == .onBox, filesUI.local[node.path] == true { return .onMac }
        return state
    }

    /// The latest upload of this path on the active storage, if any.
    func transfer(for node: FileNode) -> Transfer? {
        guard let c = active else { return nil }
        return transfers.last { $0.connectionID == c.id && ($0.publishedPath ?? $0.remotePath) == node.path && $0.phase != .cancelled }
    }

    /// Changes whenever any displayed status could have changed.
    var statusStamp: Int {
        var h = Hasher()
        for t in transfers { h.combine(t.id); h.combine(t.phase); h.combine(t.completed) }
        h.combine(verifiedVersions.count)
        h.combine(filesUI.localStamp)
        return h.finalize()
    }

    func verifiedKey(_ id: UUID, _ path: String) -> String { "\(id.uuidString)\(path)" }

    // MARK: Conflict copies

    /// The engine publishes a colliding upload as `name (conflict <machine> <date> <id>).ext` next to the original.
    func isConflictCopy(_ node: FileNode) -> Bool { node.item.entry.name.contains(" (conflict ") }

    /// Splits a conflict copy's name into the original name and the machine that made it.
    static func conflictParts(_ name: String) -> (original: String, machine: String)? {
        guard let start = name.range(of: " (conflict ") else { return nil }
        let rest = name[start.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        let machine = rest[..<close].split(separator: " ").first.map(String.init) ?? ""
        return (String(name[..<start.lowerBound]) + String(rest[rest.index(after: close)...]), machine)
    }

    /// Words for the machine named in a conflict copy; this Mac's own copies say so.
    static func machineName(_ raw: String) -> String {
        let mine = String((Host.current().localizedName ?? "Mac").map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(24))
        return raw == mine ? "this Mac" : raw.replacingOccurrences(of: "-", with: " ")
    }

    /// The original and its conflict copy, when both are in the shown folder.
    func conflictPair(for node: FileNode) -> (original: FileNode, copy: FileNode)? {
        guard let rows = browser?.roots, !node.isDirectory else { return nil }
        if let parts = Self.conflictParts(node.item.entry.name) {
            let original = rows.first { !$0.isDirectory && $0.item.entry.name == parts.original && PathRules.parent(of: $0.path) == PathRules.parent(of: node.path) }
            return original.map { ($0, node) }
        }
        let copy = rows.first { Self.conflictParts($0.item.entry.name)?.original == node.item.entry.name && PathRules.parent(of: $0.path) == PathRules.parent(of: node.path) }
        return copy.map { (node, $0) }
    }

    // MARK: Selection helpers

    /// Uploads, new folders and drops without a target go to the folder on screen.
    var uploadFolder: String { currentFolder }

    /// Files shows its breadcrumb instead; the other sections are titled by name, as on the boards.
    var windowTitle: String {
        guard let c = active else { return "Syncophant" }
        return destination == .files ? c.name : destination.title
    }

    var windowSubtitle: String {
        guard let c = active else { return "No storage connected" }
        return destination == .files ? connectionLine(for: c) : ""
    }
}
