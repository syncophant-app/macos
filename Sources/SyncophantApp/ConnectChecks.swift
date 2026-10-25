import Foundation
import Security
import CoreKit
import Network
import dnssd

/// Small measured network probes for the connection check. Each opens one connection and closes it.
enum NetProbe {
    /// TCP reachability. Throws a plain message on refusal, a bad name or a 10-second timeout.
    static func reach(host: String, port: Int) async throws {
        _ = try await connect(host: host, port: port, parameters: .tcp)
    }

    /// TLS handshake with the system trust store; returns "TLS 1.3" or "TLS 1.2".
    static func tlsVersion(host: String, port: Int) async throws -> String {
        let metadata = try await connect(host: host, port: port, parameters: .tls)
        guard let meta = metadata else { return "TLS" }
        switch sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata) {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        default: return "TLS"
        }
    }

    static func milliseconds(_ t: TimeInterval) -> String { "\(max(1, Int((t * 1000).rounded()))) ms" }
    static func seconds(_ t: TimeInterval) -> String { t < 10 ? String(format: "%.1f s", t) : "\(Int(t.rounded())) s" }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func connect(host: String, port: Int, parameters: NWParameters) async throws -> NWProtocolTLS.Metadata? {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else {
            throw AppError.unavailable("Enter a server name and a port between 1 and 65535.")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters)
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWProtocolTLS.Metadata?, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard once.claim() else { return }
                        let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                        connection.cancel()
                        continuation.resume(returning: meta)
                    case .waiting(let error), .failed(let error):
                        guard once.claim() else { return }
                        connection.cancel()
                        continuation.resume(throwing: AppError.unavailable(describe(error, port: port)))
                    case .cancelled:
                        guard once.claim() else { return }
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: AppError.unavailable("The server did not answer within 10 seconds. Check the address and your network."))
                }
            }
        } onCancel: { connection.cancel() }
    }

    private static func describe(_ error: NWError, port: Int) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: return "Nothing answered on port \(port). Check the port."
        case .posix(let code) where code == .ETIMEDOUT: return "The server did not answer. Check the address and your network."
        case .dns: return "That server name was not found. Check the address."
        case .tls: return "Its certificate is not trusted, so the password would not be safe. Check the address."
        default: return error.localizedDescription
        }
    }
}

/// SMB servers advertised on the local network (`_smb._tcp`). Browsing and resolving stay on the local link.
@MainActor @Observable
final class NearbySMB {
    private(set) var names: [String] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.names = Array(Set(found)).sorted() }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }

    /// The host name a Bonjour service name points at, such as "nas-at-home.local".
    static func resolve(_ name: String) async -> String? {
        final class Box: @unchecked Sendable {
            var continuation: CheckedContinuation<String?, Never>?
            var ref: DNSServiceRef?
            let lock = NSLock()
            func finish(_ value: String?) {
                lock.lock(); let c = continuation; continuation = nil; lock.unlock()
                if let ref { DNSServiceRefDeallocate(ref); self.ref = nil }
                c?.resume(returning: value)
            }
        }
        let box = Box()
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            let context = Unmanaged.passRetained(box).toOpaque()
            let callback: DNSServiceResolveReply = { _, _, _, error, _, target, _, _, _, context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
                let host = error == kDNSServiceErr_NoError ? target.map { String(cString: $0) } : nil
                box.finish(host.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 })
            }
            var ref: DNSServiceRef?
            let status = DNSServiceResolve(&ref, 0, 0, name, "_smb._tcp", "local.", callback, context)
            guard status == kDNSServiceErr_NoError, let ref else {
                Unmanaged<Box>.fromOpaque(context).release()
                box.finish(nil); return
            }
            box.ref = ref
            DNSServiceSetDispatchQueue(ref, .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                box.lock.lock(); let pending = box.continuation != nil; box.lock.unlock()
                guard pending else { return }
                Unmanaged.passUnretained(box).release()
                box.finish(nil)
            }
        }
    }
}

