import SwiftUI
import Network
import CoreKit

/// Backups UI state: the selected job, live run progress, and what the New backup window should load.
@MainActor @Observable
final class BackupsState {
    /// A request to load the New backup window. A new value reloads an already open window.
    struct EditRequest: Equatable {
        let token = UUID()
        var job: UUID?
    }

    var selected: UUID?
    /// Files done and total of the running backup; nil while it is still checking for changes.
    var progress: JobProgress?
    var editRequest = EditRequest(job: nil)
    /// Read by the scheduler for "Skip on Personal Hotspot" (an expensive network path).
    @ObservationIgnored let network = NWPathMonitor()

    init() { network.start(queue: DispatchQueue(label: "app.syncophant.backups.network", qos: .utility)) }
}

// MARK: - Backups screen

/// Every scheduled backup as a card whose dots tell its recent history and whose ring counts down to the next run.
struct BackupsView: View {
    @Environment(AppModel.self) private var app
    @State private var removing: BackupJob?
    @State private var renaming: BackupJob?
    @State private var newName = ""

    private var jobs: [BackupJob] { app.jobs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var selectedJob: BackupJob? { jobs.first { $0.id == app.backupsUI.selected } ?? jobs.first }

    var body: some View {
        Group {
            if app.isDemo {
                ContentUnavailableView("Backups need your own storage", systemImage: "externaldrive.badge.timemachine",
                                       description: Text("Demo mode never schedules or uploads backups. Connect your own storage to set one up."))
            } else if app.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No backups yet", systemImage: "externaldrive.badge.timemachine")
                } description: {
                    Text("Copy a folder from this Mac to your storage on a schedule. Backups only add files: deleting a file here never deletes its copy on your storage.")
                } actions: {
                    Button("New Backup…") { app.editBackup(nil) }.buttonStyle(.glassProminent)
                }
            } else {
                content
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.editBackup(nil) } label: { Label("New Backup", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.glassProminent)
                    .disabled(app.isDemo)
                    .help(app.isDemo ? "Not available in demo mode" : "Back up a folder to your storage")
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Backup", role: .destructive) { if let r = removing { app.removeJob(r.id) } }
        } message: {
            Text("This stops the schedule. Files already copied stay on your storage.")
        }
        .alert("Rename Backup", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { app.renameJob(r.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 200), spacing: 14, alignment: .top), count: 3), spacing: 14) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        JobCard(job: job, selected: job.id == selectedJob?.id,
                                rename: { newName = job.name; renaming = job }, remove: { removing = job })
                            .rowEntrance(index)
                    }
                }
                if let job = selectedJob {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            RunsCard(job: job).frame(minWidth: 420)
                            WhatItDoesCard(job: job).frame(width: 360)
                        }
                        VStack(spacing: 14) {
                            RunsCard(job: job)
                            WhatItDoesCard(job: job)
                        }
                    }
                    .id(job.id)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }
        .motion(Motion.smooth, value: selectedJob?.id)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Backups").font(.system(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader)
            Label { Text(summary) } icon: {
                Image(systemName: troubled ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .foregroundStyle(troubled ? Tone.orange.text : Tone.green.text)
            }
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .frame(minHeight: 30)
    }

    /// True when any job's latest run did not fully succeed.
    private var troubled: Bool {
        jobs.contains { [.failed, .partial].contains($0.runs?.last?.result) }
    }

    /// "2 running on schedule · 1 paused · last problem 11 days ago", from the saved jobs and their runs.
    private var summary: String {
        let on = jobs.filter(\.enabled).count, paused = jobs.count - on
        var parts = [String(localized: "\(on) running on schedule")]
        if paused > 0 { parts.append(String(localized: "\(paused) paused")) }
        let runs: [BackupRun] = jobs.flatMap { $0.runs ?? [] }
        let problem: Date? = runs.filter { [RunResult.failed, .partial].contains($0.result) }.map(\.finished).max()
        parts.append(problem.map { String(localized: "last problem \(Self.relativeDay($0))") } ?? String(localized: "no problems so far"))
        return parts.joined(separator: " · ")
    }

    static func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        return f.localizedString(from: DateComponents(day: -days))
    }
}

