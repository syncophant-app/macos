import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import FileProvider
import CoreKit

/// 300 pt solid inspector: preview, status card, a block for the state, and the path.
struct FilesInspector: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.selection.count == 1, let node = app.selection.first {
                InspectorBody(node: node).id(node.item.id)
            } else {
                ContentUnavailableView(app.selection.isEmpty ? "No Selection" : "\(app.selection.count) Items Selected",
                                       systemImage: "sidebar.right",
                                       description: Text("Select one item to see where it lives."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct InspectorBody: View {
    @Environment(AppModel.self) private var app
    let node: FileNode
    @State private var thumbnail: NSImage?

    var body: some View {
        let _ = app.browser?.revision // FileNode is not observable; listings and pin changes bump this.
        let storage = app.active?.name ?? "your storage"
        let state = app.fileState(of: node)
        let local = app.isLocal(node)
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.item.entry.name).font(.system(size: 15, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                        Text(meta).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    statusCard(state, storage: storage)
                    block(state, storage: storage)
                }
                .padding(16)
            }
            PathChip(path: node.path).padding([.horizontal, .bottom], 16)
        }
        .task(id: "\(node.item.id)|\(local)") { await loadThumbnail(local: local) }
    }

    private var meta: String {
        let size = app.sizeText(node)
        let modified = Format.modified.string(from: node.item.entry.modifiedAt)
        return size.isEmpty ? modified : "\(size) · \(modified)"
    }

    // MARK: Preview

    private var preview: some View {
        Image(nsImage: thumbnail ?? FileIcons.image(for: node))
            .resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: thumbnail == nil ? 96 : .infinity, maxHeight: thumbnail == nil ? 96 : 160)
            .frame(maxWidth: .infinity).frame(height: 168)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
    }

    /// A real thumbnail only when the file's data is already on this Mac, so looking never downloads.
    private func loadThumbnail(local: Bool) async {
        guard local, !node.isDirectory, app.canUseFinder, let url = try? await app.visibleURL(for: node) else { thumbnail = nil; return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 268, height: 160), scale: 2, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    // MARK: Status card

    @ViewBuilder private func statusCard(_ state: FileState?, storage: String) -> some View {
        let (title, detail) = words(state, storage: storage)
        HStack(alignment: .top, spacing: 12) {
            if let state { FileStateBadge(state: state, size: 34) } else {
                Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(.secondary).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .statusCard(state?.tone ?? .neutral)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status")
        .accessibilityValue("\(title). \(detail)")
    }

    private func words(_ state: FileState?, storage: String) -> (String, String) {
        let transfer = app.transfer(for: node)
        guard let state else {
            if let n = app.browser?.counts[node.path] { return ("Folder on \(storage)", "\(n) item\(n == 1 ? "" : "s") when last listed.") }
            return ("Folder on \(storage)", "Open it to see what’s inside.")
        }
        switch state {
        case .onBox: return ("On \(storage) only", "Opens in a moment when you need it. Uses no space on this Mac.")
        case .onMac: return ("On this Mac and \(storage)", "macOS may free this up when space runs low.")
        case .kept: return ("Kept on this Mac", "Stays downloaded, even offline.")
        case .waiting: return (app.queuePaused ? "Upload paused" : "Waiting to upload", app.queuePaused ? "Resume transfers in Activity." : "Starts when an upload slot is free.")
        case .uploading: return (state.words(storage: storage), transfer?.progressDetail ?? "")
        case .downloading: return (state.words(storage: storage), "Will stay on this Mac when done.")
        case .verifying: return ("Verifying", "Comparing checksums with \(storage).")
        case .verified: return ("Uploaded and verified", "Checksum matched on \(storage).")
        case .unverified: return ("Uploaded, not verified", "\(storage) couldn’t confirm the checksum. Retry to check again.")
        case .twoVersions:
            let who = AppModel.conflictParts(node.item.entry.name).map { AppModel.machineName($0.machine) } ?? "another Mac"
            return ("Edited in two places", "\(who.prefix(1).uppercased() + who.dropFirst()) and \(storage) both changed it before syncing. Both are kept.")
        case .failed:
            if case .failed(let reason) = transfer?.phase { return (app.words(for: node, state, storage: storage), reason) }
            return (app.words(for: node, state, storage: storage), "")
        case .skipped: return ("Skipped", "")
        }
    }

    // MARK: State-specific block

    @ViewBuilder private func block(_ state: FileState?, storage: String) -> some View {
        if let pair = app.conflictPair(for: node) {
            VersionsBlock(original: pair.original, copy: pair.copy, storage: storage)
        } else if let t = app.transfer(for: node), state == .failed || state == .unverified {
            Button("Retry Now") { app.retry(t.id) }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            actionsBlock
        }
    }

    @ViewBuilder private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { node.item.isPinned },
                                 set: { $0 ? app.keepOnThisMac([node]) : app.stopKeeping([node]) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Downloaded").font(.system(size: 13, weight: .medium))
                    Text(app.canUseFinder ? "Always on this Mac, even offline" : app.finderUnavailableReason)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!app.canUseFinder)
            .contentCard(radius: 14, padding: 12)

            HStack(spacing: 8) {
                if app.canShare([node]) {
                    Button("Share…") { app.selection = [node]; app.beginSharing() }.buttonStyle(.glass)
                }
                if app.canUseFinder {
                    Button("Show in Finder") { app.showInFinder(node) }.buttonStyle(.glass)
                }
                if app.canUseSnapshots {
                    Button("Versions…") { app.show(.timeTravel) }.buttonStyle(.glass).help("Browse versions in Time Travel (⇧⌘S)")
                }
            }
            .controlSize(.regular)
        }
    }
}

/// The two copies of a conflict: the one already on the storage and the one another Mac sent.
private struct VersionsBlock: View {
    @Environment(AppModel.self) private var app
    let original: FileNode
    let copy: FileNode
    let storage: String
    @State private var busy = false

    var body: some View {
        let copyNewer = copy.item.entry.modifiedAt > original.item.entry.modifiedAt
        let machine = AppModel.conflictParts(copy.item.entry.name).map { AppModel.machineName($0.machine) } ?? "Other copy"
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Which version do you want?")
            HStack(spacing: 8) {
                card(symbol: "externaldrive", title: "On \(storage)", node: original, newer: !copyNewer)
                card(symbol: "laptopcomputer", title: machine.prefix(1).uppercased() + machine.dropFirst(), node: copy, newer: copyNewer)
            }
            HStack(spacing: 8) {
                Button("Keep Both") { run { try await app.keepBoth(copy: copy) } }
                    .buttonStyle(.glass).frame(maxWidth: .infinity)
                Button("Use Newer") { run { try await app.useNewer(original: original, copy: copy) } }
                    .buttonStyle(.glassProminent).frame(maxWidth: .infinity)
            }
            .disabled(busy)
            Text("Keep Both renames the copy. Use Newer moves the other version to Recently deleted in Time Travel for 30 days.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(symbol: String, title: String, node: FileNode, newer: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text("\(Format.modified.string(from: node.item.entry.modifiedAt)) · \(Format.bytes(node.item.entry.size))\(newer ? " · newer" : "")")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(newer ? Color.accentColor.opacity(0.12) : Fill.one, in: shape)
        .overlay(shape.strokeBorder(newer ? Color.accentColor : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            do { try await work() } catch { app.say("Could not resolve the two versions: \(message(for: error))", error: true) }
            busy = false
        }
    }
}

/// The item's path on the storage; clicking copies it.
private struct PathChip: View {
    @Environment(AppModel.self) private var app
    let path: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            app.say("Copied \(path)")
        } label: {
            HStack(spacing: 6) {
                Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy path")
        .accessibilityLabel("Copy path \(path)")
    }
}

// MARK: - Resolving conflict copies (never deletes: the loser goes to the remote trash)

extension AppModel {
    /// Renames the copy to "name (Machine).ext" so both versions stay as ordinary files.
    func keepBoth(copy: FileNode) async throws {
        guard let c = active, let parts = Self.conflictParts(copy.item.entry.name) else { return }
        let meta = try metadataStore(for: c), store = try remoteStore(for: c)
        let ext = (parts.original as NSString).pathExtension
        let stem = ext.isEmpty ? parts.original : (parts.original as NSString).deletingPathExtension
        let machine = Self.machineName(parts.machine) == "this Mac" ? "this Mac" : parts.machine.replacingOccurrences(of: "-", with: " ")
        let taken = Set(browser?.roots.map(\.item.entry.name) ?? [])
        var name = "", n = 1
        repeat {
            name = "\(stem) (\(machine)\(n > 1 ? " \(n)" : ""))" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        } while taken.contains(name)
        try await meta.move(store: store, id: copy.item.id, to: join(PathRules.parent(of: copy.path), name))
        await afterResolve(c)
        say("Kept both versions. The copy is now “\(name)”.")
    }

    /// Keeps the newer version under the original name; the older goes to Recently deleted (30 days).
    func useNewer(original: FileNode, copy: FileNode) async throws {
        guard let c = active else { return }
        let meta = try metadataStore(for: c), store = try remoteStore(for: c)
        let trash = RemoteTrash(store: store, metadata: meta)
        if copy.item.entry.modifiedAt > original.item.entry.modifiedAt {
            let target = original.path
            try await trash.delete(original.item, expectedVersion: original.item.entry.version)
            try await meta.move(store: store, id: copy.item.id, to: target)
        } else {
            try await trash.delete(copy.item, expectedVersion: copy.item.entry.version)
        }
        selection = []
        await afterResolve(c)
        say("Kept the newer version. The other is in Recently deleted for 30 days.")
    }

    private func afterResolve(_ c: StorageConnection) async {
        if canUseFinder, let manager = NSFileProviderManager(for: DriveManager.domain(c)) {
            let m = UncheckedManager(manager)
            try? await m.value.signalEnumerator(for: .workingSet)
        }
        await showCurrentFolder()
    }
}
