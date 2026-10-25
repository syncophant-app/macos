import SwiftUI
import CoreKit

/// Connect server: one adaptive form for SFTP, WebDAV, S3, SMB and cloud drives, with a live connection check on the right.
/// Connect stays disabled until every check passes; nothing is saved before that.
struct ConnectServerView: View {
    static let kinds: [StorageKind] = [.sftp, .webdav, .s3, .smb, .cloud]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kind: StorageKind = .sftp
    @State private var flow: ConnectModel = { let m = ConnectModel(); m.choice = .sftp; return m }()
    @State private var check = ServerCheck()
    @State private var webdav = StorageDraft(provider: .webdav)
    @State private var s3 = StorageDraft(provider: .s3, region: "us-east-1")
    @State private var smb = StorageDraft(provider: .smb)
    @State private var cloud = StorageDraft(provider: .dropbox)
    @State private var signingIn = false
    @State private var signInError: String?
    @State private var signInTask: Task<Void, Never>?
    @State private var s3Service = ServicePreset.generic(.s3)
    @State private var webdavService = ServicePreset.generic(.webdav)
    @State private var smbService = ServicePreset.generic(.smb)
    @State private var nearby = NearbySMB()
    @State private var encryptionOpen = false
    @State private var passphrase = ""
    @State private var passphraseAgain = ""
    @State private var connecting = false
    @State private var connectError: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    form.padding(.bottom, 16)
                        .id(kind)
                        .transition(reduceMotion ? .opacity : .offset(x: 24).combined(with: .opacity))
                }
                .scrollBounceBehavior(.basedOnSize)
                .disabled(checking || connecting)
                checkCard.frame(width: 270)
            }
            .padding(.horizontal, 40).padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(Motion.resolve(Motion.smooth, reduceMotion: reduceMotion), value: kind)
            footer
        }
        .setupWindow()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Storage type", selection: $kind) {
                    ForEach(Self.kinds) { Label(tabTitle($0), systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 470)
                .disabled(checking || connecting)
            }
        }
        .task(id: app.connectUI.handoffID) { take() }
        .task { await flow.loadSSHHosts() }
        .onAppear { nearby.start() }
        .onDisappear {
            task?.cancel(); signInTask?.cancel(); nearby.stop()
            app.connectUI.encryptionPassphrase = nil
            passphrase = ""; passphraseAgain = ""; flow.password = ""; flow.passphrase = ""
        }
        .onChange(of: signature) { invalidate() }
        .onChange(of: flow.server) { flow.applySSHMatch() }
        .onChange(of: s3.endpoint) {
            if let r = ServicePreset.region(for: s3.endpoint) { s3.region = r }
            if let p = ServicePreset.match(s3.endpoint, provider: .s3) { s3Service = p }
        }
        .onChange(of: webdav.endpoint) { if let p = ServicePreset.match(webdav.endpoint, provider: .webdav) { webdavService = p } }
        .onChange(of: cloud.provider) { cloud.token = nil; cloud.account = ""; signInError = nil }
        .onChange(of: cloud.clientID) { cloud.token = nil; cloud.account = "" }
        .onChange(of: cloud.clientSecret) { cloud.token = nil; cloud.account = "" }
        .onChange(of: smb.endpoint) { if let p = ServicePreset.match(smb.endpoint, provider: .smb) { smbService = p } }
        .onChange(of: sftpFinished) { _, finished in if finished { finishSFTP() } }
        .onChange(of: flow.running) { _, running in if !running, connecting, kind == .sftp, !sftpFinished { connecting = false } }
    }

    // MARK: Hand-off from Add storage

    private func take() {
        guard let h = app.connectUI.take(), Self.kinds.contains(h.kind) else { return }
        kind = h.kind
        let text = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch h.kind {
        case .sftp: flow.server = text
        case .webdav: webdav.endpoint = text
        case .smb:
            let parts = text.replacingOccurrences(of: "smb://", with: "", options: [.caseInsensitive, .anchored]).split(separator: "/").map(String.init)
            smb.endpoint = parts.first ?? ""
            if parts.count > 1 { smb.share = parts[1] }
            if parts.count > 2 { smb.rootPath = "/" + parts.dropFirst(2).joined(separator: "/") }
        case .s3:
            let lower = text.lowercased()
            s3Service = ServicePreset.match(text, provider: .s3) ?? .generic(.s3)
            if lower.hasPrefix("s3://") {
                let parts = text.dropFirst(5).split(separator: "/").map(String.init)
                s3.bucket = parts.first ?? ""
                if s3.endpoint.isEmpty { s3.endpoint = s3Service.endpoint }
            } else if let url = URL(string: text.contains("://") ? text : "https://" + text), let host = url.host {
                s3.endpoint = "https://" + host + (url.port.map { ":\($0)" } ?? "")
                if let first = url.pathComponents.dropFirst().first { s3.bucket = first }
            }
        case .cloud:
            if let service = OAuthService.allCases.first(where: { s in s.webDomains.contains { ServicePreset.host(of: text).hasSuffix($0) } }) {
                cloud.provider = service.provider
            }
        case .hetzner: break
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 21, weight: .bold)).tracking(-0.4).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            switch kind {
            case .sftp: sftpFields
            case .webdav: webdavFields
            case .s3: s3Fields
            case .smb: smbFields
            case .cloud: cloudFields
            case .hetzner: EmptyView()
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Folder on the server")
                    FieldBox {
                        Image(systemName: "folder").foregroundStyle(.tertiary).accessibilityHidden(true)
                        TextField("Folder on the server", text: folderBinding, prompt: Text(kind == .sftp ? flow.defaultFolder : "/"))
                            .font(.system(size: 12.5, design: .monospaced))
                    }
                }
                LabeledField(label: "Name on this Mac", text: nameBinding, prompt: suggestedName)
            }
            encryptionRow
            ForEach(problems, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Palette.caution)
            }
        }
    }

    private var sftpFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField(label: "Server", text: $flow.server, prompt: "user@host:port", mono: true,
                         hint: flow.address.host.isEmpty ? nil : flow.portHint,
                         hintTone: flow.address.port != nil || flow.sshMatch != nil ? .green : .neutral)
            if flow.user.isEmpty, !flow.address.host.isEmpty {
                Text("Add the user name: user@\(flow.address.host)").font(.system(size: 11.5)).foregroundStyle(Palette.caution)
            }
            SignInCards(flow: flow)
        }
    }

    private var webdavFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerPicker(.webdav, selection: $webdavService, endpoint: $webdav.endpoint)
            LabeledField(label: "Address", text: $webdav.endpoint, prompt: webdavService.prompt.isEmpty ? "https://…" : webdavService.prompt,
                         mono: true, caption: webdavService.note)
            LabeledField(label: webdavService.user, text: $webdav.username)
            LabeledField(label: webdavService.secret, text: $webdav.password, secure: true,
                         caption: webdavService.secretHint.map { "\($0). Not your login password." })
        }
    }

    private var s3Fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerPicker(.s3, selection: $s3Service, endpoint: $s3.endpoint)
            LabeledField(label: "Endpoint", text: $s3.endpoint, prompt: s3Service.prompt.isEmpty ? "https://s3.example.com" : s3Service.prompt, mono: true,
                         caption: !s3.endpoint.isEmpty && s3.endpoint == s3Service.endpoint ? "Filled in for you. Change the region in the address if yours differs." : s3Service.note)
            if ServicePreset.region(for: s3.endpoint) == nil {
                LabeledField(label: "Region", text: $s3.region, prompt: "us-east-1", mono: true)
            }
            LabeledField(label: s3Service.user, text: $s3.username, mono: true)
            LabeledField(label: s3Service.secret, text: $s3.password, secure: true, mono: true)
            LabeledField(label: "Bucket", text: $s3.bucket, prompt: "my-bucket", mono: true,
                         hint: ServicePreset.region(for: s3.endpoint).map { "Region \($0)" })
        }
    }

    /// Named services for one protocol. Picking one fills in its address unless the person typed their own.
    private func providerPicker(_ provider: StorageProvider, selection: Binding<ServicePreset>, endpoint: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Provider")
            Picker("Provider", selection: Binding(get: { selection.wrappedValue }, set: { picked in
                let typed = endpoint.wrappedValue
                selection.wrappedValue = picked
                if typed.isEmpty || ServicePreset.all.contains(where: { $0.endpoint == typed }) { endpoint.wrappedValue = picked.endpoint }
            })) {
                ForEach(ServicePreset.presets(for: provider)) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    private var cloudService: OAuthService { cloud.provider.oauthService ?? .dropbox }

    private var cloudFields: some View {
        let service = cloudService
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Provider")
                HStack(spacing: 8) {
                    Picker("Provider", selection: Binding(get: { service }, set: { cloud.provider = $0.provider })) {
                        ForEach(OAuthService.allCases) { Text($0.isExperimental ? "\($0.title) (Experimental)" : $0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    if service.isExperimental { ExperimentalBadge() }
                }
                if service.isExperimental {
                    Text("Google Drive allows several files with the same name and can’t refuse an outdated change, so Syncophant checks these itself. A change made elsewhere at the same moment can be lost. Files that share a name are hidden, and Google Docs are skipped.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Use your own \(service.title) app")
                ForEach(Array(service.setupSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
                Link("Open the \(service.title) developer console", destination: service.consoleURL).font(.system(size: 12))
            }
            HStack(alignment: .bottom, spacing: 8) {
                LabeledField(label: "Redirect URI", text: .constant(OAuthService.redirectURI), mono: true)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OAuthService.redirectURI, forType: .string)
                }
                .buttonStyle(.glass).padding(.bottom, 4)
            }
            LabeledField(label: service == .dropbox ? "App key" : "Client ID", text: $cloud.clientID, mono: true)
            if service.requiresSecret {
                LabeledField(label: "Client secret", text: $cloud.clientSecret, secure: true, mono: true,
                             caption: "Stays in your Keychain and is sent only to \(service.title).")
            }
            HStack(spacing: 10) {
                Button(signingIn ? "Waiting for your browser…" : cloud.token == nil ? "Sign In with \(service.title)…" : "Sign In Again…", action: signIn)
                    .buttonStyle(.glass)
                    .disabled(signingIn || app.isDemo || cloud.clientID.isEmpty || (service.requiresSecret && cloud.clientSecret.isEmpty))
                if signingIn { Button("Cancel") { signInTask?.cancel() }.buttonStyle(.glass) }
                if cloud.token != nil, !signingIn {
                    Label(cloud.account, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                }
            }
            if let signInError { Text(signInError).font(.system(size: 11.5)).foregroundStyle(Palette.failure) }
        }
    }

    private func signIn() {
        signInError = nil
        signingIn = true
        let service = cloudService
        let client = OAuthClient(clientID: cloud.clientID, clientSecret: service.requiresSecret ? cloud.clientSecret : nil)
        signInTask = Task {
            defer { signingIn = false }
            do {
                let result = try await CloudSignIn.run(service, client: client)
                cloud.token = result.token
                cloud.account = result.account
            } catch is CancellationError {
            } catch { signInError = message(for: error) }
        }
    }

    private var smbFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerPicker(.smb, selection: $smbService, endpoint: $smb.endpoint)
            LabeledField(label: "Server", text: $smb.endpoint, prompt: smbService.prompt, mono: true,
                         hint: smb.endpoint.lowercased().hasSuffix(".local") ? "On your network" : nil, hintTone: .green,
                         caption: smbService.note)
            if !nearby.names.isEmpty {
                HStack(spacing: 6) {
                    Text("Nearby").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    ForEach(nearby.names.prefix(4), id: \.self) { name in
                        Button(name) { Task { if let host = await NearbySMB.resolve(name) { smb.endpoint = host } } }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                }
            }
            LabeledField(label: "Share", text: $smb.share, prompt: "Files")
            LabeledField(label: smbService.user, text: $smb.username)
            LabeledField(label: smbService.secret, text: $smb.password, secure: true)
        }
    }

    // MARK: Encryption

    /// Opens the Encryption window; until that window can hand back a passphrase (`connectUI.encryptionPassphrase`)
    /// the row also expands to a passphrase and its confirmation, because rclone-compatible encryption must be chosen
    /// before the first connect.
    private var encryptionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(Motion.resolve(Motion.smooth)) { encryptionOpen.toggle() } } label: {
                HStack(spacing: 12) {
                    KindIcon(symbol: "lock.fill", color: .purple, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("End-to-end encryption").font(.system(size: 12.5, weight: .semibold))
                        Text(encryptionStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).rotationEffect(.degrees(encryptionOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(encryptionStatus)
            if encryptionOpen {
                VStack(alignment: .leading, spacing: 8) {
                    if app.connectUI.encryptionPassphrase != nil {
                        Text("Using the passphrase from the Encryption window.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        FieldBox(height: 30) { SecureField("Passphrase", text: $passphrase, prompt: Text("Passphrase")) }
                        if !passphrase.isEmpty {
                            StrengthMeter(strength: PassphraseStrength.evaluate(passphrase))
                            FieldBox(height: 30, tint: passphraseAgain.isEmpty ? nil : (passphraseAgain == passphrase ? .green : .red)) {
                                SecureField("Type it again", text: $passphraseAgain, prompt: Text("Type it again"))
                            }
                        }
                        Label("Nobody can recover a forgotten passphrase, not even Syncophant. Choose an empty folder.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.caution)
                    }
                    Button("Open Encryption Setup…") { app.open(.encryption) }.buttonStyle(.glass).controlSize(.small)
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var encryptionSecret: String {
        if let p = app.connectUI.encryptionPassphrase, !p.isEmpty { return p }
        return passphrase.isEmpty || passphrase != passphraseAgain || PassphraseStrength.evaluate(passphrase).segments < 3 ? "" : passphrase
    }
    private var encryptionPending: Bool { app.connectUI.encryptionPassphrase == nil && !passphrase.isEmpty && encryptionSecret.isEmpty }
    private var encryptionStatus: String {
        if !encryptionSecret.isEmpty { return "On. Names and contents are locked before they leave this Mac." }
        if encryptionPending { return "Not on yet. Finish the passphrase: at least Okay, typed twice." }
        return "Off. The server can read file names and contents."
    }

    // MARK: Connection check

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection check").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 2) {
                ForEach(checkSteps) { CheckRow(step: $0) }
            }
            .accessibilityElement(children: .contain)
            if kind == .sftp, flow.fingerprint != nil, flow.steps.contains(where: { $0.kind == .hostKey && $0.state != .pending }) {
                HostKeyCard(flow: flow, showsTrustButton: false)
            }
            if passed, let latency = currentLatency, let roundTrip = currentRoundTrip {
                Label("Ready. \(NetProbe.milliseconds(latency)) away, 1 MB round trip in \(NetProbe.seconds(roundTrip)).", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if let connectError { Text(connectError).font(.system(size: 11.5)).foregroundStyle(Palette.failure) }
            Button(checkLabel, action: runCheck)
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                .disabled(!checkEnabled)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .motion(Motion.smooth, value: checkSteps)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection check")
    }

    /// Before the first check, the four steps wait; afterwards they show what happened.
    private var checkSteps: [ConnectModel.Step] {
        if kind == .sftp {
            let visible = flow.steps.filter { $0.kind.rawValue < ConnectModel.Step.Kind.save.rawValue || $0.state != .pending }
            return visible.isEmpty ? [.init(kind: .reach, title: "Reach the server"), .init(kind: .hostKey, title: "Confirm its fingerprint"),
                                      .init(kind: .signIn, title: "Sign in"), .init(kind: .preflight, title: "Test safe reads and writes")] : visible
        }
        if !check.steps.isEmpty { return check.steps }
        return [.init(kind: .reach, title: "Reach the server")]
            + (kind == .smb ? [] : [.init(kind: .secure, title: "Secure connection")])
            + [.init(kind: .signIn, title: "Sign in"), .init(kind: .preflight, title: "Test safe reads and writes")]
    }

    private var checking: Bool { kind == .sftp ? flow.running : check.running }
    private var awaitingTrust: Bool { kind == .sftp && flow.steps.contains { $0.kind == .hostKey && $0.state == .awaitingApproval } }
    private var passed: Bool { kind == .sftp ? flow.checkPassed : check.passed }
    private var currentLatency: TimeInterval? { kind == .sftp ? flow.latency : check.latency }
    private var currentRoundTrip: TimeInterval? { kind == .sftp ? flow.roundTrip : check.roundTrip }

    private var checkLabel: String {
        if awaitingTrust { return flow.previousFingerprint == nil ? "Trust and Continue" : "Trust the New Key" }
        if checking { return "Checking…" }
        let ran = kind == .sftp ? !flow.steps.isEmpty : !check.steps.isEmpty
        return ran ? "Check Again" : "Check Connection"
    }

    private var checkEnabled: Bool {
        if app.isDemo || connecting { return false }
        if awaitingTrust { return flow.canTrustKey && !flow.running }
        return !checking && inputReady
    }

    private var inputReady: Bool {
        guard !encryptionPending else { return false }
        switch kind {
        case .sftp: return flow.sftpValid
        case .webdav: return webdav.complete
        case .s3: return s3.complete
        case .smb: return smb.complete
        case .cloud: return cloud.complete
        case .hetzner: return false
        }
    }

    private func runCheck() {
        connectError = nil
        if awaitingTrust { flow.approveHostKey(model: app); return }
        if kind == .sftp {
            flow.encryptionPassphrase = encryptionSecret
            flow.begin(model: app)
        } else {
            var d = draft
            d.name = d.name.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName : d.name
            d.encryptionPassword = encryptionSecret
            task = Task { await check.run(d, model: app) }
        }
    }

    // MARK: Footer and Connect

    private var footer: some View {
        SetupFooter {
            Button("Back") { app.open(.addStorage); dismiss() }.buttonStyle(.glass)
            Spacer()
            if app.isDemo { Text("Demo mode connects to no servers.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            else if !passed { Text("Connect unlocks when every check passes").font(.system(size: 11.5)).foregroundStyle(.tertiary) }
            Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            Button(connecting ? "Connecting…" : "Connect", action: connect)
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .frame(minWidth: 110)
                .disabled(!passed || connecting || app.isDemo)
        }
    }

    private func connect() {
        connectError = nil
        if kind == .sftp {
            if flow.name.trimmingCharacters(in: .whitespaces).isEmpty { flow.name = suggestedName }
            connecting = true
            flow.resume(model: app)
            return
        }
        guard let verified = check.verified else { return }
        var connection = verified.connection
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        connection.name = typed.isEmpty ? suggestedName : typed
        connecting = true
        task = Task {
            defer { connecting = false }
            do {
                try await app.saveStorage(connection, credentials: verified.credentials, store: verified.store)
                app.connectUI.encryptionPassphrase = nil
                dismiss()
            } catch { connectError = message(for: error) }
        }
    }

    /// The SFTP save and Finder steps after Connect; closes when saved (Finder trouble is reported, not blocking).
    private var sftpFinished: Bool { flow.saved != nil && !flow.running && (flow.allDone || flow.finderStepFailed) }

    private func finishSFTP() {
        connecting = false
        app.connectUI.encryptionPassphrase = nil
        if flow.finderStepFailed { app.say("\(flow.displayName) is connected. Adding it to Finder did not finish; try again from Settings.", error: true) }
        dismiss()
    }

    // MARK: Draft plumbing

    private var draft: StorageDraft {
        get { switch kind { case .s3: s3; case .smb: smb; case .cloud: cloud; default: webdav } }
    }

    private func setDraft(_ change: (inout StorageDraft) -> Void) {
        switch kind { case .s3: change(&s3); case .smb: change(&smb); case .cloud: change(&cloud); default: change(&webdav) }
    }

    private var folderBinding: Binding<String> {
        kind == .sftp ? $flow.remoteFolder
            : Binding(get: { draft.rootPath == "/" ? "" : draft.rootPath }, set: { v in setDraft { $0.rootPath = v.isEmpty ? "/" : v } })
    }

    private var nameBinding: Binding<String> {
        kind == .sftp ? $flow.name : Binding(get: { draft.name }, set: { v in setDraft { $0.name = v } })
    }

    private var suggestedName: String {
        switch kind {
        case .sftp: return flow.suggestedName
        case .webdav:
            return webdavService.isGeneric ? "WebDAV" : webdavService.title
        case .s3: return s3.bucket.isEmpty ? "S3 bucket" : s3.bucket
        case .smb: return smb.share.isEmpty ? "Shared folder" : smb.share
        case .cloud: return cloudService.title
        case .hetzner: return ""
        }
    }

    private var problems: [String] { kind == .sftp ? [] : draft.problems }

    /// Everything a check depends on (not the friendly name). Any change invalidates a finished check.
    private var signature: String {
        let d = draft
        let sftp = [flow.server, flow.remoteFolder, flow.authentication.rawValue, flow.password, flow.privateKey, flow.passphrase, flow.agentSocket]
        let other = [d.provider.rawValue, d.endpoint, d.username, d.password, d.bucket, d.region, d.share, d.rootPath,
                     d.clientID, d.clientSecret, d.token?.refreshToken ?? ""]
        return ([kind.rawValue, encryptionSecret] + (kind == .sftp ? sftp : other)).joined(separator: "\u{1F}")
    }

    private func invalidate() {
        guard !connecting else { return }
        task?.cancel()
        if !flow.running { flow.reset() }
        check.reset()
        connectError = nil
    }

    private var title: String {
        switch kind {
        case .sftp: "Connect an SFTP server"
        case .webdav: "Connect a WebDAV server"
        case .s3: "Connect an S3-compatible bucket"
        case .smb: "Connect a shared folder"
        case .cloud: "Connect a cloud drive"
        case .hetzner: ""
        }
    }

    private var subtitle: String {
        switch kind {
        case .sftp: "Anything you can reach with ssh, including a Storage Box sub-account."
        case .webdav: "Nextcloud, pCloud, Koofr, kDrive, a NAS or any WebDAV server over HTTPS."
        case .s3: "AWS, R2, B2, Hetzner, Wasabi and more. Pick one and the endpoint fills itself in."
        case .smb: "A NAS or another Mac on your network, or an Azure file share."
        case .cloud: "Dropbox, OneDrive, Box or Google Drive, signed in with your own app keys."
        case .hetzner: ""
        }
    }

    private func tabTitle(_ k: StorageKind) -> String {
        switch k { case .sftp: "SFTP"; case .webdav: "WebDAV"; case .s3: "S3"; case .smb: "SMB"; case .cloud: "Cloud"; case .hetzner: "Hetzner" }
    }
}

/// Marks a provider whose safety checks are weaker than the others.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Palette.caution, in: Capsule())
            .accessibilityLabel("Experimental")
    }
}
