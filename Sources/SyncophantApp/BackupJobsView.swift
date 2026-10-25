import SwiftUI
import CoreKit

// The New backup window: a backup is set up by completing one sentence, with a real scan of the source folder
// underneath. The scan is the preview the engine contract asks for, so Save waits until it has finished.

/// A cancellable local scan of the source folder, summarised by skip rule and file kind.
@MainActor @Observable
final class FolderScan {
    struct Tally: Sendable { var count = 0; var bytes: Int64 = 0 }
    /// Totals keyed by the rule that would skip the files (0 = none), then by kind.
    typealias Buckets = [Int: [FileKind: Tally]]

    private(set) var counted = 0
    private(set) var buckets: Buckets?
    private(set) var error: String?
    private(set) var stopped = false
    private var task: Task<Void, Never>?
    private var generation = 0

    var running: Bool { task != nil }

    func start(_ url: URL) {
        cancel()
        counted = 0; buckets = nil; error = nil; stopped = false
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            do {
                let result = try await Self.summarise(url) { n in Task { @MainActor in if self?.generation == mine { self?.counted = n } } }
                guard let self, self.generation == mine else { return }
                self.buckets = result
            } catch {
                guard let self, self.generation == mine else { return }
                if !(error is CancellationError) { self.error = message(for: error) }
            }
            if self?.generation == mine { self?.task = nil }
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel(); self.task = nil; stopped = buckets == nil
    }

    private nonisolated static func summarise(_ url: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> Buckets {
        var buckets: Buckets = [:]
        for item in try await BackupEngine.scan(source: url, progress: progress) {
            var tally = buckets[item.rule?.rawValue ?? 0, default: [:]][FileKind(path: item.path), default: Tally()]
            tally.count += 1; tally.bytes += item.size
            buckets[item.rule?.rawValue ?? 0, default: [:]][FileKind(path: item.path)] = tally
        }
        return buckets
    }

    /// Files that would be sent with these rules on, by kind.
    func included(_ rules: BackupExclusions) -> [FileKind: Tally] {
        var out: [FileKind: Tally] = [:]
        for (rule, kinds) in buckets ?? [:] where rule == 0 || !rules.contains(BackupExclusions(rawValue: rule)) {
            for (kind, t) in kinds { out[kind, default: Tally()].count += t.count; out[kind, default: Tally()].bytes += t.bytes }
        }
        return out
    }

    func tally(_ rule: BackupExclusions) -> Tally {
        (buckets?[rule.rawValue] ?? [:]).values.reduce(into: Tally()) { $0.count += $1.count; $0.bytes += $1.bytes }
    }
}

struct NewBackupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    private enum Token: Hashable { case source, storage, when, keeping }

    @State private var scan = FolderScan()
    @State private var original: BackupJob?
    @State private var jobID = UUID()
    @State private var source: URL?
    @State private var bookmark: Data?
    @State private var connectionID: UUID?
    @State private var schedule: BackupJob.Schedule = .daily
    @State private var timeOfDay = 2 * 60
    @State private var weekday = 1
    @State private var exclusions: BackupExclusions = [.caches, .nodeModules]
    @State private var catchUp = true
    @State private var skipOnHotspot = true
    @State private var requiresPower = false
    @State private var open: Token?
    @State private var saved: String?
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if app.isDemo {
                ContentUnavailableView("Backups need your own storage", systemImage: "externaldrive.badge.timemachine",
                                       description: Text("Demo mode never schedules or uploads backups. Connect your own storage to set one up."))
            } else if !app.hasConnections {
                ContentUnavailableView {
                    Label("Add storage first", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("A backup copies a folder from this Mac to one of your storages.")
                } actions: {
                    Button("Add Storage…") { app.open(.addStorage) }.buttonStyle(.glassProminent)
                }
            } else {
                editor
            }
        }
        .frame(width: 820, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(original == nil ? "New Backup" : "Edit Backup")
        .onAppear { load(app.backupsUI.editRequest) }
        .onChange(of: app.backupsUI.editRequest) { _, request in load(request) }
        .onDisappear { scan.cancel() }
    }

