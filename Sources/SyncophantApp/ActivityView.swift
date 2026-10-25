import SwiftUI
import CoreKit

/// Activity section UI state (filter, fix progress per problem). Owned by the Activity screen.
@MainActor @Observable
final class ActivityState {
    enum Filter: Hashable { case all, uploads, needsYou }
    var filter: Filter = .all
    /// Fix progress per issue ID. Missing means idle.
    var fixes: [String: FixPhase] = [:]
    /// What a fixed card says before it collapses, such as "Studio Box is in Finder".
    var results: [String: String] = [:]
    /// Cards kept on screen while their fix runs and for 1.3 s after, even once the model drops the issue.
    var kept: [String: Issue] = [:]
    /// Measured round-trip time per storage, from a timed `stat("/")`.
    var roundTrip: [UUID: TimeInterval] = [:]
}

/// What is moving, what is next and what needs you, each problem with its own fix.
struct ActivityView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let filter = app.activityUI.filter
        let cards = problemCards
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(spacing: 14) {
                    if filter != .uploads, !cards.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(cards) { issue in ProblemCard(issue: issue).transition(.opacity) }
                        }
                    }
                    if filter == .needsYou, cards.isEmpty {
                        EmptyNote(text: "No problems. Nothing needs you.").contentCard(radius: 16)
                    }
                    if filter != .needsYou {
                        if !app.throughput.isEmpty || !app.activeTransfers.isEmpty { ThroughputCard() }
                        TransfersCard()
                    }
                }
                .motion(Motion.smooth, value: cards.map(\.id))
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)

            ScrollView {
                VStack(spacing: 14) {
                    ConnectionCard()
                    DayCard()
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            .frame(width: 330)
        }
        .padding(.top, 8).padding(.leading, 20).padding(.trailing, 16)
        .toolbar { ActivityToolbar() }
    }

    /// Live problems plus any card still showing its fix, most severe first.
    private var problemCards: [Issue] {
        let live = app.rankedIssues
        let liveIDs = Set(live.map(\.id))
        let kept = app.activityUI.kept.values.filter { !liveIDs.contains($0.id) }
        return (live + kept).sorted { ($0.rank, $0.title) < ($1.rank, $1.title) }
    }
}

// MARK: - Toolbar

private struct ActivityToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        @Bindable var state = app.activityUI
        let count = app.issues.count
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $state.filter) {
                Text("All").tag(ActivityState.Filter.all)
                Text("Uploads").tag(ActivityState.Filter.uploads)
                Text(count > 0 ? "Needs you \(count)" : "Needs you").tag(ActivityState.Filter.needsYou)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show everything, only uploads, or only problems")
        }
        ToolbarItem(placement: .primaryAction) {
            let paused = app.queuePaused
            Button { app.setPaused(!paused) } label: {
                Label(paused ? "Resume All" : "Pause All", systemImage: paused ? "play.fill" : "pause.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .tint(paused ? .orange : nil)
            .help(paused ? "Resume uploads and scheduled backups" : "Pause uploads and scheduled backups after the current chunk")
        }
    }
}

// MARK: - Needs you

private struct ProblemCard: View {
    @Environment(AppModel.self) private var app
    let issue: Issue

