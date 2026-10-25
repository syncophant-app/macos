import Foundation
import ServiceManagement
import Observation
import CoreKit

@Observable @MainActor
final class SSHAgentBroker {
    static let shared = SSHAgentBroker()
    private var listener: NSXPCListener?
    private var delegate: SSHAgentAppListener?
    private var registration: NSXPCConnection?
    private var registrationID: UUID?
    private(set) var status = "SSH agent access is off."

    /// Start only for configured agent users. Background-item approval is reported, never opened implicitly.
    func start() throws {
        if listener != nil {
            if registration == nil { registerEndpoint() }
            return
        }
        let service = SMAppService.agent(plistName: SSHAgentBrokerPolicy.launchAgentPlist)
        if service.status == .notRegistered { try service.register() }
        guard service.status == .enabled else {
            status = service.status == .requiresApproval
                ? "SSH agent access needs approval in System Settings → General → Login Items & Extensions."
                : "SSH agent access is unavailable. Reinstall Syncophant and try again."
            throw NSError(domain: "app.syncophant.mac.ssh-agent", code: 2, userInfo: [NSLocalizedDescriptionKey: status])
        }
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(SSHAgentBrokerPolicy.providerRequirement)
        let delegate = SSHAgentAppListener()
        listener.delegate = delegate
        self.delegate = delegate; self.listener = listener
        listener.activate()
        registerEndpoint()
    }

    func stop() {
        registrationID = nil; registration?.invalidate(); registration = nil
        listener?.invalidate(); listener = nil
        delegate?.stop(); delegate = nil
        status = "SSH agent access is off."
    }

    private func registerEndpoint() {
        guard let listener else { return }
        let token = UUID()
        let connection = NSXPCConnection(machServiceName: SSHAgentBrokerPolicy.registrationService)
        connection.setCodeSigningRequirement(SSHAgentBrokerPolicy.rendezvousRequirement)
        connection.remoteObjectInterface = SSHAgentXPCInterface.registration()
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.registrationID == token else { return }
                self.registration?.invalidate(); self.registration = nil
                self.status = "Reconnecting SSH agent access…"
                try? await Task.sleep(for: .seconds(1))
                if self.listener != nil { self.registerEndpoint() }
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.registrationID == token else { return }
                self.registration = nil; self.status = SSHAgentBrokerPolicy.unavailable.localizedDescription
            }
        }
        registrationID = token; registration = connection
        status = "Starting SSH agent access…"
        connection.activate()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self, self.registrationID == token else { return }
                self.status = SSHAgentBrokerPolicy.unavailable.localizedDescription
            }
        } as? SSHAgentEndpointRegistration
        proxy?.register(endpoint: listener.endpoint) { [weak self] accepted in
            Task { @MainActor in
                guard let self, self.registrationID == token else { return }
                self.status = accepted ? "SSH agent access is ready. Keep Syncophant open when using agent keys." : SSHAgentBrokerPolicy.unavailable.localizedDescription
            }
        }
    }
}

final class SSHAgentAppListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: NSXPCConnection] = [:]
    private var stopped = false
    let service: SSHAgentAppService
    init(service: SSHAgentAppService = SSHAgentAppService()) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = UUID()
        lock.lock()
        guard !stopped, connections.count < 32 else { lock.unlock(); return false }
        connections[id] = connection; lock.unlock()
        connection.exportedInterface = SSHAgentXPCInterface.signing(); connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in self?.remove(id) }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.activate(); return true
    }
    private func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; connections.removeValue(forKey: id) }
    func stop() {
        lock.lock(); stopped = true; let active = Array(connections.values); connections.removeAll(); lock.unlock()
        active.forEach { $0.invalidate() }
    }
}

final class SSHAgentAppService: NSObject, SSHAgentSigningService, @unchecked Sendable {
    typealias Configuration = @Sendable (UUID) throws -> (username: String, socketPath: String)
    private let configuration: Configuration
    private let requests = DispatchSemaphore(value: 6)
    private let queue = DispatchQueue(label: "app.syncophant.mac.ssh-agent", attributes: .concurrent)

    init(configuration: @escaping Configuration = { try SSHAgentAppService.savedConfiguration($0) }) { self.configuration = configuration }

