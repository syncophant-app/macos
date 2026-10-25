import Foundation

/// This helper only holds a live app endpoint; it cannot read credentials or contact an SSH agent.
final class SSHAgentRendezvous: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: NSXPCListenerEndpoint?
    private var owner: UUID?
    private var connections: [UUID: NSXPCConnection] = [:]
    private let registerListener: NSXPCListener
    private let lookupListener: NSXPCListener
    private var delegates: [SSHAgentRendezvousListener] = []

    override init() {
        registerListener = NSXPCListener(machServiceName: SSHAgentBrokerPolicy.registrationService)
        lookupListener = NSXPCListener(machServiceName: SSHAgentBrokerPolicy.lookupService)
        super.init()
        registerListener.setConnectionCodeSigningRequirement(SSHAgentBrokerPolicy.appRequirement)
        lookupListener.setConnectionCodeSigningRequirement(SSHAgentBrokerPolicy.providerRequirement)
        delegates = [SSHAgentRendezvousListener(registry: self, registration: true), SSHAgentRendezvousListener(registry: self, registration: false)]
        registerListener.delegate = delegates[0]; lookupListener.delegate = delegates[1]
    }

    func start() { registerListener.activate(); lookupListener.activate() }

    func stop() {
        registerListener.invalidate(); lookupListener.invalidate()
        lock.lock(); let active = Array(connections.values); connections.removeAll(); endpoint = nil; owner = nil; lock.unlock()
        active.forEach { $0.invalidate() }
    }

    static func run() {
        let service = SSHAgentRendezvous()
        service.start()
        withExtendedLifetime(service) { RunLoop.current.run() }
    }

    fileprivate func accept(_ connection: NSXPCConnection, registration: Bool) -> Bool {
        let token = UUID()
        lock.lock()
        guard connections.count < 32 else { lock.unlock(); return false }
        connections[token] = connection
        lock.unlock()
        connection.exportedInterface = registration ? SSHAgentXPCInterface.registration() : SSHAgentXPCInterface.lookup()
        connection.exportedObject = SSHAgentRendezvousPeer(registry: self, token: token)
        connection.invalidationHandler = { [weak self] in self?.remove(token) }
        connection.interruptionHandler = { [weak self, weak connection] in self?.remove(token); connection?.invalidate() }
        connection.activate()
        return true
    }

    private func remove(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: token)
        if owner == token { owner = nil; endpoint = nil }
    }

    fileprivate func publish(_ endpoint: NSXPCListenerEndpoint, token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connections[token] != nil else { return false }
        self.endpoint = endpoint; owner = token
        return true
    }

    fileprivate func currentEndpoint() -> NSXPCListenerEndpoint? {
        lock.lock(); defer { lock.unlock() }; return endpoint
    }
}

private final class SSHAgentRendezvousListener: NSObject, NSXPCListenerDelegate {
    weak var registry: SSHAgentRendezvous?
    let registration: Bool
    init(registry: SSHAgentRendezvous, registration: Bool) { self.registry = registry; self.registration = registration }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        registry?.accept(connection, registration: registration) ?? false
    }
}

private final class SSHAgentRendezvousPeer: NSObject, SSHAgentEndpointRegistration, SSHAgentEndpointLookup {
    weak var registry: SSHAgentRendezvous?
    let token: UUID
    init(registry: SSHAgentRendezvous, token: UUID) { self.registry = registry; self.token = token }
    func register(endpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void) { reply(registry?.publish(endpoint, token: token) ?? false) }
    func endpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) { reply(registry?.currentEndpoint()) }
}
