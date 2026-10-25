import Foundation
import UniformTypeIdentifiers
import CoreKit

struct BackupJob: Identifiable, Codable, Equatable {
    enum Schedule: String, Codable, CaseIterable, Identifiable {
        case hourly, daily, weekly
        var id: String { rawValue }
        var interval: TimeInterval {
            switch self { case .hourly: 3600; case .daily: 86_400; case .weekly: 604_800 }
        }
    }
    var id = UUID()
    var name: String
    var connectionID: UUID
    var source: URL
    var bookmark: Data?
    var destination: String
    var schedule: Schedule = .daily
    var enabled = true
    var nextRun: Date = Date().addingTimeInterval(86_400)
    var lastRun: Date?
    var lastSummary: String?
    var records: [String: BackupRecord] = [:]
    /// Run history, newest last. Optional so jobs saved by older versions still decode.
    var runs: [BackupRun]?
    // Everything below is optional so jobs saved by older versions still decode.
    /// Minutes after midnight for daily and weekly runs. Nil (older jobs) runs every 24 hours from the last run.
    var timeOfDay: Int?
    /// Calendar weekday for weekly runs, 1 = Sunday.
    var weekday: Int?
    /// Switchable skip rules; nil is what older jobs did (skip node_modules).
    var exclusions: BackupExclusions?
    /// Run a backup missed during sleep or while the app was closed as soon as possible. Nil means on.
    var catchUp: Bool?
    /// Wait while the Mac is on Personal Hotspot or another metered network.
    var skipOnHotspot: Bool?
    /// Wait until the Mac is on its power adapter.
    var requiresPower: Bool?

    var skipRules: BackupExclusions { exclusions ?? .legacy }
    var catchesUp: Bool { catchUp ?? true }

    /// The first scheduled time after `date`.
    func nextRun(after date: Date) -> Date {
        guard schedule != .hourly, let minutes = timeOfDay else { return date.addingTimeInterval(schedule.interval) }
        var parts = DateComponents(hour: minutes / 60, minute: minutes % 60)
        if schedule == .weekly { parts.weekday = weekday ?? 1 }
        return Calendar.current.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(schedule.interval)
    }

    /// "2:00 AM", from `timeOfDay`.
    var timeText: String? {
        timeOfDay.flatMap { Calendar.current.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: Date()) }
            .map { Format.time.string(from: $0) }
    }

    var weekdayText: String { Calendar.current.weekdaySymbols[((weekday ?? 1) - 1) % 7] }

    /// The schedule chip: "Every hour", "Daily at 2:00 AM", "Every Sunday at 10:00 PM".
    var scheduleLabel: String {
        switch schedule {
        case .hourly: String(localized: "Every hour")
        case .daily: timeText.map { String(localized: "Daily at \($0)") } ?? String(localized: "Every day")
        case .weekly: String(localized: "Every \(weekdayText) at \(timeText ?? "")")
        }
    }

    /// Lower-case words for the New backup sentence.
    var scheduleSentence: String {
        switch schedule {
        case .hourly: return String(localized: "every hour")
        case .daily:
            guard let time = timeText, let minutes = timeOfDay else { return String(localized: "every day") }
            let night = minutes < 6 * 60 || minutes >= 21 * 60
            return night ? String(localized: "every night at \(time)") : String(localized: "every day at \(time)")
        case .weekly: return String(localized: "every \(weekdayText) at \(timeText ?? "")")
        }
    }

    /// Hours of the day with a run, for the 24-hour dial.
    var runHours: Set<Int> {
        switch schedule {
        case .hourly: Set(0..<24)
        case .daily, .weekly: timeOfDay.map { [$0 / 60] } ?? []
        }
    }

    /// "Documents → Backups/Documents".
    var route: String { "\(source.lastPathComponent) → \(destination.drop { $0 == "/" })" }

    /// A symbol for the source folder, with the colour of its tile.
    var folderIcon: (symbol: String, tone: Tone) {
        switch source.lastPathComponent.lowercased() {
        case "documents": ("doc.text", .accent)
        case "pictures", "photos", "exports": ("photo", .orange)
        case "desktop": ("menubar.dock.rectangle", .teal)
        case "movies", "videos": ("film", .red)
        case "music": ("music.note", .purple)
        case "downloads": ("arrow.down.circle", .green)
        default: ("folder", .accent)
        }
    }
}

/// One finished run as the engine reported it.
struct BackupRun: Codable, Equatable, Identifiable {
    var started: Date
    var finished: Date
    var result: RunResult
    var uploaded: Int
    var failed: Int
    var skipped: Int
    var bytes: Int64
    var note: String?
    var id: Date { started }
    var duration: TimeInterval { finished.timeIntervalSince(started) }
}

struct JobPreview: Identifiable {
    let job: BackupJob
    let plan: BackupPlan
    var id: UUID { job.id }
}

/// Progress of the running backup, from the engine's per-file callback.
struct JobProgress: Equatable {
    var completed: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// What kind of file, for the First run bar. Classified by the file's type, never guessed from size.
enum FileKind: String, CaseIterable, Identifiable {
    case documents, images, archives, video, other
    var id: String { rawValue }

    init(path: String) {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { self = .other; return }
        if type.conforms(to: .image) { self = .images }
        else if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { self = .video }
        else if type.conforms(to: .archive) { self = .archives }
        else if [UTType.text, .pdf, .presentation, .spreadsheet, .compositeContent].contains(where: type.conforms) { self = .documents }
        else { self = .other }
    }

    var label: String {
        switch self {
        case .documents: String(localized: "Documents")
        case .images: String(localized: "Images")
        case .archives: String(localized: "Archives")
        case .video: String(localized: "Video")
        case .other: String(localized: "Other")
        }
    }

    var tone: Tone {
        switch self { case .documents: .accent; case .images: .orange; case .archives: .purple; case .video: .red; case .other: .neutral }
    }
}