    var body: some View {
        let state = app.activityUI
        let phase = state.fixes[issue.id] ?? .idle
        let fixed = phase == .fixed
        let failure: String? = if case .failed(let m) = phase { m } else { nil }
        HStack(spacing: 12) {
            IconTile(symbol: fixed ? "checkmark" : issue.symbol, tone: fixed ? .green : issue.tone, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(fixed ? state.results[issue.id] ?? issue.title : issue.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .contentTransition(.opacity)
                Text(failure ?? issue.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.failure))
                    .lineLimit(2)
                    .opacity(fixed ? 0 : 1)
            }
            Spacer(minLength: 8)
            switch phase {
            case .working:
                ProgressView().controlSize(.small).accessibilityLabel("Fixing")
            case .fixed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.verified)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityLabel("Fixed")
            case .idle, .failed:
                Button(failure == nil ? issue.fix.title : "Try Again") { run() }
                    .buttonStyle(.glass)
            }
        }
        .statusCard(fixed ? .green : issue.tone)
        .motion(Motion.smooth, value: fixed)
        .motion(Motion.bouncy, value: phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fixed ? state.results[issue.id] ?? issue.title : issue.title)
    }

    private func run() {
        let state = app.activityUI
        let id = issue.id
        state.kept[id] = issue
        state.fixes[id] = .working
        Task {
            let outcome = await app.resolve(issue.fix)
            switch outcome {
            case .opened:
                state.fixes[id] = nil; state.kept[id] = nil
            case .failed(let why):
                state.fixes[id] = .failed(why); state.kept[id] = nil
            case .fixed(let result):
                state.results[id] = result
                state.fixes[id] = .fixed
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(Motion.resolve(Motion.smooth)) {
                    state.kept[id] = nil; state.fixes[id] = nil; state.results[id] = nil
                }
            }
        }
    }
}

// MARK: - Throughput

private struct ThroughputCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let last = app.throughput.last
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 28) {
                BigStat(label: "Sending", tint: .accentColor,
                        value: app.queuePaused ? "Paused" : last.map { speed($0.sending) } ?? "Starting…")
                if let receiving = last?.receiving {
                    BigStat(label: "Receiving", tint: .teal, value: speed(receiving))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Left in queue").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(Format.bytes(app.bytesLeftInQueue))
                        .font(.system(size: 17, weight: .semibold))
                        .rollingNumber(app.bytesLeftInQueue)
                }
                .accessibilityElement(children: .combine)
            }
            ThroughputChart(samples: app.throughput,
                            limit: app.settings.bandwidth == .limited ? 20_000_000 : nil,
                            span: 120)
                .frame(height: 120)
            HStack {
                Text("2 min ago"); Spacer(); Text("1 min"); Spacer(); Text("Now")
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentCard(radius: 16, padding: 16)
    }

    private func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "0 KB/s" : "\(Format.bytes(Int64(bytesPerSecond)))/s"
    }
}

private struct BigStat: View {
    let label: String
    let tint: Color
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Capsule().fill(tint).frame(width: 10, height: 3).accessibilityHidden(true)
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.5)
                .rollingNumber(value)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Transfers

private struct TransfersCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let rows = self.rows
        let waiting = rows.filter { $0.phase == .queued }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Now, next and done today")
                Spacer()
                if waiting > 1 {
                    Text("Drag to change the order").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if rows.isEmpty {
                EmptyNote(text: "Nothing here. Everything is in sync.")
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, t in
                        TransferRowView(transfer: t).rowEntrance(index)
                    }
                }
                .motion(Motion.smooth, value: rows.map(\.id))
            }
        }
        .contentCard(radius: 16, padding: 8)
    }

    /// Running, then waiting in start order, then done today, newest first.
    private var rows: [Transfer] {
        let now = Date()
        let running = app.transfers.filter { $0.phase == .working }
        let waiting = app.transfers.filter { $0.phase == .queued }
        let done = app.transfers.filter { !$0.phase.isActive && now.timeIntervalSince($0.finishedAt ?? .distantPast) < 86_400 }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        return running + waiting + done
    }
}

private struct TransferRowView: View {
    @Environment(AppModel.self) private var app
    let transfer: Transfer
    @State private var hovering = false

    private var waiting: Bool { transfer.phase == .queued }

