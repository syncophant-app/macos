import SwiftUI
import CoreKit

// MARK: - Shared flow state

/// State shared by the Add storage, Connect Hetzner and Connect server windows.
@MainActor @Observable
final class ConnectFlowState {
    /// What Add storage detected, handed to the next window. `handoffID` changes on every hand-off so an already
    /// open window picks it up too.
    struct Handoff: Equatable {
        var kind: StorageKind
        var text = ""
        var isToken = false
    }
    private(set) var handoff: Handoff?
    private(set) var handoffID = 0
    /// Set by the Encryption window when the person chose a passphrase for the storage being connected.
    /// Connect server uses it for the rclone-compatible crypt layer and clears it after Connect or on close.
    var encryptionPassphrase: String?

    func hand(_ h: Handoff) { handoff = h; handoffID += 1 }
    func take() -> Handoff? { defer { handoff = nil }; return handoff }
}

/// The kinds of storage, with the colour and glyph they use everywhere in setup.
enum StorageKind: String, CaseIterable, Identifiable {
    case hetzner, sftp, webdav, s3, smb, cloud
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hetzner: "Hetzner Storage Box"
        case .sftp: "SFTP server"
        case .webdav: "WebDAV"
        case .s3: "S3-compatible"
        case .smb: "SMB share"
        case .cloud: "Cloud drive"
        }
    }
    var blurb: String {
        switch self {
        case .hetzner: "One API token sets up everything"
        case .sftp: "Any server you can ssh into, or rsync.net"
        case .webdav: "Nextcloud, pCloud, Koofr, kDrive and more"
        case .s3: "AWS, R2, B2, Hetzner, Wasabi and more"
        case .smb: "A NAS, another Mac or Azure Files"
        case .cloud: "Dropbox, OneDrive, Box, Google Drive"
        }
    }
    var symbol: String {
        switch self {
        case .hetzner: "server.rack"
        case .sftp: "terminal"
        case .webdav: "globe"
        case .s3: "cylinder.split.1x2"
        case .smb: "house"
        case .cloud: "cloud"
        }
    }
    var color: Color {
        switch self {
        case .hetzner: .red
        case .sftp: .gray
        case .webdav: .teal
        case .s3: .orange
        case .smb: .purple
        case .cloud: .blue
        }
    }
}

/// Square tile with a white glyph on the kind's colour.
struct KindIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Detection

/// What a pasted address, URL or token most likely is. Purely local: nothing is contacted.
struct Detection: Equatable {
    var kind: StorageKind
    var isToken = false
    var title: String
    var next: String
    /// 1–3 bars.
    var confidence: Int
    /// A Storage Box sub-account login (u123-sub1): goes to Connect server with SFTP, not the Hetzner setup.
    var isSubaccount = false

