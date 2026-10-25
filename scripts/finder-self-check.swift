import Foundation
import FileProvider
import QuickLookThumbnailing
import CoreKit

/// Remote size differs from the cached listing; oversized files must fail before any bytes are read.
private actor ThumbnailBoundStore: RemoteStore {
    let entry: RemoteEntry
    private(set) var reads = 0

    init(size: Int64, directory: Bool = false) {
        entry = RemoteEntry(name: "sample.pdf", path: "/sample.pdf", isDirectory: directory, size: size, modifiedAt: .distantPast)
    }

    func stat(path: String) -> RemoteEntry { entry }
    func list(path: String) -> [RemoteEntry] { [entry] }
    func read(path: String, offset: Int64, length: Int) throws -> Data { reads += 1; throw CocoaError(.featureUnsupported) }
    func write(path: String, offset: Int64, data: Data) throws { throw CocoaError(.featureUnsupported) }
    func createDirectory(path: String) throws { throw CocoaError(.featureUnsupported) }
    func move(from: String, to: String) throws { throw CocoaError(.featureUnsupported) }
    func remove(path: String) throws { throw CocoaError(.featureUnsupported) }
    func checksum(path: String) throws -> String { throw CocoaError(.featureUnsupported) }
}

@main struct FinderSelfCheck {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinderSelfCheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try MetadataStore(url: directory.appendingPathComponent("metadata.sqlite"))
        let cached = RemoteEntry(name: "sample.pdf", path: "/sample.pdf", isDirectory: false, size: 1, modifiedAt: .distantPast)
        let stored = try await metadata.reconcile([cached], parentPath: "/")[0]
        let connection = StorageConnection(name: "Isolated Finder check", host: "unused.invalid", username: "unused")
        let domain = DriveManager.domain(connection)
        precondition(!domain.supportsSyncingTrash, "Finder must route deletion to the provider's recoverable remote-trash path")
        for (size, isDirectory) in [(Int64(-1), false), (0, false), (32 * 1_048_576 + 1, false), (20 * 1_073_741_824, false), (1, true)] {
            let store = ThumbnailBoundStore(size: size, directory: isDirectory)
            let runtime = try ProviderRuntime(domain: domain, connection: connection, store: store, metadata: metadata,
                                              journalURL: directory.appendingPathComponent("journal.json"))
            do {
                _ = try await runtime.thumbnailContents(.init(rawValue: stored.id), progress: Progress(totalUnitCount: 1))
                preconditionFailure("Unsupported thumbnail source was downloaded")
            } catch {
                let error = error as NSError
                precondition(error.domain == NSCocoaErrorDomain && error.code == CocoaError.featureUnsupported.rawValue)
            }
            let reads = await store.reads
            precondition(reads == 0, "An oversized source was read before its fresh size was checked")
            await runtime.stop()
        }

