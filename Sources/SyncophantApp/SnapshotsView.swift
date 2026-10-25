import SwiftUI
import CoreKit
import HetznerKit

/// Past versions mode: the snapshot timeline, the current folder as it was, and the compare card.
struct SnapshotsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // Read first so saving a token or reloading redraws this view.
        let phase = app.snapshots.phase
        let name = app.active?.name ?? "This storage"
        if !app.canUseSnapshots {
            unavailable(title: "Past versions need snapshots",
                        text: app.isDemo ? "Not available in demo mode."
                            : "\(name) doesn’t keep snapshots Syncophant can read. Hetzner Storage Boxes do. Files you delete still stay in Recently deleted for 30 days.")
        } else if app.active?.encryptionEnabled == true {
            unavailable(title: "Encrypted snapshots can’t be browsed yet",
                        text: "\(name) is end-to-end encrypted, so its snapshots hold encrypted names. Recently deleted still works.")
        } else if !app.hasHetznerToken {
            SnapshotFolderHero(needsToken: true)
        } else {
            switch phase {
            case .idle, .loading:
                ProgressView("Asking Hetzner for snapshots…").controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let e):
                ContentUnavailableView {
                    Label("Can’t load snapshots", systemImage: "wifi.exclamationmark")
                } description: { Text(e) } actions: {
                    Button("Try Again") { Task { await app.loadSnapshots() } }.buttonStyle(.glassProminent)
                    Button("Remove Token…", role: .destructive) { app.forgetHetznerToken() }.buttonStyle(.glass)
                }
            case .loaded:
                if !app.snapshots.accountHome.isEmpty {
                    unavailable(title: "Snapshots belong to the main login",
                                text: "\(name) signs in as a sub-account, which can’t see the box’s snapshot folder. Connect with the main Storage Box login to browse past versions.")
                } else if app.snapshotsHidden {
                    SnapshotFolderHero(needsToken: false)
                } else {
                    PastVersions()
                }
            }
        }
    }

    private func unavailable(title: String, text: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "clock.arrow.circlepath")
        } description: { Text(text) } actions: {
            Button("Show Recently Deleted") { app.timeTravelUI.mode = .recentlyDeleted }.buttonStyle(.glass)
        }
    }
}

// MARK: - Snapshots hidden

/// Replaces the old "ZFS" error: the box keeps snapshots but hides the folder. One button turns it on.
private struct SnapshotFolderHero: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let needsToken: Bool
    @State private var spinning = false
    @State private var addingToken = false
    @State private var token = ""

    var body: some View {
        @Bindable var state = app.timeTravelUI
        let name = app.active?.name ?? "This box"
        let count = app.snapshots.list.count
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .strokeBorder(Palette.history.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.1, 9]))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(spinning ? .linear(duration: 14).repeatForever(autoreverses: false) : .default, value: spinning)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 44, weight: .medium)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.history)
            }
            .frame(width: 120, height: 120)
            .accessibilityHidden(true)
            .onAppear { spinning = !reduceMotion }
            .onDisappear { spinning = false }

            Text(needsToken ? "See past versions of \(name)" : "\(name) keeps snapshots, but hides them")
                .font(.system(size: 22, weight: .bold)).tracking(-0.3)
            Text(needsToken
                 ? "Snapshots are listed through api.hetzner.com with your Hetzner API token. It stays in your Keychain, and nothing is sent until you save it."
                 : (count == 0 ? "Hetzner hasn’t made a snapshot of this box yet. " : "There \(count == 1 ? "is 1 snapshot" : "are \(count) snapshots") of this box. ")
                    + "Show the snapshot folder and you can browse any of them, compare files and restore copies, right here.")
                .font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if app.snapshots.isRevealing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking Hetzner to show the snapshot folder…")
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        if needsToken {
                            Button("Add Hetzner Token…") { addingToken = true }
                                .buttonStyle(.glassProminent).controlSize(.large)
                                .popover(isPresented: $addingToken, arrowEdge: .bottom) { tokenForm }
                        } else {
                            Button("Show Snapshot Folder") { Task { await app.showSnapshotFolder() } }
                                .buttonStyle(.glassProminent).controlSize(.large)
                            Button("I’ll Do It Myself") { withAnimation(Motion.resolve(Motion.smooth)) { state.showsManualSteps.toggle() } }
                                .buttonStyle(.glass).controlSize(.large)
                                .accessibilityValue(state.showsManualSteps ? "Steps shown" : "Steps hidden")
                        }
                    }
                }
            }

            if state.showsManualSteps, !needsToken, !app.snapshots.isRevealing {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, Text("Open Hetzner Console and choose Storage Boxes."))
                    step(2, Text("Pick \(Text(app.snapshots.box?.name ?? name).bold().foregroundStyle(.primary)), then Settings."))
                    step(3, Text("Turn on \(Text("Show snapshot folder").bold().foregroundStyle(.primary)). Syncophant notices within a minute."))
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .padding(.vertical, 14).padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.offset(y: 8).combined(with: .opacity))
            }

            Text(needsToken ? "Only api.hetzner.com is contacted." : "Uses your saved Hetzner token. Nothing else on the box changes.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(width: 560)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Once a minute while the manual steps are open, so the screen switches over by itself.
        .task(id: state.showsManualSteps) {
            guard state.showsManualSteps, !needsToken else { return }
            while !Task.isCancelled, app.snapshotsHidden {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await app.loadSnapshots(quiet: true)
            }
        }
    }

    private func step(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().frame(width: 16, alignment: .trailing)
            text.multilineTextAlignment(.leading)
        }
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Hetzner API Token").font(.headline)
            Text("Create one in Hetzner Console › Security › API tokens. Read & Write lets Syncophant show the snapshot folder and take snapshots.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("API token", text: $token).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { addingToken = false }.keyboardShortcut(.cancelAction)
                Button("Save") { app.saveHetznerToken(token); token = ""; addingToken = false }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.lg).frame(width: 360)
    }
}

