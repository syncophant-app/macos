import SwiftUI
import AppKit

/// Put once in the main window (`.background(PaletteHost())`). It hands the model to the panel controller, which then
/// follows `app.showPalette` for the life of the app, so ⌘K also works from the menu bar panel after the window closes.
struct PaletteHost: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { PalettePanel.shared.watch(app) }
    }
}

/// A floating, non-activating panel over the whole screen: a dimmed backdrop with the palette near the top.
@MainActor
final class PalettePanel {
    static let shared = PalettePanel()

    private weak var app: AppModel?
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    func watch(_ app: AppModel) {
        guard self.app == nil else { return }
        self.app = app
        observe()
    }

    private func observe() {
        guard let app else { return }
        let show = withObservationTracking { app.showPalette } onChange: {
            Task { @MainActor in PalettePanel.shared.observe() }
        }
        show ? present(app) : dismiss()
    }

    private func present(_ app: AppModel) {
        guard panel == nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        let panel = KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: PaletteOverlay().environment(app))
        host.sizingOptions = []
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        // Clicking another window or app closes the palette, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { PalettePanel.shared.app?.showPalette = false }
        }
        self.panel = panel
    }

    private func dismiss() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Backdrop plus the palette, which grows in from just above its resting place.
private struct PaletteOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(shown ? (colorScheme == .dark ? 0.35 : 0.18) : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { app.showPalette = false }
                    .accessibilityHidden(true)
                CommandPalette()
                    .scaleEffect(shown ? 1 : 0.97, anchor: .top)
                    .offset(y: shown ? 0 : -14)
                    .opacity(shown ? 1 : 0)
                    .padding(.top, proxy.size.height * 0.16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(Motion.resolve(Motion.morph)) { shown = true } }
    }
}
