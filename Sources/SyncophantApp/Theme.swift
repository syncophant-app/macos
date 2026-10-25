import SwiftUI
import AppKit

/// Semantic colour roles. Every text pair is checked for 4.5:1 on its surface in light and dark.
enum Palette {
    /// Follows the person's system accent colour.
    static let accentNS = NSColor.controlAccentColor
    static let navyNS = dynamic(light: 0x0B2A5B, dark: 0xBFD7FF)
    static let verifiedNS = dynamic(light: 0x1A7F45, dark: 0x4CD07D)
    static let cautionNS = dynamic(light: 0xB45309, dark: 0xF0A24A)
    static let failureNS = dynamic(light: 0xB42318, dark: 0xFF7A70)

    static let accent = Color.accentColor
    static let navy = Color(nsColor: navyNS)
    static let verified = Color(nsColor: verifiedNS)
    static let caution = Color(nsColor: cautionNS)
    static let failure = Color(nsColor: failureNS)
    /// Text-safe purple (history: snapshots, versions, encryption) and teal (schedules, downloads).
    static let historyNS = dynamic(light: 0x7E3FD6, dark: 0xD38CF7)
    static let scheduleNS = dynamic(light: 0x0E7A88, dark: 0x5ED3E6)
    static let history = Color(nsColor: historyNS)
    static let schedule = Color(nsColor: scheduleNS)

    /// Environment hues. They colour the light behind the glass and never carry text or status.
    static let skyNS = dynamic(light: 0x7FB6FF, dark: 0x1F4FA8)
    static let lavenderNS = dynamic(light: 0xC3B4FF, dark: 0x4B3A99)
    static let emberNS = dynamic(light: 0xFFD2A8, dark: 0x6B3A1F)
    static let sky = Color(nsColor: skyNS)
    static let lavender = Color(nsColor: lavenderNS)
    static let ember = Color(nsColor: emberNS)

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

/// Spacing scale in points; windows and sheets use these instead of ad hoc numbers.
enum Space {
    static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 20, xl: CGFloat = 32
}

/// Corner radii. Concentric: a shape inside another uses the outer radius minus the gap between them.
enum Radius {
    static let canvas: CGFloat = 22, card: CGFloat = 18, tile: CGFloat = 8, row: CGFloat = 9
}

enum Format {
    /// "0 bytes", never "Zero KB".
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: value)
    }

    static let modified: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return modified.string(from: date)
    }
}

extension View {
    /// Section title used in settings and sheets; sits below its group, never in a card.
    func groupHeading() -> some View { font(.headline).foregroundStyle(.primary) }
}

// MARK: - Environment

/// Soft sky, lavender and ember light behind the window. The glass above it has something to refract;
/// the file canvas sits on top and stays opaque, so text never reads over colour. Flat under Reduce Transparency.
struct AmbientBackdrop: View {
    /// False over a system material (menu bar window), which already supplies the base.
    var base = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            if base || reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            if !reduceTransparency {
                GeometryReader { g in
                    let s = max(g.size.width, g.size.height)
                    ZStack {
                        RadialGradient(colors: [Palette.sky.opacity(dark ? 0.55 : 0.60), .clear],
                                       center: .topLeading, startRadius: 0, endRadius: s * 0.62)
                        RadialGradient(colors: [Palette.lavender.opacity(dark ? 0.42 : 0.46), .clear],
                                       center: UnitPoint(x: 0.88, y: 0.04), startRadius: 0, endRadius: s * 0.5)
                        RadialGradient(colors: [Palette.ember.opacity(dark ? 0.30 : 0.42), .clear],
                                       center: UnitPoint(x: 0.12, y: 1.02), startRadius: 0, endRadius: s * 0.55)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Glass

/// Liquid Glass surface with a solid fallback. Glass is reserved for floating controls and summaries;
/// anything the user reads for long, such as the file list, stays on an opaque canvas.
struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        } else {
            content.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        }
    }

    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
}

extension View {
    func glassSurface(radius: CGFloat = Radius.card, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, interactive: interactive))
    }

    /// The opaque reading surface that floats over the ambient backdrop.
    func readingCanvas(radius: CGFloat = Radius.canvas) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 5)
    }
}

// MARK: - Small parts

/// A tinted tile holding one SF Symbol; the app's repeated mark for a storage or a destination.
struct SymbolTile: View {
    let symbol: String
    var tint: Color = Palette.accent
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Small state dot. Always travels with a text label; the dot only repeats it.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Count badge: filled capsule, white or black text chosen for contrast on the fill.
struct CountBadge: View {
    let count: Int
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(Capsule().fill(color))
    }
}
