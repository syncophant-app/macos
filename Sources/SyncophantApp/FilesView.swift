import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import CoreKit

/// Files section UI state (inspector, view mode, history, drag, which files are on this Mac). Owned by the Files screen.
@MainActor @Observable
final class FilesState {
    enum Mode: String, CaseIterable { case list, icons }

    var showInspector = false
    var mode: Mode = .list
    /// Folder history of the active storage. `currentFolder` on AppModel is the folder on screen.
    var back: [String] = []
    var forward: [String] = []
    /// Set while Back/Forward or a storage switch moves `currentFolder`, so the move is not recorded as a visit.
    @ObservationIgnored var travelling = false
    var storageID: UUID?
    /// Search runs over the shown folder until the person asks for the whole storage.
    var searchAll = false
    var drag: (target: String, count: Int)?
    /// Files of the shown folder whose data the Finder drive holds. Missing = not known.
    var local: [String: Bool] = [:]
    var localStamp = 0
    @ObservationIgnored var driveRoot: URL?
    var previewURL: URL?

    func reset(for id: UUID) {
        storageID = id
        back = []; forward = []
        local = [:]; localStamp &+= 1
        driveRoot = nil
        searchAll = false
    }
}

// MARK: - Files

struct FilesView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        @Bindable var state = app.filesUI
        Group {
            if let loader = app.browser {
                content(loader)
            } else if let c = app.active, let e = app.connectionErrors[c.id] {
                ContentUnavailableView {
                    Label("Can’t open \(c.name)", systemImage: "wifi.exclamationmark")
                } description: { Text(e) } actions: {
                    Button("Try Again") { app.perform(.retryListing(c.id)) }
                }
            } else {
                ProgressView("Opening…").controlSize(.large)
            }
        }
        .toolbar { FilesToolbar() }
        .toolbar(removing: .title)
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { searchEverywhere() }
        .onChange(of: app.searchText) {
            state.searchAll = false
            app.searchResults = []
        }
        .onChange(of: app.searchFocusTick) { searchFocused = true }
        .onChange(of: app.currentFolder) { old, new in visit(from: old, to: new) }
        .task { if app.browser?.folder != app.currentFolder { await app.showCurrentFolder() } }
        .inspector(isPresented: $state.showInspector) {
            FilesInspector().inspectorColumnWidth(300)
        }
        .quickLookPreview($state.previewURL)
    }

    private func visit(from old: String, to new: String) {
        let state = app.filesUI
        if state.travelling { state.travelling = false } else if old != new {
            state.back.append(old)
            state.forward = []
        }
        app.searchText = ""
        guard app.browser?.folder != new else { return }
        Task { await app.showCurrentFolder() }
    }

    private func searchEverywhere() {
        guard app.isSearching else { return }
        app.filesUI.searchAll = true
        app.searchChanged()
    }

    /// Rows on screen: the folder, the folder filtered by the query, or storage-wide results.
    private func rows(_ loader: TreeLoader) -> [FileNode] {
        guard app.isSearching else { return loader.roots }
        if app.filesUI.searchAll { return app.searchResults }
        let q = app.searchText.trimmingCharacters(in: .whitespaces)
        return loader.roots.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private func content(_ loader: TreeLoader) -> some View {
        let nodes = rows(loader)
        let state = app.filesUI
        ZStack {
            switch state.mode {
            case .list:
                FileOutline(nodes: nodes, stamp: listStamp(loader), flat: true, actions: actions(loader), badgeStamp: app.statusStamp)
            case .icons:
                FileGrid(nodes: nodes)
            }
            if nodes.isEmpty { emptyState(loader) }
            if let drag = state.drag { DropOverlay(target: drag.target, count: drag.count) }
        }
        .overlay(alignment: .bottom) {
            if app.notice == nil, !app.activeTransfers.isEmpty {
                ActivityPill().padding(.bottom, Space.md).transition(.offset(y: 8).combined(with: .opacity))
            }
        }
        .motion(Motion.smooth, value: app.notice == nil && !app.activeTransfers.isEmpty)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if app.isSearching { SearchAllRow() }
                FilesFooter(loader: loader, shown: nodes)
            }
        }
    }

    /// Changes when the rows themselves change; badge-only changes go through `statusStamp`.
    private func listStamp(_ loader: TreeLoader) -> Int {
        var h = Hasher()
        h.combine(loader.revision); h.combine(app.searchText); h.combine(app.filesUI.searchAll)
        h.combine(app.searchResults.count); h.combine(loader.counts.count)
        return h.finalize()
    }

    @ViewBuilder private func emptyState(_ loader: TreeLoader) -> some View {
        if app.isSearching {
            ContentUnavailableView.search(text: app.searchText).allowsHitTesting(false)
        } else if let e = loader.rootError {
            ContentUnavailableView {
                Label("Can’t list this folder", systemImage: "wifi.exclamationmark")
            } description: { Text(e) } actions: { Button("Try Again") { app.refresh() } }
        } else if loader.isRefreshing {
            ProgressView().controlSize(.regular)
        } else {
            ContentUnavailableView("This folder is empty", systemImage: "folder",
                                   description: Text("Drop files here to upload them."))
                .allowsHitTesting(false)
        }
    }

    private func actions(_ loader: TreeLoader) -> OutlineActions {
        let storage = app.active?.name ?? "your storage"
        return OutlineActions(
            status: { app.status(of: $0) },
            select: { app.selection = $0 },
            menu: { nodes in app.menu(for: nodes) },
            drop: { urls, node in app.upload(urls, to: node?.path ?? app.currentFolder) },
            quickLookURL: { node in
                do { return try await app.visibleURL(for: node) }
                catch { app.say("Quick Look: \(message(for: error))", error: true); return nil }
            },
            state: { app.fileState(of: $0) },
            words: { node, state in app.words(for: node, state, storage: storage) },
            note: { node in
                AppModel.conflictParts(node.item.entry.name).map { "Also edited on \(AppModel.machineName($0.machine))" }
            },
            sizeText: { node in app.sizeText(node) },
            open: { app.open($0) },
            rowActions: { node, hovered in AnyView(app.rowActions(node, hovered: hovered)) },
            dragChanged: { active, folder, count in
                app.filesUI.drag = active ? (folder?.displayName ?? app.folderName(app.currentFolder), count) : nil
            })
    }
}