    // MARK: Loading

    private func load(_ request: BackupsState.EditRequest) {
        open = nil; saved = nil
        if let id = request.job, let job = app.jobs.first(where: { $0.id == id }) {
            original = job; jobID = job.id
            source = job.source; bookmark = job.bookmark; connectionID = job.connectionID
            schedule = job.schedule; timeOfDay = job.timeOfDay ?? 2 * 60; weekday = job.weekday ?? 1
            exclusions = job.skipRules; catchUp = job.catchesUp
            skipOnHotspot = job.skipOnHotspot ?? false; requiresPower = job.requiresPower ?? false
        } else {
            original = nil; jobID = UUID()
            let documents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents", directoryHint: .isDirectory)
            source = FileManager.default.fileExists(atPath: documents.path) ? documents : nil
            bookmark = source.flatMap(app.backupBookmark)
            connectionID = app.activeID ?? app.connections.first?.id
            schedule = .daily; timeOfDay = 2 * 60; weekday = 1
            exclusions = [.caches, .nodeModules]; catchUp = true; skipOnHotspot = true; requiresPower = false
        }
        rescan()
    }

    private func rescan() {
        if let source, !app.isDemo { scan.start(source) } else { scan.cancel() }
    }

    private func pick(_ url: URL, bookmark data: Data?) {
        open = nil
        guard url != source else { return }
        source = url; bookmark = data ?? app.backupBookmark(for: url)
        rescan()
    }

    // MARK: Derived

    private var connection: StorageConnection? { app.connections.first { $0.id == connectionID } }

    /// `/Backups/<source name>` for a new backup; an edited one keeps its folder unless the source changes.
    private var destination: String {
        if let original, original.source == source { return original.destination }
        return "/Backups/" + (source?.lastPathComponent ?? "")
    }

    private var draft: BackupJob? {
        guard let source, let connectionID else { return nil }
        var job = original ?? BackupJob(id: jobID, name: source.lastPathComponent, connectionID: connectionID, source: source, destination: destination)
        let moved = original.map { $0.source != source || $0.connectionID != connectionID || $0.destination != destination } ?? false
        job.source = source; job.bookmark = bookmark; job.connectionID = connectionID; job.destination = destination
        job.schedule = schedule
        job.timeOfDay = schedule == .hourly ? nil : timeOfDay
        job.weekday = schedule == .weekly ? weekday : nil
        job.exclusions = exclusions; job.catchUp = catchUp; job.skipOnHotspot = skipOnHotspot; job.requiresPower = requiresPower
        if moved { job.records = [:]; job.lastRun = nil; job.lastSummary = nil }
        job.nextRun = job.nextRun(after: Date())
        if original == nil { job.enabled = true }
        return job
    }

