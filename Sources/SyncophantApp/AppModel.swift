import SwiftUI
import FileProvider
import CoreKit
import HetznerKit

/// Port 23 supports both SFTP and the checksum exec channel used by the shared engine.
let hetznerSFTPPort = 23

@MainActor @Observable
final class AppModel {
    // Connections
    var connections: [StorageConnection] = []
    var activeID: UUID?
    var demo: DemoSession?
    var mountedIDs: Set<UUID> = []
    var credentialPresent: [UUID: Bool] = [:]
    var lastChecked: [UUID: Date] = [:]
    var connectionErrors: [UUID: String] = [:]

    // Settings, privacy, diagnostics
    var settings = AppSettings()
    var contacts: [ContactRecord] = []
    var diagnostics = DiagnosticsLog()
    var updateStatus: String?
    var isCheckingUpdates = false

    // Navigation and transient UI
    var destination: Destination = .files
    var showUploadDestination = false
    var showPalette = false
    var hostKeyReview: UUID?
    var passwordPrompt: UUID?
    var mutationRecovery: UUID?
    var notice: Notice?
    var searchText = ""
    var searchFocusTick = 0
    var browserVisible = false

    // Browser
    var browser: TreeLoader?
    var searchResults: [FileNode] = []
    var selection: [FileNode] = []
    var snapshotSelection: [FileNode] = []

    // Transfers
    var transfers: [Transfer] = []
    var queuePaused = false
    var verifiedVersions: [String: String] = [:]
    var jobs: [BackupJob] = []
    var jobPreview: JobPreview?
    var runningJob: UUID?
    var jobStatus: String?
    var previewingJob = false
    var sharingItem: FileNode?
    var storageShares: [StorageShare] = []

    // Snapshots (Hetzner API, only after an explicit action)
    var snapshots = SnapshotsState()

    // Shared live data for the status views. Every value is measured; nothing is estimated.
    /// One sample a second while anything transfers, last 120 seconds.
    var throughput: [ThroughputSample] = []
    /// Finished transfers of the last 24 hours, for the hourly bars and counters.
    var history = TransferHistory()
    /// Folder shown in the Files section, relative to the storage root.
    var currentFolder = "/"
    /// Space on this Mac per storage, as last reported by the Finder extension.
    var cacheStatus: [UUID: CacheStatus] = [:]

    // Per-screen UI state. Each class lives in its screen's file.
    let filesUI = FilesState()
    let activityUI = ActivityState()
    let timeTravelUI = TimeTravelState()
    let backupsUI = BackupsState()
    let panelUI = PanelState()
    let paletteUI = PaletteState()
    let connectUI = ConnectFlowState()
    let encryptionUI = EncryptionFlowState()
    let shareUI = ShareFlowState()
    let settingsUI = SettingsState()

    @ObservationIgnored var stores: [UUID: any RemoteStore] = [:]
    @ObservationIgnored var engines: [UUID: TransferEngine] = [:]
    @ObservationIgnored var metadata: [UUID: MetadataStore] = [:]
    @ObservationIgnored var loaders: [UUID: TreeLoader] = [:]
    @ObservationIgnored var uploadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var lastContactWrite: [String: Date] = [:]
    @ObservationIgnored var jobScheduler: Task<Void, Never>?
    @ObservationIgnored var jobTask: Task<Void, Never>?
    @ObservationIgnored var appUpdater: AppUpdater?
    @ObservationIgnored var samplerTask: Task<Void, Never>?
    /// Captured from the first SwiftUI view that appears, so the model can open setup windows.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    var isDemo: Bool { demo != nil }
    var active: StorageConnection? { connections.first { $0.id == activeID } }
    var hasConnections: Bool { !connections.isEmpty }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {
        if CommandLine.arguments.contains("--demo") {
            startDemo()
        } else {
            settings = SharedJSON.load(AppSettings.self, name: "settings.json") ?? AppSettings()
            reloadContacts()
            verifiedVersions = SharedJSON.load([String: String].self, name: "verified.json") ?? [:]
            history = SharedJSON.load(TransferHistory.self, name: "history.json")?.pruned() ?? TransferHistory()
            jobs = SharedJSON.load([BackupJob].self, name: "backup-jobs.json") ?? []
            storageShares = SharedJSON.load([StorageShare].self, name: "shares.json") ?? []
            do { connections = try SharedConfig.loadConnections() }
            catch { diagnostics.add("Could not read saved connections: \(message(for: error))") }
            for c in connections { credentialPresent[c.id] = ((try? StorageCredentials.load(for: c.id)) ?? nil) != nil }
            activeID = connections.first?.id
            if let queue = SharedJSON.load(TransferQueueSnapshot.self, name: "transfers.json") {
                transfers = queue.restoredTransfers(knownConnectionIDs: Set(connections.map(\.id)))
                queuePaused = queue.paused
            }
            Task { await refreshMounted() }
            if settings.updateChecks { Task { await runDailyUpdateCheck() } }
        }
        if activeID != nil { Task { await openActive(); pump() } }
        if !isDemo { startJobScheduler() }
        if !isDemo { refreshAgentAccess() }
        startThroughputSampler()
        if !isDemo { startShareExpiryMonitor() }
    }

