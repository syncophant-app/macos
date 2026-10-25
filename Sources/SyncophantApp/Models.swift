import SwiftUI
import CoreKit

// MARK: - Settings (shared file, no secrets)

struct AppSettings: Codable, Equatable {
    enum Bandwidth: String, Codable, CaseIterable, Identifiable {
        case auto, limited, unlimited
        var id: String { rawValue }
        var label: String {
            switch self { case .auto: "Auto"; case .limited: "20 MB/s"; case .unlimited: "Unlimited" }
        }
    }
    /// Off until the user turns it on. See PRODUCT.md: update checks are opt-in.
    var updateChecks = false
    var lastUpdateCheck: Date?
    var storageBoxLink = false
    var bandwidth: Bandwidth = .unlimited
    // Optional so settings saved by older versions still decode.
    /// Avatar colour per storage, keyed by connection ID.
    var storageColors: [String: AvatarColor]?
    /// Pinned folders per storage, keyed by connection ID, in the order the person added them.
    var pinnedFolders: [String: [String]]?
    /// Uploads that run at the same time, 1–6. Nil means the default.
    var parallelUploads: Int?
    /// How the menu bar icon shows activity. Nil means `.progressRing`.
    var menuBarIconStyle: MenuBarIconStyle?
    /// Status badges in Finder. Read by the File Provider extension; nil means on.
    var finderBadges: Bool?
}

/// Menu bar icon styles offered in Settings › General.
enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    /// Logo with a ring that fills while syncing and a dot for problems.
    case progressRing
    /// Logo that changes only when something needs you.
    case simple
    /// Ring plus the live transfer speed beside the logo.
    case withSpeed
    var id: String { rawValue }
}

// MARK: - Privacy: hosts this Mac has contacted

struct ContactRecord: Codable, Identifiable, Equatable {
    var host: String
    var purpose: String
    var lastContacted: Date
    var count: Int
    var id: String { host }
}

// MARK: - Per-file status

enum FileStatus: Equatable {
    case none
    case onBox
    case queued
    case uploading(Double?)
    case verifying
    case verified
    case unverified
    case conflict
    case kept
    case failed(String)

    var label: String {
        switch self {
        case .none: ""
        case .onBox: "On your box"
        case .queued: "Waiting to upload"
        case .uploading(let fraction): fraction.map { "Uploading \(Int($0 * 100))%" } ?? "Uploading"
        case .verifying: "Verifying on your box"
        case .verified: "On your box · verified"
        case .unverified: "Uploaded · not verified"
        case .conflict: "Conflict copy · both kept"
        case .kept: "Kept on this Mac"
        case .failed(let reason): "Upload failed · \(reason)"
        }
    }

    var symbol: String {
        switch self {
        case .none: ""
        case .onBox: "externaldrive"
        case .queued: "clock"
        case .uploading: "arrow.up.circle"
        case .verifying: "checkmark.shield"
        case .verified: "checkmark.seal.fill"
        case .unverified: "exclamationmark.circle"
        case .conflict: "arrow.triangle.branch"
        case .kept: "arrow.down.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .verified: Palette.verifiedNS
        case .uploading, .verifying, .kept: Palette.accentNS
        case .unverified, .conflict: Palette.cautionNS
        case .failed: Palette.failureNS
        default: .secondaryLabelColor
        }
    }
}

// MARK: - Transfers

struct Transfer: Identifiable, Equatable, Codable {
    enum Phase: Hashable, Codable {
        case queued, working, verified, unverified, cancelled
        case failed(String)
        var isActive: Bool { self == .queued || self == .working }
    }
    var id = UUID()
    let connectionID: UUID
    let localURL: URL
    let remotePath: String
    let size: Int64
    var phase: Phase = .queued
    /// Bytes the engine reports as written. Zero until the first report; never estimated.
    var completed: Int64 = 0
    var isVerifying = false
    /// Where the engine actually published the file; differs from remotePath when a conflict copy was made.
    var publishedPath: String?
    var bytesPerSecond: Double?
    var progressDate: Date?
    var progressBytes: Int64?
    // Optional so queues saved by older versions still decode.
    /// When the upload reached a final phase. Done rows leave Activity 24 hours after this.
    var finishedAt: Date?
    /// Paused by the person. A paused upload keeps its slot and its partial file; a paused waiting one is skipped.
    var held: Bool?
    /// The person has looked at the copy this upload made beside an existing file.
    var conflictSeen: Bool?
    var isHeld: Bool { held == true }
    /// The engine kept both: this upload was published under a new name because the path was taken.
    var madeConflictCopy: Bool { publishedPath.map { $0 != remotePath } ?? false }
    var eta: TimeInterval? {
        guard phase == .working, !isHeld, !isVerifying, let speed = bytesPerSecond, speed > 0 else { return nil }
        return Double(max(0, size - completed)) / speed
    }
    var progressDetail: String {
        guard let speed = bytesPerSecond, let eta, eta.isFinite else { return "\(Format.bytes(completed)) of \(Format.bytes(size))" }
        let remaining = eta < 60 ? "\(max(1, Int(eta))) sec left" : "\(Int(eta / 60)) min left"
        return "\(Format.bytes(completed)) of \(Format.bytes(size)) · \(Format.bytes(Int64(speed)))/s · \(remaining)"
    }
    var fraction: Double? { size > 0 && !isVerifying ? min(1, Double(completed) / Double(size)) : nil }
    var name: String { localURL.lastPathComponent }

    var status: FileStatus {
        switch phase {
        case .queued: .queued
        case .working: isVerifying ? .verifying : .uploading(fraction)
        case .verified: .verified
        case .unverified: .unverified
        case .cancelled: .none
        case .failed(let reason): .failed(reason)
        }
    }
}

