import SwiftUI
import CoreKit
import HetznerKit
import Security

/// The SSH-side setup engine behind Connect Hetzner and the SFTP tab of Connect server.
/// Every step retries on its own; finished steps are never repeated. Host keys are pinned only after the person
/// trusts them (and, for Storage Boxes, only when they match Hetzner's published list). Secrets go to the Keychain.
@MainActor @Observable
final class ConnectModel {
    enum Choice { case hetzner, sftp }
    enum Authentication: String, CaseIterable, Identifiable {
        case generatedKey, privateKey, agent, password
        var id: String { rawValue }
    }

    /// The editable Hetzner plan. Turning a switch off removes its task from the checklist.
    struct Plan: Equatable {
        var subaccount = true
        var key = true
        var snapshots = true
        var test = true
    }

    enum TokenState: Equatable { case idle, checking, valid(Int), invalid(String) }

    struct Step: Identifiable, Equatable {
        enum Kind: Int { case reach, secure, subaccount, access, snapshots, hostKey, installKey, signIn, preflight, save, mount }
        enum State: Equatable { case pending, running, awaitingApproval, done, failed(String) }
        let kind: Kind
        var title: String
        var note = ""
        var state: State = .pending
        var id: Int { kind.rawValue }
    }

    var choice: Choice = .hetzner

    // MARK: Hetzner input
    var token = ""
    var tokenState: TokenState = .idle
    var boxes: [StorageBox] = []
    var snapshotCounts: [Int: Int] = [:]
    var selectedBox: Int?
    var friendlyName = ""
    var color: AvatarColor = .blue
    var plan = Plan()
    var folder = "Syncophant"
    var mainPassword = ""

    // MARK: SFTP input
    var server = ""
    var remoteFolder = ""
    var name = ""
    var authentication: Authentication = .generatedKey
    var password = ""
    var privateKey = ""
    var privateKeyName = ""
    var passphrase = ""
    var agentSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
    var keyError: String?
    var sshHosts: [SSHHost] = []
    /// Set before the check when the person chose end-to-end encryption; never shown or stored outside the Keychain.
    var encryptionPassphrase = ""

    // MARK: Run state
    var steps: [Step] = []
    var fingerprint: String?
    /// The key pinned for this host by an existing storage, when it differs from the one the server shows now.
    var previousFingerprint: String?
    var approved = false
    var running = false
    var saved: StorageConnection?
    var mounted = false
    var latency: TimeInterval?
    var roundTrip: TimeInterval?
    /// The SFTP check stops before saving; Connect clears this and runs the rest.
    var stopsBeforeSave = false

    @ObservationIgnored private var connection: StorageConnection?
    @ObservationIgnored private var bootstrap: SSHAuthentication?
    @ObservationIgnored private var credential: SSHAuthentication?
    @ObservationIgnored private var generatedKey: SSHKeyPair?
    @ObservationIgnored private var testPath: String?
    @ObservationIgnored private var subaccountName: String?

    // MARK: Published Hetzner host keys

    // Published by Hetzner Storage Box documentation, checked 2026-10-25; never infer trust from a probe.
    static let hetznerFingerprints = ["SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM",
                                      "SHA256:EMlfI8GsRIfpVkoW1H2u0zYVpFGKkIMKHFZIRkf2ioI",
                                      "SHA256:oDHZqKXnoMtgvPBjjC57pcuFez28roaEuFcfwyg8O5c"]
    var officialFingerprintMatches: Bool { fingerprint.map(Self.hetznerFingerprints.contains) ?? false }

    /// True for Storage Box hosts: their key must match Hetzner's published list before it can be trusted.
    var targetIsHetzner: Bool { choice == .hetzner || ServerAddress.isStorageBox(address.host) }
    var canTrustKey: Bool { fingerprint != nil && (!targetIsHetzner || officialFingerprintMatches) }

    // MARK: Derived input

