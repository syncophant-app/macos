import Foundation
import Darwin

/// A private stdin/stdout bridge; rclone owns keys, name encryption and authenticated data blocks.
actor CryptBridge {
    struct Request: Encodable, Sendable {
        var op: String
        var password: String? = nil
        var password2: String? = nil
        var path: String? = nil
        var data: Data? = nil
        var offset: Int64? = nil
        var length: Int64? = nil
        var size: Int64? = nil
        var session: String? = nil
    }

    struct Response: Decodable, Sendable {
        var name: String? = nil
        var data: Data? = nil
        var size: Int64? = nil
        var error: String? = nil
        var read: Bool? = nil
        var readOffset: Int64? = nil
        var readLength: Int64? = nil
    }

    private let executable: URL
    private let password: String
    private let password2: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()
    private var busy = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(executable: URL, password: String, password2: String) {
        self.executable = executable
        self.password = password
        self.password2 = password2
    }

    deinit {
        try? input?.close()
        try? output?.close()
        process?.terminate()
    }

    func command(_ request: Request,
                 fetch: (@Sendable (Int64, Int) async throws -> Data)? = nil) async throws -> Response {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        var unfinished = false
        do {
            try await start()
            try await send(request)
            unfinished = true
            while true {
                let result = try await receive()
                if result.read == true {
                    let offset = result.readOffset ?? 0, length = result.readLength ?? 0
                    guard let fetch, offset >= 0, length >= 0, length <= 17 * 1024 * 1024 else {
                        throw CryptStoreError.helperProtocol
                    }
                    let data = try await fetch(offset, Int(length))
                    try await send(Request(op: "data", data: data))
                    continue
                }
                unfinished = false
                if result.error != nil { throw CryptStoreError.authenticationOrCorruption }
                try Task.checkCancellation()
                return result
            }
        } catch {
            // A cancelled transport callback leaves a request unfinished: discard that process.
            if unfinished || !(error is CryptStoreError) || (error as? CryptStoreError) == .helperProtocol {
                stop()
            }
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().1.resume() }
    }

    private func start() async throws {
        if let process, process.isRunning { return }
        stop()
        let process = Process(), inputPipe = Pipe(), outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = []
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        for handle in [inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw CryptStoreError.helperUnavailable
            }
        }
        // Suppress SIGPIPE only on our pipe; never change the app's process-wide signal disposition.
        guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CryptStoreError.helperUnavailable
        }
        do { try process.run() } catch { throw CryptStoreError.helperUnavailable }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        try await send(Request(op: "init", password: password, password2: password2))
        let response = try await receive()
        guard response.name == "rclone-crypt-v1.72.1", response.error == nil else {
            stop()
            throw CryptStoreError.helperProtocol
        }
    }

    private func stop() {
        try? input?.close()
        try? output?.close()
        process?.terminate()
        process = nil; input = nil; output = nil
        buffered.removeAll(keepingCapacity: false)
    }

    private func send(_ request: Request) async throws {
        guard let input else { throw CryptStoreError.helperUnavailable }
        var bytes = try JSONEncoder().encode(request)
        bytes.append(10)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var offset = 0
        while offset < bytes.count {
            try await ready(input.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw CryptStoreError.helperProtocol }
            offset += count
        }
    }

    private func receive() async throws -> Response {
        guard let output else { throw CryptStoreError.helperUnavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            try Task.checkCancellation()
            if let newline = buffered.range(of: Data([10]))?.lowerBound {
                guard buffered.distance(from: buffered.startIndex, to: newline) <= 48 * 1024 * 1024 else {
                    throw CryptStoreError.helperProtocol
                }
                let line = buffered.prefix(upTo: newline)
                let response = try JSONDecoder().decode(Response.self, from: line)
                buffered.removeSubrange(...newline)
                return response
            }
            guard buffered.count <= 48 * 1024 * 1024 else { throw CryptStoreError.helperProtocol }
            try await ready(output.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw CryptStoreError.helperProtocol }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }

    private func ready(_ fd: Int32, events: Int16, deadline: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CryptStoreError.helperProtocol }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw CryptStoreError.helperProtocol
            }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                throw CryptStoreError.helperProtocol
            }
            await Task.yield()
        }
    }
}
