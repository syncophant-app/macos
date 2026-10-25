import Foundation
import CryptoKit
import Darwin
import CLibSSH2

private struct SSHAddress: Sendable {
    let bytes: Data
    let family: Int32
    let type: Int32
    let protocolNumber: Int32
}

private final class DNSResult: @unchecked Sendable {
    let lock = NSLock()
    let ready = DispatchSemaphore(value: 0)
    var addresses: [SSHAddress] = []
    var succeeded = false
}

private final class AgentTransport {
    let socket: Int32
    let deadline: TimeInterval
    init(socket: Int32, deadline: TimeInterval) { self.socket = socket; self.deadline = deadline }
    func wait(_ fd: Int32, writing: Bool) -> Bool {
        while true {
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return false }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            var row = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
            let result = Darwin.poll(&row, 1, 100)
            if result > 0 { return true }
            if result < 0 && errno != EINTR { return false }
        }
    }
}

private let agentReceive: @convention(c) (Int32, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { fd, buffer, length, flags, abstract in
    guard let pointer = abstract?.pointee else { return -Int(EINVAL) }
    let transport = Unmanaged<AgentTransport>.fromOpaque(pointer).takeUnretainedValue()
    if fd != transport.socket && !transport.wait(fd, writing: false) { return -Int(ETIMEDOUT) }
    let count = Darwin.recv(fd, buffer, length, flags | MSG_DONTWAIT)
    if count == 0 && fd != transport.socket { return -Int(ECONNRESET) }
    return count < 0 ? -Int(errno) : count
}

private let agentSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { fd, buffer, length, flags, abstract in
    guard let pointer = abstract?.pointee else { return -Int(EINVAL) }
    let transport = Unmanaged<AgentTransport>.fromOpaque(pointer).takeUnretainedValue()
    if fd != transport.socket && !transport.wait(fd, writing: true) { return -Int(ETIMEDOUT) }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let count = Darwin.send(fd, buffer, length, flags | MSG_DONTWAIT)
    return count < 0 ? -Int(errno) : count
}

private final class AgentSignContext {
    let signer: any SSHAgentSigner
    let publicKey: Data
    let deadline: TimeInterval
    var failure: Error?
    init(signer: any SSHAgentSigner, publicKey: Data, deadline: TimeInterval) {
        self.signer = signer; self.publicKey = publicKey; self.deadline = deadline
    }
}

private let agentSign: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 = { _, signature, size, bytes, count, abstract in
    guard let pointer = abstract?.pointee, let signature, let size, let bytes, count <= 256 * 1024 else { return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED }
    let context = Unmanaged<AgentSignContext>.fromOpaque(pointer).takeUnretainedValue()
    do {
        let result = try context.signer.sign(publicKey: context.publicKey, challenge: Data(bytes: bytes, count: count), deadline: context.deadline)
        guard !result.isEmpty, result.count <= 256 * 1024, let allocation = malloc(result.count) else { return LIBSSH2_ERROR_ALLOC }
        result.copyBytes(to: allocation.assumingMemoryBound(to: UInt8.self), count: result.count)
        signature.pointee = allocation.assumingMemoryBound(to: UInt8.self); size.pointee = result.count
        return 0
    } catch { context.failure = error; return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED }
}

/// The actor exclusively owns this object and every libssh2 pointer it contains.
final class SSHSession: @unchecked Sendable {
    static let initialized: Int32 = libssh2_init(0)
    let socket: Int32
    let session: OpaquePointer
    let lease: SSHConnectionLease?
    var sftp: OpaquePointer?
    var root: String = "/"

    init(host: String, port: Int, sessionBudgetURL: URL? = nil) throws {
        guard Self.initialized == 0, !host.isEmpty, !host.contains("\0"), (1...65535).contains(port) else {
            throw CoreKitError.connection("Invalid SSH endpoint or libssh2 initialization failure.")
        }
        lease = try sessionBudgetURL.map { try SSHConnectionLease(directory: $0, host: host) }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let addresses = try Self.resolve(host: host, port: port, deadline: deadline)
        var connected: Int32 = -1
        for address in addresses {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CoreKitError.timeout }
            let fd = Darwin.socket(address.family, address.type, address.protocolNumber)
            if fd < 0 { continue }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let result = address.bytes.withUnsafeBytes { bytes in
                Darwin.connect(fd, bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(bytes.count))
            }
            if result == 0 { connected = fd; break }
            if errno == EINPROGRESS {
                do {
                    try Self.poll(fd, events: Int16(POLLOUT), deadline: deadline)
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 {
                        connected = fd; break
                    }
                } catch { Darwin.close(fd); throw error }
            }
            Darwin.close(fd)
        }
        guard connected >= 0 else { throw CoreKitError.connection("Could not connect to the SSH server.") }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            Darwin.close(connected); throw CoreKitError.connection("Could not allocate an SSH session.")
        }
        socket = connected; self.session = session
        libssh2_session_set_blocking(session, 0)
        libssh2_session_set_timeout(session, 15_000)
    }

    func handshake() throws {
        try status(deadline: ProcessInfo.processInfo.systemUptime + 15) { libssh2_session_handshake(session, socket) }
    }

    /// The caller must compare the pinned host key before entering this method.
    func authenticate(username: String, authentication: SSHAuthentication, deadline: TimeInterval, agentSigner: (any SSHAgentSigner)? = nil) throws {
        guard !username.isEmpty, !username.contains("\0"), username.utf8.count <= 1024 else { throw CoreKitError.authenticationFailed }
        switch authentication {
        case .password(let password):
            try status(deadline: deadline) {
                libssh2_userauth_password_ex(session, username, UInt32(username.utf8.count), password, UInt32(password.utf8.count), nil)
            }
        case .privateKey(let contents, let passphrase):
            guard !contents.isEmpty, !contents.contains("\0"), passphrase?.contains("\0") != true else { throw CoreKitError.authenticationFailed }
            try status(deadline: deadline) {
                libssh2_userauth_publickey_frommemory(session, username, username.utf8.count, nil, 0, contents, contents.utf8.count, passphrase)
            }
        case .agent(let socketPath):
            if let agentSigner {
                try authenticateAgent(username: username, signer: agentSigner, deadline: deadline)
                return
            }
            guard let path = socketPath ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
                  path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < 104 else {
                throw CoreKitError.connection("No SSH agent socket is available. Choose a private key or start your agent.")
            }
            guard let agent = libssh2_agent_init(session) else { throw CoreKitError.authenticationFailed }
            defer { _ = libssh2_agent_disconnect(agent); libssh2_agent_free(agent) }
            // libssh2's Unix-agent I/O is blocking by default; bound it without changing process environment.
            let transport = AgentTransport(socket: socket, deadline: deadline)
            let abstract = libssh2_session_abstract(session)!
            let oldAbstract = abstract.pointee
            abstract.pointee = Unmanaged.passUnretained(transport).toOpaque()
            let receive = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, unsafeBitCast(agentReceive, to: (@convention(c) () -> Void).self))
            let send = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, unsafeBitCast(agentSend, to: (@convention(c) () -> Void).self))
            defer {
                _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, receive)
                _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, send)
                abstract.pointee = oldAbstract
                withExtendedLifetime(transport) {}
            }
            try path.withCString { path in
                libssh2_agent_set_identity_path(agent, path)
                try status(deadline: deadline) { libssh2_agent_connect(agent) }
                try status(deadline: deadline) { libssh2_agent_list_identities(agent) }
                var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
                for _ in 0..<128 {
                    try check(deadline)
                    var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
                    let result = libssh2_agent_get_identity(agent, &identity, previous)
                    if result == 1 { break }
                    guard result == 0, let identity else { throw CoreKitError.authenticationFailed }
                    do {
                        try status(deadline: deadline) { libssh2_agent_userauth(agent, username, identity) }
                        return
                    } catch CoreKitError.authenticationFailed { previous = identity }
                }
                throw CoreKitError.authenticationFailed
            }
        }
    }

    private func authenticateAgent(username: String, signer: any SSHAgentSigner, deadline: TimeInterval) throws {
        let keys = try signer.identities(deadline: deadline)
        guard keys.count <= 128 else { throw CoreKitError.authenticationFailed }
        for key in keys {
            try check(deadline)
            guard !key.isEmpty, key.count <= 16_384 else { throw CoreKitError.authenticationFailed }
            let context = AgentSignContext(signer: signer, publicKey: key, deadline: deadline)
            var abstract: UnsafeMutableRawPointer? = Unmanaged.passUnretained(context).toOpaque()
            do {
                try key.withUnsafeBytes { bytes in
                    try status(deadline: deadline) {
                        libssh2_userauth_publickey(session, username, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count, agentSign, &abstract)
                    }
                }
                return
            } catch {
                if let failure = context.failure { throw failure }
                guard case CoreKitError.authenticationFailed = error else { throw error }
            }
        }
        throw CoreKitError.authenticationFailed
    }

    func installPublicKey(_ publicKey: String, hetzner: Bool) throws {
        let parts = publicKey.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519", Data(base64Encoded: String(parts[1])) != nil,
              !publicKey.contains(where: { $0.isNewline || $0 == "\0" }), publicKey.utf8.count < 4096 else {
            throw CoreKitError.connection("Invalid generated SSH public key.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let channel = try pointer(deadline: deadline) { libssh2_channel_open_ex(session, "session", 7, 2_097_152, 32768, nil, 0) }
        defer { _ = libssh2_channel_free(channel) }
        // Hetzner's command adds both RFC4716 and OpenSSH; generic OpenSSH appends without replacing other keys.
        let command = hetzner ? "install-ssh-key" : "umask 077; mkdir -p \"$HOME/.ssh\" && test ! -L \"$HOME/.ssh\" && test ! -L \"$HOME/.ssh/authorized_keys\" && chmod 700 \"$HOME/.ssh\" && cat >> \"$HOME/.ssh/authorized_keys\" && chmod 600 \"$HOME/.ssh/authorized_keys\""
        try status(deadline: deadline) { libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count)) }
        let input = Data(((hetzner ? "" : "\n") + publicKey + "\n").utf8)
        try input.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try check(deadline)
                let count = libssh2_channel_write_ex(channel, 0, bytes.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self), bytes.count - sent)
                if count == LIBSSH2_ERROR_EAGAIN || count == 0 { try wait(deadline: deadline); continue }
                guard count > 0 else { throw failure(Int32(count)) }
                sent += count
            }
        }
        try status(deadline: deadline) { libssh2_channel_send_eof(channel) }
        var buffer = [CChar](repeating: 0, count: 4096), total = 0
        while true {
            try check(deadline)
            var progressed = false
            for stream in 0...1 {
                let count = libssh2_channel_read_ex(channel, Int32(stream), &buffer, buffer.count)
                if count == LIBSSH2_ERROR_EAGAIN { continue }
                guard count >= 0 else { throw failure(Int32(count)) }
                total += count; progressed = progressed || count > 0
                guard total < 65_536 else { throw CoreKitError.connection("SSH key installation returned too much output.") }
            }
            if libssh2_channel_eof(channel) != 0 && !progressed { break }
            if !progressed { try wait(deadline: deadline) }
        }
        try status(deadline: deadline) { libssh2_channel_close(channel) }
        guard libssh2_channel_get_exit_status(channel) == 0 else { throw CoreKitError.connection("The server could not install the SSH public key. Your existing keys were kept.") }
    }

    deinit {
        _ = shutdown(socket, SHUT_RDWR)
        // Teardown cannot wait on an unresponsive peer.
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 100)
        if let sftp { _ = libssh2_sftp_shutdown(sftp) }
        _ = libssh2_session_free(session)
        Darwin.close(socket)
    }

    func fingerprint() throws -> String {
        var length = 0, type: Int32 = 0
        guard let bytes = libssh2_session_hostkey(session, &length, &type), length > 0 else {
            throw CoreKitError.connection("The server did not supply a host key.")
        }
        let digest = SHA256.hash(data: Data(bytes: bytes, count: length))
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func wait(deadline: TimeInterval) throws {
        let directions = libssh2_session_block_directions(session)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
        if events == 0 { events = Int16(POLLIN) }
        try Self.poll(socket, events: events, deadline: deadline)
    }

    func status(deadline: TimeInterval, _ call: () -> Int32) throws {
        while true {
            try check(deadline)
            let result = call()
            if result == LIBSSH2_ERROR_EAGAIN { try wait(deadline: deadline); continue }
            guard result >= 0 else { throw failure(result) }
            return
        }
    }

    func pointer(deadline: TimeInterval, _ call: () -> OpaquePointer?) throws -> OpaquePointer {
        while true {
            try check(deadline)
            if let result = call() { return result }
            let code = libssh2_session_last_errno(session)
            if code == LIBSSH2_ERROR_EAGAIN { try wait(deadline: deadline); continue }
            throw failure(code)
        }
    }

    func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw CoreKitError.timeout }
    }

    func failure(_ code: Int32, path: String = "") -> CoreKitError {
        if code == LIBSSH2_ERROR_SFTP_PROTOCOL, let sftp {
            let status = libssh2_sftp_last_error(sftp)
            if status == LIBSSH2_FX_NO_SUCH_FILE || status == LIBSSH2_FX_NO_SUCH_PATH { return .notFound(path) }
            if status == LIBSSH2_FX_FILE_ALREADY_EXISTS { return .alreadyExists(path) }
            return .remote("SFTP operation failed (status \(status)).")
        }
        if code == LIBSSH2_ERROR_AUTHENTICATION_FAILED || code == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED { return .authenticationFailed }
        return .connection("SSH operation failed (code \(code)).")
    }

    private static func poll(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CoreKitError.timeout }
            var row = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&row, 1, Int32(min(100, ceil(remaining * 1000))))
            if result < 0 {
                if errno == EINTR { continue }
                throw CoreKitError.connection("SSH socket polling failed.")
            }
            if result > 0 {
                guard row.revents & Int16(POLLNVAL) == 0 else { throw CoreKitError.connection("SSH socket closed.") }
                return
            }
        }
    }

    private static func resolve(host: String, port: Int, deadline: TimeInterval) throws -> [SSHAddress] {
        let result = DNSResult()
        // macOS getaddrinfo has no deadline; bound the caller while its system resolver finishes.
        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
            var rows: UnsafeMutablePointer<addrinfo>?
            let code = getaddrinfo(host, String(port), &hints, &rows)
            var addresses: [SSHAddress] = []
            if code == 0 {
                var row = rows
                while let current = row {
                    if let address = current.pointee.ai_addr {
                        addresses.append(SSHAddress(bytes: Data(bytes: address, count: Int(current.pointee.ai_addrlen)),
                                                    family: current.pointee.ai_family, type: current.pointee.ai_socktype,
                                                    protocolNumber: current.pointee.ai_protocol))
                    }
                    row = current.pointee.ai_next
                }
            }
            if let rows { freeaddrinfo(rows) }
            result.lock.lock(); result.addresses = addresses; result.succeeded = code == 0; result.lock.unlock()
            result.ready.signal()
        }
        while result.ready.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CoreKitError.timeout }
        }
        result.lock.lock(); defer { result.lock.unlock() }
        guard result.succeeded, !result.addresses.isEmpty else { throw CoreKitError.connection("Could not resolve the SSH server.") }
        return result.addresses
    }
}

