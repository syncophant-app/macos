import SwiftUI
import CoreKit

/// Settings › Storage: one card per storage, then one Add Storage… button.
struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if app.connections.isEmpty {
            Text("Nothing connected yet.").foregroundStyle(.secondary).contentCard(radius: 16)
        }
        ForEach(Array(app.connections.enumerated()), id: \.element.id) { index, c in
            StorageCard(connection: c).rowEntrance(index)
        }
        Button("Add Storage…", systemImage: "plus") {
            NSApp.activate()
            openWindow(id: SetupWindow.addStorage.rawValue)
        }
        .buttonStyle(.glass)
        .disabled(app.isDemo)
    }
}

private struct StorageCard: View {
    @Environment(AppModel.self) private var app
    let connection: StorageConnection
    @State private var renaming = false
    @State private var newName = ""
    @State private var signIn: String?

    private var c: StorageConnection { connection }
    private var expanded: Bool { app.settingsUI.expanded.contains(c.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 6) {
                chip("Snapshots", on: c.provider == .hetzner)
                chip("Sharing", on: (c.provider == .hetzner || c.provider == .s3) && c.encryptionEnabled != true)
                chip("Encrypted", on: c.encryptionEnabled == true)
                chip("Changes every 30 s", on: true)
            }
            if expanded {
                details.transition(.opacity.combined(with: .offset(y: -6)))
            }
            HStack(spacing: 8) {
                Button(expanded ? "Hide Details" : "Details") { toggleDetails() }
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Button("Rename…") { newName = c.name; renaming = true }
                Spacer()
                Button("Remove from This Mac…") { Task { await app.removeFromThisMac(c) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.failure)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .contentCard(radius: 16, padding: 16)
        .motion(Motion.smooth, value: expanded)
        .alert("Rename Storage", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new name shows in Syncophant, the menu bar and Finder.")
        }
    }

    private var header: some View {
        let health = app.health(for: c)
        return HStack(spacing: 12) {
            Menu {
                ForEach(AvatarColor.allCases) { color in
                    Button {
                        app.setAvatarColor(color, for: c)
                    } label: {
                        Label(color.name, systemImage: color == app.avatarColor(for: c) ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                StorageAvatar(name: c.name, color: app.avatarColor(for: c), size: 40)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Colour for \(c.name)")
            .help("Pick a colour")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(c.name).font(.system(size: 14, weight: .semibold))
                    HealthOrb(health: health, size: 9)
                }
                Text(kindLine(health)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let cap = app.capacity(for: c) {
                VStack(alignment: .trailing, spacing: 4) {
                    CapacityBar(used: cap.used, snapshots: cap.snapshots, total: cap.total, height: 6)
                    Text("\(Format.bytes(cap.used)) of \(Format.bytes(cap.total))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).rollingNumber(cap.used)
                }
                .frame(width: 150)
            }
        }
    }

    /// "Hetzner Storage Box · SFTP"; health words when it is not fine, since the dot is never the only signal.
    private func kindLine(_ health: Health) -> String {
        if app.connectionErrors[c.id] != nil {
            return app.lastChecked[c.id].map { "Offline · last reached \(Format.time.string(from: $0))" } ?? "Offline · not reached yet"
        }
        var line = app.providerLine(for: c)
        if c.provider == .hetzner, !app.isDemo { line += " · SFTP" }
        if health == .needsYou || health == .failing { line = "\(health.words) · \(line)" }
        return line
    }

    private func chip(_ label: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: on ? "checkmark" : "minus").font(.system(size: 9, weight: .bold))
            Text(label)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Fill.one, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Yes" : "No")
    }

    // MARK: Details

    private var details: some View {
        HStack(alignment: .center, spacing: 14) {
            if let fp = c.hostKeyFingerprint {
                HostKeyIdenticon(fingerprint: fp, size: 76)
            } else if c.usesSSH {
                IconTile(symbol: "key.slash", tone: .orange, size: 76)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { label("Server"); mono(server) }
                GridRow { label("Signs in with"); Text(signIn ?? "…").font(.system(size: 12)) }
                if c.usesSSH {
                    GridRow {
                        label("Fingerprint")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(c.hostKeyFingerprint == nil ? "Not approved yet" : "Approved on this Mac").font(.system(size: 12))
                                Button("Review…") { reviewHostKey() }.buttonStyle(.link).font(.system(size: 12)).disabled(app.isDemo)
                            }
                            if let fp = c.hostKeyFingerprint { mono(fp).foregroundStyle(.secondary) }
                        }
                    }
                }
                GridRow { label("Folder"); mono(folder) }
                if usesAgent, !SSHAgentBroker.shared.status.contains("ready") {
                    GridRow {
                        label("SSH agent")
                        HStack(spacing: 8) {
                            Text(SSHAgentBroker.shared.status).font(.system(size: 12))
                            Button("Retry") { app.refreshAgentAccess() }.buttonStyle(.link).font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: c.id) { loadSignIn() }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(2)
    }

    private var server: String {
        if app.isDemo { return "This Mac (demo)" }
        switch c.provider {
        case .hetzner, .sftp: return "\(c.username)@\(c.host):\(c.port)"
        case .webdav: return c.endpoint?.absoluteString ?? c.host
        case .s3: return [c.endpoint?.host() ?? c.host, c.bucket].compactMap { $0 }.joined(separator: " · ")
        case .smb: return "smb://\(c.host)/\(c.share ?? "")"
        case .dropbox, .onedrive, .box, .googledrive: return c.username.isEmpty ? c.host : c.username
        }
    }

    private var folder: String { c.rootPath.isEmpty ? "/" : c.rootPath }

    @State private var usesAgent = false

    private func loadSignIn() {
        guard !app.isDemo else { signIn = "Nothing, local files"; return }
        guard let credentials = try? StorageCredentials.load(for: c.id) else { signIn = "Missing from your Keychain"; return }
        switch credentials.authentication {
        case .ssh(.password), .password: signIn = "Password in your Keychain"
        case .ssh(.privateKey(_, let passphrase)): signIn = passphrase == nil ? "Key for this Mac" : "Key for this Mac, with passphrase"
        case .ssh(.agent): signIn = "Key from your SSH agent"; usesAgent = true
        case .s3: signIn = "Access key in your Keychain"
        case .oauth(let service, _, _): signIn = "Signed in through your own \(service.title) app"
        }
    }

    private func toggleDetails() {
        if expanded { app.settingsUI.expanded.remove(c.id) } else { app.settingsUI.expanded.insert(c.id) }
    }

    private func reviewHostKey() {
        app.hostKeyReview = c.id
        app.show(.files)
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != c.name else { return }
        var updated = c
        updated.name = name
        do {
            try app.update(updated)
            // Re-adding an existing domain updates its display name in Finder.
            if app.mountedIDs.contains(c.id) { Task { try? await DriveManager.mount(updated) } }
        } catch { app.say("Could not rename \(c.name): \(message(for: error))", error: true) }
    }
}

extension AppModel {
    /// `remove(_:)` (confirmation, Keychain item, Finder domain), then the local leftovers it does not touch:
    /// file metadata, the cache measurement, and this storage's colour and pinned folders.
    func removeFromThisMac(_ c: StorageConnection) async {
        await remove(c)
        guard !connections.contains(where: { $0.id == c.id }) else { return }   // cancelled or failed
        let key = c.id.uuidString
        metadata[c.id] = nil
        cacheStatus[c.id] = nil
        lastChecked[c.id] = nil
        connectionErrors[c.id] = nil
        credentialPresent[c.id] = nil
        settingsUI.expanded.remove(c.id)
        var s = settings
        s.storageColors?[key] = nil
        s.pinnedFolders?[key] = nil
        save(s)
        guard !isDemo, let dir = try? SharedConfig.directory() else { return }
        for name in ["cache-status-\(key).json", "metadata-\(key).sqlite", "metadata-\(key).sqlite-wal", "metadata-\(key).sqlite-shm"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { diagnostics.add("Could not remove \(name): \(message(for: error))") }
            }
        }
    }
}
