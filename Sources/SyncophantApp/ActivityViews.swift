import SwiftUI
import CoreKit

extension Transfer.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

// MARK: - Sheets

/// Shows the server's key as a picture. When it changed, the approved and the new key sit side by side,
/// and the connection stays blocked until the person decides.
struct HostKeyReview: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let connectionID: UUID
    @State private var fingerprint: String?
    @State private var error: String?
    @State private var understood = false

    private var connection: StorageConnection? { app.connections.first { $0.id == connectionID } }
    private var changed: Bool { connection?.hostKeyFingerprint != nil && fingerprint != nil && connection?.hostKeyFingerprint != fingerprint }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(changed ? "The server key changed" : "Server key for \(connection?.name ?? "this storage")")
                    .font(.system(size: 17, weight: .bold))
                if let c = connection {
                    Text("\(c.name) · \(c.host) · port \(c.port)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let fp = fingerprint {
                if changed, let pinned = connection?.hostKeyFingerprint {
                    HStack(alignment: .top, spacing: 20) {
                        key(pinned, caption: "You approved", tone: .neutral)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 40).accessibilityHidden(true)
                        key(fp, caption: "The server shows now", tone: .red)
                    }
                    .frame(maxWidth: .infinity)
                    Label("The pictures don’t match. This can mean the server was reinstalled, or that someone is intercepting the connection. Check with your provider before trusting it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.failure)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I checked with my provider and want to trust the new key", isOn: $understood)
                } else {
                    key(fp, caption: connection?.hostKeyFingerprint == nil ? "First connection" : "Matches the key you approved",
                        tone: connection?.hostKeyFingerprint == nil ? .neutral : .green)
                        .frame(maxWidth: .infinity)
                }
            } else if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(Palette.failure)
            } else {
                ProgressView("Asking the server for its key…").frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(changed ? "Trust New Key" : "Trust This Key") {
                    if let fp = fingerprint { app.approveHostKey(fp, for: connectionID); dismiss() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(fingerprint == nil || (changed && !understood) || connection?.hostKeyFingerprint == fingerprint)
            }
        }
        .padding(Space.lg)
        .frame(width: 520)
        .task { await probe() }
    }

    private func key(_ fingerprint: String, caption: String, tone: Tone) -> some View {
        VStack(spacing: 8) {
            HostKeyIdenticon(fingerprint: fingerprint, size: 96, showsText: true)
            Text(caption).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.text)
        }
    }

    private func probe() async {
        guard !app.isDemo else { error = "Host key checks are disabled in demo mode."; return }
        guard let c = connection else { return }
        app.noteContact(c)
        do { fingerprint = try await SFTPStore.probeHostKey(host: c.host, port: c.port, sessionBudgetURL: try SharedConfig.directory().appendingPathComponent("ssh-session-budget")) }
        catch { self.error = message(for: error) }
    }
}

struct PasswordPrompt: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let connectionID: UUID
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Sign in to \(app.connections.first { $0.id == connectionID }?.name ?? "storage")")
                .font(.system(size: 17, weight: .bold))
            SecureField("Password", text: $password)
            Text("Saved to your Keychain only.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") { app.savePassword(password, for: connectionID); dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(Space.lg).frame(width: 400)
    }
}
