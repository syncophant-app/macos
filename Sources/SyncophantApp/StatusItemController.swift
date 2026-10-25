import SwiftUI
import AppKit

/// The menu bar front door: an `NSStatusItem` that accepts file drags (MenuBarExtra cannot) and a borderless,
/// non-activating panel that hosts the SwiftUI panel under it. The panel follows `app.panelUI.isOpen`.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let app: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: MenuBarPanel
    private let dot = NSView()
    private var monitors: [Any] = []
    private var lastImageKey = ""

    init(app: AppModel) {
        self.app = app
        let host = NSHostingController(rootView: MenuBarView().environment(app))
        host.sizingOptions = [.preferredContentSize]
        panel = MenuBarPanel(contentViewController: host)
        super.init()
        app.loadUploadDestinations()
        panel.onEscape = { [weak app] in app?.panelUI.close() }

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageOnly
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            dot.isHidden = true
            button.addSubview(dot)
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Upload to…") { [weak app] in app?.chooseFilesForPanel(); return true }
            ])
        }
        // The status bar window forwards drag messages to its delegate. It exists once the item is in the bar.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.item.button?.window else { return }
            window.registerForDraggedTypes([.fileURL])
            window.delegate = self
        }
        observeStatus()
        observePanel()
    }

    // MARK: Status item

    private func observeStatus() {
        withObservationTracking { renderStatus() } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    private func renderStatus() {
        guard let button = item.button else { return }
        let progress = app.activeTransfers.isEmpty ? nil : (app.transferProgress ?? 0)
        let style = app.settings.menuBarIconStyle ?? .progressRing
        let issues = app.issues
        let failed = issues.contains { $0.severity == .failure }
        // Simple: the icon changes only when something needs you, so no ring.
        let ring = style == .simple ? nil : progress
        let key = ring.map { "\(Int($0 * 100))" } ?? "idle"
        if key != lastImageKey {
            lastImageKey = key
            button.image = MenuBarIcon.statusImage(progress: ring)
        }
        // With speed: the last measured speed beside the icon while anything moves.
        let speed = style == .withSpeed && progress != nil ? app.throughput.last.map(\.sending) ?? 0 : 0
        let title = speed > 0 ? " \(Format.bytes(Int64(speed)))/s" : ""
        if button.title != title {
            button.title = title
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        dot.isHidden = issues.isEmpty
        dot.layer?.backgroundColor = (failed ? NSColor.systemRed : NSColor.systemOrange).cgColor
        let b = button.bounds
        dot.frame = NSRect(x: b.maxX - 9, y: button.isFlipped ? 2 : b.maxY - 9, width: 7, height: 7)

        let label: String
        if app.panelUI.mode == .pick && app.panelUI.dragLive { label = "Syncophant, drop target" }
        else if let progress { label = "Syncophant, uploading \(Int((progress * 100).rounded())) percent" }
        else if !issues.isEmpty { label = "Syncophant, \(issues.count) problem\(issues.count == 1 ? "" : "s")" }
        else if let c = app.active, app.health(for: c) == .offline { label = "Syncophant, can’t reach \(c.name)" }
        else { label = "Syncophant, up to date" }
        button.setAccessibilityLabel(label)
        button.toolTip = label.replacingOccurrences(of: "Syncophant, ", with: "").capitalizedFirst
    }

    @objc private func toggle() {
        app.panelUI.isOpen ? app.panelUI.close() : app.panelUI.open()
    }

    // MARK: Panel

    private func observePanel() {
        let open = withObservationTracking { app.panelUI.isOpen } onChange: { [weak self] in
            Task { @MainActor in self?.observePanel() }
        }
        if open, !panel.isVisible { show() } else if !open, panel.isVisible { hide() }
    }

    private func show() {
        guard let button = item.button, let window = button.window else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let width = MenuBarView.width
        let left = min(max(icon.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        panel.topLeft = NSPoint(x: left, y: icon.minY - 6)
        app.panelUI.growAnchor = UnitPoint(x: max(0, min(1, (icon.midX - left) / width)), y: 0)
        panel.setFrame(panel.frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installMonitors()
        // The window shadow follows the content's alpha; take it again once the entrance has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak panel] in panel?.invalidateShadow() }
    }

    private func hide() {
        removeMonitors()
        panel.orderOut(nil)
        item.button?.highlight(false)
        app.panelDidClose()
    }

    /// Outside clicks close the panel: in other apps (global) and in this app's other windows (local).
    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.app.panelUI.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Menus opened from the panel (storage switcher, More) live in their own windows above it.
                let inMenu = (event.window?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue
                if !inMenu, event.window !== self.panel, event.window !== self.item.button?.window { self.app.panelUI.close() }
            }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: Drops on the status item

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, app.active != nil else { return [] }
        app.beginPick(urls, live: true)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { app.active == nil ? [] : .copy }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    /// Released on the icon itself: keep the files and let a click on a tile choose the folder.
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, app.active != nil else { return false }
        app.beginPick(urls, live: false)
        return true
    }
}

/// Borderless, non-activating, glass drawn by SwiftUI. Keeps its top edge under the status item while the
/// content grows or shrinks, and becomes key so Escape and ⌘K reach it.
final class MenuBarPanel: NSPanel {
    var topLeft: NSPoint?
    var onEscape: (() -> Void)?

    convenience init(contentViewController: NSViewController) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: MenuBarView.width, height: 400),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let topLeft { rect.origin = NSPoint(x: topLeft.x, y: topLeft.y - rect.height) }
        super.setFrame(rect, display: flag)
        invalidateShadow()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