// MARK: - Words, sizes and menus

extension AppModel {
    func folderName(_ path: String) -> String {
        path == "/" ? (active?.name ?? "this storage") : PathRules.name(of: path)
    }

    /// "Stopped at 82%" when the engine measured where a failed upload stopped.
    func words(for node: FileNode, _ state: FileState, storage: String) -> String {
        if state == .failed, let t = transfer(for: node), t.size > 0, t.completed > 0 {
            return "Stopped at \(Int(Double(t.completed) / Double(t.size) * 100))%"
        }
        return state.words(storage: storage)
    }

    func sizeText(_ node: FileNode) -> String {
        guard node.isDirectory else { return Format.bytes(node.item.entry.size) }
        guard let n = browser?.counts[node.path] else { return "" }
        return "\(n) item\(n == 1 ? "" : "s")"
    }

    /// On this Mac as far as anyone can tell: kept, or the drive holds its data.
    func isLocal(_ node: FileNode) -> Bool { node.item.isPinned || filesUI.local[node.path] == true }

    func canShare(_ nodes: [FileNode]) -> Bool {
        guard !isDemo, let c = active, c.encryptionEnabled != true, nodes.count == 1, let item = nodes.first else { return false }
        return (c.provider == .s3 && !item.isDirectory) || (c.provider == .hetzner && item.isDirectory)
    }

    func quickLook(_ node: FileNode) {
        Task {
            do { filesUI.previewURL = try await visibleURL(for: node) }
            catch { say("Quick Look: \(message(for: error))", error: true) }
        }
    }