    var body: some View {
        let t = transfer
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 22)
                .opacity(waiting && hovering ? 1 : 0)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                IconTile(symbol: tileSymbol, tone: tileTone, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(t.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(place).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if t.phase == .working || (waiting && t.completed > 0) {
                        Group {
                            if let f = t.fraction { ProgressView(value: f) } else { ProgressView() }
                        }
                        .progressViewStyle(.linear)
                        .tint(t.isHeld || app.queuePaused ? .orange : .accentColor)
                        .controlSize(.small)
                        .motion(Motion.smooth, value: t.fraction)
                    }
                }
                Spacer(minLength: 8)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(metaTone.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.secondary))
                    .rollingNumber(meta)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            actions.frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(hovering ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(waiting ? 0.62 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(Reorderable(transfer: t))
    }

    @ViewBuilder private var actions: some View {
        let t = transfer
        HStack(spacing: 2) {
            switch t.phase {
            case .queued, .working:
                RowButton(symbol: t.isHeld ? "play.fill" : "pause.fill", label: "\(t.isHeld ? "Resume" : "Pause") \(t.name)") {
                    app.setHeld(t.id, !t.isHeld)
                }
                RowButton(symbol: "xmark", label: "Cancel \(t.name)") { app.cancel(t.id) }
            case .verified:
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Palette.verified)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Verified")
            case .unverified, .failed, .cancelled:
                RowButton(symbol: "arrow.clockwise", label: "Retry \(t.name)") { app.retry(t.id) }
            }
        }
    }

    private var tileSymbol: String {
        switch transfer.phase {
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        default: "arrow.up"
        }
    }

    private var tileTone: Tone {
        switch transfer.phase {
        case .working, .queued: .accent
        case .failed: .red
        default: .neutral
        }
    }

    /// The folder it goes to (the storage name for the top level), and for done rows when it finished.
    private var place: String {
        let folder = PathRules.parent(of: transfer.publishedPath ?? transfer.remotePath)
        let name = folder == "/" ? app.connections.first { $0.id == transfer.connectionID }?.name ?? "Top level" : PathRules.name(of: folder)
        if let done = transfer.finishedAt, !transfer.phase.isActive { return "\(name) · \(Format.ago(done))" }
        return name
    }

    private var meta: String {
        let t = transfer
        let percent = t.fraction.map { "\(Int($0 * 100))%" }
        switch t.phase {
        case .queued: return t.isHeld ? "Paused" : "Waiting · \(Format.bytes(t.size))"
        case .working:
            if t.isVerifying { return "Verifying…" }
            if t.isHeld { return ["Paused", percent].compactMap { $0 }.joined(separator: " · ") }
            return [percent, t.eta.map(Self.left)].compactMap { $0 }.joined(separator: " · ")
        case .verified: return Format.bytes(t.size)
        case .unverified: return "Not verified"
        case .cancelled: return "Cancelled"
        case .failed: return percent.map { "Stopped at \($0)" } ?? "Didn’t upload"
        }
    }

    private var metaTone: Tone? {
        switch transfer.phase {
        case .unverified: .orange
        case .failed: .red
        case .queued, .working: transfer.isHeld ? .orange : nil
        default: nil
        }
    }

    static func left(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        let s = max(1, Int(seconds))
        if s < 60 { return "\(s) s left" }
        if s < 3600 { return "\(s / 60) min left" }
        return "\(s / 3600) h \(s % 3600 / 60) min left"
    }
}

/// Waiting rows can be dragged onto another waiting row; the move changes the real start order.
private struct Reorderable: ViewModifier {
    @Environment(AppModel.self) private var app
    let transfer: Transfer