    static func savedConfiguration(_ id: UUID) throws -> (username: String, socketPath: String) {
        guard let connection = try SharedConfig.loadConnections().first(where: { $0.id == id }),
              connection.provider == .sftp || connection.provider == .hetzner,
              let credentials = try StorageCredentials.load(for: id),
              case .ssh(.agent(let configuredPath)) = credentials.authentication,
              let path = configuredPath ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] else { throw SSHAgentBrokerPolicy.unavailable }
        return (connection.username, path)
    }

    func identities(connectionID: String, reply: @escaping @Sendable ([Data]?, NSError?) -> Void) {
        perform(connectionID: connectionID, reply: reply) { configuration, deadline in
            try SSHAgentSocketSigner(socketPath: configuration.socketPath).identities(deadline: deadline)
        }
    }

    func sign(connectionID: String, publicKey: Data, challenge: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        guard publicKey.count <= 16_384, challenge.count <= 256 * 1024 else { reply(nil, SSHAgentBrokerPolicy.unavailable); return }
        perform(connectionID: connectionID, reply: reply) { configuration, deadline in
            let auth = try SSHAgentAuthenticationRequest(challenge: challenge)
            guard auth.username == configuration.username, auth.publicKey == publicKey else { throw CoreKitError.authenticationFailed }
            return try SSHAgentSocketSigner(socketPath: configuration.socketPath).sign(publicKey: publicKey, challenge: challenge, deadline: deadline)
        }
    }

    private func perform<T: Sendable>(connectionID: String, reply: @escaping @Sendable (T?, NSError?) -> Void,
                                     operation: @escaping @Sendable ((username: String, socketPath: String), TimeInterval) throws -> T) {
        guard let id = UUID(uuidString: connectionID), requests.wait(timeout: .now()) == .success else { reply(nil, SSHAgentBrokerPolicy.unavailable); return }
        queue.async { [self] in
            defer { requests.signal() }
            do { reply(try operation(configuration(id), ProcessInfo.processInfo.systemUptime + 15), nil) }
            catch { reply(nil, NSError(domain: "app.syncophant.mac.ssh-agent", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "SSH agent authentication failed. Keep Syncophant and your agent open, then approve the sign-in request."])) }
        }
    }
}

struct SSHAgentBrokerClient: SSHAgentSigner {
    let connectionID: UUID

    func identities(deadline: TimeInterval) throws -> [Data] {
        let connection = try signingConnection(deadline: deadline)
        defer { connection.invalidate() }
        let keys: [Data] = try SSHAgentXPC.call(connection, deadline: deadline) { proxy, complete in
            (proxy as? SSHAgentSigningService)?.identities(connectionID: connectionID.uuidString) { keys, error in
                complete(keys.map(Result.success) ?? .failure(error ?? SSHAgentBrokerPolicy.unavailable))
            }
        }
        guard keys.count <= 128, keys.allSatisfy({ !$0.isEmpty && $0.count <= 16_384 }), keys.reduce(0, { $0 + $1.count }) <= 256 * 1024 else { throw CoreKitError.authenticationFailed }
        return keys
    }

    func sign(publicKey: Data, challenge: Data, deadline: TimeInterval) throws -> Data {
        let connection = try signingConnection(deadline: deadline)
        defer { connection.invalidate() }
        let signature: Data = try SSHAgentXPC.call(connection, deadline: deadline) { proxy, complete in
            (proxy as? SSHAgentSigningService)?.sign(connectionID: connectionID.uuidString, publicKey: publicKey, challenge: challenge) { signature, error in
                complete(signature.map(Result.success) ?? .failure(error ?? SSHAgentBrokerPolicy.unavailable))
            }
        }
        guard !signature.isEmpty, signature.count <= 256 * 1024 else { throw CoreKitError.authenticationFailed }
        return signature
    }

    private func signingConnection(deadline: TimeInterval) throws -> NSXPCConnection {
        let lookup = NSXPCConnection(machServiceName: SSHAgentBrokerPolicy.lookupService)
        lookup.setCodeSigningRequirement(SSHAgentBrokerPolicy.rendezvousRequirement)
        lookup.remoteObjectInterface = SSHAgentXPCInterface.lookup(); lookup.activate()
        defer { lookup.invalidate() }
        let endpoint: NSXPCListenerEndpoint = try SSHAgentXPC.call(lookup, deadline: deadline) { proxy, complete in
            (proxy as? SSHAgentEndpointLookup)?.endpoint { endpoint in
                complete(endpoint.map(Result.success) ?? .failure(SSHAgentBrokerPolicy.unavailable))
            }
        }
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.setCodeSigningRequirement(SSHAgentBrokerPolicy.appRequirement)
        connection.remoteObjectInterface = SSHAgentXPCInterface.signing(); connection.activate()
        return connection
    }
}

enum SSHAgentXPC {
    static func call<T>(_ connection: NSXPCConnection, deadline: TimeInterval,
                        invoke: (Any, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) throws -> T {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw CoreKitError.timeout }
        let reply = SSHAgentXPCReply<T>()
        connection.invalidationHandler = { reply.finish(.failure(SSHAgentBrokerPolicy.unavailable)) }
        connection.interruptionHandler = { reply.finish(.failure(SSHAgentBrokerPolicy.unavailable)) }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(.failure(SSHAgentBrokerPolicy.unavailable)) }
        invoke(proxy) { reply.finish($0) }
        while reply.ready.wait(timeout: .now() + 0.05) == .timedOut {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CoreKitError.timeout }
        }
        return try reply.value().get()
    }
}

private final class SSHAgentXPCReply<T>: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func finish(_ value: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }; result = value; ready.signal()
    }
    func value() -> Result<T, Error> { lock.lock(); defer { lock.unlock() }; return result! }
}
