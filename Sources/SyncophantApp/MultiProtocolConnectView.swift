import SwiftUI
import CoreKit

/// Connect server: one adaptive form for SFTP, WebDAV, S3 and SMB, with a live connection check on the right.
/// Connect stays disabled until every check passes; nothing is saved before that.
struct ConnectServerView: View {
    static let kinds: [StorageKind] = [.sftp, .webdav, .s3, .smb]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kind: StorageKind = .sftp
    @State private var flow: ConnectModel = { let m = ConnectModel(); m.choice = .sftp; return m }()
    @State private var check = ServerCheck()
    @State private var webdav = StorageDraft(provider: .webdav)
    @State private var s3 = StorageDraft(provider: .s3, region: "us-east-1")
    @State private var smb = StorageDraft(provider: .smb)
    @State private var preset: S3Preset = .other
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
                .frame(width: 384)
                .disabled(checking || connecting)
            }
        }
        .task(id: app.connectUI.handoffID) { take() }
        .task { await flow.loadSSHHosts() }
        .onAppear { nearby.start() }
        .onDisappear {
            task?.cancel(); nearby.stop()
            app.connectUI.encryptionPassphrase = nil
            passphrase = ""; passphraseAgain = ""; flow.password = ""; flow.passphrase = ""
        }
        .onChange(of: signature) { invalidate() }
        .onChange(of: flow.server) { flow.applySSHMatch() }
        .onChange(of: s3.endpoint) { if let r = S3Preset.region(for: s3.endpoint) { s3.region = r } }
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
            preset = S3Preset.allCases.first { $0.matches(lower) } ?? .other
            if lower.hasPrefix("s3://") {
                let parts = text.dropFirst(5).split(separator: "/").map(String.init)
                s3.bucket = parts.first ?? ""
                if s3.endpoint.isEmpty { s3.endpoint = preset.endpoint }
            } else if let url = URL(string: text.contains("://") ? text : "https://" + text), let host = url.host {
                s3.endpoint = "https://" + host + (url.port.map { ":\($0)" } ?? "")
                if let first = url.pathComponents.dropFirst().first { s3.bucket = first }
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
        let cloud = ServerCheck.looksLikeNextcloud(webdav.endpoint)
        let product = webdav.endpoint.lowercased().contains("owncloud") || webdav.endpoint.lowercased().contains("remote.php/webdav") ? "ownCloud" : "Nextcloud"
        return VStack(alignment: .leading, spacing: 14) {
            LabeledField(label: "Address", text: $webdav.endpoint, prompt: "https://…", mono: true,
                         hint: cloud ? product : nil, hintTone: .green)
            LabeledField(label: "User name", text: $webdav.username)
            LabeledField(label: cloud ? "App password" : "Password", text: $webdav.password,
                         prompt: cloud ? "Create one in \(product) › Security" : "", secure: true,
                         hint: cloud ? "Not your login password" : nil)
        }
    }

    private var s3Fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Provider")
                HStack(spacing: 6) {
                    ForEach(S3Preset.allCases) { p in
                        Button(p.title) {
                            preset = p
                            if !p.endpoint.isEmpty || S3Preset.allCases.contains(where: { $0.endpoint == s3.endpoint }) { s3.endpoint = p.endpoint }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .foregroundStyle(preset == p ? Color.white : Color.primary)
                        .background(preset == p ? Color.accentColor : Fill.two, in: Capsule())
                        .accessibilityAddTraits(preset == p ? [.isSelected] : [])
                    }
                }
                .motion(Motion.snappy, value: preset)
            }
            LabeledField(label: "Endpoint", text: $s3.endpoint, prompt: preset.prompt, mono: true,
                         hint: !s3.endpoint.isEmpty && s3.endpoint == preset.endpoint ? "Filled in for you · change the region if yours differs" : nil)
            if preset == .other || S3Preset.region(for: s3.endpoint) == nil {
                LabeledField(label: "Region", text: $s3.region, prompt: "us-east-1", mono: true)
            }
            LabeledField(label: "Access key ID", text: $s3.username, mono: true)
            LabeledField(label: "Secret access key", text: $s3.password, secure: true, mono: true)
            LabeledField(label: "Bucket", text: $s3.bucket, prompt: "my-bucket", mono: true,
                         hint: S3Preset.region(for: s3.endpoint).map { "Region \($0)" })
        }
    }

    private var smbFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField(label: "Server", text: $smb.endpoint, prompt: "nas.local", mono: true,
                         hint: smb.endpoint.lowercased().hasSuffix(".local") ? "On your network" : nil, hintTone: .green)
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
            LabeledField(label: "User name", text: $smb.username)
            LabeledField(label: "Password", text: $smb.password, secure: true)
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
                                      .init(kind: .signIn, title: "Sign in"), .init(kind: .preflight, title: "Read and write 1 MB")] : visible
        }
        if !check.steps.isEmpty { return check.steps }
        return [.init(kind: .reach, title: "Reach the server")]
            + (kind == .smb ? [] : [.init(kind: .secure, title: "Secure connection")])
            + [.init(kind: .signIn, title: "Sign in"), .init(kind: .preflight, title: "Read and write 1 MB")]
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
        get { switch kind { case .s3: s3; case .smb: smb; default: webdav } }
    }

    private func setDraft(_ change: (inout StorageDraft) -> Void) {
        switch kind { case .s3: change(&s3); case .smb: change(&smb); default: change(&webdav) }
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
            let a = webdav.endpoint.lowercased()
            return a.contains("owncloud") ? "ownCloud" : ServerCheck.looksLikeNextcloud(a) ? "Nextcloud" : "WebDAV"
        case .s3: return s3.bucket.isEmpty ? "S3 bucket" : s3.bucket
        case .smb: return smb.share.isEmpty ? "Shared folder" : smb.share
        case .hetzner: return ""
        }
    }

    private var problems: [String] { kind == .sftp ? [] : draft.problems }

    /// Everything a check depends on (not the friendly name). Any change invalidates a finished check.
    private var signature: String {
        let d = draft
        let sftp = [flow.server, flow.remoteFolder, flow.authentication.rawValue, flow.password, flow.privateKey, flow.passphrase, flow.agentSocket]
        let other = [d.endpoint, d.username, d.password, d.bucket, d.region, d.share, d.rootPath]
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
        case .hetzner: ""
        }
    }

    private var subtitle: String {
        switch kind {
        case .sftp: "Anything you can reach with ssh, including a Storage Box sub-account."
        case .webdav: "Nextcloud, ownCloud, Synology, or a Storage Box over HTTPS."
        case .s3: "Pick a provider and the endpoint fills itself in."
        case .smb: "A NAS or another Mac on your network."
        case .hetzner: ""
        }
    }

    private func tabTitle(_ k: StorageKind) -> String {
        switch k { case .sftp: "SFTP"; case .webdav: "WebDAV"; case .s3: "S3"; case .smb: "SMB"; case .hetzner: "Hetzner" }
    }
}