    /// Nothing has been copied to this target yet, so the scan is exactly what the first run sends.
    private var firstRun: Bool { original == nil || original?.records.isEmpty == true || draft?.records.isEmpty == true }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                sentence
                HStack(alignment: .top, spacing: 16) {
                    firstRunCard
                    whenCard.frame(width: 200)
                }
                SentenceFlow(spacing: 8, lineSpacing: 8) {
                    ConditionChip(title: "Catch up after sleep", isOn: $catchUp,
                                  help: "Off: a run missed while the Mac slept or Syncophant was closed waits for its next time.")
                    ConditionChip(title: "Skip on Personal Hotspot", isOn: $skipOnHotspot,
                                  help: "Waits while the Mac is on Personal Hotspot or another network macOS marks as metered.")
                    ConditionChip(title: "Only on power adapter", isOn: $requiresPower, help: "Waits until the Mac is plugged in.")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 48).padding(.top, 18)
            Divider()
            footer
        }
    }

    // MARK: Sentence

    private var sentence: some View {
        let format = NSLocalizedString("Back up %1$@ to %2$@, %3$@, keeping %4$@.",
                                       comment: "New backup sentence: source folder, storage, schedule, history. Each placeholder is a button.")
        var parts: [(id: String, glued: Bool, token: Token?, text: String)] = []
        // Text touching a token with no space ("," after it, or "(" before it) stays glued to it when lines wrap.
        var cursor = format.startIndex, glue = false
        func words(_ text: Substring) {
            for (i, word) in text.split(separator: " ").enumerated() {
                parts.append(("w\(parts.count)", i == 0 && !text.hasPrefix(" ") && !parts.isEmpty, nil, String(word)))
            }
            glue = !text.isEmpty && !text.hasSuffix(" ")
        }
        for match in format.matches(of: /%(\d)\$@/) {
            words(format[cursor..<match.range.lowerBound])
            let token: Token = switch match.output.1 { case "1": .source; case "2": .storage; case "3": .when; default: .keeping }
            parts.append(("t\(parts.count)", glue, token, ""))
            cursor = match.range.upperBound
        }
        words(format[cursor...])
        let spoken = String(format: format, source?.lastPathComponent ?? String(localized: "no folder"), connection?.name ?? "",
                            whenWords, String(localized: "every version"))

        return SentenceFlow(spacing: 8, lineSpacing: 6) {
            ForEach(parts, id: \.id) { part in
                Group {
                    if let token = part.token { tokenButton(token) }
                    else { Text(part.text).font(.system(size: 26, weight: .semibold)).tracking(-0.5).accessibilityHidden(true) }
                }
                .glued(part.glued)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    private var whenWords: String {
        var job = BackupJob(name: "", connectionID: UUID(), source: URL(filePath: "/"), destination: "/")
        job.schedule = schedule; job.timeOfDay = timeOfDay; job.weekday = weekday
        return job.scheduleSentence
    }

    @ViewBuilder private func tokenButton(_ token: Token) -> some View {
        switch token {
        case .source:
            TokenButton(tint: .accent, isOpen: open == .source, label: "Folder to back up", value: source?.lastPathComponent ?? String(localized: "Choose a folder")) {
                Image(systemName: "folder.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
            } action: { open = .source }
            .popover(isPresented: binding(.source), arrowEdge: .bottom) { sourceOptions }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
                pick(url, bookmark: nil); return true
            } isTargeted: { dropTargeted = $0 }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2) } }
        case .storage:
            TokenButton(tint: .neutral, isOpen: open == .storage, label: "Storage", value: connection?.name ?? String(localized: "Choose storage")) {
                if let connection { StorageAvatar(name: connection.name, color: app.avatarColor(for: connection), size: 28) }
            } action: { open = .storage }
            .popover(isPresented: binding(.storage), arrowEdge: .bottom) { storageOptions }
        case .when:
            TokenButton(tint: .teal, isOpen: open == .when, label: "When", value: whenWords) { EmptyView() } action: { open = .when }
                .popover(isPresented: binding(.when), arrowEdge: .bottom) { whenOptions }
        case .keeping:
            TokenButton(tint: .purple, isOpen: open == .keeping, label: "Keeping", value: String(localized: "every version")) { EmptyView() } action: { open = .keeping }
                .popover(isPresented: binding(.keeping), arrowEdge: .bottom) { keepingOptions }
        }
    }

    private func binding(_ token: Token) -> Binding<Bool> {
        Binding(get: { open == token }, set: { if !$0, open == token { open = nil } })
    }

    // MARK: Popovers

    private var sourceOptions: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads"]
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
        let folders = (standard + app.jobs.map(\.source))
            .reduce(into: [URL]()) { list, url in if !list.contains(url), FileManager.default.fileExists(atPath: url.path) { list.append(url) } }
        return OptionList {
            ForEach(folders, id: \.self) { url in
                OptionRow(title: url.lastPathComponent, subtitle: (url.path as NSString).abbreviatingWithTildeInPath, selected: url == source) {
                    pick(url, bookmark: app.jobs.first { $0.source == url }?.bookmark)
                }
            }
            Divider().padding(.vertical, 2)
            OptionRow(title: String(localized: "Choose Folder…"), subtitle: String(localized: "Or drop a folder onto the word"), selected: false) {
                open = nil
                if let (url, data) = app.chooseBackupFolder() { pick(url, bookmark: data) }
            }
        }
    }

    private var storageOptions: some View {
        OptionList {
            ForEach(app.connections) { c in
                let free = app.capacity(for: c).map { String(localized: "\(Format.bytes($0.total - $0.used)) free") }
                OptionRow(title: c.name, subtitle: free ?? app.providerLine(for: c), selected: c.id == connectionID) {
                    connectionID = c.id; open = nil
                }
            }
        }
    }

    private var whenOptions: some View {
        let time = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: timeOfDay / 60, minute: timeOfDay % 60, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); timeOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
        return OptionList {
            OptionRow(title: String(localized: "Every hour"), subtitle: String(localized: "An hour after the last run, while the Mac is awake"), selected: schedule == .hourly) {
                schedule = .hourly; open = nil
            }
            OptionRow(title: String(localized: "Every day"), subtitle: String(localized: "At the time below"), selected: schedule == .daily) { schedule = .daily }
            OptionRow(title: String(localized: "Every week"), subtitle: String(localized: "On the day and time below"), selected: schedule == .weekly) { schedule = .weekly }
            if schedule != .hourly {
                Divider().padding(.vertical, 2)
                HStack {
                    if schedule == .weekly {
                        Picker("Day", selection: $weekday) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer()
                    Button("Done") { open = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
            }
        }
    }

    private var keepingOptions: some View {
        OptionList {
            OptionRow(title: String(localized: "Every version"),
                      subtitle: String(localized: "A changed file is uploaded beside its earlier copy. Nothing is deleted, so space used only grows."),
                      selected: true) { open = nil }
        }
    }

    // MARK: First run

    private var firstRunCard: some View {
        let kinds = scan.included(exclusions)
        let count = kinds.values.reduce(0) { $0 + $1.count }, bytes = kinds.values.reduce(Int64(0)) { $0 + $1.bytes }
        let speed = connectionID.flatMap(app.measuredBackupSpeed)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(firstRun ? "First run" : "Folder").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("→ \(destination)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if source == nil {
                Text("Choose a folder to see what the first run sends.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else if let error = scan.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.red.text).font(.callout)
                Button("Scan Again") { rescan() }.buttonStyle(.glass).controlSize(.small)
            } else if scan.buckets == nil {
                scanning
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    stat(count.formatted(), count == 1 ? "file" : "files", count)
                    stat(Format.bytes(bytes), firstRun ? "to send" : "in this backup", bytes)
                    if let speed, speed > 0 {
                        stat(durationText(Double(bytes) / speed), "at \(Format.bytes(Int64(speed)))/s", bytes)
                    }
                }
                KindBar(kinds: kinds)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Skip")
                SentenceFlow(spacing: 6, lineSpacing: 6) {
                    SkipChip(title: ".DS_Store", size: nil, isOn: .constant(true), fixed: true)
                    SkipChip(title: String(localized: "Temporary files"), size: nil, isOn: .constant(true), fixed: true)
                    ForEach([(BackupExclusions.caches, "Caches"), (.nodeModules, "node_modules"), (.largeFiles, String(localized: "Files over 2 GB"))], id: \.0.rawValue) { rule, title in
                        SkipChip(title: title, size: scan.buckets == nil ? nil : scan.tally(rule).bytes,
                                 isOn: Binding(get: { exclusions.contains(rule) }, set: { if $0 { exclusions.insert(rule) } else { exclusions.remove(rule) } }))
                    }
                }
            }
        }
        .contentCard(radius: 16, padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(firstRun ? "First run preview" : "Folder preview")
    }

    private var scanning: some View {
        HStack(spacing: 10) {
            if scan.running {
                ProgressView().controlSize(.small)
                Text("Reading \(source?.lastPathComponent ?? "")… \(scan.counted.formatted()) files").rollingNumber(scan.counted)
                Spacer()
                Button("Stop") { scan.cancel() }.buttonStyle(.glass).controlSize(.small)
            } else {
                Text(scan.stopped ? "Scan stopped. Save waits for a finished scan." : "Not scanned yet.")
                Spacer()
                Button("Scan Again") { rescan() }.buttonStyle(.glass).controlSize(.small)
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private func stat<V: Equatable>(_ value: String, _ label: LocalizedStringKey, _ roll: V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 26, weight: .bold)).tracking(-0.5).rollingNumber(roll)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: When it runs

    private var whenCard: some View {
        var job = BackupJob(name: "", connectionID: UUID(), source: URL(filePath: "/"), destination: "/")
        job.schedule = schedule; job.timeOfDay = timeOfDay; job.weekday = weekday
        let time = job.timeText ?? ""
        let base: String = switch schedule {
        case .hourly: String(localized: "Every hour while Syncophant is open.")
        case .daily: String(localized: "Once a day at \(time), while Syncophant is open.")
        case .weekly: String(localized: "Every \(job.weekdayText) at \(time), while Syncophant is open.")
        }
        let note = base + " " + (catchUp ? String(localized: "A run missed during sleep starts when the Mac wakes.")
                                         : String(localized: "A run missed during sleep waits for its next time."))
        return VStack(spacing: 10) {
            SectionLabel("When it runs")
            ScheduleDial(hours: job.runHours)
                .accessibilityLabel("Run times")
                .accessibilityValue(note)
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .contentCard(radius: 16, padding: 16)
    }

    // MARK: Footer

    private var footer: some View {
        let ready = draft != nil && scan.buckets != nil
        return HStack(spacing: 10) {
            if let saved {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tone.green.text)
                    .symbolEffect(.bounce, value: saved)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            Button("Cancel") { dismissWindow(id: SetupWindow.newBackup.rawValue) }
                .buttonStyle(.glass).keyboardShortcut(.cancelAction)
            Button("Save") { save(run: false) }
                .buttonStyle(.glass).disabled(!ready)
                .help(ready ? "Save the schedule without running now" : "Wait for the scan of the folder to finish")
            Button("Save and Back Up Now") { save(run: true) }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .frame(minWidth: 170)
                .disabled(!ready || app.runningJob != nil)
                .help(app.runningJob != nil ? "Another backup is running. Save now and this one runs on schedule." : "")
        }
        .padding(.horizontal, 22).frame(height: 68)
        .motion(Motion.smooth, value: saved)
        .task(id: saved) {
            guard saved != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            saved = nil
        }
    }

    private func save(run: Bool) {
        guard let job = draft, scan.buckets != nil else { return }
        do { try app.saveJob(job) } catch { app.say(message(for: error), error: true); return }
        original = job
        if run {
            app.runJob(job)
            app.backupsUI.selected = job.id
            app.show(.backups)
            dismissWindow(id: SetupWindow.newBackup.rawValue)
        } else {
            saved = String(localized: "Saved. First run \(Self.when(job.nextRun))")
        }
    }

    /// "tonight at 2:00 AM", "today at 3:00 PM", "tomorrow at 9:00 AM", or a date.
    static func when(_ date: Date) -> String {
        let cal = Calendar.current, time = Format.time.string(from: date), hour = cal.component(.hour, from: date)
        if cal.isDateInToday(date) { return hour >= 18 ? String(localized: "tonight at \(time)") : String(localized: "today at \(time)") }
        if cal.isDateInTomorrow(date) { return hour < 6 ? String(localized: "tonight at \(time)") : String(localized: "tomorrow at \(time)") }
        return Format.modified.string(from: date)
    }
}

// MARK: - Parts

/// A coloured word in the sentence that opens a popover of choices.
private struct TokenButton<Icon: View>: View {
    let tint: Tone
    let isOpen: Bool
    let label: String
    let value: String
    @ViewBuilder var icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                Text(value).font(.system(size: 24, weight: .bold)).tracking(-0.4).lineLimit(1)
            }
            .padding(.leading, Icon.self == EmptyView.self ? 14 : 8).padding(.trailing, 14)
            .frame(height: 40)
            .foregroundStyle(tint == .neutral ? Color.primary : tint.text)
            .background(tint == .neutral ? Fill.two : tint.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { if isOpen { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint == .neutral ? Color.primary : tint.color, lineWidth: 2) } }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: isOpen)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint("Opens choices")
    }
}

private struct OptionList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(6)
            .frame(width: 300)
    }
}

