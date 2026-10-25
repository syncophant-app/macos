import AppKit
@preconcurrency import Sparkle

/// Sparkle handles signature verification, authorization, replacement and relaunch.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var started = false
    private let didFinish: (String) -> Void

    init(didFinish: @escaping (String) -> Void) {
        self.didFinish = didFinish
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func setAutomatic(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw AppError.needsBundle }
        let updater = controller.updater
        updater.sendsSystemProfile = false
        // Opting in means hands-off: signed updates download quietly and install on quit.
        updater.automaticallyDownloadsUpdates = enabled
        if updater.automaticallyChecksForUpdates != enabled { updater.automaticallyChecksForUpdates = enabled }
        updater.updateCheckInterval = 86_400
        if !started { controller.startUpdater(); started = true }
    }

    func check() {
        guard controller.updater.canCheckForUpdates else { didFinish("An update check is already in progress."); return }
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, let host = URL(string: raw)?.host {
            try? ContactLedger.record(host: host, purpose: "Optional update check · signed Sparkle appcast")
        }
        return nil
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if let host = request.url?.host { try? ContactLedger.record(host: host, purpose: "Update download · signed app archive") }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        didFinish(error.map { "Update check: \($0.localizedDescription)" } ?? "Update check finished.")
    }
}
