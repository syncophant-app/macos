import AppKit

/// The menu bar logo (Assets/MenuBarIcon.svg) as a template image, with an optional status badge.
enum MenuBarIcon {
    enum Badge: CaseIterable {
        case none, transfers, issues

        var symbol: String? {
            switch self {
            case .none: nil
            case .transfers: "arrow.up.circle.fill"
            case .issues: "exclamationmark.circle.fill"
            }
        }
    }

    static let logoHeight: CGFloat = 16
    static let badgeDiameter: CGFloat = 7
    /// Badge centre relative to the logo's bottom-right corner. It sits in the empty pocket
    /// right of the trunk curl and hangs slightly past the logo, so the canvas reserves
    /// that overhang in every state and the menu bar item never changes width.
    static let badgeOffset = NSPoint(x: -0.7, y: 1.4)
    static let haloWidth: CGFloat = 1

    /// Nil when the SVG is not bundled (a bare `swift run` binary); callers fall back to SF Symbols.
    @MainActor static let images: [Badge: NSImage]? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let logo = NSImage(contentsOf: url) else { return nil }
        return Dictionary(uniqueKeysWithValues: Badge.allCases.map { ($0, make(logo: logo, badge: $0)) })
    }()

    /// The status item image: the logo alone, or the logo shrunk inside a 22 pt progress ring while transferring.
    /// Template, so it follows the menu bar's appearance; the alert dot is drawn by the caller in colour.
    @MainActor static func statusImage(progress: Double?) -> NSImage {
        let logo = svgLogo
            ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage()
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let aspect = logo.size.width / max(logo.size.height, 1)
            let h: CGFloat = progress == nil ? min(logoHeight, side / aspect) : 9.5
            logo.draw(in: NSRect(x: (side - h * aspect) / 2, y: (side - h) / 2, width: h * aspect, height: h))
            guard let progress else { return true }
            let center = NSPoint(x: rect.midX, y: rect.midY), radius = side / 2 - 1
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke(); track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.001, min(1, progress)), clockwise: true)
            arc.lineWidth = 2; arc.lineCapStyle = .round
            NSColor.black.setStroke(); arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    @MainActor private static let svgLogo: NSImage? = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    static func make(logo: NSImage, badge: Badge) -> NSImage {
        let radius = badgeDiameter / 2
        let logoSize = NSSize(width: logoHeight * logo.size.width / logo.size.height, height: logoHeight)
        let below = max(0, radius - badgeOffset.y)                  // badge overhang under the logo
        let size = NSSize(width: logoSize.width + max(0, badgeOffset.x + radius),
                          height: logoHeight + 2 * below)           // pad top too, keeping the logo centred
        let center = NSPoint(x: logoSize.width + badgeOffset.x, y: below + badgeOffset.y)
        let symbol = badge.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: badgeDiameter, weight: .bold))
        let image = NSImage(size: size, flipped: false) { _ in
            logo.draw(in: NSRect(origin: NSPoint(x: 0, y: below), size: logoSize))
            guard let symbol else { return true }
            // Clear a ring around the badge so it stays separate from the logo.
            let halo = radius + haloWidth
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: center.x - halo, y: center.y - halo, width: 2 * halo, height: 2 * halo)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let scale = badgeDiameter / max(symbol.size.width, symbol.size.height)
            let w = symbol.size.width * scale, h = symbol.size.height * scale
            symbol.draw(in: NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
            return true
        }
        image.isTemplate = true
        return image
    }
}