struct TransferQueueSnapshot: Codable {
    var transfers: [Transfer]
    var paused: Bool

    func restoredTransfers(knownConnectionIDs: Set<UUID>) -> [Transfer] {
        transfers.filter { knownConnectionIDs.contains($0.connectionID) }.map { saved in
            var job = saved
            if job.phase == .working {
                job.phase = .queued
                job.isVerifying = false
                job.bytesPerSecond = nil; job.progressDate = nil; job.progressBytes = nil
            }
            return job
        }
    }
}

// MARK: - Issues: plain cause, one fix

struct Issue: Identifiable, Equatable {
    enum Fix: Equatable {
        case reviewHostKey(UUID), compareHostKey(UUID), enterPassword(UUID), retryListing(UUID), addToFinder(UUID)
        case retryTransfer(UUID), showConflict(UUID), recoverMutation(UUID), reconnectStorage, freeUpSpace(UUID), showSnapshotFolder(UUID)
        var title: String {
            switch self {
            case .reviewHostKey: "Review Key…"
            case .compareHostKey: "Compare…"
            case .enterPassword: "Sign In Again…"
            case .retryListing: "Try Again"
            case .addToFinder: "Add to Finder"
            case .retryTransfer: "Retry"
            case .showConflict: "Show in Files"
            case .recoverMutation: "Review…"
            case .reconnectStorage: "Reconnect…"
            case .freeUpSpace: "Free Up Space…"
            case .showSnapshotFolder: "Turn On"
            }
        }
    }
    let id: String
    var title: String
    var detail: String
    var fix: Fix
    var severity: Severity = .caution
    enum Severity { case caution, failure }

    var tone: Tone { severity == .failure ? .red : .orange }

    var symbol: String {
        switch fix {
        case .reviewHostKey, .compareHostKey: "key.fill"
        case .enterPassword, .reconnectStorage: "person.badge.key.fill"
        case .retryListing: "wifi.exclamationmark"
        case .addToFinder: "folder.badge.plus"
        case .retryTransfer: "exclamationmark.triangle.fill"
        case .showConflict: "doc.on.doc.fill"
        case .recoverMutation: "arrow.uturn.backward"
        case .freeUpSpace: "externaldrive.fill.badge.exclamationmark"
        case .showSnapshotFolder: "clock.arrow.circlepath"
        }
    }

    /// Ranking for "the one thing that needs you": failed > conflict > nearly full > offline.
    var rank: Int {
        switch fix {
        case .retryTransfer: severity == .failure ? 0 : 1
        case .compareHostKey: 0
        case .showConflict: 1
        case .reviewHostKey, .enterPassword, .reconnectStorage, .recoverMutation: 2
        case .showSnapshotFolder: 2
        case .freeUpSpace: 3
        case .addToFinder: 5
        case .retryListing: 6
        }
    }
}

/// What pressing a fix did: opened a sheet or a place, fixed it (with the result to show), or failed.
enum FixOutcome: Equatable { case opened, fixed(String), failed(String) }

// MARK: - Errors shown to people

enum AppError: LocalizedError {
    case missingPassword
    case demoOnly
    case needsBundle
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword: "The password for this storage is not in your Keychain. Enter it again."
        case .demoOnly: "This works only with a real storage connection."
        case .needsBundle: "Finder integration needs the signed Syncophant.app bundle."
        case .unavailable(let what): what
        }
    }
}

/// Short, honest message from any error. Never includes credentials.
func message(for error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return (error as NSError).localizedDescription
}

/// The four sections of the main window, in sidebar order (⌘1–⌘4).
enum Destination: Hashable, CaseIterable {
    case files, activity, timeTravel, backups

    var title: String {
        switch self { case .files: "Files"; case .activity: "Activity"; case .timeTravel: "Time Travel"; case .backups: "Backups" }
    }
    var symbol: String {
        switch self {
        case .files: "folder"
        case .activity: "waveform.path.ecg"
        case .timeTravel: "clock.arrow.circlepath"
        case .backups: "externaldrive.badge.timemachine"
        }
    }
    var tone: Tone {
        switch self { case .files, .activity: .accent; case .timeTravel: .purple; case .backups: .green }
    }
}

/// Setup flows open as their own windows so they can stay open beside the main window.
enum SetupWindow: String, CaseIterable {
    case addStorage = "add-storage"
    case connectHetzner = "connect-hetzner"
    case connectServer = "connect-server"
    case encryption
    case newBackup = "new-backup"
    case share
}

// MARK: - Transfer history (last 24 hours, measured)

struct TransferHistory: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var date: Date
        var bytes: Int64
        var verified: Bool
        var upload = true
    }
    var entries: [Entry] = []

    func pruned(now: Date = Date()) -> TransferHistory {
        TransferHistory(entries: entries.filter { now.timeIntervalSince($0.date) < 86_400 })
    }

    /// Bytes per hour for the last 24 hours, oldest first; the last bar is the current hour.
    func hourly(now: Date = Date(), upload: Bool = true) -> [Int64] {
        var bars = [Int64](repeating: 0, count: 24)
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        for e in entries where e.upload == upload {
            let back = Int(hour.timeIntervalSince(e.date) / 3600) + (e.date >= hour ? 0 : 1)
            if (0..<24).contains(back) { bars[23 - back] += e.bytes }
        }
        return bars
    }

    var sent: Int64 { entries.filter(\.upload).reduce(0) { $0 + $1.bytes } }
    var received: Int64 { entries.filter { !$0.upload }.reduce(0) { $0 + $1.bytes } }
    var verifiedCount: Int { entries.filter(\.verified).count }
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}