    var address: ServerAddress { ServerAddress.parse(server) }
    /// The ~/.ssh/config entry for the typed host, matched by alias or host name.
    var sshMatch: SSHHost? {
        let a = address
        guard !a.host.isEmpty else { return nil }
        return sshHosts.first { ($0.alias == a.host || $0.hostName == a.host) && (a.user.isEmpty || $0.user == a.user) }
    }
    var host: String { sshMatch.map { $0.alias == address.host ? $0.hostName : address.host } ?? address.host }
    var user: String { address.user.isEmpty ? (sshMatch?.user ?? "") : address.user }
    var port: Int { address.port ?? sshMatch?.port ?? (ServerAddress.isStorageBox(address.host) ? hetznerSFTPPort : 22) }
    var portHint: String {
        if address.port != nil { return "Port \(port)" }
        if let m = sshMatch, m.port != 22 { return "Port \(m.port) from ssh config" }
        return ServerAddress.isStorageBox(address.host) ? "Port 23 for Storage Boxes" : "Port 22"
    }
    var suggestedName: String {
        if let alias = sshMatch?.alias, alias != host { return alias }
        return ServerAddress.isStorageBox(address.host) ? "Storage Box" : "SFTP server"
    }
    var defaultFolder: String { ServerAddress.isStorageBox(address.host) ? StorageBoxPath.sftpRoot : "/" }

    var authenticationValid: Bool {
        switch authentication {
        case .generatedKey: true
        case .password: !password.isEmpty
        case .privateKey: !privateKey.isEmpty
        case .agent: agentSocket.hasPrefix("/") && !agentSocket.contains("\0") && agentSocket.utf8.count < 104
        }
    }

    var sftpValid: Bool {
        !host.isEmpty && !user.isEmpty && (1...65535).contains(port) && authenticationValid
            && (try? PathRules.normalize(remoteFolder.isEmpty ? defaultFolder : remoteFolder)) != nil
    }

    var selectedBoxValue: StorageBox? { boxes.first { $0.id == selectedBox } }

    var folderValid: Bool { (try? StorageBoxPath.validateHomeDirectory(folder)) != nil }

    var planValid: Bool {
        guard let b = selectedBoxValue, b.isReady, folderValid else { return false }
        return plan.subaccount || !mainPassword.isEmpty
    }

    /// Default friendly name for a box: its Hetzner name unless that is just the login (u123456).
    static func suggestedName(for box: StorageBox) -> String {
        let n = box.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == box.username || n.range(of: #"^u\d+$"#, options: .regularExpression) != nil ? "Storage Box" : n
    }

    // MARK: Hetzner token

    /// Lists the boxes this token can see. Runs only for a plausible token typed or pasted in the Connect Hetzner window.
    func validateToken(model: AppModel) async {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeToken(t) else { tokenState = .idle; return }
        guard !model.isDemo else { tokenState = .invalid("Connections are disabled in demo mode."); return }
        tokenState = .checking
        model.noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
        do {
            let found = try await HetznerClient(token: t).storageBoxes()
            guard t == token.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            try HetznerToken.save(t)
            boxes = found
            if found.isEmpty { tokenState = .invalid("This token works but sees no Storage Boxes. Check that it belongs to the right project."); return }
            tokenState = .valid(found.count)
            if selectedBoxValue == nil, let first = found.first(where: \.isReady) { pick(first) }
            await loadSnapshotCounts(token: t)
        } catch is CancellationError {
        } catch HetznerError.http(let status, _, _) where status == 401 || status == 403 {
            tokenState = .invalid("Hetzner did not accept this token. Copy it again, with Read and Write permission.")
        } catch {
            tokenState = .invalid(message(for: error))
        }
    }

    static func looksLikeToken(_ t: String) -> Bool {
        t.count >= 32 && t.count <= 128 && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    func pick(_ box: StorageBox) {
        guard box.isReady else { return }
        let oldSuggestion = selectedBoxValue.map(Self.suggestedName)
        selectedBox = box.id
        if friendlyName.isEmpty || friendlyName == oldSuggestion { friendlyName = Self.suggestedName(for: box) }
    }

    /// Snapshot counts shown on the box cards and the Done screen. Failures just hide the chip.
    private func loadSnapshotCounts(token: String) async {
        let client = HetznerClient(token: token)
        await withTaskGroup(of: (Int, Int?).self) { group in
            for box in boxes where box.isReady {
                group.addTask { (box.id, try? await client.snapshots(boxID: box.id).count) }
            }
            for await (id, count) in group { if let count { snapshotCounts[id] = count } }
        }
    }

    // MARK: SFTP input helpers

    func loadSSHHosts() async {
        sshHosts = (try? await Task.detached { try SSHHost.read() }.value) ?? []
    }

    /// Picks up identities and agents from the matching ~/.ssh/config entry, without touching the network.
    func applySSHMatch() {
        guard let m = sshMatch else { return }
        if let agent = m.identityAgent { agentSocket = (agent as NSString).expandingTildeInPath }
        if privateKey.isEmpty, let file = m.identityFiles.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            loadPrivateKey(URL(fileURLWithPath: file))
        }
    }

    func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose a private SSH key. Its contents will be stored in your Keychain after sign-in."
        if panel.runModal() == .OK, let url = panel.url { loadPrivateKey(url) }
    }

