import Foundation
import Darwin
import CoreKit

struct NetworkContact: Codable, Sendable {
    var host: String
    var purpose: String
    var lastContacted: Date
    var count: Int
}

enum ContactLedger {
    static func records() throws -> [NetworkContact] {
        try locked { url in try read(url) }
    }

    static func record(host: String, purpose: String) throws {
        guard !host.isEmpty else { return }
        try locked { url in
            var records = try read(url)
            if let index = records.firstIndex(where: { $0.host == host }) {
                records[index].lastContacted = Date()
                records[index].count += 1
                records[index].purpose = purpose
            } else {
                records.append(.init(host: host, purpose: purpose, lastContacted: Date(), count: 1))
            }
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        }
    }

    static func clear() throws {
        try locked { url in try JSONEncoder().encode([NetworkContact]()).write(to: url, options: .atomic) }
    }

    private static func read(_ url: URL) throws -> [NetworkContact] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([NetworkContact].self, from: Data(contentsOf: url))
    }

    private static func locked<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = try SharedConfig.directory()
        let fd = Darwin.open(directory.appendingPathComponent("contacts.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try body(directory.appendingPathComponent("contacts.json"))
    }
}

/// Records storage activity in the shared local ledger; never sends diagnostics anywhere.
actor LoggedRemoteStore: RemoteStore {
    private let base: any RemoteStore
    private let host: String
    private let purpose: String
    private var lastRecorded = Date.distantPast
    nonisolated var publicationMode: PublicationMode { base.publicationMode }
    nonisolated var supportsDirectoryMove: Bool { base.supportsDirectoryMove }
    nonisolated var supportsConditionalReplacement: Bool { base.supportsConditionalReplacement }

    init(base: any RemoteStore, host: String, port: Int, protocolName: String = "SFTP") {
        self.base = base
        self.host = host
        self.purpose = "Your storage · \(protocolName) on port \(port)"
    }
    private func record() {
        // Record active hosts at most once a minute, avoiding a disk write for every streamed chunk.
        guard Date().timeIntervalSince(lastRecorded) >= 60 else { return }
        if (try? ContactLedger.record(host: host, purpose: purpose)) != nil { lastRecorded = Date() }
    }
    func list(path: String) async throws -> [RemoteEntry] { record(); return try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteEntry { record(); return try await base.stat(path: path) }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { record(); return try await base.read(path: path, offset: offset, length: length) }
    func write(path: String, offset: Int64, data: Data) async throws { record(); try await base.write(path: path, offset: offset, data: data) }
    func createDirectory(path: String) async throws { record(); try await base.createDirectory(path: path) }
    func move(from: String, to: String) async throws { record(); try await base.move(from: from, to: to) }
    func remove(path: String) async throws { record(); try await base.remove(path: path) }
    func checksum(path: String) async throws -> String { record(); return try await base.checksum(path: path) }
    func prepareUpload(path: String) async throws { record(); try await base.prepareUpload(path: path) }
    func finishUpload(path: String) async throws { record(); try await base.finishUpload(path: path) }
    func publish(from: String, to: String) async throws { record(); try await base.publish(from: from, to: to) }
    func replace(from: String, to: String, expectedVersion: String) async throws { record(); try await base.replace(from: from, to: to, expectedVersion: expectedVersion) }
}
