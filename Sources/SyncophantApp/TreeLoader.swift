import Foundation
import CoreKit

/// One row in the file browser. Reference type so NSOutlineView keeps expansion across reloads.
@MainActor
final class FileNode {
    var item: StoredItem
    var displayName: String
    var children: [FileNode]?
    var isLoading = false
    var isExpanded = false
    var loadError: String?

    init(item: StoredItem, displayName: String) { self.item = item; self.displayName = displayName }

    var path: String { item.entry.path }
    var isDirectory: Bool { item.entry.isDirectory }
}

/// Lists one folder of a remote tree at a time (`folder`), cached rows first, network second.
/// `roots` are the rows of `folder`. Snapshot outlines still expand nodes in place with `load(_:)`.
/// With `meta == nil` (snapshots) rows are built straight from the listing.
@MainActor @Observable
final class TreeLoader {
    private(set) var roots: [FileNode] = []
    private(set) var revision = 0
    func bump() { revision &+= 1 }
    private(set) var rootError: String?
    private(set) var isRefreshing = false
    private(set) var lastListed: Date?
    /// The folder `roots` belong to.
    private(set) var folder: String
    /// Item counts of sub-folders, from listings this Mac already has. Missing means unknown.
    private(set) var counts: [String: Int] = [:]

    @ObservationIgnored let store: any RemoteStore
    @ObservationIgnored let meta: MetadataStore?
    @ObservationIgnored let rootPath: String
    @ObservationIgnored var willList: (@MainActor () -> Void)?
    @ObservationIgnored var didFail: (@MainActor (Error) -> Void)?
    @ObservationIgnored var didList: (@MainActor () -> Void)?

    init(store: any RemoteStore, meta: MetadataStore?, rootPath: String) {
        self.store = store; self.meta = meta; self.rootPath = rootPath; self.folder = rootPath
    }

    /// Shows `path`: cached rows at once, then the live listing. A slower listing of a folder the person
    /// already left never overwrites the folder they are looking at.
    func open(_ path: String) async {
        if path != folder {
            folder = path
            roots = []
            counts = [:]
            rootError = nil
            revision &+= 1
        }
        if roots.isEmpty, let meta, let cached = try? await meta.items(parentPath: path), !cached.isEmpty, folder == path {
            roots = nodes(from: cached, reusing: [])
            revision &+= 1
        }
        isRefreshing = true
        defer { if folder == path { isRefreshing = false; revision &+= 1 } }
        do {
            let items = try await list(path)
            guard folder == path else { return }
            roots = nodes(from: items, reusing: roots)
            rootError = nil
            await countChildren(of: path)
        } catch {
            guard folder == path else { return }
            rootError = message(for: error)
            didFail?(error)
        }
    }

    func loadRoot() async { await open(folder) }

    func load(_ node: FileNode) async {
        guard node.isDirectory, !node.isLoading else { return }
        node.isLoading = true
        revision &+= 1
        defer { node.isLoading = false; revision &+= 1 }
        if node.children == nil, let meta, let cached = try? await meta.items(parentPath: node.path), !cached.isEmpty {
            node.children = nodes(from: cached, reusing: [])
            revision &+= 1
        }
        do {
            node.children = nodes(from: try await list(node.path), reusing: node.children ?? [])
            node.loadError = nil
        } catch {
            node.loadError = message(for: error)
            didFail?(error)
        }
    }

    /// Refreshes the shown folder and every folder open in a snapshot outline.
    func refreshOpenFolders() async {
        await loadRoot()
        for node in flatten(roots) where node.isExpanded && node.isDirectory { await load(node) }
    }

    func find(path: String) -> FileNode? { flatten(roots).first { $0.path == path } }

    private func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    /// Counts come only from listings already in the metadata cache.
    // ponytail: one cache query per sub-folder, capped at 300; a COUNT GROUP BY in MetadataStore if folders get wider.
    private func countChildren(of path: String) async {
        guard let meta else { return }
        var found: [String: Int] = [:]
        for node in roots.lazy.filter(\.isDirectory).prefix(300) {
            if let n = try? await meta.items(parentPath: node.path).count, n > 0 { found[node.path] = n }
        }
        guard folder == path else { return }
        counts = found
    }

    private func list(_ path: String) async throws -> [StoredItem] {
        willList?()
        if let meta {
            // The metadata store owns list + reconcile so stale listings cannot undo concurrent renames.
            let items = try await meta.refresh(store: store, path: path)
            didList?()
            lastListed = Date()
            return items
        }
        let entries = try await store.list(path: path).filter { $0.name != "." && $0.name != ".." }
        didList?()
        lastListed = Date()
        return entries.filter { PathRules.isVisible(path: $0.path) }.map { StoredItem(id: $0.path, entry: $0) }
    }

    func nodes(from items: [StoredItem], reusing old: [FileNode]) -> [FileNode] {
        let names = PathRules.displayNames(for: items.map(\.entry))
        let byID = Dictionary(old.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
        let made = items.map { item -> FileNode in
            let name = names[item.entry.id] ?? item.entry.name
            if let existing = byID[item.id] { existing.item = item; existing.displayName = name; return existing }
            return FileNode(item: item, displayName: name)
        }
        return made.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

extension TreeLoader {
    /// Forces the outline to redraw status columns after a change that did not come from a listing.
    func refreshStamp() { bump() }
}