    /// Only actions that would do something for these items.
    func menu(for nodes: [FileNode]) -> [OutlineMenuItem] {
        guard let first = nodes.first else { return [] }
        let finder = canUseFinder
        let one = nodes.count == 1
        let allKept = nodes.allSatisfy(\.item.isPinned)
        var items: [OutlineMenuItem] = []
        if one {
            items.append(OutlineMenuItem(title: "Open", enabled: first.isDirectory || finder) { self.open(first) })
            if !first.isDirectory, finder { items.append(OutlineMenuItem(title: "Quick Look") { self.quickLook(first) }) }
            items.append(.separator)
        }
        if finder {
            items.append(allKept
                ? OutlineMenuItem(title: "Stop Keeping Downloaded", key: "p", modifiers: [.command, .option]) { self.stopKeeping(nodes) }
                : OutlineMenuItem(title: "Keep Downloaded", key: "p", modifiers: [.command, .option]) { self.keepOnThisMac(nodes) })
            if nodes.contains(where: isLocal) {
                items.append(OutlineMenuItem(title: "Remove Download", key: "e", modifiers: [.command, .option]) { self.removeDownload(nodes.filter(self.isLocal)) })
            }
        }
        let retryable = nodes.compactMap { transfer(for: $0) }.filter {
            if case .failed = $0.phase { return true }
            return $0.phase == .unverified
        }
        if !retryable.isEmpty {
            items.append(OutlineMenuItem(title: retryable.count == 1 ? "Retry Upload" : "Retry \(retryable.count) Uploads") { retryable.forEach { self.retry($0.id) } })
        }
        items.append(.separator)
        if canShare(nodes) { items.append(OutlineMenuItem(title: "Share…") { self.selection = nodes; self.beginSharing() }) }
        if canUseSnapshots { items.append(OutlineMenuItem(title: "Browse Versions…", key: "s", modifiers: [.command, .shift]) { self.selection = nodes; self.show(.timeTravel) }) }
        if finder, one {
            items += [
                .separator,
                OutlineMenuItem(title: "Copy Path", key: "c", modifiers: [.command, .option]) { self.copyPath(first) },
                OutlineMenuItem(title: "Show in Finder") { self.showInFinder(first) },
                OutlineMenuItem(title: "More", children: [OutlineMenuItem(title: "Open in Terminal") { self.openInTerminal(first) }]),
            ]
        }
        if !finder { items += [.separator, OutlineMenuItem(title: "Finder actions: \(finderUnavailableReason)", enabled: false)] }
        // No leading, trailing or doubled separators.
        var cleaned: [OutlineMenuItem] = []
        for i in items where !(i.isSeparator && (cleaned.isEmpty || cleaned.last!.isSeparator)) { cleaned.append(i) }
        if cleaned.last?.isSeparator == true { cleaned.removeLast() }
        return cleaned
    }

    /// Hover actions for a row. Built here because hosted cells don't see the SwiftUI environment.
    func rowActions(_ node: FileNode, hovered: Bool) -> RowActions {
        let failed = transfer(for: node).flatMap { t -> UUID? in
            if case .failed = t.phase { return t.id }
            return nil
        }
        return RowActions(
            retry: failed.map { id in { self.retry(id) } },
            pin: hovered && canUseFinder ? (node.item.isPinned, { node.item.isPinned ? self.stopKeeping([node]) : self.keepOnThisMac([node]) }) : nil,
            menu: hovered ? menu(for: [node]) : nil)
    }

    /// Creates "untitled folder" (or the next free name) in the folder on screen.
    func newFolder() {
        guard let c = active, let store = try? remoteStore(for: c) else { return }
        let parent = currentFolder
        Task {
            let existing = Set(((try? await store.list(path: parent)) ?? []).map(\.name))
            var name = "untitled folder", n = 2
            while existing.contains(name) { name = "untitled folder \(n)"; n += 1 }
            do {
                try await store.createDirectory(path: join(parent, name))
                say("Made “\(name)”.")
                refresh()
            } catch { say("Could not make a folder: \(message(for: error))", error: true) }
        }
    }
}

/// Retry for failed rows; otherwise, on hover, Keep Downloaded and More.
struct RowActions: View {
    var retry: (() -> Void)?
    var pin: (kept: Bool, toggle: () -> Void)?
    var menu: [OutlineMenuItem]?

