import SwiftUI
import CoreKit

// Shared pieces of the setup windows (Add storage, Connect Hetzner, Connect server): solid body, footer,
// form fields, the live checklist row, the host-key card and the SFTP sign-in cards.

// MARK: - Window chrome

extension View {
    /// 820 × 700 setup window with a solid body (never glass) and no visible title text.
    func setupWindow() -> some View {
        frame(width: 820, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// 68 pt footer with a hairline on top.
struct SetupFooter<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .frame(height: 68)
            .overlay(alignment: .top) { Divider() }
    }
}

/// Lock glyph and a short Keychain promise, left of the footer buttons.
struct KeychainNote: View {
    var text = "Passwords and tokens stay in your Keychain"
    var body: some View {
        Label(text, systemImage: "lock")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
    }
}

/// 64 pt gradient tile with a white symbol, above a setup title.
struct HeroIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: color.opacity(0.35), radius: 13, y: 10)
            .accessibilityHidden(true)
    }
}

// MARK: - Form fields

/// 12 pt semibold secondary label above a field. Labels are never monospaced.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
}

/// The rounded flat box a setup text field sits in (36 pt; 54 pt for the hero field).
struct FieldBox<Content: View>: View {
    var height: CGFloat = 36
    var focused = false
    var tint: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height >= 50 ? 16 : 10, style: .continuous)
        HStack(spacing: height >= 50 ? 12 : 8) { content }
            .textFieldStyle(.plain)
            .padding(.horizontal, height >= 50 ? 16 : 11)
            .frame(height: height)
            .background(Fill.one, in: shape)
            .overlay(shape.strokeBorder(tint ?? (focused ? Color.accentColor : Color(nsColor: .separatorColor)), lineWidth: tint != nil || focused ? 1.5 : 0.5))
    }
}

/// A labelled one-line field, optionally secure, with a trailing hint.
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    var mono = false
    var hint: String? = nil
    var hintTone: Tone = .neutral
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            FieldBox {
                Group {
                    if secure { SecureField(label, text: $text, prompt: Text(prompt)) }
                    else { TextField(label, text: $text, prompt: Text(prompt)) }
                }
                .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                .autocorrectionDisabled()
                if let hint, !hint.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundStyle(hintTone == .neutral ? AnyShapeStyle(.tertiary) : AnyShapeStyle(hintTone.text))
                        .lineLimit(1).fixedSize()
                }
            }
        }
    }
}

// MARK: - Checklist row

/// One task of a live checklist: waiting → working → done (or failed with a plain reason).
struct CheckRow: View {
    let step: ConnectModel.Step
    var height: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                icon.frame(width: 20, height: 20)
                Text(step.title).font(.system(size: 13)).foregroundStyle(failed ? Palette.failure : .primary)
                Spacer(minLength: 8)
                if !step.note.isEmpty, step.state == .done || step.state == .awaitingApproval {
                    Text(step.note).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                        .transition(.opacity)
                }
            }
            .frame(minHeight: height)
            if case .failed(let reason) = step.state {
                Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.failure)
                    .padding(.leading, 30).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(step.state == .pending ? 0.55 : 1)
        .motion(Motion.smooth, value: step.state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateWords)
    }

    private var failed: Bool { if case .failed = step.state { true } else { false } }

    private var stateWords: String {
        switch step.state {
        case .pending: "Waiting"
        case .running: "Working"
        case .awaitingApproval: "Needs you"
        case .done: "Done"
        case .failed(let r): "Failed: \(r)"
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending: Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 10, height: 10)
        case .running: ProgressView().controlSize(.small)
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(Palette.caution)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green).transition(.scale.combined(with: .opacity))
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.red)
        }
    }
}

// MARK: - Host key

/// "Is this your server?": the fingerprint as a picture plus its SHA-256 text. A changed key shows both pictures
/// side by side. Storage Box keys can only be trusted when they match Hetzner's published list.
struct HostKeyCard: View {
    @Environment(AppModel.self) private var app
    var flow: ConnectModel
    /// Connect server puts Trust and Continue on its main check button instead.
    var showsTrustButton = true

