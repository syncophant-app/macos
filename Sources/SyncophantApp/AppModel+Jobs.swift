import AppKit
import IOKit.ps
import CoreKit

extension AppModel {
    func chooseBackupFolder() -> (URL, Data?)? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to back up"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, backupBookmark(for: url))
    }

    func backupBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func saveJob(_ job: BackupJob) throws {
        guard !isDemo, connections.contains(where: { $0.id == job.connectionID }), !job.name.trimmingCharacters(in: .whitespaces).isEmpty,
              job.source.isFileURL else { throw AppError.unavailable("Choose a name, source folder and storage connection.") }
        _ = try PathRules.normalize(job.destination)
        var updated = jobs.filter { $0.id != job.id }
        updated.append(job)
        try SharedJSON.save(updated, name: "backup-jobs.json")
        jobs = updated
    }

    func removeJob(_ id: UUID) {
        guard runningJob != id else { say("Stop this backup before removing it.", error: true); return }
        do {
            let updated = jobs.filter { $0.id != id }
            if !isDemo { try SharedJSON.save(updated, name: "backup-jobs.json") }
            jobs = updated
            if backupsUI.selected == id { backupsUI.selected = nil }
        } catch { say("Could not remove the backup: \(message(for: error))", error: true) }
    }

    func renameJob(_ id: UUID, to name: String) {
        guard var job = jobs.first(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        job.name = name.trimmingCharacters(in: .whitespaces)
        do { try saveJob(job) } catch { say(message(for: error), error: true) }
    }

    /// Pausing stops future runs only; a run in progress finishes and keeps the pause.
    func setJobEnabled(_ id: UUID, _ enabled: Bool) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.enabled = enabled
        if enabled { job.nextRun = job.nextRun(after: Date()) }
        do { try saveJob(job) } catch { say(message(for: error), error: true) }
    }

    private func resolveSource(_ job: BackupJob) throws -> URL {
        guard let data = job.bookmark else { return job.source }
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func runJob(_ job: BackupJob) {
        guard !isDemo, runningJob == nil else { return }
        runningJob = job.id; jobPreview = nil; backupsUI.progress = nil
        jobTask = Task {
            let started = Date()
            var run = BackupRun(started: started, finished: started, result: .failed, uploaded: 0, failed: 0, skipped: 0, bytes: 0)
            var records: [String: BackupRecord]?, summary: String
            defer { runningJob = nil; jobTask = nil; backupsUI.progress = nil }
            do {
                guard let c = connections.first(where: { $0.id == job.connectionID }) else { throw AppError.unavailable("This storage connection was removed.") }
                let source = try resolveSource(job), scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                noteContact(c)
                let engine = BackupEngine(store: try remoteStore(for: c), transfers: try engine(for: c))
                jobStatus = "Checking \(job.name)…"
                let plan = try await engine.preview(source: source, destination: job.destination, previous: job.records, exclusions: job.skipRules)
                backupsUI.progress = JobProgress(completed: 0, total: plan.uploadCount)
                let result = try await engine.run(plan, previous: job.records) { completed, total, path in
                    Task { @MainActor in
                        self.jobStatus = "\(completed) of \(total) · \(path)"
                        self.backupsUI.progress = JobProgress(completed: completed, total: total)
                    }
                }
                records = result.records
                run.uploaded = result.uploaded; run.failed = result.failures.count; run.skipped = plan.skippedPaths.count
                run.bytes = plan.entries.filter { $0.needsUpload && !$0.isDirectory && result.failures[$0.relativePath] == nil }.reduce(0) { $0 + $1.size }
                // Skip rules are the person's choice, not a problem; only files that failed make a run partial.
                run.result = result.failures.isEmpty ? .succeeded : (result.uploaded > 0 ? .partial : .failed)
                if !result.failures.isEmpty { run.note = "\(result.failures.count) files failed" }
                else if result.uploaded == 0 { run.note = "No changes" }
                summary = "\(result.uploaded) uploaded · \(result.failures.count) failed · \(plan.skippedPaths.count) skipped"
                if !result.failures.isEmpty { diagnostics.add("Backup \(job.name): \(result.failures.count) files failed.") }
            } catch is CancellationError {
                summary = "Stopped · local files and completed remote copies kept"
                run.result = .partial; run.note = "Stopped"
            } catch { summary = message(for: error); run.note = summary }
            jobStatus = summary
            run.finished = Date()
            // Merge into the saved job, so a pause, rename or edit made while this ran is kept.
            guard var updated = jobs.first(where: { $0.id == job.id }) else { return }
            let sameTarget = updated.source == job.source && updated.connectionID == job.connectionID && updated.destination == job.destination
            if sameTarget, let records { updated.records = records }
            updated.lastSummary = summary
            updated.runs = Array(((updated.runs ?? []) + [run]).suffix(60))
            updated.lastRun = Date(); updated.nextRun = updated.nextRun(after: Date())
            do { try saveJob(updated) } catch { say("Could not save backup results: \(message(for: error))", error: true) }
        }
    }

    func stopJob() { jobTask?.cancel() }

    func startJobScheduler() {
        jobScheduler?.cancel()
        jobScheduler = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.runningJob == nil, !self.queuePaused else { continue }
                self.skipMissedRuns()
                if let job = self.jobs.first(where: { $0.enabled && $0.nextRun <= Date() && self.conditionsMet($0) }) { self.runJob(job) }
            }
        }
    }

    /// Jobs with catch-up off record a missed run and wait for their next time instead of running late.
    private func skipMissedRuns() {
        let now = Date()
        for var job in jobs where job.enabled && !job.catchesUp && now.timeIntervalSince(job.nextRun) > 600 {
            let missed = BackupRun(started: job.nextRun, finished: job.nextRun, result: .missed, uploaded: 0, failed: 0, skipped: 0, bytes: 0,
                                   note: "Mac was asleep or Syncophant was closed")
            job.runs = Array(((job.runs ?? []) + [missed]).suffix(60))
            job.nextRun = job.nextRun(after: now)
            try? saveJob(job)
        }
    }

    /// Why a due job is waiting, or nil when it can run. Back Up Now ignores these.
    func waitingReason(_ job: BackupJob) -> String? {
        if job.requiresPower == true, !Self.onPowerAdapter { return "Waiting for the power adapter" }
        if job.skipOnHotspot == true, backupsUI.network.currentPath.isExpensive { return "Waiting to leave Personal Hotspot" }
        return nil
    }

    func conditionsMet(_ job: BackupJob) -> Bool { waitingReason(job) == nil }

    static var onPowerAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    /// Bytes per second measured on earlier backup runs to this storage, or nil when nothing was measured.
    func measuredBackupSpeed(for connectionID: UUID) -> Double? {
        let all: [BackupRun] = jobs.filter { $0.connectionID == connectionID }.flatMap { $0.runs ?? [] }
        let runs = all.filter { $0.bytes >= 1_000_000 && $0.duration >= 5 }.suffix(10)
        let seconds: TimeInterval = runs.reduce(0) { $0 + $1.duration }
        let bytes: Int64 = runs.reduce(0) { $0 + $1.bytes }
        if seconds > 0 { return Double(bytes) / seconds }
        guard connectionID == activeID else { return nil }
        let live = throughput.suffix(60).map(\.sending).filter { $0 > 0 }
        return live.isEmpty ? nil : live.reduce(0, +) / Double(live.count)
    }

    /// Shows a backup's folder on its storage in Files.
    func showBackupFolder(_ job: BackupJob) {
        if job.connectionID != activeID { select(job.connectionID) }
        openFolder(job.destination)
        show(.files)
    }
}

extension AppModel {
    /// Opens the New backup window, empty or loaded with an existing backup to edit.
    func editBackup(_ id: UUID?) {
        backupsUI.editRequest = BackupsState.EditRequest(job: id)
        open(.newBackup)
    }
}
