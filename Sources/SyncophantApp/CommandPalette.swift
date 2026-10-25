import SwiftUI
import UniformTypeIdentifiers
import CoreKit

/// Command palette UI state (query, selection, scope). Owned by the palette screen.
@MainActor @Observable
final class PaletteState {
    /// The result shown in the preview pane after an action ran.
    struct Done: Equatable {
        let id = UUID()
        let text: String
        var undo: (@MainActor () -> Void)?
        static func == (a: Done, b: Done) -> Bool { a.id == b.id }
    }

    var query = ""
    /// Folder that ⇥ limits file results to; nil searches the whole storage.
    var scope: String?
    /// Row the person moved to with the arrows or the pointer; nil means "best match".
    var selectedID: String?
    var done: Done?
    /// Metadata hits for the typed query and files changed in the last day, both from the local index.
    var found: [StoredItem] = []
    var recent: [StoredItem] = []
    var searching = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored var openSettings: OpenSettingsAction?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var doneTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?

    // MARK: Lifecycle

    func begin(_ app: AppModel) {
        self.app = app
        query = ""; scope = nil; selectedID = nil; done = nil; found = []; recent = []; searching = false
        doneTask?.cancel()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }
        guard let c = app.active, let meta = try? app.metadataStore(for: c) else { return }
        Task { [weak self] in
            let items = (try? await meta.recent(since: Date().addingTimeInterval(-86_400), limit: 12)) ?? []
            self?.recent = items.filter { PathRules.isVisible(path: $0.entry.path) }
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        searchTask?.cancel(); doneTask?.cancel()
    }

    func close() { app?.showPalette = false }

    // MARK: Typing

    func queryChanged() {
        selectedID = nil
        if done != nil { done = nil; doneTask?.cancel() }
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let app, let c = app.active, let meta = try? app.metadataStore(for: c) else {
            found = []; searching = false; return
        }
        searching = true
        // Actions match on every keystroke; the index query waits for a short pause in typing.
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let items = (try? await meta.search(q)) ?? []
            guard !Task.isCancelled, let self else { return }
            found = items.filter { PathRules.isVisible(path: $0.entry.path) }
            searching = false
        }
    }

    func toggleScope() {
        guard let folder = app?.currentFolder, folder != "/" else { return }
        scope = scope == nil ? folder : nil
        selectedID = nil
    }

    // MARK: Running

    func run(_ item: PaletteItem, keepOpen: Bool = false) {
        switch item.effect {
        case .close(let go):
            close()
            go()
        case .inPlace(let act):
            let result = act()
            withAnimation(Motion.resolve(Motion.bouncy)) { done = result }
            doneTask?.cancel()
            doneTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled, let self else { return }
                withAnimation(Motion.resolve(Motion.morph)) { done = nil }
                if !keepOpen { close() }
            }
        }
    }

    func undo() {
        doneTask?.cancel()
        done?.undo?()
        withAnimation(Motion.resolve(Motion.morph)) { done = nil }
    }

    func lookInRecentlyDeleted() {
        guard let app else { return }
        close()
        app.timeTravelUI.mode = .recentlyDeleted
        app.show(.timeTravel)
    }

    func showInFinder(_ item: PaletteItem) {
        guard let app, let node = item.file, app.canUseFinder else { return }
        close()
        app.showInFinder(node)
    }

    // MARK: Keyboard

    /// Arrows, Return (⌘ shows in Finder, ⌥ keeps the palette open), Tab, Escape and ⌘Z while a result shows.
    private func handle(_ event: NSEvent) -> Bool {
        guard let app, app.showPalette, event.window?.isKeyWindow == true else { return false }
        // Leave keys to the input method while it is composing text.
        if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let rows = rows(app)
        let index = selectedIndex(in: rows)
        switch Int(event.keyCode) {
        case 125, 126: // down, up
            guard !rows.isEmpty else { return true }
            let next = event.keyCode == 125 ? min(rows.count - 1, index + 1) : max(0, index - 1)
            selectedID = rows[next].id
        case 36, 76: // return, enter
            guard rows.indices.contains(index) else {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty, !searching { lookInRecentlyDeleted() }
                return true
            }
            if mods.contains(.command) { showInFinder(rows[index]) }
            else { run(rows[index], keepOpen: mods.contains(.option)) }
        case 48: toggleScope() // tab
        case 53: close() // escape
        case 6 where mods == .command && done?.undo != nil: undo() // ⌘Z
        default: return false
        }
        return true
    }

    func selectedIndex(in rows: [PaletteItem]) -> Int {
        if let selectedID, let i = rows.firstIndex(where: { $0.id == selectedID }) { return i }
        return rows.indices.max { rows[$0].score < rows[$1].score } ?? 0
    }
}

