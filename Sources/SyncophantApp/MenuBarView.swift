import SwiftUI
import CoreKit

/// Menu bar panel state (open/closed, drop mode, the hero's fix). Owned by the menu bar panel.
@MainActor @Observable
final class PanelState {
    enum Mode: Equatable { case normal, pick, upload, done }

    /// Views and the status item set this; `StatusItemController` shows or hides the panel to match.
    var isOpen = false
    /// Where the panel grows from along its top edge: the status item.
    var growAnchor = UnitPoint.top
    var isHovered = false

    var mode: Mode = .normal
    /// The panel opened because of a drag, so cancelling the drag closes it again.
    var openedForDrop = false
    var pickURLs: [URL] = []
    var pickSize: Int64?
    var pickHasFolder = false
    /// Top-level folders on the storage, for the "Another folder…" filter.
    var pickFolders: [String] = []
    /// The pointer still carries the files (false once they were released on the icon or chosen in a dialog).
    var dragLive = false
    var folderQuery = ""
    var batch: DropBatch?
    /// Seconds left before Done returns to the normal panel; paused while the pointer is over the panel.
    var doneLeft: Double = 6

    /// The hero's fix in flight, kept after the problem disappears so the green check can show.
    var fixingIssue: Issue?
    var fixPhase: FixPhase = .idle

    /// Remembered upload folders per storage ID, most recent first.
    var destinations: [String: [UploadDestinationRecord]] = [:]

    @ObservationIgnored var sizeTask: Task<(Int64, Bool), Never>?
    @ObservationIgnored var dragWatch: Task<Void, Never>?
    @ObservationIgnored var batchWatch: Task<Void, Never>?
    @ObservationIgnored var countdown: Task<Void, Never>?

    func open() { isOpen = true }
    func close() { isOpen = false }
}

/// The panel under the status item: 360 pt, system glass, 26 pt corners. Normal mode answers "is my stuff safe,
/// and does anything need me?"; drop mode turns it into destination tiles.
struct MenuBarView: View {
    static let width: CGFloat = 360
    static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let ui = app.panelUI
        ZStack {
            switch ui.mode {
            case .normal: PanelHome().transition(.opacity)
            case .pick: DropPick().transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .upload: DropProgress().transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .done: DropDone().transition(.opacity)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .scaleEffect(shown || reduceMotion ? 1 : 0.93, anchor: ui.growAnchor)
        .offset(y: shown || reduceMotion ? 0 : -10)
        .opacity(shown ? 1 : 0)
        .motion(Motion.morph, value: ui.mode)
        // Hidden while closed, so the first frame after a click is the start of the entrance, never a stale end state.
        .onChange(of: ui.isOpen, initial: true) { _, open in
            guard open else { shown = false; return }
            Task { @MainActor in withAnimation(Motion.resolve(Motion.morph, reduceMotion: reduceMotion)) { shown = true } }
        }
        .onHover { ui.isHovered = $0 }
        .onExitCommand { ui.mode == .pick ? app.cancelPick() : ui.close() }
        // Files dragged over the open panel turn it into the drop target; a release outside any tile cancels.
        .dropDestination(for: URL.self) { _, _ in
            app.cancelPick()
            return false
        } isTargeted: { targeted in
            guard targeted, ui.mode == .normal || ui.mode == .done else { return }
            let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            app.beginPick(urls, live: true)
        }
        .onAppear { if app.openWindowAction == nil { app.openWindowAction = openWindow } }
    }
}

// MARK: - Normal panel

private struct PanelHome: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            PanelHeader()
            if app.isDemo {
                Text(DemoSession.label).font(.caption).foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            if app.active != nil {
                PanelHero()
                QuickTiles()
                BackupsStrip()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Connect your storage to start").font(.system(size: 13, weight: .semibold))
                    Button("Add Storage…") { app.panelUI.close(); app.open(.addStorage) }.buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 132)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            PanelFooter()
        }
    }
}

