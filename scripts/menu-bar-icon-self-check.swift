import AppKit

@main
struct MenuBarIconSelfCheck {
    static func main() {
        guard let logo = NSImage(contentsOf: URL(fileURLWithPath: "Assets/MenuBarIcon.svg")) else {
            fatalError("Assets/MenuBarIcon.svg did not load as an image")
        }
        let images = Dictionary(uniqueKeysWithValues: MenuBarIcon.Badge.allCases.map { ($0, MenuBarIcon.make(logo: logo, badge: $0)) })
        let size = images[.none]!.size
        precondition(images.values.allSatisfy { $0.isTemplate && $0.size == size }, "every state must be a same-size template image")
        precondition(size.height <= 22, "too tall for the menu bar")

        let radius = MenuBarIcon.badgeDiameter / 2
        let below = (size.height - MenuBarIcon.logoHeight) / 2
        let head = NSPoint(x: (size.width - radius) / 2, y: below + MenuBarIcon.logoHeight * 0.8)
        let badgeRing = NSPoint(x: size.width - radius - radius * 0.7, y: below + MenuBarIcon.badgeOffset.y)
        for (badge, image) in images {
            precondition(alpha(image, at: head) > 0.9, "\(badge): logo missing")
            let ring = alpha(image, at: badgeRing)
            precondition(badge == .none ? ring < 0.1 : ring > 0.9, "\(badge): badge drawn wrongly (alpha \(ring))")
        }
        // Status item: 22 pt template; the progress ring appears only while transferring and fills clockwise from 12 o'clock.
        let idle = MenuBarIcon.statusImage(progress: nil), half = MenuBarIcon.statusImage(progress: 0.5)
        precondition(idle.isTemplate && half.isTemplate && idle.size == NSSize(width: 22, height: 22), "status image must be a 22 pt template")
        precondition(alpha(idle, at: NSPoint(x: 11, y: 21)) < 0.1, "idle: no ring")
        precondition(alpha(half, at: NSPoint(x: 21, y: 11)) > 0.9, "50%: ring reaches 3 o'clock")
        precondition(alpha(half, at: NSPoint(x: 1, y: 11)) < 0.5, "50%: 9 o'clock is only track")
        print("Menu bar icon self-check passed: SVG loads, same-size template images, badge only when needed.")
    }

    /// Alpha of the image rendered at 2x, sampled at a point (origin bottom-left, in points).
    static func alpha(_ image: NSImage, at point: NSPoint) -> CGFloat {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: Int(point.x * 2), y: rep.pixelsHigh - 1 - Int(point.y * 2))?.alphaComponent ?? 0
    }
}