    var body: some View {
        if let fp = flow.fingerprint {
            VStack(alignment: .leading, spacing: 10) {
                Text(flow.previousFingerprint == nil ? "Is this your server?" : "This server’s key has changed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(flow.previousFingerprint == nil ? Color.primary : Palette.failure)
                if let old = flow.previousFingerprint {
                    HStack(spacing: 12) {
                        VStack(spacing: 4) { HostKeyIdenticon(fingerprint: old, size: 64); Text("Before").font(.caption2).foregroundStyle(.secondary) }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        VStack(spacing: 4) { HostKeyIdenticon(fingerprint: fp, size: 64); Text("Now").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text("Someone may be pretending to be your server. Connect is blocked until you choose. Ask whoever runs it whether the key was replaced.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 12) {
                        HostKeyIdenticon(fingerprint: fp, size: 72)
                        Text(explanation).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if flow.targetIsHetzner {
                    Label(flow.officialFingerprintMatches ? "Matches Hetzner’s published key" : "Does not match Hetzner’s published keys",
                          systemImage: flow.officialFingerprintMatches ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(flow.officialFingerprintMatches ? Palette.verified : Palette.failure)
                }
                Text(fp).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if flow.steps.contains(where: { $0.kind == .hostKey && $0.state == .awaitingApproval }) {
                    if flow.canTrustKey {
                        if showsTrustButton {
                        Button(flow.previousFingerprint == nil ? "Trust and Continue" : "Trust the New Key") { flow.approveHostKey(model: app) }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        Link("Hetzner’s published keys", destination: URL(string: "https://docs.hetzner.com/storage/storage-box/general/#ssh-host-keys")!)
                            .font(.system(size: 11.5))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }

    private var explanation: String {
        if flow.targetIsHetzner {
            return flow.officialFingerprintMatches
                ? "First time connecting. Hetzner lists the same fingerprint for Storage Boxes, so this matches."
                : "This key is not one Hetzner publishes for Storage Boxes. Don’t continue."
        }
        return "First time connecting. Compare this picture with your server’s key. Once trusted, Syncophant stops if it ever changes."
    }
}

// MARK: - SFTP sign-in cards

/// Key for this Mac · Key from ~/.ssh · SSH agent · Password, as a 2 × 2 radio group, with the selected card's
/// explanation (and its one action) below.
struct SignInCards: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Sign in with")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ConnectModel.Authentication.allCases) { card($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sign in with")
            detail
        }
    }

    private func card(_ a: ConnectModel.Authentication) -> some View {
        let on = flow.authentication == a
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button { flow.authentication = a } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(a))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint(a), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(a)).font(.system(size: 12.5, weight: .semibold))
                    Text(subtitle(a)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.16) : Fill.one, in: shape)
            .overlay(shape.strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: on)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityHint(a == .generatedKey ? "Recommended" : "")
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch flow.authentication {
                case .generatedKey: Button("Copy Public Key") { Task { await flow.copyPublicKey(model: app) } }.buttonStyle(.glass).controlSize(.small)
                case .privateKey: Button(flow.privateKeyName.isEmpty ? "Choose Key…" : "Choose Another…") { flow.choosePrivateKey() }.buttonStyle(.glass).controlSize(.small)
                default: EmptyView()
                }
            }
            switch flow.authentication {
            case .generatedKey:
                FieldBox(height: 30) { SecureField("Server password", text: $flow.password, prompt: Text("Server password, used once to add the key (optional)")) }
            case .privateKey:
                if !flow.privateKey.isEmpty { FieldBox(height: 30) { SecureField("Key passphrase", text: $flow.passphrase, prompt: Text("Key passphrase, if it has one")) } }
                if let e = flow.keyError { Text(e).font(.system(size: 11.5)).foregroundStyle(Palette.failure) }
            case .agent:
                FieldBox(height: 30) {
                    TextField("Agent socket", text: $flow.agentSocket, prompt: Text("Agent socket path")).font(.system(size: 12, design: .monospaced))
                }
            case .password:
                FieldBox(height: 30) { SecureField("Password", text: $flow.password, prompt: Text("Password")) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .id(flow.authentication)
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    private var explanation: String {
        switch flow.authentication {
        case .generatedKey:
            "A new ed25519 key is created in your Keychain. Copy the public key to the server once, or enter the password and Syncophant adds it for you."
        case .privateKey:
            flow.privateKeyName.isEmpty ? "Choose a private key, usually in ~/.ssh. It is copied into your Keychain after sign-in."
                : "Uses \(flow.privateKeyName)\(flow.sshMatch.map { ", matched from Host \($0.alias) in your ssh config" } ?? ""). It is copied into your Keychain after sign-in."
        case .agent:
            "Uses \(agentName). Your agent may ask you to approve each connection. Finder may not reach some agents; a key always works."
        case .password:
            "Works, but a key is safer and never expires. You can switch later in Settings."
        }
    }

    private var agentName: String {
        let s = flow.agentSocket.lowercased()
        if s.contains("1password") { return "1Password’s agent" }
        if s.contains("secretive") { return "Secretive’s agent" }
        return flow.agentSocket.isEmpty ? "no agent yet: enter its socket path" : "the agent at \((flow.agentSocket as NSString).abbreviatingWithTildeInPath)"
    }

    private func symbol(_ a: ConnectModel.Authentication) -> String {
        switch a { case .generatedKey: "key.fill"; case .privateKey: "doc.text"; case .agent: "lock.shield"; case .password: "lock.fill" }
    }
    private func tint(_ a: ConnectModel.Authentication) -> Color {
        switch a { case .generatedKey: .green; case .privateKey: .accentColor; case .agent: .purple; case .password: .gray }
    }
    private func title(_ a: ConnectModel.Authentication) -> String {
        switch a { case .generatedKey: "Key for this Mac"; case .privateKey: "Key from ~/.ssh"; case .agent: "SSH agent"; case .password: "Password" }
    }
    private func subtitle(_ a: ConnectModel.Authentication) -> String {
        switch a {
        case .generatedKey: "Made and stored for you"
        case .privateKey: flow.privateKeyName.isEmpty ? "Your own key file" : flow.privateKeyName + (flow.sshMatch != nil ? " · from ssh config" : "")
        case .agent: "1Password, Secretive, ssh-agent"
        case .password: "Saved in Keychain"
        }
    }
}