    private func loadPrivateKey(_ url: URL) {
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
                  text.contains("PRIVATE KEY"), !text.contains("\0") else { throw AppError.unavailable("Choose an OpenSSH or PEM private key smaller than 1 MB.") }
            privateKey = text; privateKeyName = url.lastPathComponent; keyError = nil
        } catch { privateKey = ""; privateKeyName = ""; keyError = message(for: error) }
    }

    /// Creates (once) this Mac's ed25519 key in the Keychain and copies its public half. Local only.
    func copyPublicKey(model: AppModel) async {
        do {
            let pair = try await Task.detached { try SSHCredentials.generatedKeyPair() }.value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pair.publicKey, forType: .string)
            model.say("Copied this Mac’s public key. Add it to ~/.ssh/authorized_keys on the server.")
        } catch { model.say("Could not create the key: \(message(for: error))", error: true) }
    }

    // MARK: Setup

    /// Hetzner: the plan's tasks. SFTP: the connection check, then save and Finder on Connect.
    func begin(model: AppModel) {
        guard !model.isDemo else { model.say("Connections are disabled in demo mode."); return }
        reset()
        var list: [Step] = []
        let folderName = "/" + folder
        if choice == .hetzner {
            if plan.subaccount { list.append(Step(kind: .subaccount, title: "Creating a sub-account for this Mac")) }
            list.append(Step(kind: .access, title: "Turning on SSH"))
            if plan.snapshots { list.append(Step(kind: .snapshots, title: "Showing the snapshot folder")) }
            list.append(Step(kind: .hostKey, title: "Checking the box’s fingerprint"))
            if plan.key { list.append(Step(kind: .installKey, title: "Adding this Mac’s key")) }
            list.append(Step(kind: .signIn, title: plan.subaccount ? "Opening \(folderName)" : "Creating \(folderName)"))
            if plan.test { list.append(Step(kind: .preflight, title: "Sending and reading back 1 MB")) }
            list.append(Step(kind: .save, title: "Saving the sign-in to your Keychain"))
            list.append(Step(kind: .mount, title: "Adding \(displayName) to Finder"))
        } else {
            list.append(Step(kind: .reach, title: "Reach the server"))
            list.append(Step(kind: .hostKey, title: "Confirm its fingerprint"))
            if authentication == .generatedKey, !password.isEmpty { list.append(Step(kind: .installKey, title: "Add this Mac’s key")) }
            list.append(Step(kind: .signIn, title: "Sign in"))
            list.append(Step(kind: .preflight, title: "Read and write 1 MB"))
            list.append(Step(kind: .save, title: "Save to your Keychain"))
            list.append(Step(kind: .mount, title: "Add to Finder"))
            stopsBeforeSave = true
        }
        steps = list
        Task { await run(model: model) }
    }

    /// Forgets a previous run's state (the Mac key in the Keychain is kept; it is this Mac's identity).
    func reset() {
        approved = false; fingerprint = nil; previousFingerprint = nil; saved = nil; mounted = false
        connection = nil; bootstrap = nil; credential = nil; generatedKey = nil; testPath = nil; subaccountName = nil
        latency = nil; roundTrip = nil; steps = []; stopsBeforeSave = false
    }

    func approveHostKey(model: AppModel) {
        guard canTrustKey else { return }
        approved = true
        setState(.hostKey, .pending)
        Task { await run(model: model) }
    }

    /// Runs the remaining steps (after a failure, or Connect after a passed check).
    func resume(model: AppModel) {
        stopsBeforeSave = false
        Task { await run(model: model) }
    }

    func retry(model: AppModel) { Task { await run(model: model) } }

    var displayName: String {
        let n = (choice == .hetzner ? friendlyName : name).trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (choice == .hetzner ? "Storage Box" : suggestedName) : n
    }

    private func setState(_ kind: Step.Kind, _ state: Step.State, note: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[i].state = state
        if let note { steps[i].note = note }
    }

    private func run(model: AppModel) async {
        guard !running else { return }
        running = true
        defer { running = false }
        for step in steps where step.state != .done {
            if stopsBeforeSave && step.kind == .save { return }
            setState(step.kind, .running)
            do {
                let finished = try await perform(step.kind, model: model)
                if !finished { setState(step.kind, .awaitingApproval); return }
                setState(step.kind, .done)
            } catch {
                var reason = Self.plain(error, step: step.kind, port: connection?.port ?? port)
                if step.kind == .signIn, choice == .sftp, authentication == .generatedKey, password.isEmpty,
                   (error as? CoreKitError) == .authenticationFailed {
                    reason = "The server does not know this Mac’s key yet. Copy the public key to it, or enter the password so Syncophant adds it."
                }
                setState(step.kind, .failed(reason))
                return
            }
        }
    }

    /// Returns false when the step must wait for the person.
    private func perform(_ kind: Step.Kind, model: AppModel) async throws -> Bool {
        let apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .secure:
            return true
        case .reach:
            let started = ProcessInfo.processInfo.systemUptime
            model.noteContact(host: host, purpose: "Your storage · SFTP on port \(port)")
            try await NetProbe.reach(host: host, port: port)
            latency = ProcessInfo.processInfo.systemUptime - started
            setState(.reach, .running, note: NetProbe.milliseconds(latency!))
            return true
        case .access:
            guard let box = selectedBoxValue else { throw AppError.unavailable("Pick a Storage Box first.") }
            if box.accessSettings?.sshEnabled != true || box.accessSettings?.reachableExternally != true {
                model.noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
                try await HetznerClient(token: apiToken).updateAccess(boxID: box.id, ssh: true, externalReachability: true)
            }
            setState(.access, .running, note: "port 23")
            return true
        case .snapshots:
            guard let box = selectedBoxValue else { throw AppError.unavailable("Pick a Storage Box first.") }
            if box.accessSettings?.zfsEnabled != true {
                model.noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
                try await HetznerClient(token: apiToken).updateAccessSettings(boxID: box.id, StorageAccessSettings(zfsEnabled: true))
            }
            if let count = try? await HetznerClient(token: apiToken).snapshots(boxID: box.id).count { snapshotCounts[box.id] = count }
            setState(.snapshots, .running, note: snapshotCounts[box.id].map { $0 == 1 ? "1 snapshot" : "\($0) snapshots" } ?? "on")
            return true
        case .subaccount:
            guard let box = selectedBoxValue else { throw AppError.unavailable("Pick a Storage Box first.") }
            if connection == nil {
                let generated = try PasswordGenerator.make()
                model.noteContact(host: "api.hetzner.com", purpose: "Hetzner API · setup, quota and snapshots")
                let client = HetznerClient(token: apiToken)
                let taken = try await client.subaccounts(boxID: box.id).compactMap(\.name)
                let name = StorageSubaccount.availableName("mac-" + (Host.current().localizedName ?? ""), taken: taken)
                let sub = try await client.createSubaccount(boxID: box.id, username: name, password: generated, homeDirectory: folder)
                bootstrap = .password(generated)
                subaccountName = sub.username
                connection = StorageConnection(name: displayName, provider: .hetzner, host: sub.server ?? box.server,
                                               port: hetznerSFTPPort, username: sub.username, rootPath: StorageBoxPath.sftpRoot)
            }
            setState(.subaccount, .running, note: subaccountName ?? "")
            return true
        case .hostKey:
            if connection == nil { connection = try makeConnection(model: model) }
            guard let c = connection else { return true }
            if approved, fingerprint != nil { return true }
            model.noteContact(host: c.host, purpose: "Your storage · SFTP on port \(c.port)")
            let found = try await SFTPStore.probeHostKey(host: c.host, port: c.port, sessionBudgetURL: try sessionBudgetURL())
            fingerprint = found
            let known = model.connections.first { $0.host == c.host && $0.port == c.port && $0.hostKeyFingerprint != nil }?.hostKeyFingerprint
            previousFingerprint = known != found ? known : nil
            setState(.hostKey, .running, note: targetIsHetzner ? (officialFingerprintMatches ? "matches Hetzner’s" : "does not match Hetzner’s") : "ed25519")
            return false
        case .installKey:
            guard let c = connection, let fp = fingerprint, let bootstrap else { throw AppError.unavailable("Setup lost its state. Start over.") }
            let key = try await ensureKey()
            var pinned = c; pinned.hostKeyFingerprint = fp
            let store = SFTPStore(connection: pinned, authentication: bootstrap, sessionBudgetURL: try sessionBudgetURL())
            do {
                try await store.installPublicKey(key.publicKey, hetzner: targetIsHetzner)
                await store.disconnect()
            } catch { await store.disconnect(); throw error }
            credential = .privateKey(contents: key.privateKey, passphrase: nil)
            setState(.installKey, .running, note: "ed25519")
            return true
        case .signIn:
            guard var c = connection, let fp = fingerprint else { throw AppError.unavailable("Setup lost its state. Start over.") }
            c.hostKeyFingerprint = fp
            connection = c
            let auth = try await finalAuthentication()
            if choice == .hetzner, !plan.subaccount { try await createMainFolder(c, auth: auth) }
            let (store, base) = try makeStore(c, auth: auth)
            do { _ = try await store.list(path: "/"); await base.disconnect() }
            catch { await base.disconnect(); throw error }
            credential = auth
            setState(.signIn, .running, note: methodName)
            return true
        case .preflight:
            guard let c = connection, let credential else { throw AppError.unavailable("Setup lost its state. Start over.") }
            let (store, base) = try makeStore(c, auth: credential)
            do {
                if let path = testPath { try await removeTestFile(path, store: store); testPath = nil }
                let path = "/.syncophant-preflight-" + UUID().uuidString
                testPath = path
                var random = [UInt8](repeating: 0, count: 1_048_576)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw AppError.unavailable("Could not generate test bytes.") }
                let data = Data(random), started = ProcessInfo.processInfo.systemUptime
                try await store.write(path: path, offset: 0, data: data)
                let received = try await store.read(path: path, offset: 0, length: data.count)
                guard received == data else { throw CoreKitError.checksumMismatch }
                roundTrip = max(0.001, ProcessInfo.processInfo.systemUptime - started)
                try await store.remove(path: path); testPath = nil
                setState(.preflight, .running, note: NetProbe.seconds(roundTrip!))
                await base.disconnect()
                return true
            } catch {
                if let path = testPath {
                    do { try await removeTestFile(path, store: store); testPath = nil }
                    catch { await base.disconnect(); throw AppError.unavailable("Test cleanup failed. Try again to remove \(path) before continuing.") }
                }
                await base.disconnect(); throw error
            }
        case .save:
            guard var c = connection, let credential else { throw AppError.unavailable("Setup lost its state. Start over.") }
            c.name = displayName
            let secret = encryptionPassphrase
            if secret.isEmpty {
                try model.add(c, authentication: credential)
            } else {
                c.encryptionEnabled = true
                try StorageCredentials(authentication: .ssh(credential), encryptionPassword: secret).save(for: c.id)
                try model.add(c, authentication: nil)
                model.credentialPresent[c.id] = true
            }
            if choice == .hetzner { model.setAvatarColor(color, for: c) }
            connection = c
            saved = c
            return true
        case .mount:
            guard let c = saved else { throw AppError.unavailable("Setup lost its state. Start over.") }
            try await DriveManager.mount(c)
            model.mountedIDs.insert(c.id)
            mounted = true
            await model.applyStorageBoxLink()
            return true
        }
    }

    private var methodName: String {
        if choice == .hetzner { return plan.key ? "key" : "password" }
        switch authentication {
        case .generatedKey, .privateKey: return "key"
        case .agent: return "agent"
        case .password: return "password"
        }
    }

    private func ensureKey() async throws -> SSHKeyPair {
        if let generatedKey { return generatedKey }
        let key = try await Task.detached { try SSHCredentials.generatedKeyPair() }.value
        generatedKey = key
        return key
    }

    private func finalAuthentication() async throws -> SSHAuthentication {
        if let credential { return credential }
        if choice == .hetzner {
            guard let bootstrap else { throw AppError.unavailable("Setup lost its state. Start over.") }
            return bootstrap
        }
        switch authentication {
        case .generatedKey:
            let key = try await ensureKey()
            return .privateKey(contents: key.privateKey, passphrase: nil)
        case .password: return .password(password)
        case .privateKey: return .privateKey(contents: privateKey, passphrase: passphrase.isEmpty ? nil : passphrase)
        case .agent: return .agent(socketPath: agentSocket)
        }
    }

    /// The SFTP store, wrapped in the rclone-compatible crypt layer when encryption was chosen.
    private func makeStore(_ c: StorageConnection, auth: SSHAuthentication) throws -> (any RemoteStore, SFTPStore) {
        let base = SFTPStore(connection: c, authentication: auth, sessionBudgetURL: try sessionBudgetURL())
        guard !encryptionPassphrase.isEmpty else { return (base, base) }
        return (try CryptStore(base: base, password: encryptionPassphrase, password2: "", helperURL: SharedConfig.cryptHelperURL()), base)
    }

    /// Main-account sign-in: create the chosen folder under /home (each level; existing ones are kept).
    private func createMainFolder(_ c: StorageConnection, auth: SSHAuthentication) async throws {
        var top = c; top.rootPath = StorageBoxPath.sftpRoot
        let store = SFTPStore(connection: top, authentication: auth, sessionBudgetURL: try sessionBudgetURL())
        defer { Task { await store.disconnect() } }
        var path = ""
        for part in folder.split(separator: "/") {
            path += "/" + part
            do { try await store.createDirectory(path: path) } catch CoreKitError.alreadyExists { }
        }
    }

    private func makeConnection(model: AppModel) throws -> StorageConnection {
        switch choice {
        case .hetzner:
            guard let box = selectedBoxValue else { throw AppError.unavailable("Pick a Storage Box first.") }
            bootstrap = .password(mainPassword)
            if !plan.key { credential = .password(mainPassword) }
            return StorageConnection(name: displayName, provider: .hetzner, host: box.server, port: hetznerSFTPPort,
                                     username: box.username, rootPath: StorageBoxPath.sftpRoot + "/" + folder)
        case .sftp:
            if authentication == .generatedKey, !password.isEmpty { bootstrap = .password(password) }
            let root = try PathRules.normalize(remoteFolder.isEmpty ? defaultFolder : remoteFolder)
            return StorageConnection(name: displayName, provider: ServerAddress.isStorageBox(host) ? .hetzner : .sftp,
                                     host: host, port: port, username: user, rootPath: root)
        }
    }

    private func sessionBudgetURL() throws -> URL { try SharedConfig.directory().appendingPathComponent("ssh-session-budget") }

    private func removeTestFile(_ path: String, store: any RemoteStore) async throws {
        do { try await store.remove(path: path) } catch CoreKitError.notFound { }
    }

    var allDone: Bool { !steps.isEmpty && steps.allSatisfy { $0.state == .done } }
    /// Every step before saving has passed: the SFTP Connect button may run.
    var checkPassed: Bool {
        let before = steps.filter { $0.kind.rawValue < Step.Kind.save.rawValue }
        return !before.isEmpty && before.allSatisfy { $0.state == .done }
    }
    var failed: Bool { steps.contains { if case .failed = $0.state { true } else { false } } }
    var progress: Double { steps.isEmpty ? 0 : Double(steps.filter { $0.state == .done }.count) / Double(steps.count) }

    /// True when only the optional Finder step failed; the saved connection still works in the app.
    var finderStepFailed: Bool {
        guard saved != nil, let s = steps.first(where: { $0.kind == .mount }) else { return false }
        if case .failed = s.state { return true }
        return false
    }

    /// One plain sentence: what went wrong and what to try.
    static func plain(_ error: Error, step: Step.Kind, port: Int) -> String {
        let text = message(for: error)
        let lower = text.lowercased()
        if (error as? CryptStoreError) == .authenticationOrCorruption {
            return "This folder holds files this passphrase can’t open. Choose an empty folder, or the passphrase used before."
        }
        if step == .preflight, case .notFound? = error as? CoreKitError { return "The folder was not found. Check the folder on the server." }
        switch error as? CoreKitError {
        case .authenticationFailed?:
            return step == .installKey ? "The server refused the password. Check it and try again."
                : "The server refused the sign-in. Check the user name and the key or password."
        case .hostKeyMismatch?: return "The server’s key changed during setup. Stop and check with whoever runs the server."
        case .timeout?: return "The server did not answer in time. Check the address and your network."
        default: break
        }
        if lower.contains("refused") { return "Nothing answered on port \(port). Check the port, or that SSH is on." }
        if lower.contains("resolve") || lower.contains("nodename") || lower.contains("not known") { return "That server name was not found. Check the address." }
        return text
    }
}

/// `user@host:port` as typed, with an optional sftp:// prefix.
struct ServerAddress: Equatable {
    var user = ""
    var host = ""
    var port: Int?

    static func parse(_ raw: String) -> ServerAddress {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("sftp://") { text = String(text.dropFirst(7)) }
        if text.lowercased().hasPrefix("ssh://") { text = String(text.dropFirst(6)) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        var result = ServerAddress()
        if let at = text.lastIndex(of: "@") { result.user = String(text[..<at]); text = String(text[text.index(after: at)...]) }
        if let colon = text.lastIndex(of: ":"), let p = Int(text[text.index(after: colon)...]) {
            result.port = p; text = String(text[..<colon])
        }
        result.host = text
        return result
    }

    static func isStorageBox(_ host: String) -> Bool { host.lowercased().hasSuffix(".your-storagebox.de") }
}