private struct PanelHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            if let c = app.active {
                if app.connections.count > 1 {
                    Menu {
                        ForEach(app.connections) { other in
                            Button { app.select(other.id) } label: {
                                if other.id == app.activeID { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                            }
                        }
                        Divider()
                        Button("Add Storage…") { app.panelUI.close(); app.open(.addStorage) }
                    } label: { identity(c, switcher: true) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Storage, \(c.name). Switch storage")
                } else {
                    identity(c, switcher: false)
                }
            } else {
                StorageAvatar(name: "Syncophant", size: 36)
                Text("Syncophant").font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 4)
            if let c = app.active, let cap = app.capacity(for: c) {
                let fraction = Double(cap.used) / Double(cap.total)
                HStack(spacing: 6) {
                    ProgressRing(progress: fraction, size: 20, lineWidth: 3)
                    Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                }
                .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8))
                .background(Fill.one, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Space used")
                .accessibilityValue("\(Format.bytes(cap.used)) of \(Format.bytes(cap.total))")
            }
            Button { app.openSettingsFromPanel() } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(PanelPressStyle(shape: .circle))
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 0, trailing: 2))
    }

    private func identity(_ c: StorageConnection, switcher: Bool) -> some View {
        HStack(spacing: 10) {
            StorageAvatar(name: c.name, color: app.avatarColor(for: c), size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(c.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if switcher { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    HealthOrb(health: app.health(for: c), size: 8)
                    Text(app.providerLine(for: c)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Hero

private enum HeroKind: Equatable { case transferring, synced, needsYou, offline }

private struct PanelHero: View {
    @Environment(AppModel.self) private var app

    private var kind: HeroKind {
        guard let c = app.active else { return .synced }
        if let fixing = app.panelUI.fixingIssue { return fixing.fix == .retryListing(c.id) ? .offline : .needsYou }
        if !app.activeTransfers.isEmpty { return .transferring }
        if app.health(for: c) == .offline { return .offline }
        if !app.issues.isEmpty { return .needsYou }
        return .synced
    }

    var body: some View {
        ZStack {
            switch kind {
            case .transferring: TransferringHero().transition(.opacity)
            case .synced: SyncedHero().transition(.opacity)
            case .needsYou: NeedsYouHero().transition(.opacity)
            case .offline: OfflineHero().transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .padding(14)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motion(Motion.smooth, value: kind)
        .accessibilityElement(children: .combine)
    }
}

private struct TransferringHero: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let active = app.activeTransfers
        let paused = app.queuePaused
        let speed = paused ? nil : app.throughput.last.map(\.sending).flatMap { $0 > 0 ? $0 : nil }
        let samples = app.throughput.suffix(40).map(\.sending)
        HStack(spacing: 16) {
            ProgressRing(progress: app.transferProgress ?? 0, state: paused ? .paused : .running, size: 84, lineWidth: 9, showsLabel: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(paused ? "Paused" : "Uploading \(MenuBarView.items(active.count))").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let speed {
                        Text("\(Format.bytes(Int64(speed)))/s")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tone.accent.text)
                            .rollingNumber(Int64(speed) / 100_000)
                    }
                }
                if samples.count > 1 {
                    Sparkline(values: samples, tint: paused ? .orange : .accentColor).frame(height: 36)
                }
                HStack(spacing: 6) {
                    ForEach(Array(active.sorted { ($0.phase == .working ? 0 : 1) < ($1.phase == .working ? 0 : 1) }.prefix(3))) { t in
                        FileChip(transfer: t, paused: paused)
                    }
                }
            }
        }
    }
}

/// One moving file. Clicking it shows its folder in Files.
private struct FileChip: View {
    @Environment(AppModel.self) private var app
    let transfer: Transfer
    let paused: Bool

    var body: some View {
        Button {
            if app.activeID != transfer.connectionID { app.select(transfer.connectionID) }
            app.openFolder(PathRules.parent(of: transfer.remotePath))
            app.panelUI.close()
            app.show(.files)
        } label: {
            HStack(spacing: 5) {
                ProgressRing(progress: transfer.fraction ?? 0, state: paused ? .paused : .running, size: 16, lineWidth: 2.6)
                Text(transfer.localURL.deletingPathExtension().lastPathComponent).lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(EdgeInsets(top: 4, leading: 5, bottom: 4, trailing: 7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.two, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(transfer.name)
        .accessibilityLabel("\(transfer.name), \(Int(((transfer.fraction ?? 0) * 100).rounded())) percent. Show in Files")
    }
}

private struct SyncedHero: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        let c = app.active
        let bars = app.history.hourly()
        HStack(spacing: 16) {
            ZStack {
                Circle().strokeBorder(Color.green.opacity(0.9), lineWidth: 9)
                if drawn {
                    if reduceMotion {
                        shield.transition(.opacity)
                    } else {
                        shield.transition(.symbolEffect(.drawOn))
                    }
                }
            }
            .frame(width: 84, height: 84)
            .onAppear { withAnimation(Motion.resolve(Motion.smooth, reduceMotion: reduceMotion)) { drawn = true } }
            VStack(alignment: .leading, spacing: 6) {
                Text("Everything is on \(c?.name ?? "your storage")").font(.system(size: 15, weight: .bold)).lineLimit(2)
                if let c, let checked = app.lastChecked[c.id] {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Label("Checked \(Format.ago(checked))", systemImage: "clock").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if bars.contains(where: { $0 > 0 }) { HourBars(values: bars) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shield: some View {
        Image(systemName: "checkmark.shield")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(Palette.verified)
    }
}

/// Bytes sent per hour over the last 24 hours, oldest left. Only drawn when there was any activity.
private struct HourBars: View {
    let values: [Int64]
    var body: some View {
        let peak = Double(values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(v > 0 ? Color.accentColor : Fill.two)
                    .frame(height: v > 0 ? max(3, 26 * Double(v) / peak) : 2)
            }
        }
        .frame(height: 26, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Uploads in the last 24 hours")
        .accessibilityValue(Format.bytes(values.reduce(0, +)))
    }
}

private struct NeedsYouHero: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ui = app.panelUI
        let ranked = app.rankedIssues
        if let issue = ui.fixingIssue ?? ranked.first {
            let phase = ui.fixingIssue?.id == issue.id ? ui.fixPhase : .idle
            let more = ranked.filter { $0.id != issue.id }.count
            HStack(spacing: 16) {
                ZStack {
                    if phase == .fixed {
                        Circle().strokeBorder(Color.green, lineWidth: 9)
                        Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.verified)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Circle().strokeBorder(issue.severity == .failure ? Color.red : Color.orange, style: StrokeStyle(lineWidth: 9, dash: [18, 8]))
                        if phase == .working {
                            ProgressView().controlSize(.regular)
                        } else {
                            Image(systemName: issue.severity == .failure ? "exclamationmark.circle" : "exclamationmark.triangle")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(issue.severity == .failure ? Palette.failure : Palette.caution)
                        }
                    }
                }
                .frame(width: 84, height: 84)
                .motion(Motion.bouncy, value: phase)
                VStack(alignment: .leading, spacing: 6) {
                    Text(phase == .fixed ? "Fixed" : issue.title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                    Group {
                        if case .failed(let why) = phase { Text(why) } else if phase != .fixed { Text(issue.detail) }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if phase != .fixed {
                        HStack(spacing: 10) {
                            Button(issue.fix.title.titleCased) { app.runPanelFix(issue) }
                                .buttonStyle(.glassProminent)
                                .disabled(phase == .working)
                            if more > 0 {
                                Button("\(more) more") { ui.close(); app.show(.activity) }
                                    .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct OfflineHero: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let c = app.active {
            let ui = app.panelUI
            let phase = ui.fixingIssue?.fix == .retryListing(c.id) ? ui.fixPhase : .idle
            let waiting = app.activeTransfers.filter { $0.connectionID == c.id }.count
            HStack(spacing: 16) {
                ZStack {
                    HealthOrb(health: phase == .fixed ? .healthy : .offline, size: 84)
                    Image(systemName: phase == .fixed ? "checkmark" : "wifi.slash")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(phase == .fixed ? Palette.verified : .secondary)
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text(phase == .fixed ? "Back in touch with \(c.name)" : "Can’t reach \(c.name)")
                        .font(.system(size: 15, weight: .bold)).lineLimit(2)
                    if case .failed(let why) = phase {
                        Text(why).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    } else if let last = app.lastChecked[c.id] {
                        Text("Last reached \(Format.ago(last))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if waiting > 0 {
                        Text("\(waiting) upload\(waiting == 1 ? "" : "s") wait safely").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if phase != .fixed {
                        Button(phase == .working ? "Trying…" : "Try Now") {
                            app.runPanelFix(Issue(id: "listing-\(c.id)", title: "", detail: "", fix: .retryListing(c.id)))
                        }
                        .buttonStyle(.glass)
                        .disabled(phase == .working)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Quick tiles, backups, footer

private struct QuickTiles: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let paused = app.queuePaused
        HStack(spacing: 8) {
            tile("Upload", symbol: "arrow.up.to.line") { app.chooseFilesForPanel() }
            tile(paused ? "Resume" : "Pause", symbol: paused ? "play.fill" : "pause.fill") { app.setPaused(!paused) }
                .disabled(!paused && app.activeTransfers.isEmpty)
                .help(paused ? "Resume all uploads" : "Pause all uploads after the current chunk")
            tile("Finder", symbol: "folder") { app.panelUI.close(); app.openInFinder() }
                .disabled(!app.canUseFinder)
                .help(app.canUseFinder ? "Open in Finder" : app.finderUnavailableReason)
            tile("Browse", symbol: "sidebar.left") { app.panelUI.close(); app.show(.files) }
        }
    }

    private func tile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Tone.accent.text)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 62)
        }
        .buttonStyle(PanelPressStyle(shape: .rounded(14), resting: Fill.one))
        .accessibilityLabel(title == "Finder" ? "Open in Finder" : title)
    }
}

private struct BackupsStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Backups").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { app.panelUI.close(); app.open(.newBackup) } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(PanelPressStyle(shape: .circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel("New Backup")
                .disabled(app.isDemo)
            }
            .padding(EdgeInsets(top: 0, leading: 6, bottom: 2, trailing: 4))
            if app.jobs.isEmpty {
                Button { app.panelUI.close(); app.open(.newBackup) } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: "externaldrive.badge.timemachine", tone: .green, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Protect a Mac folder").font(.system(size: 13, weight: .medium))
                            Text("Copy it to your storage on a schedule").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    .frame(minHeight: 46)
                }
                .buttonStyle(PanelPressStyle(shape: .rounded(12)))
                .disabled(app.isDemo)
            } else {
                ForEach(Array(app.jobs.prefix(3).enumerated()), id: \.element.id) { i, job in
                    BackupRow(job: job).rowEntrance(i)
                }
                if app.jobs.count > 3 {
                    Button("\(app.jobs.count - 3) more") { app.panelUI.close(); app.show(.backups) }
                        .buttonStyle(.link).font(.system(size: 11.5, weight: .semibold)).padding(.leading, 8)
                }
            }
        }
    }
}

private struct BackupRow: View {
    @Environment(AppModel.self) private var app
    let job: BackupJob

    var body: some View {
        let state: CountdownRing.State = app.runningJob == job.id ? .running
            : job.enabled ? .counting(next: job.nextRun, interval: job.schedule.interval) : .paused
        let runs = (job.runs ?? []).map { RunHistoryDots.Dot(id: $0.started, result: $0.result) }
        Button { app.panelUI.close(); app.show(.backups) } label: {
            HStack(spacing: 10) {
                IconTile(symbol: "folder", tone: .neutral, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    RunHistoryDots(runs: runs, size: 7)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let ring = CountdownRing(state: state, size: 18, showsLabel: false)
                    HStack(spacing: 6) {
                        ring
                        Text(ring.values(now: context.date).1)
                            .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .frame(minHeight: 46)
        }
        .buttonStyle(PanelPressStyle(shape: .rounded(12)))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Backups")
    }
}

private struct PanelFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Button { app.openPaletteFromPanel() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13))
                    Text("Search \(app.active?.name ?? "Syncophant")").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("⌘K").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Fill.one, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k")
            .accessibilityLabel("Search and commands")
            Menu {
                Button("Settings…") { app.openSettingsFromPanel() }
                Button("Syncophant Help") {
                    app.panelUI.close()
                    if let url = URL(string: "https://github.com/syncophant/macos") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Quit Syncophant") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                    .background(Fill.one, in: Circle()).contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
    }
}

/// Flat fill that deepens on hover and presses in: the panel's controls sit on glass, so no second glass layer.
struct PanelPressStyle: ButtonStyle {
    enum Shape { case circle, rounded(CGFloat) }
    var shape: Shape
    var resting: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, shape: shape, resting: resting)
    }

    private struct PressBody: View {
        let configuration: Configuration
        let shape: Shape
        let resting: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let fill = configuration.isPressed ? Fill.three : hovering ? Fill.two : resting
            configuration.label
                .background {
                    switch shape {
                    case .circle: Circle().fill(fill)
                    case .rounded(let r): RoundedRectangle(cornerRadius: r, style: .continuous).fill(fill)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 && isEnabled }
                .motion(Motion.snappy, value: configuration.isPressed)
        }
    }
}

// MARK: - Model actions used by the panel

extension AppModel {
    /// The hero's fix, in place: idle → working → fixed (held 1.3 s) → idle. Fixes that need a sheet open the main window.
    func runPanelFix(_ issue: Issue) {
        switch issue.fix {
        case .reviewHostKey, .enterPassword, .recoverMutation:
            panelUI.close(); show(destination); perform(issue.fix); return
        case .reconnectStorage:
            panelUI.close(); perform(issue.fix); return
        default: break
        }
        let ui = panelUI
        let started = Date()
        ui.fixingIssue = issue
        ui.fixPhase = .working
        perform(issue.fix)
        Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, ui.fixingIssue?.id == issue.id else { return }
                var fixed = !self.issues.contains { $0.id == issue.id }
                var failed = false
                if case .retryListing(let id) = issue.fix {
                    // Clearing the error is instant; only a fresh listing proves the storage answers.
                    failed = self.connectionErrors[id] != nil
                    fixed = !failed && (self.lastChecked[id] ?? .distantPast) > started
                }
                if failed { break }
                if fixed {
                    withAnimation(Motion.resolve(Motion.bouncy)) { ui.fixPhase = .fixed }
                    try? await Task.sleep(for: .seconds(1.3))
                    withAnimation(Motion.resolve(Motion.smooth)) { ui.fixingIssue = nil; ui.fixPhase = .idle }
                    return
                }
            }
            guard ui.fixingIssue?.id == issue.id else { return }
            ui.fixPhase = .failed("That didn’t fix it. Activity has the details.")
            try? await Task.sleep(for: .seconds(3))
            if ui.fixingIssue?.id == issue.id { ui.fixingIssue = nil; ui.fixPhase = .idle }
        }
    }

    /// Opens Settings through the app menu's ⌘, item, which works from this AppKit-hosted panel.
    func openSettingsFromPanel() {
        panelUI.close()
        NSApp.activate()
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            menu.performActionForItem(at: index)
        }
    }

    func openPaletteFromPanel() {
        panelUI.close()
        show(.files)
        showPalette = true
    }
}

private extension String {
    /// "Add to Finder" from "Add to finder": Title Case for buttons, small words kept lower.
    var titleCased: String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "for", "in", "of", "on", "or", "the", "to"]
        return split(separator: " ").enumerated().map { i, word in
            let w = String(word)
            return i > 0 && small.contains(w.lowercased()) ? w.lowercased() : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
