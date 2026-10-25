import SwiftUI
import CoreKit

/// The main window: one floating glass sidebar (storage switcher, the four sections, pinned folders, capacity)
/// and solid content on the right. Glass is for navigation only.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            Detail()
                .navigationTitle(app.windowTitle)
                .navigationSubtitle(app.windowSubtitle)
        }
        .overlay(alignment: .bottom) {
            if let n = app.notice {
                Toast(notice: n)
                    .padding(.bottom, app.isDemo ? 64 : Space.xl)
                    .transition(.offset(y: 8).combined(with: .opacity))
            }
        }
        .motion(Motion.smooth, value: app.notice)
        .sheet(isPresented: $app.showUploadDestination) {
            if let connection = app.active {
                UploadDestinationView(connectionID: connection.id, initialFolder: app.uploadFolder)
            }
        }
        .sheet(isPresented: Binding(get: { app.hostKeyReview != nil }, set: { if !$0 { app.hostKeyReview = nil } })) {
            if let id = app.hostKeyReview { HostKeyReview(connectionID: id) }
        }
        .sheet(isPresented: Binding(get: { app.passwordPrompt != nil }, set: { if !$0 { app.passwordPrompt = nil } })) {
            if let id = app.passwordPrompt { PasswordPrompt(connectionID: id) }
        }
        .sheet(isPresented: Binding(get: { app.mutationRecovery != nil }, set: { if !$0 { app.mutationRecovery = nil } })) {
            if let id = app.mutationRecovery { MutationRecoveryView(connectionID: id) }
        }
        .background(PaletteHost())
        .onAppear {
            app.openWindowAction = openWindow
            app.startPolling()
            app.reloadCacheStatus()
        }
        .onDisappear { app.stopPolling() }
    }
}

/// Persistent strip at the foot of a content area, for state the user should not miss.
struct CanvasStrip<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout)
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { Color(nsColor: .windowBackgroundColor); if let tint { tint.opacity(0.12) } }
            .overlay(alignment: .top) { Divider() }
    }
}