    var body: some View {
        HStack(spacing: 2) {
            if let retry {
                Button("Retry", action: retry).buttonStyle(.glass).controlSize(.small)
            } else {
                if let pin {
                    Button(action: pin.toggle) {
                        Image(systemName: pin.kept ? "pin.fill" : "pin")
                            .foregroundStyle(pin.kept ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(pin.kept ? "Stop Keeping Downloaded" : "Keep Downloaded")
                    .accessibilityLabel(pin.kept ? "Stop Keeping Downloaded" : "Keep Downloaded")
                }
                if let menu, !menu.isEmpty {
                    Menu { MenuItems(items: menu) } label: {
                        Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Circle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("More actions")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// SwiftUI rendering of the same state-aware menu the list uses.
struct MenuItems: View {
    let items: [OutlineMenuItem]
    var body: some View {
        ForEach(items.indices, id: \.self) { i in
            let item = items[i]
            if item.isSeparator {
                Divider()
            } else if let children = item.children {
                Menu(item.title) { MenuItems(items: children) }
            } else {
                Button(item.title, action: item.run).disabled(!item.enabled)
            }
        }
    }
}

// MARK: - Toolbar

private struct FilesToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        @Bindable var state = app.filesUI
        ToolbarItemGroup(placement: .navigation) {
            Button { travel(back: true) } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(state.back.isEmpty).help("Back (⌘[)").keyboardShortcut("[", modifiers: .command)
            Button { travel(back: false) } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(state.forward.isEmpty).help("Forward (⌘])").keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItem(placement: .navigation) { Breadcrumb() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Picker("View", selection: $state.mode) {
                Label("List", systemImage: "list.bullet").tag(FilesState.Mode.list)
                Label("Icons", systemImage: "square.grid.2x2").tag(FilesState.Mode.icons)
            }
            .pickerStyle(.segmented)
            .help("Show as list or icons")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { app.chooseFilesToUpload() } label: { Label("Upload", systemImage: "arrow.up.doc") }
                .help("Upload into \(app.folderName(app.currentFolder)) (⌘U)")
                .disabled(app.active == nil)
            Button { app.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .help("New folder (⇧⌘N)")
                .disabled(app.active == nil)
            Button { app.beginSharing() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .help(app.canShareSelection ? "Share the selected item" : "Select one file on S3-compatible storage or one folder on a Hetzner Storage Box. Encrypted storage can’t be shared.")
                .disabled(!app.canShareSelection)
            Button { state.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help(state.showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
        }
        ToolbarSpacer(.fixed)
    }

    private func travel(back: Bool) {
        let state = app.filesUI
        guard let target = back ? state.back.popLast() : state.forward.popLast() else { return }
        if back { state.forward.append(app.currentFolder) } else { state.back.append(app.currentFolder) }
        state.travelling = true
        app.openFolder(target)
    }
}

/// Storage name, then each folder; every part opens its folder, the current one is bold.
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let crumbs = self.crumbs
        let shown: [(path: String, name: String)?] = crumbs.count > 4
            ? [crumbs[0], nil] + crumbs.suffix(2) : crumbs
        HStack(spacing: 4) {
            ForEach(shown.indices, id: \.self) { i in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                if let crumb = shown[i] {
                    let current = crumb.path == app.currentFolder
                    Button { app.openFolder(crumb.path) } label: {
                        Text(crumb.name).font(.system(size: 13, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(current)
                    .accessibilityLabel(current ? "\(crumb.name), current folder" : "Open \(crumb.name)")
                } else {
                    Menu("…") {
                        ForEach(crumbs.dropFirst().dropLast(2), id: \.path) { c in Button(c.name) { app.openFolder(c.path) } }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Folders in between")
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var crumbs: [(path: String, name: String)] {
        let parts = app.currentFolder.split(separator: "/").map(String.init)
        return [("/", app.active?.name ?? "Storage")] + parts.indices.map { i in
            ("/" + parts[0...i].joined(separator: "/"), parts[i])
        }
    }
}

// MARK: - Footer, search row, pill, drop overlay

private struct FilesFooter: View {
    @Environment(AppModel.self) private var app
    let loader: TreeLoader
    let shown: [FileNode]

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(summary).lineLimit(1)
            Spacer(minLength: Space.md)
            if loader.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Checking \(app.active?.name ?? "storage")…")
            } else {
                Text(checkedLine).lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.md).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        if app.isSearching && app.filesUI.searchAll {
            return "\(shown.count) result\(shown.count == 1 ? "" : "s") from folders this Mac has listed"
        }
        var parts = ["\(shown.count) item\(shown.count == 1 ? "" : "s")"]
        let bytes = shown.lazy.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.item.entry.size }
        if bytes > 0 { parts.append("\(Format.bytes(bytes)) in files") }
        if let c = app.active, let kept = app.cacheStatus[c.id]?.pinnedBytes, kept > 0 {
            parts.append("\(Format.bytes(kept)) kept on this Mac")
        }
        return parts.joined(separator: " · ")
    }

    /// The app polls; it does not get change notifications. Say so.
    private var checkedLine: String {
        let every = "Checks for changes every \(AppModel.pollInterval) s"
        guard let t = loader.lastListed else { return every }
        return "Checked \(Format.time.string(from: t)) · \(every.prefix(1).lowercased() + every.dropFirst())"
    }
}

/// Last row while searching: widen the search from this folder to the whole storage.
private struct SearchAllRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let storage = app.active?.name ?? "this storage"
        Group {
            if app.filesUI.searchAll {
                Button { app.filesUI.searchAll = false } label: {
                    Label("Show only \(app.folderName(app.currentFolder))", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    app.filesUI.searchAll = true
                    app.searchChanged()
                } label: {
                    HStack {
                        Label("Search all of \(storage)", systemImage: "magnifyingglass")
                        Spacer()
                        Image(systemName: "return").foregroundStyle(.tertiary)
                    }
                }
                .help("Searches every folder this Mac has listed on \(storage)")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, Space.md + 8).frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

/// Glass pill while anything transfers: ring, count, percent and measured speed. Opens Activity.
private struct ActivityPill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let active = app.activeTransfers
        let progress = app.transferProgress ?? 0
        let speed = active.compactMap(\.bytesPerSecond).reduce(0, +)
        Button { app.show(.activity) } label: {
            HStack(spacing: 9) {
                ProgressRing(progress: progress, state: app.queuePaused ? .paused : .running, size: 20, lineWidth: 2.5)
                Text(line(count: active.count, progress: progress, speed: speed))
                    .font(.system(size: 12, weight: .medium))
                    .rollingNumber(Int(progress * 100))
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help("Show Activity")
        .accessibilityLabel("Transfers")
        .accessibilityValue(line(count: active.count, progress: progress, speed: speed))
    }

    private func line(count: Int, progress: Double, speed: Double) -> String {
        var parts = ["\(count) transfer\(count == 1 ? "" : "s")"]
        if app.transferProgress != nil { parts.append("\(Int(progress * 100))%") }
        if app.queuePaused { parts.append("Paused") }
        else if speed > 0 { parts.append("\(Format.bytes(Int64(speed)))/s") }
        return parts.joined(separator: " · ")
    }
}

/// Accent wash and pulsing border while files are dragged over the list.
private struct DropOverlay: View {
    let target: String
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.06))
            PhaseAnimator([false, true]) { on in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(reduceMotion || on ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            } animation: { _ in reduceMotion ? nil : .easeInOut(duration: 0.9) }
            VStack(spacing: 2) {
                Text("Drop to upload into \(target)").font(.system(size: 13, weight: .semibold))
                Text(count > 0 ? "\(count) item\(count == 1 ? "" : "s") · hover a folder row to go deeper" : "Hover a folder row to go deeper")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, Space.lg)
        }
        .padding(Space.sm)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Icon view

/// 128 pt tiles: type icon with a 24 pt badge at its corner, name and state words below.
private struct FileGrid: View {
    @Environment(AppModel.self) private var app
    let nodes: [FileNode]

    var body: some View {
        let storage = app.active?.name ?? "your storage"
        let selected = Set(app.selection.map(\.path))
        let _ = app.statusStamp
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 128), spacing: 10)], spacing: 10) {
                ForEach(nodes, id: \.item.id) { node in
                    tile(node, storage: storage, selected: selected.contains(node.path))
                }
            }
            .padding(Space.md)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selection = [] }
        .dropDestination(for: URL.self) { urls, _ in
            app.upload(urls, to: app.currentFolder); return true
        } isTargeted: { on in
            app.filesUI.drag = on ? (app.folderName(app.currentFolder), 0) : nil
        }
    }

    private func tile(_ node: FileNode, storage: String, selected: Bool) -> some View {
        let state = app.fileState(of: node)
        return VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: FileIcons.image(for: node)).resizable().frame(width: 72, height: 72)
                if let state {
                    FileStateBadge(state: state, size: 24)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                        .offset(x: 6, y: 4)
                }
            }
            .frame(height: 78)
            Text(node.displayName).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            if let state {
                Text(app.words(for: node, state, storage: storage)).font(.system(size: 11))
                    .foregroundStyle(state.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(state.tone.text))
                    .lineLimit(1)
            } else if !app.sizeText(node).isEmpty {
                Text(app.sizeText(node)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: 128, height: 150, alignment: .top)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2) { app.open(node) }
        .onTapGesture { app.selection = [node] }
        .contextMenu { MenuItems(items: app.menu(for: app.selection.contains { $0 === node } ? app.selection : [node])) }
        .dropDestination(for: URL.self) { urls, _ in
            guard node.isDirectory else { return false }
            app.upload(urls, to: node.path); return true
        } isTargeted: { on in
            if node.isDirectory { app.filesUI.drag = on ? (node.displayName, 0) : nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open") { app.open(node) }
    }
}

/// Type icons, one per extension.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    static func image(for node: FileNode) -> NSImage {
        let key = node.isDirectory ? "/folder" : (node.item.entry.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let image = NSWorkspace.shared.icon(for: node.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data))
        cache[key] = image
        return image
    }
}
