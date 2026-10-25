import Foundation
import CoreKit

extension AppModel {
    func recoverConnection(_ id: UUID, mutation: MetadataStore.InterruptedMutation, outcome: MetadataStore.RecoveryOutcome) async throws {
        guard !isDemo, let c = connections.first(where: { $0.id == id }) else { throw AppError.demoOnly }
        guard !transfers.contains(where: { $0.connectionID == id && $0.phase.isActive }) else {
            throw AppError.unavailable("Cancel active uploads before repairing this connection.")
        }
        if mountedIDs.contains(id) {
            try await DriveManager.unmount(c)
            mountedIDs.remove(id)
        }
        stopPolling()
        resetSession(id)
        let meta = try metadataStore(for: c)
        let backup = try JSONEncoder().encode(await meta.snapshot().items)
        let folder = try SharedConfig.directory().appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try backup.write(to: folder.appendingPathComponent("\(id)-\(mutation.token).json"), options: .atomic)
        try await meta.recoverMutation(token: mutation.token, outcome: outcome)
        connectionErrors[id] = nil
        if activeID == id { await openActive() }
        if browserVisible { startPolling() }
        say("Operation reviewed. Cached identities were backed up; add the storage to Finder when ready.")
    }
}