    static func detect(_ raw: String) -> Detection? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = v.lowercased()
        guard !v.isEmpty else { return nil }
        if lower.contains("your-storagebox.de") {
            let address = ServerAddress.parse(v)
            let login = address.user.isEmpty ? String(address.host.split(separator: ".").first ?? "") : address.user
            let sub = lower.range(of: #"-sub\d+"#, options: .regularExpression) != nil
            return Detection(kind: .hetzner, title: "Hetzner Storage Box \(login)",
                             next: sub ? "A sub-account. Sign in with its password or an SSH key next."
                                       : "Add a Hetzner API token next and Syncophant can set everything up for you.",
                             confidence: 3, isSubaccount: sub)
        }
        if v.count == 64, v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return Detection(kind: .hetzner, isToken: true, title: "Hetzner API token",
                             next: "Next you pick a Storage Box from your account.", confidence: 3)
        }
        if let cloud = OAuthService.allCases.first(where: { s in s.webDomains.contains { ServicePreset.host(of: v).hasSuffix($0) } }) {
            return Detection(kind: .cloud, title: cloud.label, next: "Next you add your own \(cloud.title) app key and sign in.", confidence: 3)
        }
        let service = ServicePreset.match(v)
        if lower.hasPrefix("s3://") || service?.provider == .s3 {
            return Detection(kind: .s3, title: service.map { "\($0.title) bucket" } ?? "S3-compatible bucket",
                             next: "You need an access key and secret next.", confidence: 3)
        }
        if let service, service.provider == .smb {
            return Detection(kind: .smb, title: "\(service.title) share", next: "Sign in with the \(service.user.lowercased()) and its key.", confidence: 3)
        }
        if let service, service.provider == .webdav {
            return Detection(kind: .webdav, title: "\(service.title) at \(ServicePreset.host(of: v))",
                             next: "Syncophant checks it can store files safely when you connect.", confidence: 3)
        }
        if lower.hasPrefix("smb://") || lower.range(of: #"\.local(\b|/|$)"#, options: .regularExpression) != nil {
            let host = v.replacingOccurrences(of: "smb://", with: "", options: [.caseInsensitive, .anchored]).split(separator: "/").first.map(String.init) ?? v
            return Detection(kind: .smb, title: "SMB share on \(host)", next: "A shared folder on your network. Sign in with that computer’s account.", confidence: 3)
        }
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            let host = URL(string: v)?.host ?? v
            return Detection(kind: .webdav, title: "WebDAV at \(host)", next: "Syncophant checks it speaks WebDAV when you connect.", confidence: 2)
        }
        if lower.hasPrefix("sftp://") || lower.hasPrefix("ssh://") || v.contains("@")
            || lower.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?$"#, options: .regularExpression) != nil {
            let a = ServerAddress.parse(v)
            return Detection(kind: .sftp, title: "\(service?.title ?? "SFTP server") \(a.host)", next: "You confirm its fingerprint and sign in next.",
                             confidence: v.contains("@") || lower.hasPrefix("sftp://") ? 3 : 2)
        }
        return nil
    }
}

// MARK: - Add storage window

