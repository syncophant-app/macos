import SwiftUI
import Charts
import CryptoKit

// StatusKit: the reusable status views every screen draws with. Each state has a glyph and a colour first
// and words second; nothing here invents data, every view draws only what its caller passes in.

// MARK: - Motion tokens

/// Four springs cover every animation. Reduce Motion turns each into a 0.2 s cross-fade.
enum Motion {
    static let snappy = Animation.snappy(duration: 0.3)
    static let smooth = Animation.smooth(duration: 0.4)
    static let bouncy = Animation.bouncy(duration: 0.6, extraBounce: 0.1)
    static let morph = Animation.spring(response: 0.5, dampingFraction: 0.8)
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? reduced : animation }

    /// For `withAnimation` outside a view, where the environment is not available.
    @MainActor static func resolve(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? reduced : animation
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(Motion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

private struct RowEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                let delay = reduceMotion ? 0 : Double(min(index, 10)) * 0.028
                withAnimation(Motion.resolve(Motion.smooth, reduceMotion: reduceMotion).delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// Rows fade up 8 pt, staggered about 28 ms each, capped at 10 rows.
    func rowEntrance(_ index: Int) -> some View { modifier(RowEntrance(index: index)) }

    /// A number that rolls instead of jumping.
    func rollingNumber<V: Equatable>(_ value: V) -> some View {
        monospacedDigit().contentTransition(.numericText()).motion(Motion.smooth, value: value)
    }
}

// MARK: - Colour tokens

/// Status tones. `color` is for glyphs and fills; `text` is the variant that keeps 4.5:1 for words.
enum Tone: Hashable, Sendable {
    case accent, green, orange, red, purple, teal, neutral

    var color: Color {
        switch self {
        case .accent: .accentColor
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .teal: .teal
        case .neutral: .secondary
        }
    }

    var text: Color {
        switch self {
        case .accent: .accentColor
        case .green: Palette.verified
        case .orange: Palette.caution
        case .red: Palette.failure
        case .purple: Palette.history
        case .teal: Palette.schedule
        case .neutral: .secondary
        }
    }

    /// Background of a status card: the status colour at about 15%.
    var soft: Color { self == .neutral ? Fill.one : color.opacity(0.15) }
}

/// Flat fills used to group things inside glass, and for tracks and chips.
enum Fill {
    static let one = Color.primary.opacity(0.07)
    static let two = Color.primary.opacity(0.12)
    static let three = Color.primary.opacity(0.18)
    static let track = Color.primary.opacity(0.10)
}

// MARK: - Small type and surface helpers

/// 11 pt semibold uppercase tertiary group heading.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Solid content card (never glass): control background, 16–20 pt radius, hairline edge.
    func contentCard(radius: CGFloat = 18, padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    /// A card tinted by its status colour, for problems and results.
    func statusCard(_ tone: Tone, radius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.soft, in: shape)
            .overlay(shape.strokeBorder(tone.color.opacity(0.25), lineWidth: 0.5))
    }
}

/// Rounded tile holding one symbol in a status colour, the icon slot of cards and rows.
struct IconTile: View {
    let symbol: String
    var tone: Tone = .accent
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tone.text)
            .frame(width: size, height: size)
            .background(tone.soft, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - FileStateBadge

/// Where a file lives and what is happening to it. Drives the Files list, the inspector and Finder decorations.
enum FileState: Equatable, Sendable {
    case onBox
    case downloading(Double?)
    case onMac
    case kept
    case waiting
    case uploading(Double?)
    case verifying
    case verified
    case unverified
    case twoVersions
    case failed
    case skipped

    var tone: Tone {
        switch self {
        case .onBox, .onMac, .waiting, .skipped: .neutral
        case .downloading: .teal
        case .kept, .uploading, .verifying: .accent
        case .verified: .green
        case .unverified, .twoVersions: .orange
        case .failed: .red
        }
    }

    /// Short words for the "Where it lives" column. `storage` is the friendly storage name.
    func words(storage: String) -> String {
        switch self {
        case .onBox: "On \(storage)"
        case .downloading(let p): p.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        case .onMac: "On this Mac"
        case .kept: "Kept on this Mac"
        case .waiting: "Waiting to upload"
        case .uploading(let p): p.map { "Uploading \(Int($0 * 100))%" } ?? "Uploading"
        case .verifying: "Verifying"
        case .verified: "Uploaded and verified"
        case .unverified: "Uploaded, not verified"
        case .twoVersions: "Two versions"
        case .failed: "Upload stopped"
        case .skipped: "Skipped"
        }
    }

    var symbol: String {
        switch self {
        case .onBox: "icloud"
        case .downloading: "arrow.down"
        case .onMac: "circle.inset.filled"
        case .kept: "pin.fill"
        case .waiting: "clock"
        case .uploading: "arrow.up"
        case .verifying: "checkmark.shield"
        case .verified: "checkmark.shield.fill"
        case .unverified: "exclamationmark.shield"
        case .twoVersions: "doc.on.doc"
        case .failed: "exclamationmark.circle.fill"
        case .skipped: "nosign"
        }
    }

    init?(_ status: FileStatus) {
        switch status {
        case .none: return nil
        case .onBox: self = .onBox
        case .queued: self = .waiting
        case .uploading(let p): self = .uploading(p)
        case .verifying: self = .verifying
        case .verified: self = .verified
        case .unverified: self = .unverified
        case .conflict: self = .twoVersions
        case .kept: self = .kept
        case .failed: self = .failed
        }
    }
}

/// 16, 19, 24 or 34 pt. Ring states draw progress; the rest are SF Symbols, hierarchical.
struct FileStateBadge: View {
    let state: FileState
    var size: CGFloat = 19

    var body: some View {
        Group {
            switch state {
            case .uploading(let p), .downloading(let p):
                ZStack {
                    RingTrack(progress: p ?? 0, lineWidth: max(1.6, size * 0.11), tint: state.tone.color)
                    Image(systemName: state.symbol)
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(state.tone.text)
                }
            case .waiting:
                ZStack {
                    Circle().strokeBorder(Fill.three, style: StrokeStyle(lineWidth: max(1.4, size * 0.09), dash: [2, 2.5]))
                    Image(systemName: "arrow.up").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.secondary)
                }
            case .verifying:
                ProgressView().controlSize(size < 22 ? .mini : .small).frame(width: size, height: size)
            default:
                Image(systemName: state.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.78, weight: .medium))
                    .foregroundStyle(state.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(state.tone.text))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Ring progress primitive shared by badges and rings. Starts at 12 o'clock and runs clockwise.
private struct RingTrack: View {
    let progress: Double
    let lineWidth: CGFloat
    let tint: Color
    var body: some View {
        ZStack {
            Circle().stroke(Fill.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .motion(Motion.smooth, value: progress)
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - HealthOrb

enum Health: Equatable, Sendable {
    case healthy, syncing, needsYou, offline, failing

    var tone: Tone {
        switch self {
        case .healthy: .green
        case .syncing: .accent
        case .needsYou: .orange
        case .offline: .neutral
        case .failing: .red
        }
    }

    var words: String {
        switch self {
        case .healthy: "Healthy"
        case .syncing: "Syncing"
        case .needsYou: "Needs you"
        case .offline: "Offline"
        case .failing: "Failing"
        }
    }
}

/// Overall health of one storage. Healthy is solid, syncing pings, needs-you is dashed, offline is dotted and turns slowly.
struct HealthOrb: View {
    let health: Health
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let line = max(1.5, size * 0.13)
        ZStack {
            switch health {
            case .healthy, .failing:
                Circle().fill(health.tone.soft)
                Circle().strokeBorder(health.tone.color, lineWidth: line)
            case .syncing:
                if !reduceMotion {
                    PhaseAnimator([false, true]) { on in
                        Circle().fill(Color.accentColor)
                            .frame(width: size * 0.45, height: size * 0.45)
                            .scaleEffect(on ? 2.4 : 1)
                            .opacity(on ? 0 : 0.7)
                    } animation: { on in on ? .easeOut(duration: 1.8) : .linear(duration: 0) }
                }
                Circle().fill(health.tone.soft)
                Circle().strokeBorder(health.tone.color, lineWidth: line)
            case .needsYou:
                Circle().fill(health.tone.soft)
                Circle().strokeBorder(Color.orange, style: StrokeStyle(lineWidth: line, dash: [size * 0.2, size * 0.12]))
            case .offline:
                OfflineRing(lineWidth: line, spins: !reduceMotion)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Health")
        .accessibilityValue(health.words)
    }
}

private struct OfflineRing: View {
    let lineWidth: CGFloat
    let spins: Bool
    @State private var angle = 0.0
    var body: some View {
        Circle()
            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [0.5, lineWidth * 2.2]))
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard spins else { return }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

// MARK: - SignalBars

/// Connection quality from measured numbers only. `level` nil means offline.
struct SignalBars: View {
    let level: Int?
    var height: CGFloat = 14

    /// Cut-offs from the spec: 4 = under 60 ms and 5 MB/s or more; 3 = under 150 ms or 1 MB/s; 2 = under 400 ms; else 1.
    static func level(roundTrip: TimeInterval?, bytesPerSecond: Double?) -> Int? {
        guard let rtt = roundTrip else { return nil }
        let speed = bytesPerSecond ?? 0
        if rtt < 0.060 && speed >= 5_000_000 { return 4 }
        if rtt < 0.150 || speed >= 1_000_000 { return 3 }
        if rtt < 0.400 { return 2 }
        return 1
    }

    var body: some View {
        let tone: Tone = switch level { case nil: .neutral; case 4?, 3?: .green; case 2?: .orange; default: .red }
        HStack(alignment: .bottom, spacing: height * 0.14) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < (level ?? 0) ? tone.color : Fill.three)
                    .frame(width: height * 0.24, height: height * CGFloat(i + 1) / 4)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Connection quality")
        .accessibilityValue(level.map { "\($0) of 4 bars" } ?? "Offline")
    }
}

// MARK: - ProgressRing

struct ProgressRing: View {
    enum State: Equatable { case running, paused, done }
    let progress: Double
    var state: State = .running
    var size: CGFloat = 38
    var lineWidth: CGFloat? = nil
    var showsLabel = false
    /// Overrides the state colour, for rings that show time left rather than a job.
    var tint: Color? = nil

    var body: some View {
        let width = lineWidth ?? max(2, size * 0.1)
        let stateTint: Color = switch state { case .running: .accentColor; case .paused: .orange; case .done: .green }
        let tint = self.tint ?? stateTint
        ZStack {
            RingTrack(progress: state == .done ? 1 : progress, lineWidth: width, tint: tint)
            if state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(Palette.verified)
                    .transition(.scale.combined(with: .opacity))
            } else if showsLabel {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .rollingNumber(Int((progress * 100).rounded()))
            }
        }
        .frame(width: size, height: size)
        .motion(Motion.bouncy, value: state)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(state == .done ? "Done" : "\(Int((progress * 100).rounded())) percent\(state == .paused ? ", paused" : "")")
    }
}

// MARK: - CapacityBar

/// Files, snapshots and free space as one capsule. Callers hide it when the provider reports no quota.
struct CapacityBar: View {
    let used: Int64
    var snapshots: Int64? = nil
    let total: Int64
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let t = Double(max(total, 1))
            let files = Double(max(0, used - (snapshots ?? 0))) / t
            let snaps = Double(snapshots ?? 0) / t
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: g.size.width * min(1, files))
                Rectangle().fill(Color.purple).frame(width: g.size.width * min(1, snaps))
                Spacer(minLength: 0)
            }
            .background(Fill.track)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Space used")
        .accessibilityValue("\(Format.bytes(used)) of \(Format.bytes(total))")
    }
}

// MARK: - Throughput

struct ThroughputSample: Identifiable, Equatable, Sendable {
    let date: Date
    let sending: Double
    var receiving: Double? = nil
    var id: Date { date }
}

/// Live speed, one sample a second over two minutes. A dashed orange line marks a speed limit.
struct ThroughputChart: View {
    let samples: [ThroughputSample]
    var limit: Double? = nil
    /// Seconds the x axis always spans, ending at the newest sample, so a short run doesn't stretch. Nil fits the data.
    var span: TimeInterval? = nil

    private var xDomain: ClosedRange<Date> {
        let end = samples.last?.date ?? Date()
        let start = span.map { end.addingTimeInterval(-$0) } ?? samples.first?.date ?? end
        return start...max(end, start.addingTimeInterval(1))
    }

    var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.date), y: .value("Sending", s.sending), series: .value("Kind", "Sending"))
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.date), y: .value("Sending", s.sending), series: .value("Kind", "Sending"))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                if let r = s.receiving {
                    LineMark(x: .value("Time", s.date), y: .value("Receiving", r), series: .value("Kind", "Receiving"))
                        .foregroundStyle(Color.teal)
                        .interpolationMethod(.monotone)
                }
            }
            if let limit {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Fill.one)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Format.bytes(Int64(v)))/s").font(.caption2) } }
            }
        }
        .accessibilityLabel("Live transfer speed")
        .accessibilityValue(samples.last.map { "\(Format.bytes(Int64($0.sending))) per second" } ?? "No data")
    }
}