/// One row: a file, an action or a place.
struct PaletteItem: Identifiable {
    enum Effect {
        /// Closes the palette, then navigates or opens a window.
        case close(@MainActor () -> Void)
        /// Runs here and shows the result in the preview pane.
        case inPlace(@MainActor () -> PaletteState.Done)
    }
    let id: String
    var section = ""
    let title: String
    var subtitle: String
    let symbol: String
    var tone: Tone = .accent
    var shortcut: String?
    var detail: String?
    var file: FileNode?
    let effect: Effect
    var score = 0
}

// MARK: - Results

extension PaletteState {
    func rows(_ app: AppModel) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return recentItems(app).prefix(3).map { $0.in("Recent") }
                + suggested(app).prefix(3).map { $0.in("Suggested") }
                + places(app).filter { $0.id != "go-deleted" }.map { $0.in("Go to") }
        }
        let phrase = Self.fold(q)
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        func match(_ list: [PaletteItem], _ section: String) -> [PaletteItem] {
            list.compactMap { item in Self.score(item.title, item.subtitle, words, phrase).map { var i = item.in(section); i.score = $0; return i } }
        }
        let others = match(actions(app), "Actions") + match(places(app), "Go to")
        let files = fileItems(app, words: words, phrase: phrase, limit: max(5, 9 - others.count))
        return Array((files + others).prefix(9))
    }

    /// Every word must appear in the name or subtitle. Name prefix beats word start beats name hit beats subtitle hit.
    static func score(_ title: String, _ subtitle: String, _ words: [String], _ phrase: String) -> Int? {
        let name = fold(title), hay = name + " " + fold(subtitle)
        guard !words.isEmpty, words.allSatisfy(hay.contains) else { return nil }
        if name.hasPrefix(phrase) { return 3 }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(words[0]) }) { return 2 }
        return words.allSatisfy(name.contains) ? 1 : 0
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    // MARK: Files

    private func fileItems(_ app: AppModel, words: [String], phrase: String, limit: Int) -> [PaletteItem] {
        let scoped = found.filter { inScope($0.entry.path) }
        let ranked = scoped.compactMap { item -> (StoredItem, Int)? in
            Self.score(item.entry.name, folderName(item.entry.path, app), words, phrase).map { (item, $0) }
        }
        return ranked.sorted { $0.1 > $1.1 }.prefix(limit).map { item, score in
            var row = fileItem(item, app, id: "file")
            row.section = "Files"; row.score = score
            return row
        }
    }

    private func recentItems(_ app: AppModel) -> [PaletteItem] {
        guard let c = app.active else { return [] }
        let moving = app.activeTransfers.filter { $0.connectionID == c.id && inScope($0.remotePath) }
        let movingPaths = Set(moving.map(\.remotePath))
        let sending = moving.map { t in
            PaletteItem(id: "transfer-\(t.id)", title: t.name, subtitle: "\(folderName(t.remotePath, app)) · \(Self.lowerFirst(t.status.label))",
                        symbol: "arrow.up.circle", tone: t.phase == .queued || app.queuePaused ? .orange : .accent, shortcut: "↩",
                        detail: "\(t.progressDetail) · uploading from this Mac", effect: .close { app.show(.activity) })
        }
        let changed = recent.filter { !movingPaths.contains($0.entry.path) && inScope($0.entry.path) }.map { fileItem($0, app, id: "recent") }
        return sending + changed
    }

    private func inScope(_ path: String) -> Bool {
        guard let scope else { return true }
        return path.hasPrefix(scope == "/" ? "/" : scope + "/")
    }

    private func fileItem(_ item: StoredItem, _ app: AppModel, id: String) -> PaletteItem {
        let node = FileNode(item: item, displayName: item.entry.name)
        let status = app.status(of: node)
        let state = status.label.isEmpty ? (node.isDirectory ? "folder" : "on your storage") : Self.lowerFirst(status.label)
        let tone: Tone = switch status {
        case .failed: .red
        case .conflict, .unverified, .queued: .orange
        case .kept, .verified: .green
        default: node.isDirectory ? .teal : .accent
        }
        var detail = node.isDirectory ? "Folder in \(folderName(node.path, app))" : Format.bytes(item.entry.size)
        if !status.label.isEmpty { detail += " · \(Self.lowerFirst(status.label))" }
        detail += " · changed \(Format.ago(item.entry.modifiedAt))"
        return PaletteItem(id: "\(id)-\(item.id)", title: item.entry.name, subtitle: "\(folderName(node.path, app)) · \(state)",
                           symbol: node.isDirectory ? "folder.fill" : "doc", tone: tone, shortcut: "↩", detail: detail,
                           file: node, effect: .close { Self.open(node, app) })
    }

    private func folderName(_ path: String, _ app: AppModel) -> String {
        let parent = PathRules.parent(of: path)
        return parent == "/" ? (app.active?.name ?? "Top level") : PathRules.name(of: parent)
    }

    /// Folders open in Files; files open in their app through Finder, or are shown in Files when the drive is not in Finder.
    private static func open(_ node: FileNode, _ app: AppModel) {
        if node.isDirectory { app.openFolder(node.path); app.show(.files); return }
        guard app.canUseFinder else {
            app.openFolder(PathRules.parent(of: node.path)); app.selection = [node]; app.show(.files); return
        }
        Task {
            do { NSWorkspace.shared.open(try await app.visibleURL(for: node)) }
            catch { app.say("Could not open \(node.item.entry.name): \(message(for: error))", error: true) }
        }
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    // MARK: Actions (only those that can run right now)

    private func suggested(_ app: AppModel) -> [PaletteItem] {
        let ids: Set<String> = ["pause", "resume", "upload", "share", "snapshot"]
        return actions(app).filter { ids.contains($0.id) }.sorted { a, b in
            (a.id == "pause" || a.id == "resume") && !(b.id == "pause" || b.id == "resume")
        }
    }

    private func actions(_ app: AppModel) -> [PaletteItem] {
        var list: [PaletteItem] = []
        let c = app.active
        let waiting = app.activeTransfers.count
        if c != nil {
            let folder = app.uploadFolder == "/" ? (c?.name ?? "your storage") : PathRules.name(of: app.uploadFolder)
            list.append(PaletteItem(id: "upload", title: "Upload Files…", subtitle: "To \(folder)", symbol: "icloud.and.arrow.up", shortcut: "⌘U",
                                    effect: .close { app.show(.files); app.chooseFilesToUpload() }))
        }
        if app.queuePaused {
            list.append(PaletteItem(id: "resume", title: "Resume All Transfers", subtitle: waiting == 0 ? "Paused" : "\(waiting) waiting",
                                    symbol: "play.fill", shortcut: "⌥⌘.",
                                    effect: .inPlace { app.setPaused(false); return .init(text: "Resumed all transfers") { app.setPaused(true) } }))
        } else if waiting > 0 {
            list.append(PaletteItem(id: "pause", title: "Pause All Transfers", subtitle: "\(waiting) running", symbol: "pause.fill", tone: .orange,
                                    shortcut: "⌥⌘.",
                                    effect: .inPlace { app.setPaused(true); return .init(text: "Paused all transfers") { app.setPaused(false) } }))
        }
        if let c, app.canUseSnapshots, app.hasHetznerToken, app.snapshots.box != nil, !app.snapshots.isCreating {
            list.append(PaletteItem(id: "snapshot", title: "Take Snapshot", subtitle: "\(c.name) keeps it until you delete it", symbol: "camera",
                                    tone: .purple, effect: .inPlace {
                                        Task { await app.createSnapshot(description: "Taken from Syncophant") }
                                        return .init(text: "Taking a snapshot of \(c.name)")
                                    }))
        }
        if app.canShareSelection, let item = app.selection.first {
            list.append(PaletteItem(id: "share", title: item.isDirectory ? "Share Folder…" : "Share File…", subtitle: item.item.entry.name,
                                    symbol: "square.and.arrow.up", effect: .close { app.beginSharing() }))
        }
        let selection = app.selection
        if app.canUseFinder, !selection.isEmpty {
            let what = selection.count == 1 ? selection[0].item.entry.name : "\(selection.count) items"
            if selection.contains(where: { !$0.item.isPinned }) {
                list.append(PaletteItem(id: "keep", title: "Keep Downloaded", subtitle: what, symbol: "pin.fill", tone: .teal, shortcut: "⌥⌘P",
                                        effect: .inPlace { app.keepOnThisMac(selection); return .init(text: "Keeping \(what) on this Mac") }))
            }
            if selection.contains(where: \.item.isPinned) {
                list.append(PaletteItem(id: "evict", title: "Remove Download", subtitle: "\(what) stays on your storage", symbol: "pin.slash",
                                        tone: .teal, shortcut: "⌥⌘E",
                                        effect: .inPlace { app.removeDownload(selection); return .init(text: "Removing the download of \(what)") }))
            }
            if selection.count == 1 {
                list.append(PaletteItem(id: "copypath", title: "Copy Path", subtitle: what, symbol: "doc.on.clipboard", tone: .neutral, shortcut: "⌥⌘C",
                                        effect: .inPlace { app.copyPath(selection[0]); return .init(text: "Copied the path of \(what)") }))
            }
        }
        if let c {
            list.append(PaletteItem(id: "newfolder", title: "New Folder", subtitle: "In \(app.uploadFolder == "/" ? c.name : PathRules.name(of: app.uploadFolder))",
                                    symbol: "folder.badge.plus", shortcut: "⇧⌘N", effect: .close { app.show(.files); app.newFolder() }))
            list.append(PaletteItem(id: "refresh", title: "Refresh", subtitle: "List \(c.name) again", symbol: "arrow.clockwise", tone: .neutral,
                                    shortcut: "⌘R", effect: .inPlace { app.refresh(); return .init(text: "Refreshing \(c.name)") }))
            if app.canUseFinder {
                list.append(PaletteItem(id: "finder", title: "Open in Finder", subtitle: c.name, symbol: "macwindow", tone: .neutral,
                                        effect: .close { app.openInFinder() }))
            }
        }
        if !app.isDemo {
            if app.runningJob == nil {
                for job in app.jobs {
                    let last = job.lastRun.map { "last ran \(Format.ago($0))" } ?? "has not run yet"
                    list.append(PaletteItem(id: "job-\(job.id)", title: "Back Up Now", subtitle: "\(job.name) · \(last)",
                                            symbol: "externaldrive.badge.timemachine", tone: .green,
                                            effect: .inPlace { app.runJob(job); return .init(text: "Backing up \(job.name)") }))
                }
            }
            if app.hasConnections {
                list.append(PaletteItem(id: "newbackup", title: "New Backup…", subtitle: "Copy a Mac folder on a schedule", symbol: "plus.circle",
                                        tone: .green, effect: .close { app.open(.newBackup) }))
            }
        }
        list.append(PaletteItem(id: "addstorage", title: "Add Storage…", subtitle: "Hetzner, SFTP, WebDAV, S3 or SMB", symbol: "plus",
                                shortcut: "⌘N", effect: .close { app.open(.addStorage) }))
        for other in app.connections where other.id != app.activeID {
            list.append(PaletteItem(id: "switch-\(other.id)", title: "Switch to \(other.name)", subtitle: app.providerLine(for: other),
                                    symbol: "externaldrive", tone: .neutral, effect: .close { app.select(other.id); app.show(.files) }))
        }
        return list
    }

    // MARK: Places

    private func places(_ app: AppModel) -> [PaletteItem] {
        let problems = app.issues.count
        let snaps = app.snapshots.phase == .loaded ? app.snapshots.list.count : nil
        var list = Destination.allCases.enumerated().map { i, d in
            let subtitle = switch d {
            case .files: app.active?.name ?? "No storage yet"
            case .activity: problems == 0 ? "Transfers and problems" : "\(problems) problem\(problems == 1 ? "" : "s") need you"
            case .timeTravel: snaps.map { "\($0) snapshot\($0 == 1 ? "" : "s"), past versions and recently deleted" } ?? "Past versions and recently deleted"
            case .backups: app.jobs.isEmpty ? "Copy Mac folders on a schedule" : "\(app.jobs.count) backup\(app.jobs.count == 1 ? "" : "s")"
            }
            return PaletteItem(id: "go-\(d)", title: d.title, subtitle: subtitle, symbol: d.symbol, tone: .neutral, shortcut: "⌘\(i + 1)",
                               effect: .close { app.show(d) })
        }
        list.append(PaletteItem(id: "go-deleted", title: "Recently Deleted", subtitle: "Time Travel · files you removed", symbol: "trash",
                                tone: .neutral, effect: .close { [weak self] in self?.lookInRecentlyDeleted() }))
        let openSettings = openSettings
        list.append(PaletteItem(id: "go-settings", title: "Settings", subtitle: "General, storage, transfers, privacy", symbol: "gearshape",
                                tone: .neutral, shortcut: "⌘,", effect: .close {
                                    NSApp.activate()
                                    if let openSettings { openSettings() }
                                    else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                                }))
        return list
    }
}

