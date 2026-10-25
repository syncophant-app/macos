import Foundation

enum SSHAgentBrokerPolicy {
    static let appGroup = "group.app.syncophant.mac"
    static let registrationService = appGroup + ".ssh-agent.register"
    static let lookupService = appGroup + ".ssh-agent.lookup"
    static let launchAgentPlist = "app.syncophant.mac.agent-rendezvous.plist"
    static let appRequirement = requirement("app.syncophant.mac")
    static let providerRequirement = requirement("app.syncophant.mac.provider")
    static let rendezvousRequirement = requirement("app.syncophant.mac.agent-rendezvous")

    private static func requirement(_ identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"654ASRW868\" and identifier \"\(identifier)\""
    }

    static var unavailable: NSError {
        NSError(domain: "app.syncophant.mac.ssh-agent", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Keep Syncophant open to use your SSH agent. Check SSH agent access in Settings if it is already open."])
    }
}

@objc protocol SSHAgentEndpointRegistration {
    func register(endpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void)
}

@objc protocol SSHAgentEndpointLookup {
    func endpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

@objc protocol SSHAgentSigningService {
    func identities(connectionID: String, reply: @escaping @Sendable ([Data]?, NSError?) -> Void)
    func sign(connectionID: String, publicKey: Data, challenge: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
}

enum SSHAgentXPCInterface {
    static func registration() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SSHAgentEndpointRegistration.self)
        interface.setClasses(NSSet(object: NSXPCListenerEndpoint.self) as! Set<AnyHashable>, for: #selector(SSHAgentEndpointRegistration.register(endpoint:reply:)), argumentIndex: 0, ofReply: false)
        return interface
    }
    static func lookup() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SSHAgentEndpointLookup.self)
        interface.setClasses(NSSet(object: NSXPCListenerEndpoint.self) as! Set<AnyHashable>, for: #selector(SSHAgentEndpointLookup.endpoint(reply:)), argumentIndex: 0, ofReply: true)
        return interface
    }
    static func signing() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SSHAgentSigningService.self)
        interface.setClasses(NSSet(objects: NSArray.self, NSData.self) as! Set<AnyHashable>, for: #selector(SSHAgentSigningService.identities(connectionID:reply:)), argumentIndex: 0, ofReply: true)
        return interface
    }
}