    // MARK: Notices

    func say(_ text: String, error: Bool = false) {
        notice = Notice(text: text, isError: error)
        if error { diagnostics.add("Shown to user: \(text)") }
        noticeTask?.cancel()
        let id = notice?.id
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(error ? 8 : 4))
            if !Task.isCancelled, notice?.id == id { notice = nil }
        }
    }

    // MARK: Stores

    func remoteStore(for c: StorageConnection) throws -> any RemoteStore {
        if let s = stores[c.id] { return s }
        let s: any RemoteStore
        if let demo, demo.connection.id == c.id {
            s = demo.store
        } else {
            if c.usesSSH, c.hostKeyFingerprint == nil { throw CoreKitError.hostKeyRequired }
            s = try StorageCredentials.makeStore(connection: c)
        }
        stores[c.id] = s
        return s
    }

    func metadataStore(for c: StorageConnection) throws -> MetadataStore {
        if let m = metadata[c.id] { return m }
        if let demo, demo.connection.id == c.id { metadata[c.id] = demo.meta; return demo.meta }
        let m = try MetadataStore(url: SharedConfig.metadataURL(for: c.id))
        metadata[c.id] = m
        return m
    }

    func engine(for c: StorageConnection) throws -> TransferEngine {
        if let engine = engines[c.id] { return engine }
        let engine = TransferEngine(store: try remoteStore(for: c), metadata: try metadataStore(for: c))
        engines[c.id] = engine
        return engine
    }

    /// Drops cached sessions after credentials or the pinned host key change.
    func resetSession(_ id: UUID) {
        stores[id] = nil
        engines[id] = nil
        loaders[id] = nil
        if activeID == id { browser = nil }
    }

    // MARK: Connections

    func select(_ id: UUID) {
        guard id != activeID else { destination = .files; return }
        activeID = id
        destination = .files
        searchText = ""
        selection = []
        snapshots = SnapshotsState()
        Task { await openActive() }
    }

    func add(_ connection: StorageConnection, password: String?) throws {
        try add(connection, authentication: password.map { .password($0) })
    }

    func add(_ connection: StorageConnection, authentication: SSHAuthentication?) throws {
        guard !isDemo else { throw AppError.unavailable("Connections are disabled in demo mode.") }
        if let authentication { try SSHCredentials.save(authentication, for: connection.id) }
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        try persist()
        credentialPresent[connection.id] = authentication != nil || credentialPresent[connection.id] == true
        resetSession(connection.id)
        activeID = connection.id
        refreshAgentAccess()
        destination = .files
        Task { await openActive() }
    }

    func update(_ connection: StorageConnection) throws {
        guard let i = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[i] = connection
        try persist()
        resetSession(connection.id)
        if activeID == connection.id { Task { await openActive() } }
    }

    func refreshAgentAccess() {
        guard !isDemo else { return }
        let usesAgent = connections.contains { connection in
            guard let credentials = try? StorageCredentials.load(for: connection.id) else { return false }
            if case .ssh(.agent) = credentials.authentication { return true }
            return false
        }
        if usesAgent {
            do { try SSHAgentBroker.shared.start() }
            catch { diagnostics.add("SSH agent access: \(message(for: error))") }
        } else { SSHAgentBroker.shared.stop() }
    }

    func remove(_ connection: StorageConnection) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(connection.name)?"
        alert.informativeText = isDemo ? "This removes the local demo connection. No remote storage is connected." : "This stops syncing this connection and removes its saved password from this Mac. Files on your storage and downloaded Finder data are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Connection")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for transfer in activeTransfers where transfer.connectionID == connection.id { cancel(transfer.id) }
        do {
            if !isDemo {
                if mountedIDs.contains(connection.id) { try await DriveManager.unmount(connection) }
                try SSHCredentials.delete(for: connection.id)
            }
        } catch { say("Could not remove \(connection.name): \(message(for: error))", error: true); return }
        mountedIDs.remove(connection.id)
        connections.removeAll { $0.id == connection.id }
        try? persist()
        resetSession(connection.id)
        if activeID == connection.id { activeID = connections.first?.id; browser = nil; if activeID != nil { await openActive() } }
    }

    func persist() throws {
        guard !isDemo else { return }
        try SharedConfig.saveConnections(connections)
    }

    func savePassword(_ password: String, for id: UUID) {
        guard !isDemo else { return }
        do {
            try SSHCredentials.save(.password(password), for: id)
            credentialPresent[id] = true
            resetSession(id)
            passwordPrompt = nil
            if activeID == id { Task { await openActive() } }
        } catch { say("Could not save the password to your Keychain: \(message(for: error))", error: true) }
    }

    func approveHostKey(_ fingerprint: String, for id: UUID) {
        guard var c = connections.first(where: { $0.id == id }) else { return }
        c.hostKeyFingerprint = fingerprint
        do { try update(c); hostKeyReview = nil; say("Pinned the host key for \(c.name).") }
        catch { say("Could not save the host key: \(message(for: error))", error: true) }
    }

    // MARK: Privacy

    /// Records into the ledger the Finder extension also writes. At most one write per host per minute from here.
    func noteContact(host: String, purpose: String) {
        guard !isDemo, !host.isEmpty else { return }
        if let last = lastContactWrite[host], Date().timeIntervalSince(last) < 60 { return }
        lastContactWrite[host] = Date()
        do { try ContactLedger.record(host: host, purpose: purpose) }
        catch { diagnostics.add("Could not record contact: \(message(for: error))") }
        reloadContacts()
    }

    func reloadContacts() {
        let records = (try? ContactLedger.records()) ?? []
        contacts = records.map { ContactRecord(host: $0.host, purpose: $0.purpose, lastContacted: $0.lastContacted, count: $0.count) }
            .sorted { $0.lastContacted > $1.lastContacted }
    }

    func noteContact(_ c: StorageConnection) { noteContact(host: c.host, purpose: "Your storage · \(c.usesSSH ? "SFTP" : c.provider.rawValue.uppercased()) on port \(c.port)") }

    func clearContactHistory() {
        guard !isDemo else { contacts = []; return }
        do { try ContactLedger.clear() } catch { say("Could not clear the history: \(message(for: error))", error: true) }
        lastContactWrite = [:]
        reloadContacts()
    }

    // MARK: Settings

    func save(_ settings: AppSettings) {
        self.settings = settings
        guard !isDemo else { return }
        do { try SharedJSON.save(settings, name: "settings.json") }
        catch { say("Could not save settings: \(message(for: error))", error: true) }
    }

    func setUpdateChecks(_ on: Bool) {
        var s = settings; s.updateChecks = on; save(s)
        guard !isDemo else { return }
        do { try updater().setAutomatic(on); updateStatus = nil }
        catch { updateStatus = message(for: error) }
    }

    /// Always an explicit request; also used by the opt-in daily check.
    func checkForUpdates() async {
        guard !isDemo else { say("Update checks are disabled in demo mode."); return }
        isCheckingUpdates = true
        do {
            let updater = updater()
            try updater.setAutomatic(settings.updateChecks)
            updater.check()
        } catch { isCheckingUpdates = false; updateStatus = "Could not check: \(message(for: error))" }
    }

    private func updater() -> AppUpdater {
        if let appUpdater { return appUpdater }
        let updater = AppUpdater { [weak self] status in
            guard let self else { return }
            self.isCheckingUpdates = false; self.updateStatus = status
            var updated = self.settings; updated.lastUpdateCheck = Date(); self.save(updated)
            self.reloadContacts()
        }
        appUpdater = updater
        return updater
    }

    private func runDailyUpdateCheck() async {
        guard settings.updateChecks else { return }
        do { try updater().setAutomatic(true) }
        catch { updateStatus = message(for: error) }
    }

    func exportDiagnostics() -> URL? {
        let text = diagnostics.redacted(hosts: connections.map(\.host), users: connections.map(\.username))
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let url = downloads.appendingPathComponent("diagnostics-\(day).txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { say("Could not save diagnostics: \(message(for: error))", error: true); return nil }
    }

    // MARK: Issues

    var issues: [Issue] {
        var list: [Issue] = []
        let keyChanged = CoreKitError.hostKeyMismatch.errorDescription
        let signInFailed = CoreKitError.authenticationFailed.errorDescription
        for c in connections where !(isDemo && c.id == demo?.connection.id) {
            let error = connectionErrors[c.id]
            if c.usesSSH, c.hostKeyFingerprint == nil {
                list.append(Issue(id: "hostkey-\(c.id)", title: "Approve the server key for \(c.name)",
                                  detail: "Syncophant won’t connect until you check and approve this server’s key.",
                                  fix: .reviewHostKey(c.id), severity: .failure))
            } else if c.usesSSH, error == keyChanged {
                list.append(Issue(id: "hostkey-\(c.id)", title: "The server key for \(c.name) changed",
                                  detail: "It no longer matches the key you approved. Syncophant stays disconnected until you decide.",
                                  fix: .compareHostKey(c.id), severity: .failure))
            } else if credentialPresent[c.id] != true || error == signInFailed {
                let missing = credentialPresent[c.id] != true
                list.append(Issue(id: "password-\(c.id)", title: missing ? "\(c.name) needs its password" : "Sign-in to \(c.name) failed",
                                  detail: missing ? "The saved password isn’t in your Keychain, so the drive can’t sign in."
                                                  : "The server turned down the saved password. Enter it again to reconnect.",
                                  fix: c.usesSSH ? .enterPassword(c.id) : .reconnectStorage, severity: .failure))
            } else if let e = error {
                list.append(Issue(id: "listing-\(c.id)", title: "\(c.name) did not answer", detail: e,
                                  fix: e.contains("needs recovery") ? .recoverMutation(c.id) : .retryListing(c.id), severity: .failure))
            }
            if let space = capacity(for: c), Double(space.used) / Double(space.total) > 0.9 {
                list.append(Issue(id: "full-\(c.id)", title: "\(c.name) is nearly full",
                                  detail: "\(Format.bytes(max(0, space.total - space.used))) left of \(Format.bytes(space.total)). New uploads stop when it’s full.",
                                  fix: .freeUpSpace(c.id)))
            }
            if c.id == activeID, snapshotsHidden {
                list.append(Issue(id: "snapshots-\(c.id)", title: "Snapshots are hidden on \(c.name)",
                                  detail: "Time Travel needs the snapshot folder. Syncophant can switch it on through the Hetzner API.",
                                  fix: .showSnapshotFolder(c.id)))
            }
            if !mountedIDs.contains(c.id), Bundle.main.bundleURL.pathExtension == "app" {
                list.append(Issue(id: "finder-\(c.id)", title: "\(c.name) is not in Finder",
                                  detail: "The drive is saved but not added under Locations.", fix: .addToFinder(c.id)))
            }
        }
        for t in transfers {
            switch t.phase {
            case .failed(let reason):
                let stopped = t.fraction.map { $0 > 0 ? "\(t.name) stopped at \(Int($0 * 100))%" : nil } ?? nil
                list.append(Issue(id: "transfer-\(t.id)", title: stopped ?? "\(t.name) did not upload", detail: reason,
                                  fix: .retryTransfer(t.id), severity: .failure))
            case .unverified:
                list.append(Issue(id: "transfer-\(t.id)", title: "\(t.name) is on your box but not verified",
                                  detail: "The server’s checksum could not confirm this upload.", fix: .retryTransfer(t.id)))
            default: break
            }
            if t.madeConflictCopy, t.conflictSeen != true, let path = t.publishedPath,
               Date().timeIntervalSince(t.finishedAt ?? .distantPast) < 86_400 {
                list.append(Issue(id: "conflict-\(t.id)", title: "\(t.name) was already on your box",
                                  detail: "Both are kept. Yours was saved as “\(PathRules.name(of: path))”.", fix: .showConflict(t.id)))
            }
        }
        return list
    }

    /// Fire-and-forget form for buttons outside Activity.
    func perform(_ fix: Issue.Fix) { Task { _ = await resolve(fix) } }

    /// Runs a fix and says what happened, so a problem card can turn green or show why it failed.
    func resolve(_ fix: Issue.Fix) async -> FixOutcome {
        func connection(_ id: UUID) -> StorageConnection? { connections.first { $0.id == id } }
        switch fix {
        case .reviewHostKey(let id), .compareHostKey(let id): hostKeyReview = id; return .opened
        case .enterPassword(let id): passwordPrompt = id; return .opened
        case .recoverMutation(let id): mutationRecovery = id; return .opened
        case .reconnectStorage: open(.connectServer); return .opened
        case .retryListing(let id):
            guard let c = connection(id) else { return .opened }
            connectionErrors[id] = nil
            if id == activeID { await openActive() } else {
                do { _ = try await roundTrip(to: c) } catch { connectionErrors[id] = message(for: error) }
            }
            if let e = connectionErrors[id] { return .failed(e) }
            return .fixed("\(c.name) is answering again")
        case .addToFinder(let id):
            guard let c = connection(id) else { return .opened }
            await mount(c)
            return mountedIDs.contains(id) ? .fixed("\(c.name) is in Finder") : .failed("Couldn’t add \(c.name) to Finder.")
        case .retryTransfer(let id):
            retry(id)
            guard let t = transfers.first(where: { $0.id == id }), t.phase.isActive else { return .failed("This upload can’t be retried.") }
            return .fixed("\(t.name) is uploading again")
        case .showConflict(let id):
            guard let i = transfers.firstIndex(where: { $0.id == id }) else { return .opened }
            transfers[i].conflictSeen = true
            persistQueue()
            let t = transfers[i]
            if t.connectionID != activeID { select(t.connectionID) }
            openFolder(PathRules.parent(of: t.publishedPath ?? t.remotePath))
            return .opened
        case .showSnapshotFolder(let id):
            guard let c = connection(id) else { return .opened }
            if id != activeID || HetznerToken.load() == nil { if id != activeID { select(id) }; show(.timeTravel); return .opened }
            await showSnapshotFolder()
            return snapshotsHidden ? .failed("Hetzner didn’t switch the snapshot folder on. Try again in Time Travel.")
                : .fixed("Snapshot folder is on for \(c.name)")
        case .freeUpSpace(let id):
            if id != activeID { select(id) }
            openFolder("/")
            return .opened
        }
    }

    func connectionLine(for c: StorageConnection) -> String {
        if isDemo, c.id == demo?.connection.id { return "Demo · local files" }
        if let e = connectionErrors[c.id] { return "Not reachable · \(e)" }
        if let t = lastChecked[c.id] { return "Checked \(Format.time.string(from: t))" }
        return "Not checked yet"
    }
}
