import Foundation
import CoreKit

/// Local stand-in for a storage server, used only when launched with `--demo`.
/// Everything lives in a temporary folder; nothing connects to a network or the Keychain.
struct DemoSession {
    let connection: StorageConnection
    let store: LocalRemoteStore
    let meta: MetadataStore
    let root: URL

    static let label = "Demo mode · files are in a temporary folder on this Mac. Nothing is connected to a server."

    static func make() throws -> DemoSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syncophant-demo-\(UUID().uuidString)", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: files.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: files.appendingPathComponent("Projects/Sample"), withIntermediateDirectories: true)
        let samples: [(String, String)] = [
            ("README (demo).txt", "Demo file created by Syncophant --demo. It exists only in a temporary folder."),
            ("Documents/Meeting notes (sample).md", "# Sample\nNot real data."),
            ("Documents/Meeting notes (sample) (conflict \(UUID().uuidString)).md", "# Sample, other copy\nNot real data."),
            ("Projects/Sample/Draft (sample).txt", "Draft text for the demo."),
        ]
        for (path, text) in samples {
            try text.write(to: files.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let connection = StorageConnection(name: "Demo storage", provider: .sftp, host: "demo.invalid", port: 22,
                                           username: "demo", rootPath: "/", hostKeyFingerprint: nil)
        return DemoSession(connection: connection, store: try LocalRemoteStore(root: files),
                           meta: try MetadataStore(url: root.appendingPathComponent("metadata.sqlite")), root: root)
    }
}

extension AppModel {
    func startDemo() {
        do {
            let session = try DemoSession.make()
            demo = session
            contacts = []
            connections = [session.connection]
            activeID = session.connection.id
            credentialPresent[session.connection.id] = true
        } catch { say("Could not start the demo: \(message(for: error))", error: true) }
    }
}
