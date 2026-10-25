import SwiftUI
import CoreKit

enum SettingsTab: Hashable { case general, storage, transfers, privacy, about }

/// Settings UI state (tab, expanded storage). Owned by the Settings screen.
@MainActor @Observable
final class SettingsState {
    /// Other screens may set this before opening Settings, e.g. `.privacy`.
    var tab: SettingsTab = .general
    var expanded: Set<UUID> = []
}

/// Five toolbar tabs over grouped solid cards. Every control applies immediately; there is no Apply button.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var ui = app.settingsUI
        TabView(selection: $ui.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { SettingsPage { GeneralSettings() } }
            Tab("Storage", systemImage: "externaldrive", value: SettingsTab.storage) { SettingsPage { StorageSettings() } }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: SettingsTab.transfers) { SettingsPage { TransferSettings() } }
            Tab("Privacy", systemImage: "hand.raised", value: SettingsTab.privacy) { SettingsPage { PrivacySettings() } }
            Tab("About", systemImage: "info.circle", value: SettingsTab.about) { SettingsPage { AboutSettings() } }
        }
        .frame(width: 760, height: 640)
    }
}

// MARK: - Shared layout

/// Scrolling page with the board's 40 pt side margins.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 40)
                .padding(.top, 12)
                .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A solid grouped card whose rows are separated by hairlines.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider() }
                    row
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .contentCard(radius: 16, padding: 0)
    }
}

/// Title, optional one-line explanation, and a trailing control. 48 pt minimum height.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

/// Switch row: the switch is named by the row title for VoiceOver.
struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().accessibilityLabel(title)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var login = false

    var body: some View {
        SettingsGroup {
            SettingsToggle(title: "Status badges in Finder",
                           detail: "Shows kept, two-version and stopped files at a glance in Finder.",
                           isOn: Binding(
                               get: { app.settings.finderBadges ?? true },
                               set: { v in var s = app.settings; s.finderBadges = v; app.save(s); app.requestCacheCheck() }))
                .disabled(app.isDemo)
            SettingsToggle(title: "Open at login", isOn: Binding(
                get: { login },
                set: { on in login = on; app.setOpensAtLogin(on); login = app.opensAtLogin }))
                .disabled(app.isDemo)
            SettingsToggle(title: "Add a ~/StorageBox shortcut",
                           detail: "A link in your home folder for Terminal and scripts. Needs the drive in Finder.",
                           isOn: Binding(
                               get: { app.settings.storageBoxLink },
                               set: { v in var s = app.settings; s.storageBoxLink = v; app.save(s); Task { await app.applyStorageBoxLink() } }))
                .disabled(app.isDemo)
        }
        .onAppear { login = app.opensAtLogin }

        SectionLabel("Menu bar icon").padding(.leading, 4)
        MenuBarIconPicker()

        SectionLabel("Shortcuts").padding(.leading, 4)
        SettingsGroup {
            SettingsRow(title: "Search this storage", detail: "Works from any app") { KeyCaps("⌃⌥Space") }
            SettingsRow(title: "Command palette") { KeyCaps("⌘K") }
        }
    }
}