private struct OptionRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(hovering ? Fill.two : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A Skip chip: struck through while the rule is on. Fixed chips are rules the engine always applies.
private struct SkipChip: View {
    let title: String
    let size: Int64?
    @Binding var isOn: Bool
    var fixed = false

    var body: some View {
        Button { if !fixed { isOn.toggle() } } label: {
            HStack(spacing: 6) {
                Text(title).strikethrough(isOn)
                if let size { Text(Format.bytes(size)).strikethrough(isOn).opacity(0.7).monospacedDigit() }
                if fixed { Image(systemName: "lock.fill").font(.system(size: 9)).opacity(0.6) }
            }
            .font(.system(size: 12))
            .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 11).frame(height: 28)
            .background(isOn ? Fill.two : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Fill.two, lineWidth: isOn ? 0 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: isOn)
        .help(fixed ? "Always skipped" : isOn ? "Skipped. Click to include" : "Included. Click to skip")
        .accessibilityLabel(title)
        .accessibilityValue(fixed ? "Always skipped" : isOn ? "Skipped" : "Included")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct ConditionChip: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    let help: LocalizedStringKey

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 18, height: 18)
                    .background(isOn ? Color.green : Fill.three, in: Circle())
                Text(title).font(.system(size: 12.5))
            }
            .padding(.leading, 8).padding(.trailing, 12).frame(height: 32)
            .background(isOn ? Fill.two : Fill.one, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: isOn)
        .help(help)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A stacked bar of bytes by kind, with its legend.
private struct KindBar: View {
    let kinds: [FileKind: FolderScan.Tally]

    var body: some View {
        let shown = FileKind.allCases.filter { (kinds[$0]?.bytes ?? 0) > 0 }
        let total = max(1, shown.reduce(Int64(0)) { $0 + (kinds[$1]?.bytes ?? 0) })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(shown) { kind in
                        Capsule().fill(kind == .other ? Fill.three : kind.tone.color)
                            .frame(width: max(4, (g.size.width - CGFloat(shown.count - 1) * 2) * CGFloat(kinds[kind]!.bytes) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .background(Fill.track, in: Capsule())
            .motion(Motion.smooth, value: shown.map { kinds[$0]!.bytes })
            HStack(spacing: 14) {
                ForEach(shown) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(kind == .other ? Fill.three : kind.tone.color).frame(width: 8, height: 8)
                        Text(kind.label)
                    }
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Kinds of files")
        .accessibilityValue(shown.map { "\(Int((Double(kinds[$0]!.bytes) / Double(total) * 100).rounded())) percent \($0.label)" }.joined(separator: ", "))
    }
}

/// 24 hours as a dial, with a teal tick for each hour that has a run. Midnight is at the top.
private struct ScheduleDial: View {
    let hours: Set<Int>

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r: CGFloat = 56
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Fill.track), lineWidth: 2)
            for h in 0..<24 {
                let a = Double(h) / 24 * 2 * .pi - .pi / 2, on = hours.contains(h)
                let inner = on ? 40.0 : 48.0
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                tick.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                context.stroke(tick, with: .color(on ? .teal : Fill.three), style: StrokeStyle(lineWidth: on ? 4 : 2, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.teal))
            context.draw(Text("24 h").font(.system(size: 10)).foregroundStyle(.tertiary), at: CGPoint(x: c.x, y: c.y + 32))
        }
        .frame(width: 140, height: 140)
        .motion(Motion.smooth, value: hours)
        .accessibilityElement()
    }
}
