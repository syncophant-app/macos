import SwiftUI
import CoreKit

/// Recently deleted mode: Syncophant's own 30-day bin on the storage, with a compare card and Restore.
struct TrashView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var state = app.timeTravelUI
        let name = app.active?.name ?? "your storage"
        Group {
            if let error = state.trashError, state.trash.isEmpty {
                ContentUnavailableView {
                    Label("Can’t read Recently deleted", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await app.loadTrash() } }.buttonStyle(.glass)
                }
            } else if state.trash.isEmpty {
                if state.trashLoading {
                    ProgressView("Reading Recently deleted…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Nothing recently deleted", systemImage: "trash",
                                           description: Text("Files you delete stay on \(name) for 30 days. Restoring never replaces a file that is there now."))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    list(state)
                    TrashCompareCard().frame(width: 360)
                }
                .padding(.leading, 20).padding(.trailing, 16).padding(.bottom, 16).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ state: TimeTravelState) -> some View {
        @Bindable var state = state
        let storage = app.active?.name ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("Kept for 30 days, then removed for good")
                Spacer()
                if state.trashLoading { ProgressView().controlSize(.small) }
                Button("Restore All") { Task { await app.restoreFromTrash(state.trash) } }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 12.5, weight: .semibold))
                    .disabled(state.trashLoading)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            List(selection: $state.selectedTrash) {
                ForEach(Array(state.trash.enumerated()), id: \.element.id) { index, item in
                    TrashRow(item: item, storage: storage)
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .rowEntrance(index)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentCard(padding: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recently deleted")
    }
}

/// Whole days until the bin removes an item for good; nil for older deletions that never expire.
private func daysLeft(_ item: TrashedItem, now: Date = Date()) -> Int? {
    item.deletedAt.map { max(0, Int((($0.addingTimeInterval(RemoteTrash.retention).timeIntervalSince(now)) / 86_400).rounded(.up))) }
}

private struct TrashRow: View {
    let item: TrashedItem
    let storage: String

    var body: some View {
        let left = daysLeft(item)
        let urgent = (left ?? 99) <= 5
        HStack(spacing: 10) {
            TypeIcon(name: item.name, isDirectory: item.isDirectory, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            if let left {
                HStack(spacing: 7) {
                    ZStack {
                        Circle().stroke(Fill.track, lineWidth: 2)
                        Circle().trim(from: 0, to: Double(left) / 30)
                            .stroke(urgent ? Color.orange : Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    Text(left == 1 ? "1 day left" : "\(left) days left")
                        .foregroundStyle(urgent ? AnyShapeStyle(Palette.caution) : AnyShapeStyle(.secondary))
                }
                .font(.system(size: 12)).monospacedDigit().fixedSize()
            } else {
                Text("Kept until restored").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            }
            Text(item.isDirectory ? "" : Format.bytes(item.size))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let from = "from \(TimeFormat.folder(PathRules.parent(of: item.originalPath), storage: storage))"
        return item.deletedAt.map { "Deleted \(TimeFormat.day($0)) · \(from)" } ?? "Deleted earlier · \(from)"
    }
}

private struct TrashCompareCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let state = app.timeTravelUI
        let storage = app.active?.name ?? ""
        VStack(alignment: .leading, spacing: 14) {
            if let item = state.trash.first(where: { $0.id == state.selectedTrash }) {
                let folder = TimeFormat.folder(PathRules.parent(of: item.originalPath), storage: storage)
                let left = daysLeft(item)
                Text(item.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                HStack(spacing: 10) {
                    ThenNowTile(label: "Then", name: item.name, isDirectory: item.isDirectory, isThen: true,
                                lines: ["Before deletion", item.isDirectory ? "Folder" : Format.bytes(item.size)])
                    ThenNowTile(label: "Now", name: item.name, isDirectory: item.isDirectory, gone: true,
                                lines: [item.deletedAt.map { "Deleted \(TimeFormat.day($0))" } ?? "Deleted earlier",
                                        left.map { $0 == 1 ? "Removed for good in 1 day" : "Removed for good in \($0) days" } ?? ""])
                }
                Text("Restoring puts it back in \(folder). If that name is taken now, nothing is replaced and Syncophant tells you.")
                    .font(.system(size: 12)).lineSpacing(2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await app.restoreFromTrash([item]) } } label: { Text("Restore").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(state.trashLoading)
            } else {
                ContentUnavailableView("Pick an item", systemImage: "trash", description: Text("Choose something on the left to see where it goes back."))
                    .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            CompareFootnote(text: "Restoring never replaces a file that is there now. Items here are removed for good 30 days after deletion.")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare")
    }
}

struct MutationRecoveryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let connectionID: UUID
    @State private var mutation: MetadataStore.InterruptedMutation?
    @State private var checked = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Review an interrupted operation").font(.title3.weight(.semibold))
            Text("Syncophant kept the file identities because a remote rename may have finished after the connection dropped. Stop editors and other Macs writing to this storage, then check the paths directly on your server.")
            if let mutation {
                if let source = mutation.source, let target = mutation.destination {
                    LabeledContent("Original", value: source).textSelection(.enabled)
                    LabeledContent("Destination", value: target).textSelection(.enabled)
                } else {
                    Text("This was an upload publication. Check the original and conflict copies before continuing.")
                }
                if mutation.leaseUntil > Date() {
                    Text("The operation's safety window is still active. Try again after \(mutation.leaseUntil.formatted(date: .omitted, time: .standard)).").foregroundStyle(Palette.caution)
                }
                Toggle("All writers are stopped, and I checked the remote files", isOn: $checked)
            } else if !busy {
                Label("No interrupted operation is recorded.", systemImage: "checkmark.circle").foregroundStyle(Palette.verified)
            }
            if let error { Text(error).foregroundStyle(Palette.failure) }
            Text("Finder will be disconnected during repair. A local metadata backup is kept; remote files are never removed by this repair.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if mutation?.source != nil {
                    Button("Rename Finished") { repair(.acceptMovedPaths) }.disabled(!canRepair)
                }
                Button(mutation?.source == nil ? "Resume Refresh" : "Keep Original Paths") { repair(.keepOriginalPaths) }.disabled(!canRepair)
            }
        }.padding(Space.lg).frame(width: 580).task { await inspect() }
    }

    private var canRepair: Bool { checked && !busy && mutation.map { $0.leaseUntil <= Date() } == true }

    private func inspect() async {
        guard let c = app.connections.first(where: { $0.id == connectionID }) else { return }
        do { mutation = try await app.metadataStore(for: c).interruptedMutation() }
        catch { self.error = message(for: error) }
    }

    private func repair(_ outcome: MetadataStore.RecoveryOutcome) {
        guard let mutation, canRepair else { return }
        busy = true
        Task {
            do {
                try await app.recoverConnection(connectionID, mutation: mutation, outcome: outcome)
                dismiss()
            } catch { self.error = message(for: error) }
            busy = false
        }
    }
}