    func body(content: Content) -> some View {
        if transfer.phase == .queued {
            content
                .draggable(transfer.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    app.moveWaiting(id, to: transfer.id)
                    return true
                }
                .contextMenu { Button("Upload Next") { app.uploadNext(transfer.id) } }
                .accessibilityAction(named: "Upload next") { app.uploadNext(transfer.id) }
        } else {
            content
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(hovering ? Fill.two : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct EmptyNote: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(Palette.verified)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .transition(.opacity)
    }
}

// MARK: - Connection

private struct ConnectionCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let c = app.active { header(c) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Upload speed").font(.system(size: 12, weight: .semibold))
                Picker("Upload speed", selection: Binding(get: { app.settings.bandwidth }, set: { app.setBandwidth($0) })) {
                    ForEach(AppSettings.Bandwidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ParallelStepper()
        }
        .contentCard(radius: 16, padding: 16)
        .task(id: app.activeID) { await measure() }
    }

    @ViewBuilder private func header(_ c: StorageConnection) -> some View {
        let rtt = app.activityUI.roundTrip[c.id]
        let reachable = app.connectionErrors[c.id] == nil
        HStack(spacing: 12) {
            if let rtt, reachable {
                SignalBars(level: SignalBars.level(roundTrip: rtt, bytesPerSecond: app.throughput.last?.sending), height: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(reachable ? "Connected to \(c.name)" : "Can’t reach \(c.name)")
                    .font(.system(size: 13, weight: .semibold))
                Text([protocolName(c), rtt.map { "\(max(1, Int(($0 * 1000).rounded()))) ms" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func protocolName(_ c: StorageConnection) -> String {
        if app.isDemo, c.id == app.demo?.connection.id { return "Demo" }
        switch c.provider {
        case .hetzner, .sftp: return "SFTP"
        case .webdav: return "WebDAV"
        case .s3: return "S3"
        case .smb: return "SMB"
        }
    }

    private var hint: String {
        switch app.settings.bandwidth {
        case .auto: "Adjusts to your connection and backs off when it gets slow."
        case .limited: "Uploads stay under 20 MB/s."
        case .unlimited: "Uses all the bandwidth it can get."
        }
    }

    /// Times a cheap stat now and every 30 seconds while Activity is open. Nothing is shown until it's measured.
    private func measure() async {
        guard let c = app.active, !app.isDemo else { return }
        while !Task.isCancelled {
            if let rtt = try? await app.roundTrip(to: c) { app.activityUI.roundTrip[c.id] = rtt }
            else { app.activityUI.roundTrip[c.id] = nil }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

/// "At the same time": how many uploads run at once, 1–6, drawn as six dots.
private struct ParallelStepper: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let n = app.maxParallel
        HStack(spacing: 10) {
            Text("At the same time").font(.system(size: 12.5, weight: .medium))
            Spacer()
            HStack(spacing: 8) {
                RowButton(symbol: "minus", label: "Fewer at once") { app.setParallelUploads(n - 1) }.disabled(n <= 1)
                HStack(spacing: 3) {
                    ForEach(1...6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(i <= n ? Color.accentColor : Fill.two)
                            .frame(width: 8, height: 14)
                    }
                }
                .motion(Motion.snappy, value: n)
                RowButton(symbol: "plus", label: "More at once") { app.setParallelUploads(n + 1) }.disabled(n >= 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uploads at the same time")
        .accessibilityValue("\(n)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: app.setParallelUploads(n + 1)
            case .decrement: app.setParallelUploads(n - 1)
            @unknown default: break
            }
        }
    }
}

// MARK: - Last 24 hours

private struct DayCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let history = app.history
        let bars = history.hourly()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 24 hours").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(totals(history)).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            HourBars(values: bars).frame(height: 56)
            HStack {
                ForEach(hourLabels, id: \.self) { label in
                    Text(label)
                    if label != "Now" { Spacer() }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Counter(value: history.verifiedCount, label: "verified")
                Counter(value: app.issues.count, label: "need you")
            }
        }
        .contentCard(radius: 16, padding: 16)
    }

    private func totals(_ h: TransferHistory) -> String {
        var parts = ["\(Format.bytes(h.sent)) sent"]
        if h.received > 0 { parts.append("\(Format.bytes(h.received)) received") }
        return parts.joined(separator: " · ")
    }

    /// Hours under bars 0, 6, 12 and 18, then "Now" under the current hour.
    private var hourLabels: [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        return [23, 17, 11, 5].map { String(format: "%02d", (hour - $0 + 24) % 24) } + ["Now"]
    }
}

private struct HourBars: View {
    let values: [Int64]

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                GeometryReader { g in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(i == values.count - 1 ? Color.accentColor : Fill.three)
                            .frame(height: max(2, g.size.height * CGFloat(Double(v) / Double(peak))))
                    }
                }
            }
        }
        .motion(Motion.smooth, value: values)
        .accessibilityElement()
        .accessibilityLabel("Sent per hour, last 24 hours")
        .accessibilityValue("\(Format.bytes(values.reduce(0, +))) in total, \(Format.bytes(values.last ?? 0)) this hour")
    }
}

private struct Counter: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 18, weight: .bold)).rollingNumber(value)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