        // Cancel before native registration: no generation request, Finder, clipboard, or Terminal is touched.
        let request = QLThumbnailGenerator.Request(fileAt: directory.appendingPathComponent("never-opened.pdf"),
                                                   size: CGSize(width: 256, height: 256), scale: 1, representationTypes: .thumbnail)
        let operation = ThumbnailRequest(request)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            try await operation.save(to: directory.appendingPathComponent("never-written.jpg"))
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("A cancelled thumbnail request succeeded") }
        catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("never-written.jpg").path))

        var completions = 0
        let once = ActionCompletion { error in
            completions += 1
            precondition((error as NSError?)?.code == CocoaError.userCancelled.rawValue)
        }
        once.finish(CocoaError(.userCancelled))
        once.finish(nil)
        precondition(completions == 1, "Cancellation and action completion both reached Finder")

        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Config/Provider-Info.plist")), format: nil) as! [String: Any]
        let ext = plist["NSExtension"] as! [String: Any]
        let actions = ext["NSExtensionFileProviderActions"] as! [[String: Any]]
        let identifiers = actions.compactMap { $0["NSExtensionFileProviderActionIdentifier"] as? String }
        precondition(Set(identifiers) == ProviderRuntime.actions && identifiers.count == ProviderRuntime.actions.count, "Declared and handled actions differ")
        precondition(!identifiers.contains("app.syncophant.evict"), "Remove Download is the system's; the custom copy must stay gone")
        let decorations = Set((ext["NSFileProviderDecorations"] as! [[String: Any]]).compactMap { $0["Identifier"] as? String })

        // Four files, four different menus, each with only what applies (spec: Finder integration, Done when).
        let file = RemoteEntry(name: "Proposal.pages", path: "/Work/Proposal.pages", isDirectory: false, size: 10, modifiedAt: .distantPast)
        let conflictCopy = RemoteEntry(name: "Proposal (conflict 1A2B).pages", path: "/Work/Proposal (conflict 1A2B).pages", isDirectory: false, size: 10, modifiedAt: .distantPast)
        let hetzner = FinderContext(canShare: false, hasVersions: true)
        let cases: [(String, ProviderItem, [String])] = [
            ("cloud-only", ProviderItem(StoredItem(id: "a", entry: file), parent: .rootContainer, context: hetzner), ["Keep Downloaded", "Browse Versions…"]),
            ("kept", ProviderItem(StoredItem(id: "b", entry: file, isPinned: true), parent: .rootContainer, context: hetzner), ["Stop Keeping Downloaded", "Browse Versions…"]),
            ("failed", ProviderItem(StoredItem(id: "c", entry: file), parent: .rootContainer, context: FinderContext(transfer: "failed", hasVersions: true)),
             ["Retry Upload", "Why Did It Stop?", "Browse Versions…"]),
            ("conflict", ProviderItem(StoredItem(id: "d", entry: conflictCopy), parent: .rootContainer, context: hetzner), ["Compare Versions…", "Browse Versions…"]),
        ]
        let always: Set<String> = ["Copy Path", "Open in Terminal", "Refresh from Storage"]
        func menu(_ items: [ProviderItem]) -> [String] {
            let context = ["fileproviderItems": items.map { ["userInfo": $0.userInfo ?? [:]] }]
            return actions.filter { NSPredicate(format: $0["NSExtensionFileProviderActionActivationRule"] as! String).evaluate(with: context) }
                .map { $0["NSExtensionFileProviderActionName"] as! String }
        }
        for (name, item, expected) in cases {
            let shown = menu([item])
            precondition(shown.filter { !always.contains($0) } == expected, "\(name) menu: \(shown)")
            precondition(Array(shown.suffix(3)) == ["Copy Path", "Open in Terminal", "Refresh from Storage"], "Utility actions must come last")
            if let decoration = item.decorations?.first { precondition(decorations.contains(decoration.rawValue), "Undeclared decoration \(decoration.rawValue)") }
        }
        precondition(menu([cases[2].1, cases[0].1]).contains("Retry Upload") == false, "Retry must not include files that did not fail")
        precondition(menu([cases[0].1, cases[1].1]).contains("Browse Versions…") == false, "Single-item actions stay single-item")
        let s3Folder = ProviderItem(StoredItem(id: "e", entry: RemoteEntry(name: "Work", path: "/Work", isDirectory: true, size: 0, modifiedAt: .distantPast)),
                                    parent: .rootContainer, context: FinderContext(canShare: true))
        precondition(menu([s3Folder]).contains("Share…"))
        precondition(cases.map { $0.1.decorations?.first?.rawValue }
                     == [nil, "app.syncophant.mac.provider.kept", "app.syncophant.mac.provider.failed", "app.syncophant.mac.provider.two-versions"])
        precondition(ProviderItem(StoredItem(id: "f", entry: file, isPinned: true), parent: .rootContainer, context: FinderContext(badges: false)).decorations == nil)
        precondition(cases[0].1.itemVersion.metadataVersion != cases[2].1.itemVersion.metadataVersion, "State changes must change the metadata version")

        // The app's queue file: latest non-cancelled transfer per path wins; other storages are ignored.
        let me = UUID(), other = UUID()
        let queue = """
        {"paused":false,"transfers":[
          {"connectionID":"\(me)","remotePath":"/a","phase":{"failed":{"_0":"Connection reset"}},"localURL":"file:///tmp/a"},
          {"connectionID":"\(me)","remotePath":"/b","phase":{"failed":{"_0":"x"}}},
          {"connectionID":"\(me)","remotePath":"/b","phase":{"verified":{}}},
          {"connectionID":"\(me)","remotePath":"/c","publishedPath":"/c (conflict 1)","phase":{"working":{}}},
          {"connectionID":"\(me)","remotePath":"/d","phase":{"queued":{}}},
          {"connectionID":"\(me)","remotePath":"/d","phase":{"cancelled":{}}},
          {"connectionID":"\(other)","remotePath":"/e","phase":{"failed":{"_0":"x"}}}]}
        """
        precondition(FinderContext.transferStates(Data(queue.utf8), connection: me) == ["/a": "failed", "/c (conflict 1)": "uploading", "/d": "uploading"])
        precondition(FinderContext.transferStates(Data("not json".utf8), connection: me).isEmpty)
        precondition(FinderContext.badgesEnabled(nil) && FinderContext.badgesEnabled(Data("{}".utf8)) && !FinderContext.badgesEnabled(Data(#"{"finderBadges":false}"#.utf8)))

        let url = ProviderRuntime.appURL(route: "time-travel", storage: me, path: "/Work/Q&A ?#1.md")!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(url.scheme == "syncophant" && url.host == "time-travel" && query.first { $0.name == "path" }?.value == "/Work/Q&A ?#1.md"
                     && query.first { $0.name == "storage" }?.value == me.uuidString)
        print("Finder self-check passed: fresh-size rejection without remote reads, pre-start native cancellation, one-shot action completion, state-aware menus, badges and app links.")
    }
}