private struct KeyCaps: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Three cards with live previews. Stored in `AppSettings.menuBarIconStyle`; the menu bar reads it.
private struct MenuBarIconPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let current = app.settings.menuBarIconStyle ?? .progressRing
        HStack(spacing: 10) {
            ForEach(MenuBarIconStyle.allCases) { style in
                let on = style == current
                Button {
                    var s = app.settings; s.menuBarIconStyle = style; app.save(s)
                } label: {
                    VStack(spacing: 10) {
                        preview(style)
                        Text(title(style)).font(.system(size: 12.5, weight: .semibold))
                        Text(subtitle(style)).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(EdgeInsets(top: 16, leading: 10, bottom: 12, trailing: 10))
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
                    .background(on ? Color.accentColor.opacity(0.18) : Fill.one, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(style))
                .accessibilityHint(subtitle(style))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .motion(Motion.snappy, value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar icon")
    }

    /// Live: the ring shows the real upload progress and the speed is the last measured sample.
    private func preview(_ style: MenuBarIconStyle) -> some View {
        HStack(spacing: 8) {
            logo
            if style != .simple { ProgressRing(progress: progress, size: 14, lineWidth: 2) }
            if style == .withSpeed {
                Text("\(Format.bytes(Int64(speed)))/s").font(.system(size: 11)).foregroundStyle(.secondary).rollingNumber(Int64(speed))
            }
            if style == .simple, !app.issues.isEmpty {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Fill.two, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var logo: some View {
        if let image = MenuBarIcon.images?[.none] {
            Image(nsImage: image).renderingMode(.template).foregroundStyle(.primary)
        } else {
            Image(systemName: "externaldrive.fill").font(.system(size: 13))
        }
    }

    private var progress: Double {
        let active = app.transfers.filter { $0.phase.isActive }
        let size = active.reduce(Int64(0)) { $0 + $1.size }
        return size > 0 ? Double(active.reduce(Int64(0)) { $0 + $1.completed }) / Double(size) : 0
    }

    private var speed: Double {
        guard let last = app.throughput.last, Date().timeIntervalSince(last.date) < 5 else { return 0 }
        return last.sending + (last.receiving ?? 0)
    }

    private func title(_ s: MenuBarIconStyle) -> String {
        switch s { case .progressRing: "Progress ring"; case .simple: "Simple"; case .withSpeed: "With speed" }
    }
    private func subtitle(_ s: MenuBarIconStyle) -> String {
        switch s {
        case .progressRing: "Fills while syncing, a dot for problems"
        case .simple: "Changes only when something needs you"
        case .withSpeed: "Ring plus live speed"
        }
    }
}

// MARK: - Transfers

private struct TransferSettings: View {
    @Environment(AppModel.self) private var app
    @State private var sizeGB: Double = 5
    @State private var savedGB = 5
    @State private var autoTarget: Int64?
    @State private var applying = false

    var body: some View {
        spaceCard
        SettingsGroup {
            SettingsRow(title: "Upload speed", detail: speedDetail) {
                Picker("Upload speed", selection: Binding(get: { app.settings.bandwidth }, set: { app.setBandwidth($0) })) {
                    ForEach([AppSettings.Bandwidth.auto, .limited, .unlimited]) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Skip temporary files",
                        detail: ".DS_Store, ._ and ~$ lock files, .tmp, .part, .crdownload and editor swap files stay on this Mac") {
                Label("Always on", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            savedGB = (try? CachePolicy.load().sizeGB) ?? 5
            sizeGB = Double(savedGB)
            app.reloadCacheStatus()
        }
        .task(id: Int(sizeGB)) {
            // Saves shortly after the slider settles, so dragging does not write a file per step.
            let value = Int(sizeGB)
            guard value != savedGB, !app.isDemo else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            do { try CachePolicy(sizeGB: value).save(); savedGB = value; app.requestCacheCheck() }
            catch { app.say("Could not save the space limit: \(message(for: error))", error: true) }
        }
        .task(id: app.settings.bandwidth) {
            autoTarget = nil
            while !Task.isCancelled, app.settings.bandwidth == .auto {
                if let c = app.active, let engine = try? app.engine(for: c) { autoTarget = await engine.bandwidthLimitBytesPerSecond }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var speedDetail: String {
        switch app.settings.bandwidth {
        case .auto:
            let base = "Slows down when the connection gets busy, then recovers"
            return autoTarget.map { "\(base) · now \(Format.bytes($0))/s" } ?? base
        case .limited: return "Per storage. Changes apply after the current chunk."
        case .unlimited: return "As fast as the connection allows"
        }
    }

    // Space on this Mac, summed over every storage the Finder extension has measured.
    private var measured: [CacheStatus] { app.connections.compactMap { app.cacheStatus[$0.id] } }

    private var spaceCard: some View {
        let statuses = measured
        let kept = statuses.reduce(Int64(0)) { $0 + $1.pinnedBytes }
        let recent = statuses.reduce(Int64(0)) { $0 + max(0, $1.cachedBytes - $1.pinnedBytes) }
        let perDrive = Int64(sizeGB) * 1_000_000_000
        let limit = perDrive * Int64(max(1, statuses.count))
        let upper = max(50, savedGB, Int(sizeGB))
        return HStack(alignment: .center, spacing: 20) {
            ZStack {
                CacheDonut(kept: kept, recent: recent, limit: limit, size: 120)
                VStack(spacing: 0) {
                    Text("\(Int(sizeGB)) GB").font(.system(size: 20, weight: .bold)).rollingNumber(Int(sizeGB))
                    Text(statuses.count > 1 ? "each storage" : "limit").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Space on this Mac").font(.system(size: 14, weight: .semibold))
                VStack(spacing: 6) {
                    Slider(value: $sizeGB, in: 1...Double(upper), step: 1)
                        .accessibilityLabel("Most space Syncophant may use per storage")
                        .accessibilityValue("\(Int(sizeGB)) gigabytes")
                        .disabled(app.isDemo)
                    HStack { Text("1 GB"); Spacer(); Text("\(upper) GB") }
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if statuses.isEmpty {
                    Text("Nothing measured yet. Sizes appear once a drive in Finder has opened a file.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        legend(.accentColor, "Kept \(Format.bytes(kept)), never removed")
                        legend(.teal, "Recently opened \(Format.bytes(recent))")
                    }
                    Text(checkedLine(statuses)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if !app.mountedIDs.isEmpty {
                Button(applying ? "Checking…" : "Apply Limit Now") { applyNow() }
                    .buttonStyle(.glass)
                    .disabled(applying)
                    .help("Asks each Finder drive to remove recently opened files above the limit. Kept files stay.")
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .contentCard(radius: 16, padding: 16)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(text).rollingNumber(text)
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }

    private func checkedLine(_ statuses: [CacheStatus]) -> String {
        let oldest = statuses.map(\.timestamp).min() ?? Date()
        let met = statuses.allSatisfy(\.enforced)
        return "\(met ? "Within the limit" : "Limit not confirmed yet") · checked \(Format.ago(oldest))"
    }

    private func applyNow() {
        applying = true
        app.requestCacheCheck()
        Task {
            try? await Task.sleep(for: .seconds(3))
            app.reloadCacheStatus()
            applying = false
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    private static let repo = URL(string: "https://github.com/syncophant/macos")!
    private static let licences: [(String, String)] = [
        ("libssh2", "BSD-3-Clause"),
        ("OpenSSL 3", "Apache-2.0"),
        ("Sparkle", "MIT"),
        ("AMSMB2", "LGPL-2.1"),
        ("rclone crypt (encryption helper)", "MIT"),
        ("Syncophant libraries", "MIT"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Syncophant").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                Text("Version \(UpdateChecker.currentVersion) · Free and open source, GPL-3.0-or-later")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(app.isCheckingUpdates ? "Checking GitHub…" : "Check for Updates") { Task { await app.checkForUpdates() } }
                        .buttonStyle(.glassProminent)
                        .disabled(app.isCheckingUpdates || app.isDemo)
                    Button("Source Code") { openURL(Self.repo) }.buttonStyle(.glass)
                    Button("Report a Problem") { openURL(Self.repo.appendingPathComponent("issues")) }.buttonStyle(.glass)
                }
            }
            if let status = app.updateStatus {
                Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary).transition(.opacity)
            }
            Text("Runs only when you click it, unless daily checks are on in Privacy.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)

            SettingsGroup {
                ForEach(Self.licences, id: \.0) { name, licence in
                    SettingsRow(title: name) { Text(licence).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .motion(Motion.smooth, value: app.updateStatus)
    }
}
