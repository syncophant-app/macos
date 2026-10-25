import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct SyncophantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window("Syncophant", id: "browser") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1360, height: 820)
        .commands { AppCommands(model: model) }

        // The menu bar item is an AppKit status item (see AppDelegate): MenuBarExtra cannot accept file drops.

        // Setup flows: their own windows so they can stay open beside the main window.
        setupWindow(.addStorage, title: "Add Storage") { AddStorageView() }
        setupWindow(.connectHetzner, title: "Connect Hetzner Storage Box") { ConnectHetznerView() }
        setupWindow(.connectServer, title: "Connect Server") { ConnectServerView() }
        setupWindow(.encryption, title: "Encryption") { EncryptionSetupView() }
        setupWindow(.newBackup, title: "New Backup") { NewBackupView() }
        setupWindow(.share, title: "Share") { ShareFolderView() }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    private func setupWindow<Content: View>(_ kind: SetupWindow, title: String, @ViewBuilder content: () -> Content) -> some Scene {
        let view = content()
        return Window(title, id: kind.rawValue) {
            WindowActionCapture(model: model) { view }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Hands the model the window-opening action from whichever window appears first.
private struct WindowActionCapture<Content: View>: View {
    let model: AppModel
    @ViewBuilder var content: Content
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        content
            .environment(model)
            .onAppear { if model.openWindowAction == nil { model.openWindowAction = openWindow } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A bare `swift run` binary has no Info.plist; behave like a normal app so windows can appear.
        if Bundle.main.bundleURL.pathExtension != "app" { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        GlobalHotKey.register { [weak self] in self?.revealSearch() }
        if let model = Self.model { statusItem = StatusItemController(app: model) }
    }

    /// Files dropped on the Dock icon open the panel as a drop target, like a drop on the status item.
    func application(_ application: NSApplication, open urls: [URL]) {
        let links = urls.filter { $0.scheme == "syncophant" }
        for link in links { Self.model?.handle(link) }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { Self.model?.beginPick(files, live: false) }
    }

    func applicationDidBecomeActive(_ notification: Notification) { Self.model?.refreshAgentAccess() }
    func applicationWillTerminate(_ notification: Notification) { SSHAgentBroker.shared.stop() }

    /// The drive stays reachable through the menu bar after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showBrowser() }
        return true
    }

    func showBrowser() {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.contains("browser") == true }?.makeKeyAndOrderFront(nil)
    }

    func revealSearch() {
        showBrowser()
        Self.model?.focusSearch()
    }
}

/// ⌃⌥Space, system-wide. Registration failure is silent: the shortcut is a convenience, not a feature gate.
@MainActor
enum GlobalHotKey {
    private static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handler?() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53594E43), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Storage…") { model.open(.addStorage) }.keyboardShortcut("n")
            Button("Upload Files…") { model.chooseFilesToUpload() }.keyboardShortcut("u").disabled(model.active == nil)
            Button("New Folder") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.active == nil)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await model.checkForUpdates() } }
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Destination.allCases.enumerated()), id: \.offset) { i, d in
                Button(d.title) { model.show(d) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button(model.filesUI.showInspector ? "Hide Inspector" : "Show Inspector") { model.filesUI.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Storage") {
            Button("Command Palette…") { model.showPalette = true }.keyboardShortcut("k")
            Button("Search This Storage") { model.focusSearch() }.keyboardShortcut("f")
            Button("Refresh") { model.refresh() }.keyboardShortcut("r").disabled(model.active == nil)
            Divider()
            Button("Keep Downloaded") { model.keepOnThisMac(model.selection) }
                .keyboardShortcut("p", modifiers: [.command, .option]).disabled(model.selection.isEmpty || !model.canUseFinder)
            Button("Remove Download") { model.removeDownload(model.selection) }
                .keyboardShortcut("e", modifiers: [.command, .option]).disabled(model.selection.isEmpty || !model.canUseFinder)
            Button("Browse Versions…") { model.show(.timeTravel) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.active == nil)
            Button("Copy Path") { if let n = model.selection.first { model.copyPath(n) } }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(model.selection.count != 1 || !model.canUseFinder)
            Button("Share…") { model.beginSharing() }.disabled(!model.canShareSelection)
            Divider()
            Button(model.queuePaused ? "Resume All Transfers" : "Pause All Transfers") { model.setPaused(!model.queuePaused) }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Button("Cancel Uploads") { model.cancelAll() }.keyboardShortcut(".").disabled(model.activeTransfers.isEmpty)
        }
    }
}

extension AppModel {
    func chooseFilesToUpload() {
        showUploadDestination = true
    }
}
