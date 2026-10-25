import SwiftUI
import CoreKit

// Drop to upload: Drag → Pick → Upload → Done, inside the menu bar panel. No destination sheet first.

/// One destination tile.
private struct DropTarget: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let tint: Color
    var badge: String?
    let folder: String
    var share = false
}

// MARK: - Pick

struct DropPick: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var ui = app.panelUI
        if let c = app.active {
            let fit = app.dropFit(for: c, size: ui.pickSize)
            let refused = (fit?.shortfall ?? 0) > 0
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StackedThumbnails(urls: ui.pickURLs)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ui.dragLive ? "Drop to upload" : "Choose a folder").font(.system(size: 15, weight: .semibold))
                        Text(summary(fit: fit))
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(refused ? Palette.failure : .secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if let fit, let size = ui.pickSize {
                        FreeSpaceRing(fraction: Double(fit.total - fit.free + size) / Double(max(fit.total, 1)), refused: refused)
                            .accessibilityLabel(refused ? "Won’t fit. \(Format.bytes(fit.shortfall)) more space needed"
                                                : "Free space after upload: \(Format.bytes(fit.free - size))")
                    }
                    if !ui.dragLive {
                        Button { app.cancelPick() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Circle())
                        }
                        .buttonStyle(PanelPressStyle(shape: .circle))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel")
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 0, trailing: 2))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(targets(for: c)) { target in
                        DropTile(target: target, count: ui.pickURLs.count, refused: refused)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Destinations")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.tertiary)
                    TextField("Another folder…", text: $ui.folderQuery).textFieldStyle(.plain)
                        .accessibilityLabel("Find another folder")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                let matches = matchingFolders(c)
                if !matches.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(matches, id: \.self) { path in
                            FolderMatchRow(path: path, storage: c.name, refused: refused)
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("⌥").font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Fill.two, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Originals stay on this Mac. Hold Option to move them instead; they go to the Trash once every file is verified.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
    }

    private func summary(fit: (free: Int64, total: Int64, shortfall: Int64)?) -> String {
        let ui = app.panelUI
        var parts = [MenuBarView.items(ui.pickURLs.count)]
        guard let size = ui.pickSize else { return (parts + ["counting…"]).joined(separator: " · ") }
        parts.append(Format.bytes(size))
        if let fit {
            parts.append(fit.shortfall > 0 ? "won’t fit, free up \(Format.bytes(fit.shortfall))" : "fits, \(Format.bytes(fit.free - size)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// Last used, the most frequent folders, the top level, and Upload and share when this storage can share what was dropped.
    private func targets(for c: StorageConnection) -> [DropTarget] {
        let records = app.uploadDestinations(for: c.id)
        let canShare = app.canShareDrop(app.panelUI.pickURLs)
        let folderSlots = canShare ? 3 : 4
        var folders: [(path: String, badge: String?)] = []
        if let last = records.first { folders.append((last.path, "Last used")) }
        for r in records.dropFirst().sorted(by: { $0.count > $1.count })
            where folders.count < folderSlots - 1 && !folders.contains(where: { $0.path == r.path }) {
            folders.append((r.path, nil))
        }
        if !folders.contains(where: { $0.path == "/" }) { folders.append(("/", nil)) }
        var targets = folders.prefix(folderSlots).map { f in
            f.path == "/"
                ? DropTarget(id: "/", name: c.name, detail: "Top level", symbol: "externaldrive.fill", tint: .secondary, badge: f.badge, folder: "/")
                : DropTarget(id: f.path, name: PathRules.name(of: f.path), detail: breadcrumb(f.path, storage: c.name),
                             symbol: "folder.fill", tint: .accentColor, badge: f.badge, folder: f.path)
        }
        if canShare {
            let into = records.first?.path ?? "/"
            targets.append(DropTarget(id: "share", name: "Upload and share",
                                      detail: c.provider == .s3 ? "Then makes a read link" : "Then makes a read-only login",
                                      symbol: "square.and.arrow.up.fill", tint: .purple, folder: into, share: true))
        }
        return targets
    }

    private func matchingFolders(_ c: StorageConnection) -> [String] {
        let query = app.panelUI.folderQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        let candidates = (app.recentUploadFolders(for: c.id) + app.panelUI.pickFolders).filter { $0 != "/" && seen.insert($0).inserted }
        return Array(candidates.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(4))
    }
}

private func breadcrumb(_ path: String, storage: String) -> String {
    ([storage] + path.split(separator: "/").dropLast().map(String.init)).joined(separator: " › ")
}

/// A destination: a drop target and a button. Hovering while dragging grows it 3.5% and rings it in the accent colour.
private struct DropTile: View {
    @Environment(AppModel.self) private var app
    let target: DropTarget
    let count: Int
    let refused: Bool
    @State private var targeted = false

    var body: some View {
        Button { app.dropUpload(app.panelUI.pickURLs, to: target.folder, share: target.share) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: target.symbol)
                        .font(.system(size: 24))
                        .foregroundStyle(target.tint)
                        .symbolEffect(.bounce, value: targeted)
                    Spacer(minLength: 4)
                    if let badge = target.badge {
                        Text(badge).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Fill.two, in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(target.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(targeted ? Fill.two : Fill.one, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(targeted ? 1.035 : 1)
            .motion(Motion.snappy, value: targeted)
        }
        .buttonStyle(.plain)
        .disabled(refused)
        .dropDestination(for: URL.self) { urls, _ in
            guard !refused else { return false }
            app.dropUpload(urls, to: target.folder, share: target.share)
            return true
        } isTargeted: { targeted = $0 && !refused }
        .accessibilityLabel("Upload \(MenuBarView.items(count)) to \(target.name)")
        .accessibilityHint(target.detail)
    }
}

/// A folder found by the "Another folder…" filter; also a drop target.
private struct FolderMatchRow: View {
    @Environment(AppModel.self) private var app
    let path: String
    let storage: String
    let refused: Bool
    @State private var targeted = false

    var body: some View {
        Button { app.dropUpload(app.panelUI.pickURLs, to: path) } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(PathRules.name(of: path)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(breadcrumb(path, storage: storage)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(targeted ? Fill.two : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refused)
        .dropDestination(for: URL.self) { urls, _ in
            guard !refused else { return false }
            app.dropUpload(urls, to: path)
            return true
        } isTargeted: { targeted = $0 && !refused }
        .accessibilityLabel("Upload to \(PathRules.name(of: path))")
    }
}

/// The dragged items' real Finder icons, fanned out.
private struct StackedThumbnails: View {
    let urls: [URL]
    var body: some View {
        ZStack {
            ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { i, url in
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high)
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees([6, -2, -10][i]))
                    .offset(x: CGFloat(4 - i * 4))
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

/// Space used after the upload; red when it won't fit. Only shown when the provider reports a quota.
private struct FreeSpaceRing: View {
    let fraction: Double
    let refused: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Fill.track, lineWidth: 3)
            Circle().trim(from: 0, to: min(1, fraction))
                .stroke(refused ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
        .frame(width: 22, height: 22)
        .accessibilityElement()
    }
}

// MARK: - Upload

struct DropProgress: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let b = app.panelUI.batch {
            let mine = app.transfers(in: b).filter { $0.phase != .cancelled }
            let total = mine.reduce(Int64(0)) { $0 + $1.size }
            let done = mine.reduce(Int64(0)) { $0 + ($1.phase.isActive ? $1.completed : $1.size) }
            let progress = total > 0 ? Double(done) / Double(total) : 0
            let paused = app.queuePaused
            let speed = paused ? 0 : mine.filter { $0.phase == .working }.compactMap(\.bytesPerSecond).reduce(0, +)
            let samples = app.throughput.suffix(30).map(\.sending)
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: b.folder == "/" ? "externaldrive.fill" : "folder.fill")
                        .font(.system(size: 22)).foregroundStyle(b.folder == "/" ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Uploading to \(folderName(b))").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(b.folder == "/" ? "Top level" : breadcrumb(b.folder, storage: app.active?.name ?? ""))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Button { app.setPaused(!paused) } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 13)).frame(width: 30, height: 30).contentShape(Circle())
                    }
                    .buttonStyle(PanelPressStyle(shape: .circle))
                    .accessibilityLabel(paused ? "Resume" : "Pause")
                    Button { app.cancelDropUpload() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30).contentShape(Circle())
                    }
                    .buttonStyle(PanelPressStyle(shape: .circle))
                    .accessibilityLabel("Cancel Upload")
                }
                .foregroundStyle(.primary)
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 0, trailing: 2))

                HStack(spacing: 16) {
                    ProgressRing(progress: progress, state: paused ? .paused : .running, size: 84, lineWidth: 9, showsLabel: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(paused ? "Paused" : speed > 0 ? "\(Format.bytes(Int64(speed)))/s" : "Starting…")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(paused ? Palette.caution : .primary)
                            .rollingNumber(Int64(speed) / 100_000)
                        if samples.count > 1 { Sparkline(values: samples, tint: paused ? .orange : .accentColor).frame(height: 34) }
                        Text(remaining(total: total, done: done, speed: speed))
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 2) {
                    ForEach(Array(mine.prefix(5).enumerated()), id: \.element.id) { i, t in
                        DropFileRow(transfer: t).rowEntrance(i)
                    }
                    if mine.count > 5 {
                        Text("and \(mine.count - 5) more").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Files")
            }
            .onChange(of: Int(progress * 4)) { _, quarter in
                // Announce at 25% steps, not every change.
                if (1...3).contains(quarter) {
                    AccessibilityNotification.Announcement("Upload \(quarter * 25) percent").post()
                }
            }
        }
    }

    private func folderName(_ b: DropBatch) -> String { b.folder == "/" ? (app.active?.name ?? "your storage") : PathRules.name(of: b.folder) }

    private func remaining(total: Int64, done: Int64, speed: Double) -> String {
        let left = max(0, total - done)
        var text = "\(Format.bytes(left)) left"
        if speed > 0 {
            let seconds = Double(left) / speed
            text += seconds < 60 ? " · \(max(1, Int(seconds))) sec" : " · \(Int(seconds / 60)) min"
        }
        return text
    }
}

private struct DropFileRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: transfer.localURL.path))
                .resizable().interpolation(.high).frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(transfer.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(transfer.phase == .working && !transfer.isVerifying
                     ? "\(Format.bytes(transfer.completed)) of \(Format.bytes(transfer.size))" : Format.bytes(transfer.size))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            FileStateBadge(state: FileState(transfer.status) ?? .waiting, size: 22)
                .transition(.scale.combined(with: .opacity))
                .id(transfer.phase)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .motion(Motion.bouncy, value: transfer.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transfer.name)
        .accessibilityValue(transfer.status.label)
    }
}

