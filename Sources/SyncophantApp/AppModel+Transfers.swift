import SwiftUI
import CoreKit

extension AppModel {
    /// Uploads that run at once, 1–6 (Settings default 2).
    var maxParallel: Int { min(6, max(1, settings.parallelUploads ?? 2)) }

    func setParallelUploads(_ count: Int) {
        var updated = settings
        updated.parallelUploads = min(6, max(1, count))
        save(updated)
        pump()
    }

    var activeTransfers: [Transfer] { transfers.filter { $0.phase.isActive } }
    var hasTransfers: Bool { !transfers.isEmpty }

    /// Uploads files and folders into `folder`. Folders are recreated remotely; temp files are skipped.
    func upload(_ urls: [URL], to folder: String? = nil) {
        guard let c = active else { say("Add a storage connection first.", error: true); return }
        let target = folder ?? uploadFolder
        Task {
            do {
                let store = try remoteStore(for: c)
                var added = 0
                for url in urls {
                    do {
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values?.isSymbolicLink == true { say("Skipped \(url.lastPathComponent): links are not uploaded.", error: true); continue }
                        if values?.isDirectory == true {
                            added += try await enqueueFolder(url, under: target, connection: c, store: store)
                        } else if PathRules.isVisible(path: "/" + url.lastPathComponent) {
                            enqueue(url, remote: join(target, url.lastPathComponent), connection: c)
                            added += 1
                        }
                    } catch { say("Could not queue \(url.lastPathComponent): \(message(for: error))", error: true) }
                }
                if added == 0 { say("Nothing to upload. Temporary files are never uploaded.") }
                persistQueue()
                pump()
            } catch { say("Could not queue the upload: \(message(for: error))", error: true) }
        }
    }

    private func enqueueFolder(_ url: URL, under target: String, connection c: StorageConnection, store: any RemoteStore) async throws -> Int {
        let base = join(target, url.lastPathComponent)
        try await makeDirectory(base, store)
        var count = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let item = walker?.nextObject() as? URL {
            let relative = String(item.path.dropFirst(url.path.count))
            guard PathRules.isVisible(path: relative) else { walker?.skipDescendants(); continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                do { try await makeDirectory(base + relative, store) }
                catch { walker?.skipDescendants(); say("Could not upload folder \(item.lastPathComponent): \(message(for: error))", error: true) }
            }
            else { enqueue(item, remote: base + relative, connection: c); count += 1 }
        }
        return count
    }

    private func makeDirectory(_ path: String, _ store: any RemoteStore) async throws {
        do { try await store.createDirectory(path: path) }
        catch CoreKitError.alreadyExists {
            guard try await store.stat(path: path).isDirectory else { throw CoreKitError.alreadyExists(path) }
        }
    }

    private func enqueue(_ url: URL, remote: String, connection c: StorageConnection) {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        transfers.append(Transfer(connectionID: c.id, localURL: url, remotePath: remote, size: size))
    }

    func join(_ folder: String, _ name: String) -> String { (folder == "/" ? "" : folder) + "/" + name }

    /// Starts waiting uploads in list order. A paused running upload keeps its slot; paused waiting ones are skipped.
    func pump() {
        pruneFinished()
        guard !queuePaused else { return }
        var free = maxParallel - transfers.filter { $0.phase == .working }.count
        for t in transfers where t.phase == .queued && !t.isHeld && free > 0 { start(t.id); free -= 1 }
    }

    /// Finished rows leave 24 hours after they finish. Failed and unverified ones stay until retried: they need you.
    private func pruneFinished(now: Date = Date()) {
        let before = transfers.count
        transfers.removeAll { t in
            (t.phase == .verified || t.phase == .cancelled) && now.timeIntervalSince(t.finishedAt ?? .distantPast) >= 86_400
        }
        if transfers.count != before { persistQueue() }
    }

    /// Moves a waiting upload to where `target` sits, so `pump()` starts it in that order.
    func moveWaiting(_ id: UUID, to target: UUID) {
        guard id != target, let from = transfers.firstIndex(where: { $0.id == id }), transfers[from].phase == .queued,
              let goal = transfers.firstIndex(where: { $0.id == target }) else { return }
        let item = transfers.remove(at: from)
        transfers.insert(item, at: goal)  // after the target when moving down, before it when moving up
        persistQueue()
    }

