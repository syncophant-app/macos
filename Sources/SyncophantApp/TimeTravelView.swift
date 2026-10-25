import SwiftUI
import UniformTypeIdentifiers
import CoreKit

/// Time Travel UI state (mode, selected moment, the folder as it was, Recently deleted). Owned by the Time Travel screen.
@MainActor @Observable
final class TimeTravelState {
    enum Mode: Hashable { case pastVersions, recentlyDeleted }
    enum FolderPhase: Equatable { case idle, loading, loaded, missing, failed(String) }
    var mode: Mode = .pastVersions

    /// Folder being compared; nil follows the window's current folder.
    var folder: String?
    var rows: [VersionRow] = []
    var addedSince = 0
    var folderPhase: FolderPhase = .idle
    var selectedRow: VersionRow.ID?
    var confirmingReplace = false
    var showsManualSteps = false

    var trash: [TrashedItem] = []
    var trashLoading = false
    var trashError: String?
    var selectedTrash: TrashedItem.ID?
}

/// Snapshots and Recently deleted on one timeline: pick a moment, see the folder as it was, restore a copy.
struct TimeTravelView: View {
    @Environment(AppModel.self) private var app
    @State private var askingNote = false

    var body: some View {
        @Bindable var state = app.timeTravelUI
        Group {
            switch state.mode {
            case .pastVersions: SnapshotsView()
            case .recentlyDeleted: TrashView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $state.mode) {
                    Text("Past versions").tag(TimeTravelState.Mode.pastVersions)
                    Text(state.trash.isEmpty ? "Recently deleted" : "Recently deleted · \(state.trash.count)")
                        .tag(TimeTravelState.Mode.recentlyDeleted)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel("Time Travel mode")
            }
            if state.mode == .pastVersions, app.canUseSnapshots, app.snapshots.box != nil, !app.snapshotsHidden {
                ToolbarItem(placement: .primaryAction) {
                    Button { askingNote = true } label: { Label("Take Snapshot", systemImage: "camera") }
                        .labelStyle(.titleAndIcon)
                        .disabled(app.snapshots.isCreating)
                        .popover(isPresented: $askingNote, arrowEdge: .bottom) { TakeSnapshotPopover() }
                }
            }
        }
        .motion(Motion.snappy, value: state.mode)
        .task(id: app.activeID) {
            state.confirmingReplace = false
            await app.loadTrash()
            if app.canUseSnapshots, app.hasHetznerToken, app.snapshots.connectionID != app.activeID { await app.loadSnapshots() }
        }
    }
}

/// Asks for the snapshot's description, then calls Hetzner's create-snapshot API.
private struct TakeSnapshotPopover: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var note = "Taken from Syncophant"
    /// Hetzner accepts only these characters in a description.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_,:<>+#!()[]{} ")
    private var valid: Bool { note.count <= 1000 && note.allSatisfy(Self.allowed.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Take a Snapshot").font(.headline)
            Text("\(app.active?.name ?? "The box") keeps a read-only copy of everything as it is now. Snapshots use space on the box until you delete them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Description", text: $note).textFieldStyle(.roundedBorder)
            if !valid {
                Text("Use letters, numbers, spaces and - _ , : + # ! ( ) [ ] { } < > only.")
                    .font(.caption).foregroundStyle(Palette.caution)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Take Snapshot") {
                    let text = note
                    dismiss()
                    Task { await app.createSnapshot(description: text) }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(Space.lg).frame(width: 340)
    }
}

// MARK: - Shared pieces of both modes

/// The system icon for a file's type, or a folder.
struct TypeIcon: View {
    let name: String
    let isDirectory: Bool
    var size: CGFloat = 24
    var body: some View {
        let type = isDirectory ? UTType.folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// One side of the compare card: Then (purple ring) or Now.
struct ThenNowTile: View {
    let label: String
    let name: String
    let isDirectory: Bool
    var isThen = false
    /// Now is gone: a dashed red outline instead of the icon.
    var gone = false
    let lines: [String]

    var body: some View {
        VStack(spacing: Space.sm) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.3)
                .foregroundStyle(isThen ? AnyShapeStyle(Palette.history) : AnyShapeStyle(.tertiary))
            if gone {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.failure, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 56, height: 64)
                    .overlay(Image(systemName: "trash").foregroundStyle(Palette.failure))
            } else {
                TypeIcon(name: name, isDirectory: isDirectory, size: 64)
            }
            VStack(spacing: 2) {
                ForEach(lines.filter { !$0.isEmpty }, id: \.self) { Text($0) }
            }
            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isThen { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.purple, lineWidth: 1.5) }
        }
        .opacity(gone ? 0.8 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// The quiet note at the foot of the compare card.
struct CompareFootnote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .padding(.horizontal, Space.md).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum TimeFormat {
    /// "Sat 18 Oct, 04:00" in the person's locale.
    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
    /// "18 Oct".
    static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }

    /// "Projects › Work" for a folder path, or the storage name at the top.
    static func folder(_ path: String, storage: String) -> String {
        let parts = path.split(separator: "/")
        return parts.isEmpty ? storage : parts.joined(separator: " › ")
    }
}