/// Compact speed line, no axes.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            let peak = max(values.max() ?? 0, 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? g.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                        y: g.size.height - g.size.height * CGFloat(v / peak) * 0.92 - 1)
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: g.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(tint.opacity(0.18))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - RunHistoryDots

enum RunResult: String, Codable, Sendable {
    case succeeded, partial, failed, missed

    var tone: Tone {
        switch self { case .succeeded: .green; case .partial: .orange; case .failed: .red; case .missed: .neutral }
    }
    var words: String {
        switch self { case .succeeded: "Succeeded"; case .partial: "Partly done"; case .failed: "Failed"; case .missed: "Did not run" }
    }
}

/// Last 14 runs, newest on the right. Empty slots are drawn as faint squares so the row never changes width.
struct RunHistoryDots: View {
    struct Dot: Identifiable, Equatable { let id: Date; let result: RunResult }
    let runs: [Dot]
    var count = 14
    var size: CGFloat = 14

    var body: some View {
        let recent = Array(runs.suffix(count))
        HStack(spacing: size * 0.28) {
            ForEach(0..<(count - recent.count), id: \.self) { _ in
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Fill.one).frame(width: size, height: size)
            }
            ForEach(recent) { dot in
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(dot.result == .missed ? Fill.three : dot.result.tone.color)
                    .frame(width: size, height: size)
                    .help("\(dot.result.words) · \(Format.modified.string(from: dot.id))")
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .motion(Motion.bouncy, value: runs.last?.id)
        .accessibilityElement()
        .accessibilityLabel("Recent runs")
        .accessibilityValue(recent.isEmpty ? "No runs yet"
            : "\(recent.filter { $0.result == .succeeded }.count) of \(recent.count) recent runs succeeded")
    }
}

// MARK: - CountdownRing

/// Teal ring that empties toward the next scheduled run.
struct CountdownRing: View {
    enum State: Equatable { case counting(next: Date, interval: TimeInterval), running, paused }
    let state: State
    var size: CGFloat = 38
    /// Off for small rings whose caller prints the time beside them.
    var showsLabel = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let (fraction, label) = values(now: context.date)
            ZStack {
                RingTrack(progress: fraction, lineWidth: max(2.5, size * 0.1), tint: .teal)
                if showsLabel {
                    Text(label)
                        .font(.system(size: size * 0.26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(state == .paused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Next run")
            .accessibilityValue(label == "now" ? "Running now" : label == "off" ? "Paused" : "in \(label)")
        }
    }

    func values(now: Date) -> (Double, String) {
        switch state {
        case .running: return (1, "now")
        case .paused: return (0, "off")
        case .counting(let next, let interval):
            let left = max(0, next.timeIntervalSince(now))
            return (interval > 0 ? min(1, left / interval) : 0, Self.short(left))
        }
    }

    static func short(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

// MARK: - SnapshotTimeline

struct TimelineMark: Identifiable, Equatable {
    enum Kind: Equatable { case automatic, user, deletion }
    let id: String
    let date: Date
    let kind: Kind
}

/// Two weeks to scale. Automatic snapshots are purple dots, the user's are orange diamonds, deletions are red dashes.
/// A glass lens marks the selection and springs between marks.
struct SnapshotTimeline: View {
    let marks: [TimelineMark]
    let range: ClosedRange<Date>
    var selected: String?
    var onSelect: (String) -> Void = { _ in }
    var height: CGFloat = 44
    /// Day-of-month numbers under the ticks and an accent "Now" at the trailing end.
    var showsDayLabels = false
    @Namespace private var lens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let span = max(range.upperBound.timeIntervalSince(range.lowerBound), 1)
            let x: (Date) -> CGFloat = { d in
                let f = d.timeIntervalSince(range.lowerBound) / span
                return 8 + (g.size.width - 16) * CGFloat(max(0, min(1, f)))
            }
            let mid = showsDayLabels ? g.size.height / 2 - 8 : g.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Fill.track).frame(height: 2).offset(y: mid - 1)
                ForEach(dayTicks, id: \.self) { day in
                    Rectangle().fill(Fill.two).frame(width: 1, height: 8).offset(x: x(day), y: mid - 4)
                    if showsDayLabels, x(day) < g.size.width - 28 {
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
                            .fixedSize().position(x: x(day), y: mid + 18)
                    }
                }
                if showsDayLabels {
                    Circle().fill(Color.accentColor).frame(width: 12, height: 12).position(x: x(range.upperBound), y: mid)
                    Text("Now").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.accent)
                        .fixedSize().position(x: x(range.upperBound), y: mid + 18)
                }
                ForEach(marks) { m in
                    Button { onSelect(m.id) } label: { glyph(m).frame(width: 18, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .position(x: x(m.date), y: mid)
                        .accessibilityLabel(label(for: m))
                        .accessibilityAddTraits(m.id == selected ? .isSelected : [])
                }
                if let sel = marks.first(where: { $0.id == selected }) {
                    Capsule()
                        .fill(.clear)
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .position(x: x(sel.date), y: mid)
                        .allowsHitTesting(false)
                        .animation(reduceMotion ? Motion.reduced : .spring(response: 0.5, dampingFraction: 0.75), value: sel.id)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Snapshot timeline")
    }

    private var dayTicks: [Date] {
        var days: [Date] = []
        var d = Calendar.current.startOfDay(for: range.lowerBound)
        while d <= range.upperBound {
            if d >= range.lowerBound { days.append(d) }
            d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? range.upperBound.addingTimeInterval(1)
        }
        return days
    }

    @ViewBuilder private func glyph(_ m: TimelineMark) -> some View {
        switch m.kind {
        case .automatic: Circle().fill(Color.purple).frame(width: 8, height: 8)
        case .user: Rectangle().fill(Color.orange).frame(width: 8, height: 8).rotationEffect(.degrees(45))
        case .deletion: Capsule().fill(Color.red).frame(width: 3, height: 12)
        }
    }

    private func label(for m: TimelineMark) -> String {
        let kind = switch m.kind { case .automatic: "Automatic snapshot"; case .user: "Your snapshot"; case .deletion: "File deleted" }
        return "\(kind), \(Format.modified.string(from: m.date))"
    }
}

// MARK: - HostKeyIdenticon

/// A server's SSH fingerprint as a picture: 8 × 8, left half mirrored, 4 colours from the SHA-256 bytes.
/// The same key always draws the same picture everywhere.
struct HostKeyIdenticon: View {
    let fingerprint: String
    var size: CGFloat = 88
    var showsText = false

    /// 32 cells (8 rows × 4 columns) of colour indices 0...3; the right half mirrors the left.
    static func cells(for fingerprint: String) -> [Int] {
        let body = fingerprint.hasPrefix("SHA256:") ? String(fingerprint.dropFirst(7)) : fingerprint
        var padded = body
        while padded.count % 4 != 0 { padded += "=" }
        let bytes = Data(base64Encoded: padded).flatMap { $0.count >= 16 ? Array($0) : nil }
            ?? Array(SHA256.hash(data: Data(fingerprint.utf8)))
        return (0..<32).map { Int(bytes[$0 % bytes.count] >> UInt8(($0 / bytes.count) * 2 % 8)) % 4 }
    }

    private static let colors: [Color] = [.accentColor, .teal, .purple, Fill.three]

    var body: some View {
        let cells = Self.cells(for: fingerprint)
        let gap: CGFloat = 2, pad: CGFloat = 4
        let cell = (size - pad * 2 - gap * 7) / 8
        VStack(spacing: 6) {
            VStack(spacing: gap) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<8, id: \.self) { col in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Self.colors[cells[row * 4 + (col < 4 ? col : 7 - col)]])
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .padding(pad)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
            if showsText {
                Text(fingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: max(size, 180))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Host key picture")
        .accessibilityValue(fingerprint)
    }
}

// MARK: - CacheDonut

/// Space used on this Mac: kept (never evicted, drawn first), recently opened, and room left under the limit.
struct CacheDonut: View {
    let kept: Int64
    let recent: Int64
    let limit: Int64
    var size: CGFloat = 120
    var lineWidth: CGFloat? = nil

    var body: some View {
        let total = Double(max(limit, kept + recent, 1))
        let k = Double(kept) / total, r = Double(recent) / total
        let w = lineWidth ?? size * 0.14
        ZStack {
            Circle().stroke(Fill.track, lineWidth: w)
            Circle().trim(from: 0, to: k).stroke(Color.accentColor, style: StrokeStyle(lineWidth: w, lineCap: .butt)).rotationEffect(.degrees(-90))
            Circle().trim(from: k, to: min(1, k + r)).stroke(Color.teal, style: StrokeStyle(lineWidth: w, lineCap: .butt)).rotationEffect(.degrees(-90))
        }
        .padding(w / 2)
        .frame(width: size, height: size)
        .motion(Motion.smooth, value: kept &+ recent &+ limit)
        .accessibilityElement()
        .accessibilityLabel("Space on this Mac")
        .accessibilityValue("\(Format.bytes(kept)) kept, \(Format.bytes(recent)) recently opened, limit \(Format.bytes(limit))")
    }
}

// MARK: - StrengthMeter

struct PassphraseStrength: Equatable {
    let bits: Double
    let segments: Int
    let label: String
    let crackTime: String

    /// Two or more words count about 12.9 bits each (a 7,776-word list); otherwise length × log2(character pool).
    /// Cut-offs at 28, 38, 48 and 58 bits map to the five segments.
    static func evaluate(_ phrase: String) -> PassphraseStrength {
        guard !phrase.isEmpty else { return PassphraseStrength(bits: 0, segments: 0, label: "Empty", crackTime: "") }
        let words = phrase.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" }).filter { $0.count >= 2 }
        let bits: Double
        if words.count >= 2 {
            bits = Double(words.count) * 12.9
        } else {
            var pool = 0
            if phrase.contains(where: \.isLowercase) { pool += 26 }
            if phrase.contains(where: \.isUppercase) { pool += 26 }
            if phrase.contains(where: \.isNumber) { pool += 10 }
            if phrase.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
            bits = Double(phrase.count) * log2(Double(max(pool, 2)))
        }
        let segments = bits < 28 ? 1 : bits < 38 ? 2 : bits < 48 ? 3 : bits < 58 ? 4 : 5
        let labels = ["Very weak", "Weak", "Okay", "Strong", "Very strong"]
        return PassphraseStrength(bits: bits, segments: segments, label: labels[segments - 1], crackTime: crackPhrase(bits))
    }

    /// Offline guessing at ten billion guesses a second; a rough phrase, not a promise.
    private static func crackPhrase(_ bits: Double) -> String {
        let seconds = pow(2, bits) / 1e10
        switch seconds {
        case ..<1: return "cracked instantly"
        case ..<3600: return "cracked in minutes"
        case ..<86_400: return "cracked in hours"
        case ..<(86_400 * 365): return "cracked in days to months"
        case ..<(86_400 * 365 * 1000): return "takes years to crack"
        default: return "takes centuries to crack"
        }
    }
}

struct StrengthMeter: View {
    let strength: PassphraseStrength

    var body: some View {
        let tones: [Color] = [.red, .orange, .yellow, .green, .green]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(i < strength.segments ? tones[max(0, strength.segments - 1)] : Fill.two)
                        .frame(height: 5)
                }
            }
            .motion(Motion.snappy, value: strength.segments)
            if strength.segments > 0 {
                HStack(spacing: 6) {
                    Text(strength.label).font(.caption.weight(.semibold))
                    Text("· \(strength.crackTime)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Passphrase strength")
        .accessibilityValue(strength.segments == 0 ? "Empty" : "\(strength.label), \(strength.crackTime)")
    }
}

// MARK: - StorageAvatar

/// Colours a person can pick for a storage. Stored by name so the palette can change without migrations.
enum AvatarColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case blue, purple, green, orange, pink, teal, graphite
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .teal: .teal
        case .graphite: .gray
        }
    }
    var name: String { rawValue.capitalized }
}

/// Which storage: its initial on a rounded square in the colour the person picked.
struct StorageAvatar: View {
    let name: String
    var color: AvatarColor = .blue
    var size: CGFloat = 32

    var body: some View {
        Text(name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.color.gradient, in: RoundedRectangle(cornerRadius: max(9, min(13, size * 0.3)), style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - StepDots

/// Setup progress: the current step is a 28 pt capsule, the others 6 pt dots.
struct StepDots: View {
    let count: Int
    let current: Int
    var tint: Color = .accentColor
    @Namespace private var dots

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? tint : (i < current ? tint.opacity(0.45) : Fill.three))
                    .frame(width: i == current ? 28 : 6, height: 6)
            }
        }
        .motion(Motion.morph, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Fix button state

/// The life of a fix on a problem card: idle → working (spinner) → fixed (green, then collapses after 1.3 s).
enum FixPhase: Equatable { case idle, working, fixed, failed(String) }