    /// Puts a waiting upload first in line.
    func uploadNext(_ id: UUID) {
        guard let first = transfers.first(where: { $0.phase == .queued }) else { return }
        moveWaiting(id, to: first.id)
    }

    /// Pauses or resumes one upload. A running one holds between chunks and keeps its partial, so it resumes from that byte.
    func setHeld(_ id: UUID, _ held: Bool) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].phase.isActive else { return }
        transfers[i].held = held ? true : nil
        transfers[i].bytesPerSecond = nil; transfers[i].progressDate = nil; transfers[i].progressBytes = nil
        let engine = transfers[i].phase == .working ? engines[transfers[i].connectionID] : nil
        persistQueue()
        Task {
            await engine?.setHeld(held, resumeID: id)
            if !held { pump() }
        }
    }

    private func start(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }),
              let c = connections.first(where: { $0.id == transfers[i].connectionID }) else { return }
        transfers[i].phase = .working
        persistQueue()
        let t = transfers[i]
        uploadTasks[id] = Task {
            var result: Transfer.Phase
            var finalPath = t.remotePath
            do {
                noteContact(c)
                let engine = try engine(for: c)
                await engine.setPaused(queuePaused)
                await configureBandwidth(engine)
                let receipt = try await engine.upload(localURL: t.localURL, remotePath: t.remotePath, resumeID: t.id) { event in
                    Task { @MainActor in self.apply(event, to: id) }
                }
                finalPath = receipt.remotePath
                if receipt.verified {
                    verifiedVersions[verifiedKey(c.id, receipt.remotePath)] = receipt.remoteVersion
                    if !isDemo { try? SharedJSON.save(verifiedVersions, name: "verified.json") }
                }
                result = receipt.verified ? .verified : .unverified
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failed(message(for: error))
                diagnostics.add("Upload failed: \(message(for: error))")
            }
            if let i = transfers.firstIndex(where: { $0.id == id }) {
                transfers[i].phase = result
                transfers[i].finishedAt = Date()
                transfers[i].held = nil
                if result == .verified || result == .unverified { transfers[i].publishedPath = finalPath }
            }
            uploadTasks[id] = nil
            if result == .verified || result == .unverified { recordHistory(bytes: t.size, verified: result == .verified) }
            persistQueue()
            if result == .verified || result == .unverified { await recordUpload(finalPath, connection: c) }
            pump()
        }
    }

    private func apply(_ event: UploadProgress, to id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].phase == .working else { return }
        switch event {
        case .uploading(let done, _):
            let now = Date()
            if transfers[i].isHeld { transfers[i].completed = done; return }
            if let date = transfers[i].progressDate, let previous = transfers[i].progressBytes, now.timeIntervalSince(date) >= 0.3, done > previous {
                let rate = Double(done - previous) / now.timeIntervalSince(date)
                transfers[i].bytesPerSecond = transfers[i].bytesPerSecond.map { $0 * 0.7 + rate * 0.3 } ?? rate
                transfers[i].progressDate = now; transfers[i].progressBytes = done
            } else if transfers[i].progressDate == nil {
                transfers[i].progressDate = now; transfers[i].progressBytes = done
            }
            transfers[i].completed = done
        case .verifying: transfers[i].isVerifying = true
        case .verified: break
        }
    }

    /// Reloads the listing only. The verified badge comes from the receipt's remote version, never from this listing:
    /// it disappears if another writer replaces the file.
    private func recordUpload(_ path: String, connection c: StorageConnection) async {
        guard c.id == activeID, let loader = browser else { return }
        let parent = PathRules.parent(of: path)
        if let node = loader.find(path: parent), parent != loader.rootPath { await loader.load(node) } else { await loader.loadRoot() }
    }

    func cancel(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        if transfers[i].phase == .queued { transfers[i].phase = .cancelled; transfers[i].finishedAt = Date() }
        transfers[i].held = nil
        uploadTasks[id]?.cancel()
        if let engine = engines[transfers[i].connectionID] { Task { await engine.setHeld(false, resumeID: id) } }
        persistQueue()
    }

    func cancelAll() { for t in activeTransfers { cancel(t.id) } }

    func retry(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), !transfers[i].phase.isActive else { return }
        transfers[i].phase = .queued
        transfers[i].completed = 0
        transfers[i].isVerifying = false
        transfers[i].finishedAt = nil; transfers[i].held = nil
        transfers[i].bytesPerSecond = nil; transfers[i].progressDate = nil; transfers[i].progressBytes = nil
        persistQueue()
        pump()
    }

    func clearFinished() { transfers.removeAll { !$0.phase.isActive }; persistQueue() }

    func setPaused(_ paused: Bool) {
        queuePaused = paused
        persistQueue()
        let activeEngines = Array(engines.values)
        Task {
            for engine in activeEngines { await engine.setPaused(queuePaused) }
            if !queuePaused { pump() }
        }
    }

    func setBandwidth(_ bandwidth: AppSettings.Bandwidth) {
        var updated = settings
        updated.bandwidth = bandwidth
        save(updated)
        let activeEngines = Array(engines.values)
        Task {
            for engine in activeEngines {
                await configureBandwidth(engine)
            }
        }
    }

    private func configureBandwidth(_ engine: TransferEngine) async {
        if settings.bandwidth == .auto { await engine.setAdaptiveBandwidth(true) }
        else {
            await engine.setAdaptiveBandwidth(false)
            await engine.setBandwidthLimit(bytesPerSecond: settings.bandwidth == .limited ? 20_000_000 : nil)
        }
    }

    func recordHistory(bytes: Int64, verified: Bool, upload: Bool = true) {
        history.entries.append(.init(date: Date(), bytes: bytes, verified: verified, upload: upload))
        history = history.pruned()
        guard !isDemo else { return }
        try? SharedJSON.save(history, name: "history.json")
    }

    /// Samples the summed engine speed once a second while anything transfers. Stops adding samples when idle.
    func startThroughputSampler() {
        samplerTask?.cancel()
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let working = self.transfers.filter { $0.phase == .working }
                let speed = self.queuePaused ? 0 : working.compactMap(\.bytesPerSecond).reduce(0, +)
                if working.isEmpty, self.throughput.allSatisfy({ $0.sending == 0 }) {
                    if !self.throughput.isEmpty { self.throughput = [] }
                    continue
                }
                var samples = self.throughput
                samples.append(ThroughputSample(date: Date(), sending: speed))
                if samples.count > 120 { samples.removeFirst(samples.count - 120) }
                self.throughput = samples
            }
        }
    }

    /// Times one cheap `stat("/")` on an open session. Measured, never estimated; the first call absorbs any sign-in.
    func roundTrip(to c: StorageConnection) async throws -> TimeInterval {
        noteContact(c)
        let store = try remoteStore(for: c)
        _ = try await store.stat(path: "/")
        let start = ContinuousClock.now
        _ = try await store.stat(path: "/")
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    /// Bytes still to send for everything waiting or moving.
    var bytesLeftInQueue: Int64 { activeTransfers.reduce(0) { $0 + max(0, $1.size - $1.completed) } }

    /// Overall progress of everything waiting or moving, by bytes.
    var transferProgress: Double? {
        let active = activeTransfers
        let total = active.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return nil }
        return Double(active.reduce(Int64(0)) { $0 + $1.completed }) / Double(total)
    }

    func persistQueue() {
        guard !isDemo else { return }
        do { try SharedJSON.save(TransferQueueSnapshot(transfers: transfers, paused: queuePaused), name: "transfers.json") }
        catch { say("Could not save the upload queue: \(message(for: error))", error: true) }
        // Finder reads upload state from transfers.json for its badges and menus; ask it to look again.
        requestCacheCheck()
    }

    var transferSummary: String {
        let working = transfers.filter { $0.phase == .working }.count
        let queued = transfers.filter { $0.phase == .queued }.count
        if working + queued == 0 { return transfers.isEmpty ? "No transfers" : "All uploads finished" }
        if queuePaused { return "Paused · \(queued + working) waiting" }
        return "\(working) uploading, \(queued) waiting"
    }
}
