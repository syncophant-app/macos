import SwiftUI
import CoreKit

struct UploadDestinationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let connectionID: UUID
    @State private var folder: String
    @State private var folders: [RemoteEntry] = []
    @State private var loadedFolder: String?
    @State private var error: String?
    @State private var retry = 0

    init(connectionID: UUID, initialFolder: String) {
        self.connectionID = connectionID
        _folder = State(initialValue: initialFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Upload destination").font(.title2.weight(.semibold))
            Text("Choose a folder on your storage, then select files from this Mac.").foregroundStyle(.secondary)
            HStack {
                Button { folder = PathRules.parent(of: folder) } label: { Label("Up", systemImage: "arrow.up") }
                    .disabled(folder == "/")
                Button("Root") { folder = "/" }.disabled(folder == "/")
                Spacer()
                let recent = app.recentUploadFolders(for: connectionID)
                if !recent.isEmpty {
                    Menu("Recent Folders") {
                        ForEach(recent, id: \.self) { path in Button(path) { folder = path } }
                    }
                }
            }
            Text(folder).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle).accessibilityLabel("Destination: \(folder)")
            List(folders, id: \.path) { entry in
                Button { folder = entry.path } label: {
                    HStack {
                        Label(entry.name, systemImage: "folder")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open folder \(entry.name)")
            }
            .overlay {
                if let error {
                    ContentUnavailableView {
                        Label("Can’t open this folder", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { retry += 1 }
                    }
                } else if loadedFolder != folder {
                    ProgressView("Loading folders…")
                } else if folders.isEmpty {
                    ContentUnavailableView("No subfolders", systemImage: "folder", description: Text("You can upload into this folder."))
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Files…") {
                    let destination = folder
                    dismiss()
                    app.chooseFilesForUpload(to: destination, connectionID: connectionID)
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(loadedFolder != folder || error != nil || app.activeID != connectionID)
            }
        }
        .padding(Space.lg)
        .frame(width: 540, height: 460)
        .task(id: [folder, String(retry)]) { await load() }
        .onChange(of: app.activeID) { if app.activeID != connectionID { dismiss() } }
    }

    private func load() async {
        let path = folder
        folders = []; error = nil; loadedFolder = nil
        do {
            let entries = try await app.uploadSubfolders(in: path, connectionID: connectionID)
            try Task.checkCancellation()
            guard folder == path else { return }
            folders = entries; loadedFolder = path
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, folder == path else { return }
            self.error = message(for: error)
        }
    }

}
