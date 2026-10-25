import Foundation
import Darwin

/// An agent exposes public identities and signs SSH authentication packets, never private keys.
public protocol SSHAgentSigner: Sendable {
    func identities(deadline: TimeInterval) throws -> [Data]
    func sign(publicKey: Data, challenge: Data, deadline: TimeInterval) throws -> Data
}

public struct SSHAgentAuthenticationRequest: Sendable {
    public let username: String
    public let algorithm: String
    public let publicKey: Data

    public init(challenge: Data) throws {
        guard challenge.count <= SSHAgentWire.maximumPacket else { throw CoreKitError.authenticationFailed }
        var packet = SSHAgentWire(challenge)
        let sessionID = try packet.string()
        guard (16...64).contains(sessionID.count), try packet.byte() == 50,
              let username = String(data: try packet.string(), encoding: .utf8),
              !username.isEmpty, username.utf8.count <= 1024, !username.contains("\0"),
              try packet.string() == Data("ssh-connection".utf8),
              try packet.string() == Data("publickey".utf8), try packet.byte() == 1,
              let algorithm = String(data: try packet.string(), encoding: .utf8) else { throw CoreKitError.authenticationFailed }
        let key = try packet.string()
        guard packet.finished, !key.isEmpty, key.count <= 16_384 else { throw CoreKitError.authenticationFailed }
        var keyPacket = SSHAgentWire(key)
        let keyAlgorithm = try keyPacket.string()
        guard keyAlgorithm == Data(algorithm.utf8) ||
                (keyAlgorithm == Data("ssh-rsa".utf8) && ["rsa-sha2-256", "rsa-sha2-512"].contains(algorithm)) else { throw CoreKitError.authenticationFailed }
        self.username = username; self.algorithm = algorithm; self.publicKey = key
    }
}

struct SSHAgentWire {
    static let maximumPacket = 256 * 1024
    var data: Data
    var offset = 0
    init(_ data: Data = Data()) { self.data = Data(data) }
    var finished: Bool { offset == data.count }
    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw CoreKitError.authenticationFailed }
        defer { offset += 1 }; return data[offset]
    }
    mutating func uint32() throws -> UInt32 {
        guard data.count - offset >= 4 else { throw CoreKitError.authenticationFailed }
        var value: UInt32 = 0
        for _ in 0..<4 { value = value << 8 | UInt32(try byte()) }
        return value
    }
    mutating func string() throws -> Data {
        let size = Int(try uint32())
        guard size <= Self.maximumPacket, size <= data.count - offset else { throw CoreKitError.authenticationFailed }
        defer { offset += size }; return data.subdata(in: offset..<(offset + size))
    }
    mutating func append(_ value: UInt32) {
        var value = value.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    mutating func append(_ value: Data) { append(UInt32(value.count)); data.append(value) }
}

public struct SSHAgentSocketSigner: SSHAgentSigner {
    private let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }

    public func identities(deadline: TimeInterval) throws -> [Data] {
        var response = SSHAgentWire(try exchange(Data([11]), deadline: deadline))
        guard try response.byte() == 12 else { throw CoreKitError.authenticationFailed }
        let count = try response.uint32()
        guard count <= 128 else { throw CoreKitError.authenticationFailed }
        var keys: [Data] = []
        for _ in 0..<count {
            let key = try response.string()
            guard !key.isEmpty, key.count <= 16_384 else { throw CoreKitError.authenticationFailed }
            keys.append(key); _ = try response.string() // Agent comments stay in the app.
        }
        guard response.finished else { throw CoreKitError.authenticationFailed }
        return keys
    }

    public func sign(publicKey: Data, challenge: Data, deadline: TimeInterval) throws -> Data {
        let auth = try SSHAgentAuthenticationRequest(challenge: challenge)
        guard auth.publicKey == publicKey else { throw CoreKitError.authenticationFailed }
        var request = SSHAgentWire(Data([13]))
        request.append(publicKey); request.append(challenge)
        request.append(auth.algorithm == "rsa-sha2-512" ? UInt32(4) : auth.algorithm == "rsa-sha2-256" ? UInt32(2) : UInt32(0))
        var response = SSHAgentWire(try exchange(request.data, deadline: deadline))
        guard try response.byte() == 14 else { throw CoreKitError.authenticationFailed }
        var signature = SSHAgentWire(try response.string())
        guard response.finished, try signature.string() == Data(auth.algorithm.utf8) else { throw CoreKitError.authenticationFailed }
        let bytes = try signature.string()
        guard signature.finished, !bytes.isEmpty else { throw CoreKitError.authenticationFailed }
        return bytes
    }

    private func exchange(_ packet: Data, deadline: TimeInterval) throws -> Data {
        var address = sockaddr_un()
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0"),
              socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path),
              packet.count <= SSHAgentWire.maximumPacket else { throw CoreKitError.connection("No usable SSH agent socket is configured.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: Array(socketPath.utf8) + [0])
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreKitError.authenticationFailed }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CoreKitError.authenticationFailed }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw CoreKitError.authenticationFailed }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw CoreKitError.connection("The SSH agent is unavailable. Open your agent and try again.") }
            try wait(fd, writing: true, deadline: deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CoreKitError.authenticationFailed }
        }
        var framed = SSHAgentWire(); framed.append(packet)
        try framed.data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try wait(fd, writing: true, deadline: deadline)
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw CoreKitError.authenticationFailed }; sent += count
            }
        }
        func receive(_ size: Int) throws -> Data {
            var bytes = Data(count: size)
            try bytes.withUnsafeMutableBytes { buffer in
                var received = 0
                while received < size {
                    try wait(fd, writing: false, deadline: deadline)
                    let count = Darwin.recv(fd, buffer.baseAddress!.advanced(by: received), size - received, 0)
                    if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                    guard count > 0 else { throw CoreKitError.authenticationFailed }; received += count
                }
            }
            return bytes
        }
        var header = SSHAgentWire(try receive(4))
        let size = Int(try header.uint32())
        guard (1...SSHAgentWire.maximumPacket).contains(size) else { throw CoreKitError.authenticationFailed }
        return try receive(size)
    }

    private func wait(_ fd: Int32, writing: Bool, deadline: TimeInterval) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CoreKitError.timeout }
            var row = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
            let result = Darwin.poll(&row, 1, Int32(min(remaining * 1000 + 1, 100)))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw CoreKitError.authenticationFailed }
        }
    }
}