/// Add storage: one smart field detects the type and the next step; local finds and type tiles below.
struct AddStorageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var detecting = false
    @State private var detection: Detection?
    @State private var picked: StorageKind?
    @State private var sshHosts: [SSHHost] = []
    @State private var nearby = NearbySMB()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StepDots(count: 3, current: 0).padding(.top, 2).padding(.bottom, 8)
            VStack(spacing: 20) {
                hero
                VStack(spacing: 10) { field; result }
                if !chips.isEmpty { found }
                tiles
            }
            .padding(.horizontal, 56)
            .frame(maxHeight: .infinity, alignment: .top)
            SetupFooter {
                KeychainNote()
                Spacer()
                if let reason = disabledReason { Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Continue", action: next).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .frame(minWidth: 110).disabled(chosen == nil)
            }
        }
        .setupWindow()
        .task { sshHosts = (try? await Task.detached { try SSHHost.read() }.value) ?? [] }
        .onAppear { nearby.start(); fieldFocused = true }
        .onDisappear { nearby.stop() }
        .task(id: text) {
            picked = nil
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { detection = nil; detecting = false; return }
            detecting = true
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            detection = Detection.detect(text)
            detecting = false
        }
    }

    // MARK: Parts

    private var hero: some View {
        VStack(spacing: 10) {
            HeroIcon(symbol: "externaldrive.connected.to.line.below", color: .accentColor)
            Text("Where should your files live?").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            Text("Paste anything that points at your storage. Syncophant works out the rest.")
                .font(.system(size: 13.5)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var field: some View {
        FieldBox(height: 54, focused: fieldFocused) {
            Image(systemName: "link").font(.system(size: 17)).foregroundStyle(.tertiary).accessibilityHidden(true)
            TextField("Storage address, URL or Hetzner API token", text: $text,
                      prompt: Text("u123456.your-storagebox.de, https://…, s3://…, smb://… or a Hetzner token"))
                .font(.system(size: 16))
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .onSubmit { if chosen != nil { next() } }
            if detecting { ProgressView().controlSize(.small).accessibilityLabel("Checking") }
        }
        .motion(Motion.snappy, value: fieldFocused)
    }

    /// The detection card (type colour and icon, plain title, next step, 3-bar confidence) or the not-sure note.
    @ViewBuilder private var result: some View {
        if let kind = chosen, !detecting {
            let d = picked == nil ? detection : nil
            HStack(spacing: 12) {
                KindIcon(symbol: d?.isToken == true ? "key.fill" : kind.symbol, color: kind.color, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d?.title ?? kind.title).font(.system(size: 13.5, weight: .semibold))
                    Text(d?.next ?? "You fill in the details next.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                let confidence = d?.confidence ?? 3
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(i < confidence ? kind.color : Fill.track).frame(width: 6, height: 16)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Confidence")
                .accessibilityValue(confidence == 3 ? "Sure" : "Fairly sure")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else if !detecting, detection == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            Label("Not sure what that is yet. Keep typing, or pick a type below.", systemImage: "questionmark.circle")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity)
        }
    }

    private struct Chip: Identifiable {
        let id: String
        let label: String
        let source: String
        let kind: StorageKind
        let use: () -> Void
    }

    /// Hosts from ~/.ssh/config and SMB servers advertised nearby. Each fills the field and runs detection.
    private var chips: [Chip] {
        let smbNames = nearby.names.prefix(2)
        let ssh = sshHosts.prefix(smbNames.isEmpty ? 4 : 2).map { h in
            Chip(id: "ssh-" + h.alias, label: h.alias, source: "SSH config", kind: .sftp) {
                text = (h.user.isEmpty ? "" : h.user + "@") + h.hostName + (h.port == 22 ? "" : ":\(h.port)")
            }
        }
        let smb = smbNames.map { name in
            Chip(id: "smb-" + name, label: name, source: "on your network", kind: .smb) {
                Task { if let host = await NearbySMB.resolve(name) { text = "smb://" + host } }
            }
        }
        return ssh + smb
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Found on this Mac")
            FlowChips(chips: chips)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct FlowChips: View {
        let chips: [Chip]
        var body: some View {
            HStack(spacing: 8) {
                ForEach(chips) { c in
                    Button(action: c.use) {
                        HStack(spacing: 8) {
                            KindIcon(symbol: c.kind.symbol, color: c.kind.color, size: 22)
                            Text(c.label).fontWeight(.medium)
                            Text(c.source).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 13))
                        .lineLimit(1)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("\(c.label), \(c.source)")
                }
            }
        }
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Or choose a type")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(StorageKind.allCases) { kind in tile(kind) }
            }
        }
    }

    private func tile(_ kind: StorageKind) -> some View {
        let on = chosen == kind
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { picked = kind; detecting = false } label: {
            HStack(spacing: 12) {
                KindIcon(symbol: kind.symbol, color: kind.color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(kind.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(on ? kind.color.opacity(0.12) : Fill.one, in: shape)
            .overlay(shape.strokeBorder(on ? kind.color : .clear, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: on)
        .accessibilityLabel(kind.title)
        .accessibilityHint(kind.blurb)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Routing

    /// A tile overrides detection; otherwise the settled detection decides.
    private var chosen: StorageKind? { picked ?? (detecting ? nil : detection?.kind) }

    private var disabledReason: String? {
        guard chosen == nil, !detecting else { return nil }
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? "Paste an address or choose a type" : nil
    }

    private func next() {
        guard let kind = chosen else { return }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = picked == nil ? detection : nil
        if kind == .hetzner, d?.isSubaccount != true {
            app.connectUI.hand(.init(kind: .hetzner, text: d?.isToken == true ? input : "", isToken: d?.isToken == true))
            app.open(.connectHetzner)
        } else {
            let target: StorageKind = kind == .hetzner ? .sftp : kind
            app.connectUI.hand(.init(kind: target, text: picked == nil || detection?.kind == kind ? input : ""))
            app.open(.connectServer)
        }
        dismiss()
    }
}
