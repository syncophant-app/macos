import Foundation

@main
struct AppStateSelfCheck {
    static func main() throws {
        let connection = UUID()
        var running = Transfer(connectionID: connection, localURL: URL(fileURLWithPath: "/tmp/source"), remotePath: "/target", size: 17)
        running.phase = .working
        running.isVerifying = true
        var finished = running
        finished.id = UUID()
        finished.phase = .verified
        var removed = running
        removed.id = UUID()
        let snapshot = TransferQueueSnapshot(transfers: [running, finished, removed], paused: true)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TransferQueueSnapshot.self, from: data)
        var jobs = decoded.transfers
        jobs[2] = Transfer(connectionID: UUID(), localURL: removed.localURL, remotePath: "/removed", size: 17)
        let restored = TransferQueueSnapshot(transfers: jobs, paused: decoded.paused)
            .restoredTransfers(knownConnectionIDs: [connection])
        precondition(decoded.paused && decoded.transfers[0].id == running.id)
        precondition(restored.count == 2 && restored[0].phase == .queued && !restored[0].isVerifying)
        precondition(restored[1].phase == .verified && restored[0].localURL == running.localURL)
        precondition(AppSettings().updateChecks == false)
        print("App state self-check passed: stable resume IDs, queue recovery, removed-connection filtering, and private defaults.")
    }
}