private extension PaletteItem {
    func `in`(_ section: String) -> PaletteItem { var copy = self; copy.section = section; return copy }
}

// MARK: - View

/// ⌘K: one glass field that finds files, runs actions and jumps anywhere, with a live preview.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = app.paletteUI
        let rows = state.rows(app)
        let selected = state.selectedIndex(in: rows)
        VStack(spacing: 0) {
            header(query: $state.query)
            Divider()
            HStack(spacing: 0) {
                results(rows, selected)
                    .frame(maxWidth: .infinity)
                preview(rows.indices.contains(selected) ? rows[selected] : nil)
                    .frame(width: 280)
            }
            .frame(height: 430)
            Divider()
            hints
        }
        .frame(width: 760)
        .glassSurface(radius: 28)
        .onAppear {
            state.begin(app)
            state.openSettings = openSettings
            focused = true
        }
        .onDisappear { state.end() }
        .onChange(of: state.query) { state.queryChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    // MARK: Field

    private func header(query: Binding<String>) -> some View {
        let state = app.paletteUI
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search files, folders and actions", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
                .accessibilityLabel("Search files and actions")
            if let scope = state.scope {
                HStack(spacing: 6) {
                    Text("in \(PathRules.name(of: scope))")
                    Button { state.scope = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search everywhere")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 10).padding(.trailing, 4)
                .frame(height: 26)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Text("⌘K")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Fill.two, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        }
        .padding(.leading, 20).padding(.trailing, 18)
        .frame(height: 62)
        .motion(Motion.bouncy, value: state.scope)
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ rows: [PaletteItem], _ selected: Int) -> some View {
        let state = app.paletteUI
        let q = state.query.trimmingCharacters(in: .whitespaces)
        if rows.isEmpty, !q.isEmpty, !state.searching {
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Nothing on \(app.active?.name ?? "your storage") matches “\(q)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button { state.lookInRecentlyDeleted() } label: {
                    Text("Look in Recently Deleted").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 13).frame(height: 30)
                        .background(Fill.two, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || rows[i - 1].section != item.section {
                                SectionLabel(item.section)
                                    .padding(.horizontal, 10).padding(.top, i == 0 ? 6 : 10).padding(.bottom, 4)
                            }
                            PaletteRow(item: item, selected: i == selected)
                                .id(item.id)
                                .onHover { if $0 { state.selectedID = item.id } }
                                .onTapGesture { state.run(item) }
                                .accessibilityAction { state.run(item) }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: selected) { _, new in
                    if rows.indices.contains(new) { proxy.scrollTo(rows[new].id) }
                }
            }
        }
    }

    // MARK: Preview

    private func preview(_ item: PaletteItem?) -> some View {
        let state = app.paletteUI
        return ZStack {
            if let done = state.done {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Color.green, in: Circle())
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .accessibilityHidden(true)
                    Text(done.text)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                    if done.undo != nil {
                        Button("Undo") { state.undo() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Undo (⌘Z)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.updatesFrequently)
            } else if let item {
                ItemPreview(item: item, keys: keys(for: item))
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Fill.one)
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5) }
        .motion(Motion.morph, value: state.done)
    }

    private func keys(for item: PaletteItem) -> [(String, String)] {
        if item.file != nil {
            return [("Open", "↩")] + (app.canUseFinder ? [("Show in Finder", "⌘↩")] : [])
        }
        switch item.effect {
        case .inPlace: return [("Run", "↩"), ("Run without closing", "⌥↩")]
        case .close: return [(item.section == "Go to" ? "Go there" : "Run", "↩")]
        }
    }

    // MARK: Hints

    private var hints: some View {
        HStack(spacing: 16) {
            hint("↑↓", "move")
            hint("↩", "open or run")
            if app.canUseFinder { hint("⌘↩", "show in Finder") }
            if app.currentFolder != "/" { hint("⇥", "limit to folder") }
            Spacer(minLength: 8)
            Text("Searches file names, not contents")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: 40)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        Text("\(Text(keys).fontWeight(.semibold).foregroundStyle(.primary)) \(label)")
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            if selected {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8.4, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                IconTile(symbol: item.symbol, tone: item.tone, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13.5, weight: .medium))
                Text(item.subtitle).font(.system(size: 11.5)).opacity(0.75)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.system(size: 12)).opacity(0.7).accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ItemPreview: View {
    let item: PaletteItem
    let keys: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Fill.one)
                icon
            }
            .frame(height: 150)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(item.detail ?? item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                ForEach(keys, id: \.0) { label, key in
                    HStack {
                        Text(label)
                        Spacer()
                        Text(key)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Fill.two, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var icon: some View {
        if let file = item.file {
            // The system icon for the file's type. Thumbnails would need the file's contents, which may not be on this Mac.
            let type = file.isDirectory ? UTType.folder : (UTType(filenameExtension: (file.item.entry.name as NSString).pathExtension) ?? .data)
            Image(nsImage: NSWorkspace.shared.icon(for: type))
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
        } else {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 74, height: 74)
                .background((item.tone == .neutral ? Tone.accent : item.tone).color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                .accessibilityHidden(true)
        }
    }
}