// MARK: - Done

struct DropDone: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        if let b = app.panelUI.batch, let c = app.connections.first(where: { $0.id == b.connectionID }) {
            let mine = app.transfers(in: b)
            let verified = mine.filter { $0.phase == .verified }.count
            let place = b.folder == "/" ? "the top level" : PathRules.name(of: b.folder)
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Tone.green.soft)
                    Circle().strokeBorder(Color.green, lineWidth: 2.5)
                    if drawn {
                        if reduceMotion { check.transition(.opacity) } else { check.transition(.symbolEffect(.drawOn)) }
                    }
                }
                .frame(width: 68, height: 68)
                .onAppear {
                    withAnimation(Motion.resolve(Motion.bouncy, reduceMotion: reduceMotion)) { drawn = true }
                    AccessibilityNotification.Announcement("Upload finished").post()
                }

                VStack(spacing: 3) {
                    Text("\(MenuBarView.items(b.landed)) \(b.landed == 1 ? "is" : "are") on \(c.name)")
                        .font(.system(size: 16, weight: .semibold))
                    Text(detail(b, verified: verified, place: place))
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if b.failed > 0 {
                        Button("\(b.failed) didn’t upload · Open Activity") { app.panelUI.close(); app.show(.activity) }
                            .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                    }
                    if b.movedOriginals {
                        Text("Originals moved to the Trash on this Mac").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    if b.share {
                        showButton(b).buttonStyle(.glass)
                        Button("Manage Link") { app.reopenShare() }.buttonStyle(.glassProminent)
                    } else {
                        showButton(b).buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)

                HStack {
                    if b.undoable {
                        Button("Undo Upload") { app.undoDropUpload() }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tone.accent.text)
                            .help("Moves the uploaded copies to Recently deleted")
                    }
                    Spacer()
                    Text(app.panelUI.isHovered ? "Stays open while you point here" : "Closes by itself")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 2)

                GeometryReader { g in
                    Capsule().fill(Fill.track)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.green).frame(width: g.size.width * app.panelUI.doneLeft / 6)
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
            .padding(EdgeInsets(top: 14, leading: 6, bottom: 4, trailing: 6))
        }
    }

    private var check: some View {
        Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.verified)
    }

    private func showButton(_ b: DropBatch) -> some View {
        Button(app.canUseFinder ? "Show in Finder" : "Show in Files") {
            app.panelUI.close()
            if app.canUseFinder { app.openInFinder() } else { app.openFolder(b.folder); app.show(.files) }
        }
        .frame(maxWidth: .infinity)
    }

    private func detail(_ b: DropBatch, verified: Int, place: String) -> String {
        let seconds = (b.finished ?? Date()).timeIntervalSince(b.started)
        let took = seconds < 60 ? "\(max(1, Int(seconds))) s" : "\(Int(seconds / 60)) min"
        let size = b.size.map { "\(Format.bytes($0)) in " } ?? ""
        return (verified == b.landed ? "Verified in \(place)" : "Uploaded to \(place), \(verified) verified") + " · \(size)\(took)"
    }
}
