import AppKit
import FileProvider
import CoreKit

@MainActor
enum DriveManager {
    static func domain(_ connection: StorageConnection) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: .init(rawValue: connection.id.uuidString), displayName: connection.name)
        // Deletions use RemoteTrash; this provider does not enumerate Finder's synchronized trash.
        domain.supportsSyncingTrash = false
        return domain
    }

    static func mount(_ connection: StorageConnection) async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw NSError(domain: "Syncophant", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Finder integration needs the signed Syncophant.app bundle. Build the Xcode app target first."])
        }
        try await NSFileProviderManager.add(domain(connection))
    }

    static func unmount(_ connection: StorageConnection) async throws {
        try await NSFileProviderManager.remove(domain(connection), mode: .preserveDownloadedUserData)
    }

    static func open(_ connection: StorageConnection) async throws {
        guard let manager = NSFileProviderManager(for: domain(connection)) else { throw CocoaError(.fileNoSuchFile) }
        let url = try await manager.getUserVisibleURL(for: .rootContainer)
        NSWorkspace.shared.open(url)
    }
}
