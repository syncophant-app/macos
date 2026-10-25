import Foundation
import CLibSSH2

public actor SFTPStore: RemoteStore {
    private let connection: StorageConnection
    private let authentication: SSHAuthentication
    private let sessionBudgetURL: URL?
    private let agentSigner: (any SSHAgentSigner)?
    private var active: SSHSession?
    private var statFormat: SFTPStatFormat?
    private var statProbed = false
    private var readCache = SFTPReadCache()

    public init(connection: StorageConnection, password: String?, privateKey: String?, passphrase: String? = nil, sessionBudgetURL: URL? = nil) {
        self.connection = connection
        self.agentSigner = nil
        self.sessionBudgetURL = sessionBudgetURL
        self.authentication = privateKey.map { .privateKey(contents: $0, passphrase: passphrase) } ?? .password(password ?? "")
    }

    public init(connection: StorageConnection, authentication: SSHAuthentication, sessionBudgetURL: URL? = nil, agentSigner: (any SSHAgentSigner)? = nil) {
        self.connection = connection; self.authentication = authentication
        self.agentSigner = agentSigner
        self.sessionBudgetURL = sessionBudgetURL
    }

    public func installPublicKey(_ publicKey: String, hetzner: Bool) throws {
        let ssh = try connected()
        try ssh.installPublicKey(publicKey, hetzner: hetzner)
    }

    public static func probeHostKey(host: String, port: Int, sessionBudgetURL: URL? = nil) async throws -> String {
        let session = try SSHSession(host: host, port: port, sessionBudgetURL: sessionBudgetURL)
        try session.handshake()
        return try session.fingerprint()
    }

    public func disconnect() { active = nil; statFormat = nil; statProbed = false; readCache.clear() }

    public func list(path: String) throws -> [RemoteEntry] {
        try operation { ssh, deadline in
            let virtual = try PathRules.normalize(path)
            let full = try checkedPath(virtual, ssh: ssh, deadline: deadline)
            let handle = try ssh.pointer(deadline: deadline) {
                libssh2_sftp_open_ex(ssh.sftp, full, UInt32(full.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR)
            }
            var closed = false
            defer { if !closed { close(handle, ssh: ssh, deadline: deadline) } }
            var result: [RemoteEntry] = [], buffer = [CChar](repeating: 0, count: 4097)
            while true {
                try ssh.check(deadline)
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                let count = libssh2_sftp_readdir_ex(handle, &buffer, buffer.count - 1, nil, 0, &attributes)
                if count == LIBSSH2_ERROR_EAGAIN { try ssh.wait(deadline: deadline); continue }
                guard count >= 0 else { throw ssh.failure(count, path: virtual) }
                if count == 0 { break }
                guard let name = String(bytes: buffer.prefix(Int(count)).map({ UInt8(bitPattern: $0) }), encoding: .utf8) else { continue }
                if name == "." || name == ".." || name.contains("/") || PathRules.isTemporary(name) { continue }
                let child = (virtual == "/" ? "" : virtual) + "/" + name
                guard (try? PathRules.normalize(child)) != nil, supported(attributes) else { continue }
                result.append(try entry(child, attributes))
            }
            closed = true
            try ssh.status(deadline: deadline) { libssh2_sftp_close_handle(handle) }
            try enrichRevisions(&result, ssh: ssh, deadline: deadline)
            return result.sorted { $0.name < $1.name }
        }
    }

    public func stat(path: String) throws -> RemoteEntry {
        try operation { ssh, deadline in try snapshot(path, ssh: ssh, deadline: deadline) }
    }

    private func snapshot(_ path: String, ssh: SSHSession, deadline: TimeInterval) throws -> RemoteEntry {
        let virtual = try PathRules.normalize(path)
        let full = try checkedPath(virtual, ssh: ssh, deadline: deadline)
        let before = try entry(virtual, attributes(full, ssh: ssh, deadline: deadline))
        if before.isDirectory { return before }
        if let revision = try serverRevision(full, ssh: ssh, deadline: deadline), revision.highResolution {
            var after = try entry(virtual, attributes(full, ssh: ssh, deadline: deadline))
            guard !after.isDirectory, before.version == after.version,
                  revision.size == after.size, revision.modifiedSeconds == Int64(after.modifiedAt.timeIntervalSince1970) else {
                throw CoreKitError.itemChanged(virtual)
            }
            after.remoteRevision = revision.value
            readCache.validate(path: virtual, version: after.version)
            return after
        }
        let digest = try serverChecksum(full, ssh: ssh, deadline: deadline)
        var after = try entry(virtual, attributes(full, ssh: ssh, deadline: deadline))
        guard !after.isDirectory, before.version == after.version else { throw CoreKitError.itemChanged(virtual) }
        after.contentHash = digest
        readCache.validate(path: virtual, version: after.version)
        return after
    }

    public func read(path: String, offset: Int64, length: Int) throws -> Data {
        try PathRules.validateRange(offset: offset, length: length)
        return try operation { ssh, deadline in
            let virtual = try PathRules.normalize(path)
            let before = try snapshot(virtual, ssh: ssh, deadline: deadline)
            guard !before.isDirectory else { throw CoreKitError.unsafePath(virtual) }
            if let cached = readCache.read(path: virtual, version: before.version, offset: offset, length: length, fileSize: before.size) {
                guard try snapshot(virtual, ssh: ssh, deadline: deadline).version == before.version else {
                    throw CoreKitError.itemChanged(virtual)
                }
                return cached
            }
            let full = try checkedPath(virtual, ssh: ssh, deadline: deadline)
            let handle = try openFile(full, flags: UInt(LIBSSH2_FXF_READ), ssh: ssh, deadline: deadline)
            var closed = false
            defer { if !closed { close(handle, ssh: ssh, deadline: deadline) } }
            libssh2_sftp_seek64(handle, UInt64(offset))
            let available = max(0, before.size - offset)
            let warmedLength = length == 0 ? 0 : length <= SFTPReadCache.capacity ? SFTPReadCache.capacity : length
            let readLength = Int(min(Int64(warmedLength), available))
            var data = Data(count: readLength), total = 0
            try data.withUnsafeMutableBytes { bytes in
                while total < readLength {
                    try ssh.check(deadline)
                    let count = libssh2_sftp_read(handle, bytes.baseAddress!.advanced(by: total).assumingMemoryBound(to: CChar.self), min(256 * 1024, readLength - total))
                    if count == LIBSSH2_ERROR_EAGAIN { try ssh.wait(deadline: deadline); continue }
                    guard count >= 0 else { throw ssh.failure(Int32(count), path: virtual) }
                    if count == 0 { break }
                    total += count
                }
            }
            data.count = total
            closed = true
            try ssh.status(deadline: deadline) { libssh2_sftp_close_handle(handle) }
            guard total == readLength, try snapshot(virtual, ssh: ssh, deadline: deadline).version == before.version else {
                throw CoreKitError.itemChanged(virtual)
            }
            if length > 0 { readCache.insert(path: virtual, version: before.version, offset: offset, data: data) }
            return Data(data.prefix(length))
        }
    }

    public func write(path: String, offset: Int64, data: Data) throws {
        readCache.clear()
        try PathRules.validateRange(offset: offset, length: data.count)
        try operation { ssh, deadline in
            let full = try checkedPath(path, allowMissingLeaf: true, ssh: ssh, deadline: deadline)
            let handle = try openFile(full, flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT), ssh: ssh, deadline: deadline)
            var closed = false
            defer { if !closed { close(handle, ssh: ssh, deadline: deadline) } }
            libssh2_sftp_seek64(handle, UInt64(offset))
            try data.withUnsafeBytes { bytes in
                var total = 0
                while total < data.count {
                    try ssh.check(deadline)
                    let count = libssh2_sftp_write(handle, bytes.baseAddress!.advanced(by: total).assumingMemoryBound(to: CChar.self), data.count - total)
                    if count == LIBSSH2_ERROR_EAGAIN || count == 0 { try ssh.wait(deadline: deadline); continue }
                    guard count > 0 else { throw ssh.failure(Int32(count), path: path) }
                    total += count
                }
            }
            closed = true
            try ssh.status(deadline: deadline) { libssh2_sftp_close_handle(handle) }
        }
    }

    public func createDirectory(path: String) throws {
        readCache.clear()
        try operation { ssh, deadline in
            let full = try checkedPath(path, allowMissingLeaf: true, ssh: ssh, deadline: deadline)
            try ssh.status(deadline: deadline) { libssh2_sftp_mkdir_ex(ssh.sftp, full, UInt32(full.utf8.count), 0o700) }
        }
    }

    public func move(from: String, to: String) throws {
        readCache.clear()
        try operation { ssh, deadline in
            guard try PathRules.normalize(from) != "/", try PathRules.normalize(to) != "/" else { throw CoreKitError.invalidPath(to) }
            let source = try checkedPath(from, ssh: ssh, deadline: deadline)
            let target = try checkedPath(to, allowMissingLeaf: true, ssh: ssh, deadline: deadline)
            do { _ = try attributes(target, ssh: ssh, deadline: deadline); throw CoreKitError.alreadyExists(to) }
            catch CoreKitError.notFound { }
            do {
                // SFTP v3 rename without OVERWRITE preserves an existing destination.
                try ssh.status(deadline: deadline) {
                    libssh2_sftp_rename_ex(ssh.sftp, source, UInt32(source.utf8.count), target, UInt32(target.utf8.count), 0)
                }
            } catch {
                if (try? attributes(target, ssh: ssh, deadline: deadline)) != nil { throw CoreKitError.alreadyExists(to) }
                throw error
            }
        }
    }

    public func remove(path: String) throws {
        readCache.clear()
        try operation { ssh, deadline in
            guard try PathRules.normalize(path) != "/" else { throw CoreKitError.invalidPath(path) }
            let full = try checkedPath(path, ssh: ssh, deadline: deadline)
            let info = try attributes(full, ssh: ssh, deadline: deadline)
            try ssh.status(deadline: deadline) {
                if info.permissions & 0o170000 == 0o040000 {
                    return libssh2_sftp_rmdir_ex(ssh.sftp, full, UInt32(full.utf8.count))
                }
                return libssh2_sftp_unlink_ex(ssh.sftp, full, UInt32(full.utf8.count))
            }
        }
    }

    public func checksum(path: String) throws -> String {
        try operation { ssh, deadline in
            let full = try checkedPath(path, ssh: ssh, deadline: deadline)
            return try serverChecksum(full, ssh: ssh, deadline: deadline)
        }
    }

    private func enrichRevisions(_ entries: inout [RemoteEntry], ssh: SSHSession, deadline: TimeInterval) throws {
        let indices = entries.indices.filter { !entries[$0].isDirectory }
        guard let first = indices.first else { return }
        func fullPath(_ index: Int) -> String { (ssh.root == "/" ? "" : ssh.root) + entries[index].path }
        if !statProbed { _ = try serverRevision(fullPath(first), ssh: ssh, deadline: deadline) }
        guard let statFormat else { return }
        for start in stride(from: 0, to: indices.count, by: 16) {
            let batch = Array(indices[start..<min(start + 16, indices.count)])
            let result = try execute(statFormat.command(paths: batch.map(fullPath)), ssh: ssh, deadline: deadline)
            guard result.status == 0 else { continue }
            let rows = result.output.split(separator: 10, omittingEmptySubsequences: true)
            guard rows.count == batch.count else { continue }
            for (index, row) in zip(batch, rows) {
                if let revision = statFormat.parse(Data(row)), revision.highResolution,
                   revision.size == entries[index].size,
                   revision.modifiedSeconds == Int64(entries[index].modifiedAt.timeIntervalSince1970) {
                    entries[index].remoteRevision = revision.value
                    readCache.validate(path: entries[index].path, version: entries[index].version)
                }
            }
        }
    }

    private func serverRevision(_ full: String, ssh: SSHSession, deadline: TimeInterval) throws -> SFTPStatRevision? {
        if statProbed {
            guard let statFormat else { return nil }
            let result = try execute(statFormat.command(path: full), ssh: ssh, deadline: deadline)
            return result.status == 0 ? statFormat.parse(result.output) : nil
        }
        for format in SFTPStatFormat.allCases {
            let result = try execute(format.command(path: full), ssh: ssh, deadline: deadline)
            if result.status == 0, let revision = format.parse(result.output) {
                statFormat = format; statProbed = true
                return revision
            }
        }
        statProbed = true
        return nil
    }

    private func serverChecksum(_ full: String, ssh: SSHSession, deadline: TimeInterval) throws -> String {
        let result = try execute("sha256sum -- " + PathRules.shellQuote(full), ssh: ssh, deadline: deadline)
        guard result.status == 0 else { throw CoreKitError.remote("The server could not compute SHA256. Nothing was published.") }
        let token = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw CoreKitError.remote("The server returned an invalid SHA256 checksum.")
        }
        return token.lowercased()
    }

    private func execute(_ command: String, ssh: SSHSession, deadline: TimeInterval) throws -> (status: Int32, output: Data) {
        let channel = try ssh.pointer(deadline: deadline) {
            libssh2_channel_open_ex(ssh.session, "session", 7, 2 * 1024 * 1024, UInt32(LIBSSH2_CHANNEL_PACKET_DEFAULT), nil, 0)
        }
        defer {
            do { try ssh.status(deadline: deadline) { libssh2_channel_free(channel) } }
            catch { disconnect() }
        }
        while true {
            try ssh.check(deadline)
            let result = libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count))
            if result == LIBSSH2_ERROR_EAGAIN { try ssh.wait(deadline: deadline); continue }
            if result == LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED {
                try ssh.status(deadline: deadline) { libssh2_channel_close(channel) }
                try ssh.status(deadline: deadline) { libssh2_channel_wait_closed(channel) }
                return (127, Data())
            }
            guard result >= 0 else { throw ssh.failure(result) }
            break
        }
        var output = Data(), total = 0, buffer = [CChar](repeating: 0, count: 4096)
        while true {
            try ssh.check(deadline)
            var progressed = false
            for stream: Int32 in [0, SSH_EXTENDED_DATA_STDERR] {
                let count = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                if count == LIBSSH2_ERROR_EAGAIN { continue }
                guard count >= 0 else { throw ssh.failure(Int32(count)) }
                if count > 0 {
                    progressed = true; total += count
                    guard total <= 65536 else { throw CoreKitError.remote("Unexpected SSH command output.") }
                    if stream == 0 { output.append(contentsOf: buffer.prefix(count).map { UInt8(bitPattern: $0) }) }
                }
            }
            if libssh2_channel_eof(channel) != 0 && !progressed { break }
            if !progressed { try ssh.wait(deadline: deadline) }
        }
        try ssh.status(deadline: deadline) { libssh2_channel_close(channel) }
        try ssh.status(deadline: deadline) { libssh2_channel_wait_closed(channel) }
        return (libssh2_channel_get_exit_status(channel), output)
    }

    private func operation<T>(_ body: (SSHSession, TimeInterval) throws -> T) throws -> T {
        do {
            let ssh = try connected()
            return try body(ssh, ProcessInfo.processInfo.systemUptime + 30)
        } catch {
            // Discard incomplete libssh2 state after cancellation, timeout, or protocol failure.
            if case CoreKitError.notFound = error { throw error }
            if case CoreKitError.alreadyExists = error { throw error }
            if case CoreKitError.unsafePath = error { throw error }
            if case CoreKitError.invalidPath = error { throw error }
            disconnect()
            throw error
        }
    }

    private func connected() throws -> SSHSession {
        if let active { return active }
        guard let pinned = connection.hostKeyFingerprint, !pinned.isEmpty else { throw CoreKitError.hostKeyRequired }
        let configuredRoot = try PathRules.normalize(connection.rootPath)
        let ssh = try SSHSession(host: connection.host, port: connection.port, sessionBudgetURL: sessionBudgetURL)
        try ssh.handshake()
        guard try ssh.fingerprint() == pinned else { throw CoreKitError.hostKeyMismatch }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        guard !connection.username.isEmpty, !connection.username.contains("\0") else { throw CoreKitError.authenticationFailed }
        try ssh.authenticate(username: connection.username, authentication: authentication, deadline: deadline, agentSigner: agentSigner)
        ssh.sftp = try ssh.pointer(deadline: deadline) { libssh2_sftp_init(ssh.session) }
        var rootBuffer = [CChar](repeating: 0, count: 4097)
        var length: Int32 = 0
        try ssh.status(deadline: deadline) {
            length = libssh2_sftp_symlink_ex(ssh.sftp, configuredRoot, UInt32(configuredRoot.utf8.count), &rootBuffer, UInt32(rootBuffer.count - 1), LIBSSH2_SFTP_REALPATH)
            return length
        }
        guard length > 0, length < rootBuffer.count - 1 else { throw CoreKitError.unsafePath(configuredRoot) }
        guard let root = String(bytes: rootBuffer.prefix(Int(length)).map({ UInt8(bitPattern: $0) }), encoding: .utf8) else {
            throw CoreKitError.unsafePath(configuredRoot)
        }
        ssh.root = try PathRules.normalize(root)
        let rootInfo = try attributes(ssh.root, ssh: ssh, deadline: deadline)
        guard rootInfo.permissions & 0o170000 == 0o040000 else { throw CoreKitError.unsafePath(configuredRoot) }
        active = ssh
        return ssh
    }

    private func attributes(_ path: String, ssh: SSHSession, deadline: TimeInterval) throws -> LIBSSH2_SFTP_ATTRIBUTES {
        var info = LIBSSH2_SFTP_ATTRIBUTES()
        do {
            try ssh.status(deadline: deadline) {
                libssh2_sftp_stat_ex(ssh.sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_LSTAT, &info)
            }
        } catch CoreKitError.notFound { throw CoreKitError.notFound(path) }
        guard info.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else { throw CoreKitError.remote("SFTP server omitted file type attributes.") }
        return info
    }

    private func checkedPath(_ path: String, allowMissingLeaf: Bool = false, ssh: SSHSession, deadline: TimeInterval) throws -> String {
        let virtual = try PathRules.normalize(path)
        var rootPrefix = ""
        for part in ssh.root.split(separator: "/") {
            rootPrefix += "/" + part
            let info = try attributes(rootPrefix, ssh: ssh, deadline: deadline)
            guard info.permissions & 0o170000 == 0o040000 else { throw CoreKitError.unsafePath(virtual) }
        }
        var full = ssh.root == "/" ? "" : ssh.root
        let parts = virtual.split(separator: "/")
        for (index, part) in parts.enumerated() {
            full += "/" + part
            do {
                let info = try attributes(full, ssh: ssh, deadline: deadline)
                guard supported(info), index == parts.count - 1 || info.permissions & 0o170000 == 0o040000 else {
                    throw CoreKitError.unsafePath(virtual)
                }
            } catch CoreKitError.notFound {
                if allowMissingLeaf && index == parts.count - 1 { return full }
                throw CoreKitError.notFound(virtual)
            }
        }
        return full.isEmpty ? "/" : full
    }

    private func openFile(_ path: String, flags: UInt, ssh: SSHSession, deadline: TimeInterval) throws -> OpaquePointer {
        let handle = try ssh.pointer(deadline: deadline) {
            libssh2_sftp_open_ex(ssh.sftp, path, UInt32(path.utf8.count), flags, 0o600, LIBSSH2_SFTP_OPENFILE)
        }
        var info = LIBSSH2_SFTP_ATTRIBUTES()
        do {
            try ssh.status(deadline: deadline) { libssh2_sftp_fstat_ex(handle, &info, 0) }
            guard supported(info), info.permissions & 0o170000 == 0o100000 else { throw CoreKitError.unsafePath(path) }
            return handle
        } catch { close(handle, ssh: ssh, deadline: deadline); throw error }
    }

    private func close(_ handle: OpaquePointer, ssh: SSHSession, deadline: TimeInterval) {
        do { try ssh.status(deadline: deadline) { libssh2_sftp_close_handle(handle) } }
        catch { active = nil }
    }

    private func supported(_ info: LIBSSH2_SFTP_ATTRIBUTES) -> Bool {
        let type = info.permissions & 0o170000
        return info.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 && (type == 0o100000 || type == 0o040000)
    }

    private func entry(_ path: String, _ info: LIBSSH2_SFTP_ATTRIBUTES) throws -> RemoteEntry {
        guard supported(info), info.filesize <= UInt64(Int64.max),
              info.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0,
              info.permissions & 0o170000 == 0o040000 || info.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 else { throw CoreKitError.unsafePath(path) }
        return RemoteEntry(name: PathRules.name(of: path), path: path, isDirectory: info.permissions & 0o170000 == 0o040000,
                           size: Int64(info.filesize), modifiedAt: Date(timeIntervalSince1970: Double(info.mtime)))
    }
}