private struct DemoBanner: View {
    var body: some View {
        CanvasStrip(tint: Palette.caution) {
            Label(DemoSession.label, systemImage: "flask").fontWeight(.medium).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo mode. \(DemoSession.label)")
    }
}

/// Result of an action: a glass capsule that rises 8 pt from the bottom and leaves on its own.
struct Toast: View {
    var notice: Notice
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(notice.isError ? Color.red : Color.green)
            Text(notice.text).foregroundStyle(.primary)
        }
        .font(.callout.weight(.medium))
        .lineLimit(3)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Sidebar

extension StorageConnection {
    var kindName: String {
        switch provider {
        case .hetzner: "Hetzner Storage Box"
        case .sftp: "SFTP server"
        case .webdav: "WebDAV server"
        case .s3: "S3-compatible storage"
        case .smb: "SMB share"
        }
    }
    var kindSymbol: String {
        switch provider {
        case .hetzner: "externaldrive.connected.to.line.below"
        case .sftp: "terminal"
        case .webdav: "globe"
        case .s3: "cloud"
        case .smb: "server.rack"
        }
    }
}

private enum SidebarItem: Hashable { case section(Destination), pinned(String) }

private struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List(selection: Binding<SidebarItem?>(
            get: { .section(app.destination) },
            set: { item in
                switch item {
                case .section(let d): app.destination = d
                case .pinned(let path): app.openFolder(path)
                case nil: break
                }
            })) {
            Section {
                ForEach(Destination.allCases, id: \.self) { d in
                    SectionRow(destination: d).tag(SidebarItem.section(d))
                }
            }
            if let c = app.active, !app.pinnedFolders(for: c).isEmpty {
                Section("Pinned") {
                    ForEach(app.pinnedFolders(for: c), id: \.self) { path in
                        Label(PathRules.name(of: path), systemImage: "folder.fill")
                            .tag(SidebarItem.pinned(path))
                            .contextMenu { Button("Unpin") { app.setPinned(path, pinned: false, for: c) } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            StorageSwitcher().padding(.horizontal, 10).padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let c = app.active { CapacityCard(connection: c).padding(10) }
        }
    }
}

/// Avatar, name, health and provider. A menu of every storage plus Add Storage.
private struct StorageSwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            ForEach(app.connections) { c in
                Button { app.select(c.id) } label: {
                    Label(c.name, systemImage: c.id == app.activeID ? "checkmark" : "")
                }
            }
            Divider()
            Button("Add Storage…") { app.open(.addStorage) }
            if let c = app.active {
                Divider()
                Button("Remove \(c.name)…", role: .destructive) { Task { await app.remove(c) } }
            }
        } label: {
            HStack(spacing: 10) {
                if let c = app.active {
                    StorageAvatar(name: c.name, color: app.avatarColor(for: c), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            HealthOrb(health: app.health(for: c), size: 8)
                            Text(app.providerLine(for: c)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    IconTile(symbol: "externaldrive.badge.plus", size: 32)
                    Text("Add Storage").font(.system(size: 13, weight: .semibold))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Switch storage, current: \(app.active?.name ?? "none")")
    }
}

/// One of the four sections, with live status on the trailing edge.
private struct SectionRow: View {
    @Environment(AppModel.self) private var app
    let destination: Destination

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(destination.title)
            } icon: {
                Image(systemName: destination.symbol).foregroundStyle(destination.tone.text)
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        switch destination {
        case .activity:
            if let progress = app.transferProgress {
                ProgressRing(progress: progress, state: app.queuePaused ? .paused : .running, size: 16, lineWidth: 2)
                    .accessibilityLabel("Transfers in progress")
            } else if !app.issues.isEmpty {
                Circle().fill(Color.orange).frame(width: 8, height: 8).accessibilityLabel("Needs attention")
            }
        case .backups:
            let runs = app.jobs.flatMap { $0.runs ?? [] }.sorted { $0.started < $1.started }.suffix(4)
            if !runs.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(runs)) { run in
                        Capsule().fill(run.result.tone.color).frame(width: 3, height: 10)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Last \(runs.count) backup runs")
                .accessibilityValue(runs.map(\.result.words).joined(separator: ", "))
            }
        default: EmptyView()
        }
    }
}

/// Space on the storage and on this Mac. Hidden parts stay hidden: no quota, no bar.
private struct CapacityCard: View {
    @Environment(AppModel.self) private var app
    let connection: StorageConnection

    var body: some View {
        let capacity = app.capacity(for: connection)
        let kept = app.cacheStatus[connection.id]?.pinnedBytes
        let offerFinder = !app.isDemo && !app.mountedIDs.contains(connection.id) && Bundle.main.bundleURL.pathExtension == "app"
        if capacity != nil || kept != nil || offerFinder {
            VStack(alignment: .leading, spacing: 8) {
                if let capacity {
                    CapacityBar(used: capacity.used, snapshots: capacity.snapshots, total: capacity.total, height: 6)
                    HStack {
                        Text("\(Format.bytes(capacity.total - capacity.used)) free")
                        Spacer()
                        Text("of \(Format.bytes(capacity.total))")
                    }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let kept, let status = app.cacheStatus[connection.id] {
                    SettingsLink {
                        HStack(spacing: 6) {
                            CacheDonut(kept: kept, recent: max(0, status.cachedBytes - kept), limit: status.budgetBytes, size: 14, lineWidth: 2.6)
                            Text("\(Format.bytes(kept)) kept on this Mac")
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if offerFinder {
                    Button("Add to Finder") { app.perform(.addToFinder(connection.id)) }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - Detail

private struct Detail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.hasConnections {
            Welcome()
        } else {
            Group {
                switch app.destination {
                case .files: FilesView()
                case .activity: ActivityView()
                case .timeTravel: TimeTravelView()
                case .backups: BackupsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .safeAreaInset(edge: .bottom, spacing: 0) { if app.isDemo { DemoBanner() } }
        }
    }
}

private struct Welcome: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Space.lg) {
            IconTile(symbol: "externaldrive.badge.plus", size: 64)
            VStack(spacing: Space.sm) {
                Text("Where should your files live?").font(.system(size: 24, weight: .bold)).tracking(-0.3)
                Text("Add a Hetzner Storage Box, an SFTP, WebDAV or SMB server, or S3 storage. Files stay there until you open them, and every upload is checked before it says verified.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Add Storage…") { app.open(.addStorage) }
                .buttonStyle(.glassProminent).controlSize(.large)
            Label("Free, no account. Credentials stay in your Keychain.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(Space.xl)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