// MARK: - Job card

private struct JobCard: View {
    @Environment(AppModel.self) private var app
    let job: BackupJob
    let selected: Bool
    let rename: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var running: Bool { app.runningJob == job.id }
    private var busy: Bool { app.runningJob != nil }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: job.folderIcon.symbol, tone: job.enabled ? job.folderIcon.tone : .neutral, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(job.route).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                CountdownRing(state: running ? .running : !job.enabled ? .paused : .counting(next: job.nextRun, interval: job.schedule.interval))
            }
            Group {
                if running { runningBody.transition(.opacity.combined(with: .scale(scale: 0.96))) }
                else { idleBody.transition(.opacity) }
            }
            .motion(Motion.morph, value: running)
            footer
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: selected ? 2 : 0.5))
        .shadow(color: selected ? Color.accentColor.opacity(0.18) : .clear, radius: 13, y: 10)
        .offset(y: hovering ? -2 : 0)
        .motion(Motion.snappy, value: hovering)
        .motion(Motion.snappy, value: selected)
        .contentShape(shape)
        .onTapGesture { select() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Back Up Now") { backUpNow() }.disabled(busy)
            if running { Button("Stop Backup") { app.stopJob() } }
            Button(job.enabled ? "Pause Schedule" : "Resume Schedule") { app.setJobEnabled(job.id, !job.enabled) }
            Divider()
            Button("Edit…") { app.editBackup(job.id) }
            Button("Rename…", action: rename)
            Button("Show Backup Folder") { app.showBackupFolder(job) }
            Divider()
            Button("Remove…", role: .destructive, action: remove).disabled(running)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.name)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Select") { select() }
    }

    private func select() { app.backupsUI.selected = job.id }

    private func backUpNow() {
        select()
        app.runJob(job)
    }

    @ViewBuilder private var runningBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = app.backupsUI.progress {
                FillBar(fraction: p.fraction)
                HStack {
                    Text("\(p.completed) of \(p.total) changed files")
                    Spacer()
                    Text("\(Int((p.fraction * 100).rounded()))%").rollingNumber(p.completed)
                }
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
                Text("Checking for changes…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 40)
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            RunHistoryDots(runs: (job.runs ?? []).map { RunHistoryDots.Dot(id: $0.started, result: $0.result) })
            Text(lastLine).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(minHeight: 40)
    }

    /// "Last run Today at 2:00 AM · 214 files · 1.6 GB · 3 min", straight from the latest run.
    private var lastLine: String {
        let last = job.runs?.last
        if !job.enabled {
            return last.map { String(localized: "Paused · last run \(Format.modified.string(from: $0.started))") } ?? String(localized: "Paused · not run yet")
        }
        if job.nextRun <= Date(), let reason = app.waitingReason(job) { return reason }
        guard let last else { return String(localized: "Not run yet · first run \(Format.modified.string(from: job.nextRun))") }
        if last.result == .failed || last.result == .missed {
            return String(localized: "Last run \(Format.modified.string(from: last.started)) · \(last.note ?? last.result.words)")
        }
        return [String(localized: "Last run \(Format.modified.string(from: last.started))"),
                String(localized: "\(last.uploaded) files"), Format.bytes(last.bytes), durationText(last.duration)].joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(job.enabled ? job.scheduleLabel : String(localized: "Paused"), systemImage: job.enabled ? "clock" : "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(job.enabled ? Color.primary : Tone.orange.text)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Fill.one, in: Capsule())
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { select(); app.setJobEnabled(job.id, !job.enabled) } label: {
                Image(systemName: job.enabled ? "pause.fill" : "play.fill").font(.system(size: 12))
                    .frame(width: 28, height: 28).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(job.enabled ? "Pause schedule" : "Resume schedule")
            .accessibilityLabel(job.enabled ? "Pause schedule" : "Resume schedule")
            Button("Back Up Now") { backUpNow() }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(busy)
                .help(running ? "Backing up now" : busy ? "Another backup is running" : "Back up changed files now")
        }
    }
}

/// An 8 pt capsule that fills smoothly.
private struct FillBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Fill.track)
                .overlay(alignment: .leading) { Capsule().fill(Color.accentColor).frame(width: g.size.width * min(1, max(0, fraction))) }
        }
        .frame(height: 8)
        .motion(Motion.smooth, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(1, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
}

// MARK: - Runs card

private struct RunsCard: View {
    @Environment(AppModel.self) private var app
    let job: BackupJob

    var body: some View {
        let runs = Array((job.runs ?? []).suffix(14))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(runs.isEmpty ? job.name : "\(job.name) · last \(runs.count) runs").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !runs.isEmpty { Text("Bar height is data sent").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            if runs.isEmpty {
                Text(job.enabled ? "No runs yet. The first one starts \(Format.modified.string(from: job.nextRun)), or choose Back Up Now."
                                 : "No runs yet. The schedule is paused.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                RunBars(runs: runs)
                VStack(spacing: 1) {
                    ForEach(Array(runs.suffix(4).reversed().enumerated()), id: \.element.id) { index, run in
                        RunRow(run: run).rowEntrance(index)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Browse…") { app.showBackupFolder(job) }
                    .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                    .help("Show this backup’s folder on your storage in Files. Every version sits there side by side.")
            }
        }
        .contentCard(radius: 16, padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Runs of \(job.name)")
    }
}

private struct RunBars: View {
    let runs: [BackupRun]

    var body: some View {
        let top = max(1, runs.map(\.bytes).max() ?? 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<max(0, 14 - runs.count), id: \.self) { _ in Color.clear.frame(maxWidth: 30, maxHeight: 0) }
            ForEach(runs) { run in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(run.result == .missed ? Fill.three : run.result.tone.color)
                    .frame(maxWidth: 30)
                    .frame(height: height(run, top: top))
                    .help("\(run.result.words) · \(Format.modified.string(from: run.started)) · \(Format.bytes(run.bytes))")
                    .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: 120, alignment: .bottom)
        .background {
            VStack(spacing: 0) {
                Spacer(); Divider(); Spacer(); Divider(); Spacer()
            }
        }
        .motion(Motion.bouncy, value: runs.last?.id)
        .accessibilityElement()
        .accessibilityLabel("Data sent per run")
        .accessibilityValue("\(runs.count) runs, most recent \(Format.bytes(runs.last?.bytes ?? 0)), largest \(Format.bytes(top))")
    }

    private func height(_ run: BackupRun, top: Int64) -> CGFloat {
        switch run.result {
        case .missed: 4
        case .failed where run.bytes == 0: 10
        default: max(8, CGFloat(Double(run.bytes) / Double(top)) * 116)
        }
    }
}

private struct RunRow: View {
    let run: BackupRun
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(run.result == .missed ? Fill.three : run.result.tone.color).frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text("\(Format.modified.string(from: run.started))\(Text(run.note.map { " · \($0)" } ?? "").foregroundStyle(noteStyle))")
                .font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group { if run.result != .missed { Text("^[\(run.uploaded) file](inflect: true)") } }
                .frame(width: 90, alignment: .leading)
            Text(run.result == .missed ? "" : durationText(run.duration))
                .frame(width: 60, alignment: .leading)
        }
        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: 38)
        .background(hovering ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(run.result.words)
    }

    private var noteStyle: AnyShapeStyle { run.result == .succeeded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(run.result.tone.text) }
}

// MARK: - What it does

private struct WhatItDoesCard: View {
    @Environment(AppModel.self) private var app
    let job: BackupJob

    private var storageName: String { app.connections.first { $0.id == job.connectionID }?.name ?? String(localized: "Removed storage") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What it does").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Edit…") { app.editBackup(job.id) }.buttonStyle(.link).font(.system(size: 12.5, weight: .semibold))
            }
            RouteDrawing(from: job.source.lastPathComponent, to: "\(storageName) › \(job.destination.drop { $0 == "/" })",
                         running: app.runningJob == job.id)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Skips")
                SentenceFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(skips, id: \.self) { Chip(text: $0, mono: $0.hasPrefix(".") || $0.hasSuffix("/")) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Keeps")
                Label("Every version", systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Tone.purple.text)
                Text("Backups only add. A changed file is uploaded beside its earlier copy, and nothing on your storage is ever deleted, so the space used only grows.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SentenceFlow(spacing: 6, lineSpacing: 6) {
                ForEach(conditions, id: \.0) { Chip(text: $0.0, symbol: $0.1) }
            }
            Text("Runs only while Syncophant is open in the menu bar.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .contentCard(radius: 16, padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What \(job.name) does")
    }

    private var skips: [String] {
        var list = [".DS_Store", String(localized: "Temporary files"), ".git/", String(localized: "Photos and Final Cut libraries")]
        if job.skipRules.contains(.caches) { list.append("Caches/") }
        if job.skipRules.contains(.nodeModules) { list.append("node_modules/") }
        if job.skipRules.contains(.largeFiles) { list.append(String(localized: "Files over 2 GB")) }
        return list
    }

    private var conditions: [(String, String)] {
        var list = [job.catchesUp ? (String(localized: "Catches up after sleep"), "moon.zzz") : (String(localized: "Skips missed runs"), "forward.end")]
        if job.skipOnHotspot == true { list.append((String(localized: "Skips on hotspot"), "personalhotspot")) }
        if job.requiresPower == true { list.append((String(localized: "Only on power adapter"), "powerplug")) }
        list.append((String(localized: "Verifies every file"), "checkmark.shield"))
        return list
    }
}

private struct Chip: View {
    let text: String
    var symbol: String?
    var mono = false
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(text).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(mono ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 26)
        .background(Fill.one, in: Capsule())
    }
}

/// Mac folder → storage folder, with a dot travelling the dashed line while a run is in progress.
private struct RouteDrawing: View {
    let from: String
    let to: String
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            end(symbol: "laptopcomputer", text: from, tint: .secondary)
            TimelineView(.animation(paused: !running || reduceMotion)) { context in
                GeometryReader { g in
                    let w = g.size.width, y = g.size.height / 2
                    let phase = running && !reduceMotion
                        ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 0
                    ZStack(alignment: .topLeading) {
                        Path { p in p.move(to: CGPoint(x: 2, y: y)); p.addLine(to: CGPoint(x: w - 8, y: y)) }
                            .stroke(Fill.three, style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                        Path { p in
                            p.move(to: CGPoint(x: w - 9, y: y - 5)); p.addLine(to: CGPoint(x: w - 2, y: y)); p.addLine(to: CGPoint(x: w - 9, y: y + 5))
                        }
                        .stroke(.tertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            .position(x: 10 + phase * max(0, w - 30), y: y)
                    }
                }
            }
            .frame(height: 20)
            end(symbol: "cloud", text: to, tint: Tone.accent.text)
        }
        .padding(12)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("From \(from) to \(to)")
        .accessibilityValue(running ? "Backing up now" : "")
    }

    private func end(symbol: String, text: String, tint: some ShapeStyle) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(width: 92)
    }
}

// MARK: - Flow layout

/// Lays out children left to right and wraps them, like words in a sentence. A child marked `.glued()` sits
/// against the one before it with no gap, so punctuation stays with its word.
struct SentenceFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    struct Glued: LayoutValueKey { static let defaultValue = false }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: y + row.height / 2), anchor: .leading,
                                           proposal: ProposedViewSize(item.size))
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(index: Int, x: CGFloat, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let gap = view[Glued.self] ? 0 : spacing
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + gap
            // Keep a glued child on its word's line; otherwise wrap when it would overflow.
            if !row.items.isEmpty, x + size.width > width, !view[Glued.self] {
                rows.append(Row()); row = Row()
                row.items.append((index, 0, size)); row.width = size.width; row.height = size.height
            } else {
                row.items.append((index, x, size)); row.width = x + size.width; row.height = max(row.height, size.height)
            }
            rows[rows.count - 1] = row
        }
        return rows
    }
}

extension View {
    /// In a `SentenceFlow`, sit against the previous child with no gap.
    func glued(_ on: Bool = true) -> some View { layoutValue(key: SentenceFlow.Glued.self, value: on) }
}