// MARK: - Past versions

private struct PastVersions: View {
    @Environment(AppModel.self) private var app
    @State private var revealed = false

    var body: some View {
        let state = app.timeTravelUI
        let folder = state.folder ?? app.currentFolder
        VStack(spacing: 14) {
            TimelineCard(folder: folder)
                .mask(alignment: .leading) {
                    GeometryReader { g in Rectangle().frame(width: revealed ? g.size.width : 0) }
                }
            HStack(alignment: .top, spacing: 14) {
                FolderCard(folder: folder)
                VersionCompareCard(folder: folder).frame(width: 360)
            }
        }
        .padding(.leading, 20).padding(.trailing, 16).padding(.bottom, 16).padding(.top, 4)
        .onAppear {
            state.folder = nil
            withAnimation(Motion.resolve(.smooth(duration: 0.8))) { revealed = true }
        }
        .task(id: "\(app.snapshots.selected ?? 0)|\(folder)|\(app.activeID?.uuidString ?? "")") {
            state.confirmingReplace = false
            await app.loadFolderAsItWas(folder)
        }
    }
}

private struct TimelineCard: View {
    @Environment(AppModel.self) private var app
    let folder: String

    var body: some View {
        let now = Date()
        let range = now.addingTimeInterval(-14 * 86_400)...now
        let list = app.snapshots.list
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stepButton("chevron.left", "Earlier snapshot", by: 1)
                stepButton("chevron.right", "Later snapshot", by: -1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText()).motion(Motion.snappy, value: app.snapshots.selected)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Space.md)
                legend
            }
            if list.isEmpty {
                Text("No snapshots yet. Take one now, or wait for the box’s snapshot plan.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 64)
            } else {
                SnapshotTimeline(marks: marks(in: range), range: range, selected: app.snapshots.selected.map { "s\($0)" },
                                 onSelect: select, height: 64, showsDayLabels: true)
            }
        }
        .contentCard(padding: 16)
        .focusable()
        .onKeyPress(.leftArrow) { step(by: 1); return .handled }
        .onKeyPress(.rightArrow) { step(by: -1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline, \(title)")
    }

    private var title: String {
        guard let s = app.selectedSnapshot else { return "No snapshot chosen" }
        return s.createdAt.map(TimeFormat.moment) ?? "Snapshot"
    }

    private var subtitle: String {
        guard let s = app.selectedSnapshot else { return "Pick a moment on the timeline" }
        let kind = isUser(s) ? (s.description.flatMap { $0.isEmpty ? nil : "Yours: \($0)" } ?? "Your snapshot") : "Automatic snapshot"
        let ui = app.timeTravelUI
        guard ui.folderPhase == .loaded else { return kind }
        let place = TimeFormat.folder(folder, storage: app.active?.name ?? "")
        return "\(kind) · \(ui.rows.count) item\(ui.rows.count == 1 ? "" : "s") in \(place)"
    }

    /// Made by a person: Hetzner's flag, or a description when the flag is missing.
    private func isUser(_ s: StorageSnapshot) -> Bool { s.isAutomatic.map(!) ?? (s.description?.isEmpty == false) }

    private func marks(in range: ClosedRange<Date>) -> [TimelineMark] {
        let shots = app.snapshots.list.compactMap { s in
            s.createdAt.flatMap { range.contains($0) ? TimelineMark(id: "s\(s.id)", date: $0, kind: isUser(s) ? .user : .automatic) : nil }
        }
        let deletions = app.timeTravelUI.trash.compactMap { t in
            t.deletedAt.flatMap { range.contains($0) ? TimelineMark(id: "d\(t.id.uuidString)", date: $0, kind: .deletion) : nil }
        }
        return deletions + shots
    }

    private func select(_ id: String) {
        if id.hasPrefix("s"), let n = Int(id.dropFirst()) {
            app.snapshots.selected = n
        } else if id.hasPrefix("d"), let uuid = UUID(uuidString: String(id.dropFirst())) {
            app.timeTravelUI.selectedTrash = uuid
            app.timeTravelUI.mode = .recentlyDeleted
        }
    }

    /// The list is newest first, so +1 is earlier.
    private func step(by delta: Int) {
        let list = app.snapshots.list
        guard let i = list.firstIndex(where: { $0.id == app.snapshots.selected }) else {
            app.snapshots.selected = list.first?.id; return
        }
        let j = i + delta
        if list.indices.contains(j) { app.snapshots.selected = list[j].id }
    }

    private func stepButton(_ symbol: String, _ label: String, by delta: Int) -> some View {
        let list = app.snapshots.list
        let i = list.firstIndex { $0.id == app.snapshots.selected }
        let enabled = i.map { list.indices.contains($0 + delta) } ?? !list.isEmpty
        return Button { step(by: delta) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                .background(Fill.one, in: Circle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) { Circle().fill(Color.purple).frame(width: 8, height: 8); Text("Automatic") }
            HStack(spacing: 5) { Rectangle().fill(Color.orange).frame(width: 7, height: 7).rotationEffect(.degrees(45)); Text("Yours") }
            HStack(spacing: 5) { Capsule().fill(Color.red).frame(width: 8, height: 3); Text("Deleted") }
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Folder as it was

private struct FolderCard: View {
    @Environment(AppModel.self) private var app
    let folder: String

    var body: some View {
        @Bindable var state = app.timeTravelUI
        let place = TimeFormat.folder(folder, storage: app.active?.name ?? "")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if state.folder != nil {
                    Button { let up = PathRules.parent(of: folder); state.folder = up == app.currentFolder ? nil : up } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Back to the enclosing folder")
                }
                SectionLabel("\(PathRules.name(of: folder) == "/" ? place : PathRules.name(of: folder)), as it was")
                Spacer()
                if state.addedSince > 0, state.folderPhase == .loaded {
                    Text("\(state.addedSince) item\(state.addedSince == 1 ? "" : "s") added since, not shown")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            switch state.folderPhase {
            case .idle:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading where state.rows.isEmpty:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                ContentUnavailableView("\(place) didn’t exist yet", systemImage: "folder.badge.questionmark",
                                       description: Text("Pick a later moment, or open another folder in Files."))
            case .failed(let e):
                ContentUnavailableView {
                    Label("Can’t read this snapshot", systemImage: "exclamationmark.triangle")
                } description: { Text(e) } actions: {
                    Button("Try Again") { Task { await app.loadFolderAsItWas(folder) } }.buttonStyle(.glass)
                }
            default:
                if state.rows.isEmpty {
                    ContentUnavailableView("Empty then", systemImage: "folder", description: Text("\(place) had nothing in it at this moment."))
                } else {
                    List(selection: $state.selectedRow) {
                        ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                            VersionRowView(row: row, place: place)
                                .tag(row.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                .rowEntrance(index)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: VersionRow.ID.self) { _ in } primaryAction: { ids in
                        if let id = ids.first, let row = state.rows.first(where: { $0.id == id }), row.then.isDirectory {
                            state.folder = folder == "/" ? "/" + row.then.name : folder + "/" + row.then.name
                        }
                    }
                    .onChange(of: state.selectedRow) { state.confirmingReplace = false }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentCard(padding: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(place) as it was")
    }
}

private struct VersionRowView: View {
    let row: VersionRow
    let place: String

    var body: some View {
        HStack(spacing: 10) {
            TypeIcon(name: row.then.name, isDirectory: row.then.isDirectory, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.then.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(row.diff == .gone)
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            DiffBadge(diff: row.diff)
            Text(row.then.isDirectory ? "" : Format.bytes(row.then.size))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.then.isDirectory ? "Double-click to open" : "")
    }

    private var detail: String {
        switch row.diff {
        case .gone: row.deletedAt.map { "Deleted \(TimeFormat.day($0))" } ?? "Not in \(place) now"
        case .changed: row.then.isDirectory ? "Items added or removed since then" : "Edited since then"
        case .same: "Unchanged since then"
        case .folderSame: "Same items; files inside may have changed"
        }
    }
}

struct DiffBadge: View {
    let diff: VersionRow.Diff
    var body: some View {
        let (symbol, text, tone): (String, String, Tone) = switch diff {
        case .same: ("equal.circle", "Same as now", .neutral)
        case .folderSame: ("equal.circle", "Same items", .neutral)
        case .changed: ("plus.circle.fill", "Changed since", .orange)
        case .gone: ("minus.circle.fill", "Gone now", .red)
        }
        HStack(spacing: 6) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(tone == .neutral ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tone.color))
            Text(text).foregroundStyle(tone == .neutral ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tone.text))
        }
        .font(.system(size: 12)).fixedSize()
    }
}

// MARK: Compare

private struct VersionCompareCard: View {
    @Environment(AppModel.self) private var app
    let folder: String

    var body: some View {
        let state = app.timeTravelUI
        VStack(alignment: .leading, spacing: 14) {
            if let row = state.rows.first(where: { $0.id == state.selectedRow }), let snap = app.selectedSnapshot, state.folderPhase == .loaded {
                content(row, snap)
            } else {
                ContentUnavailableView("Pick an item", systemImage: "clock.arrow.circlepath",
                                       description: Text("Choose something on the left to compare it with now."))
                    .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            CompareFootnote(text: "Restores never overwrite without asking. Rolling the whole box back stays in Hetzner Console on purpose.")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare")
    }

    @ViewBuilder private func content(_ row: VersionRow, _ snap: StorageSnapshot) -> some View {
        let state = app.timeTravelUI
        let isDir = row.then.isDirectory
        Text(row.then.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
        HStack(spacing: 10) {
            ThenNowTile(label: "Then", name: row.then.name, isDirectory: isDir, isThen: true,
                        lines: [snap.createdAt.map(TimeFormat.moment) ?? "", isDir ? "Folder" : Format.bytes(row.then.size)])
            if let now = row.now {
                ThenNowTile(label: "Now", name: now.name, isDirectory: isDir,
                            lines: [row.diff == .changed ? "Changed \(TimeFormat.moment(now.modifiedAt))" : "Unchanged",
                                    isDir ? "Folder" : Format.bytes(now.size)])
            } else {
                ThenNowTile(label: "Now", name: row.then.name, isDirectory: isDir, gone: true,
                            lines: [row.deletedAt.map { "Deleted \(TimeFormat.day($0))" } ?? "Not there now",
                                    row.deletedAt == nil ? "" : "In Recently deleted"])
            }
        }
        Text(explain(row, snap)).font(.system(size: 12)).lineSpacing(2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if app.snapshots.isRestoring {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Restoring…") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if state.confirmingReplace {
            VStack(alignment: .leading, spacing: 10) {
                Text("The current version goes to Recently deleted, so you can undo this for 30 days.")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { state.confirmingReplace = false } label: { Text("Cancel").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    Button { state.confirmingReplace = false; Task { await app.replaceCurrent(row, folder: folder) } } label: {
                        Text("Replace").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).tint(.orange)
                }
            }
            .statusCard(.orange, radius: 14, padding: 12)
            .transition(.offset(y: 8).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Replace current version")
        } else if row.diff != .same {
            VStack(spacing: 8) {
                Button { Task { await app.restoreCopy(row, folder: folder) } } label: {
                    Text(row.diff == .gone ? "Restore" : "Restore a Copy").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                if row.diff == .changed, !isDir {
                    Button { withAnimation(Motion.resolve(Motion.smooth)) { state.confirmingReplace = true } } label: {
                        Text("Replace Current Version…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass).controlSize(.large)
                }
            }
        }
    }

    private func explain(_ row: VersionRow, _ snap: StorageSnapshot) -> String {
        let name = row.then.name
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let copy = "\(base) (\(TimeFormat.day(snap.createdAt ?? Date())))" + (ext.isEmpty ? "" : ".\(ext)")
        return switch row.diff {
        case .gone: "This was removed after the snapshot. Restoring puts it back where it was."
        case .same: "Identical to the current version, so there is nothing to bring back from this point."
        case .folderSame, .changed:
            row.then.isDirectory
                ? "Restoring a copy puts the whole folder next to the current one as “\(copy)”. Your current folder stays untouched."
                : "Restoring a copy puts it next to the current file as “\(copy)”. Your current version stays untouched."
        }
    }
}