/// The connection check for WebDAV, S3 and SMB: reach (latency), secure connection (TLS version, not SMB),
/// sign in, and a 1 MB write, read back and delete. Nothing is saved until Connect.
@MainActor @Observable
final class ServerCheck {
    typealias Step = ConnectModel.Step
    var steps: [Step] = []
    var running = false
    var latency: TimeInterval?
    var roundTrip: TimeInterval?
    /// The draft that passed, with the store that proved it; Connect saves exactly this.
    @ObservationIgnored private(set) var verified: (draft: StorageDraft, connection: StorageConnection, credentials: StorageCredentials, store: any RemoteStore)?

    var passed: Bool { verified != nil && !steps.isEmpty && steps.allSatisfy { $0.state == .done } }

    func reset() { steps = []; verified = nil; latency = nil; roundTrip = nil }

    func run(_ draft: StorageDraft, model: AppModel) async {
        guard !running, !model.isDemo else { return }
        reset()
        running = true
        defer { running = false }
        steps = [Step(kind: .reach, title: "Reach the server")]
            + (draft.provider == .smb ? [] : [Step(kind: .secure, title: "Secure connection")])
            + [Step(kind: .signIn, title: "Sign in"), Step(kind: .preflight, title: "Read and write 1 MB")]
        let made: (StorageConnection, StorageCredentials)
        do { made = try draft.make() } catch { fail(.reach, error, port: 0); return }
        let (connection, credentials) = made
        let store: any RemoteStore
        do { store = try credentials.makeStore(connection: connection) } catch { fail(.reach, error, port: connection.port); return }
        model.noteContact(host: connection.host, purpose: "Your storage · \(draft.provider.rawValue.uppercased()) setup")
        for step in steps {
            set(step.kind, .running)
            do {
                switch step.kind {
                case .reach:
                    let started = ProcessInfo.processInfo.systemUptime
                    try await NetProbe.reach(host: connection.host, port: connection.port)
                    latency = ProcessInfo.processInfo.systemUptime - started
                    set(.reach, .done, note: NetProbe.milliseconds(latency!))
                case .secure:
                    set(.secure, .done, note: try await NetProbe.tlsVersion(host: connection.host, port: connection.port))
                case .signIn:
                    _ = try await store.list(path: "/")
                    set(.signIn, .done, note: draft.provider == .s3 ? "access key" : draft.provider == .webdav && Self.looksLikeNextcloud(draft.endpoint) ? "app password" : "password")
                default:
                    roundTrip = try await Self.readWrite(store)
                    set(.preflight, .done, note: NetProbe.seconds(roundTrip!))
                }
            } catch is CancellationError {
                set(step.kind, .pending); return
            } catch {
                fail(step.kind, error, port: connection.port); return
            }
        }
        verified = (draft, connection, credentials, store)
    }

    /// Writes 1 MB of random bytes, reads them back, compares and deletes. Returns the round-trip time.
    static func readWrite(_ store: any RemoteStore) async throws -> TimeInterval {
        let path = "/.syncophant-preflight-" + UUID().uuidString
        var random = [UInt8](repeating: 0, count: 1_048_576)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw AppError.unavailable("Could not generate test bytes.") }
        let data = Data(random), started = ProcessInfo.processInfo.systemUptime
        do {
            try await store.write(path: path, offset: 0, data: data)
            let back = try await store.read(path: path, offset: 0, length: data.count)
            guard back == data else { throw CoreKitError.checksumMismatch }
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - started)
            try await store.remove(path: path)
            return elapsed
        } catch {
            try? await store.remove(path: path)
            throw error
        }
    }

    static func looksLikeNextcloud(_ address: String) -> Bool {
        let a = address.lowercased()
        return a.contains("remote.php") || a.contains("nextcloud") || a.contains("owncloud")
    }

    private func set(_ kind: Step.Kind, _ state: Step.State, note: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[i].state = state
        if let note { steps[i].note = note }
    }

    private func fail(_ kind: Step.Kind, _ error: Error, port: Int) {
        var text = ConnectModel.plain(error, step: kind, port: port)
        let lower = text.lowercased()
        if kind == .signIn, lower.contains("404") || lower.contains("nosuchbucket") || lower.contains("not found") {
            text = "Bucket or folder not found. Check its name and the region in the endpoint."
        } else if kind == .signIn, lower.contains("401") || lower.contains("403") {
            text = "The server refused the sign-in. Check the user name or key, and the password or secret."
        }
        set(kind, .failed(text))
    }
}
