import Foundation
import NetFS
import Darwin
import AMSMB2

/// Native SMB networking, mounted privately without authentication UI. No local-directory fallback.
public actor SMBStore: RemoteStore {
    private let url: URL
    private let username: String
    private let password: String
    private let share: String
    private let rootPath: String
    private var renameClient: SMB2Manager?
    private var mounted: LocalRemoteStore?
    private var mountpoint: URL?
    private var mounting = false

    public init(server: String, share: String, username: String, password: String, rootPath: String = "/") throws {
        let root = try PathRules.normalize(rootPath)
        guard !server.isEmpty, server.utf8.count <= 253, !server.contains(where: { $0.isWhitespace || "/\\@?#".contains($0) }),
              !share.isEmpty, share != ".", share != "..", !share.contains("/"), !share.contains("\\"),
              !share.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !username.isEmpty else {
            throw CoreKitError.connection("SMB requires a server hostname, share and username.")
        }
        var c = URLComponents(); c.scheme = "smb"; c.host = server
        c.percentEncodedPath = "/" + HTTPStoreSupport.encode(share) + (root == "/" ? "" : root.split(separator: "/").map { "/" + HTTPStoreSupport.encode(String($0)) }.joined())
        guard let url = c.url, url.host != nil else { throw CoreKitError.connection("Invalid SMB server hostname.") }
        self.url = url; self.username = username; self.password = password
        self.share = share; self.rootPath = root
    }

    deinit {
        mounted = nil
        if let mountpoint {
            // Never force-unmount: open descriptors or another process must not lose their filesystem.
            if unmount(mountpoint.path, 0) == 0 { Self.removeMountDirectories(mountpoint) }
        }
    }

    public static func mount(server: String, share: String, username: String, password: String,
                             rootPath: String = "/") async throws -> SMBStore {
        let store = try SMBStore(server: server, share: share, username: username, password: password, rootPath: rootPath)
        _ = try await store.store()
        return store
    }

    private func store() async throws -> LocalRemoteStore {
        try Task.checkCancellation()
        if let mounted { return mounted }
        // Actor reentrancy must not mount the same credentials/share twice.
        while mounting {
            try await Task.sleep(for: .milliseconds(50))
            if let mounted { return mounted }
        }
        mounting = true; defer { mounting = false }
        // Validate supplied credentials through an independent encrypted session before NetFS can reuse OS authentication.
        _ = try await authenticatedClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("syncophant-smb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let requestedPoint = directory.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: requestedPoint, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let resolved = realpath(requestedPoint.path, nil) else {
            try? FileManager.default.removeItem(at: directory)
            throw CoreKitError.connection("Cannot resolve the private SMB mount point.")
        }
        let point = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        let url = self.url, username = self.username, password = self.password
        // NetFS owns negotiation/authentication and the SMB network filesystem. Its synchronous API is isolated off the caller executor.
        let status = await Task.detached {
            let openOptions: NSMutableDictionary = [kNAUIOptionKey: kNAUIOptionNoUI,
                                                     kNetFSForceNewSessionKey: true, kNetFSUseGuestKey: false]
            if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") { openOptions[kNetFSAllowLoopbackKey] = true }
            let mountOptions: NSMutableDictionary = [kNetFSMountAtMountDirKey: true, kNetFSAllowSubMountsKey: true, kNetFSForceNewSessionKey: true,
                                                      kNetFSSoftMountKey: true,
                                                      kNetFSMountFlagsKey: MNT_DONTBROWSE | MNT_NOSUID | MNT_NODEV | MNT_NOEXEC]
            if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") { mountOptions[kNetFSAllowLoopbackKey] = true }
            var points: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url as CFURL, point as CFURL, username as CFString, password as CFString,
                                          openOptions, mountOptions, &points)
            _ = points?.takeRetainedValue()
            return status
        }.value
        do {
            guard status == 0 else {
                if status == EAUTH || status == EACCES { throw CoreKitError.authenticationFailed }
                throw CoreKitError.connection("Native SMB mount failed (\(status)). Check the share, credentials, network and macOS network-volume permission; no authentication dialog was opened.")
            }
            var fs = statfs()
            guard statfs(point.path, &fs) == 0 else { throw CoreKitError.connection("Cannot inspect the native SMB mount.") }
            let type = withUnsafePointer(to: &fs.f_fstypename) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
            }
            guard type == "smbfs" else { throw CoreKitError.connection("NetFS did not mount an SMB filesystem; local fallback is refused.") }
            try await Self.validateTransport(point)
            try Task.checkCancellation()
            let store = try LocalRemoteStore(root: point)
            self.mountpoint = point; mounted = store
            return store
        } catch {
            if status != 0 || unmount(point.path, 0) == 0 { Self.removeMountDirectories(point) }
            throw error
        }
    }

    private nonisolated static func removeMountDirectories(_ point: URL) {
        // Never recursively remove a mount path, even when mounting failed or unmounting was unacknowledged.
        _ = rmdir(point.path); _ = rmdir(point.deletingLastPathComponent().path)
    }

    private nonisolated static func validateTransport(_ point: URL) async throws {
        let output = try HTTPStoreSupport.temporary(); defer { HTTPStoreSupport.cleanup(output) }
        let file = try FileHandle(forWritingTo: output); defer { try? file.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = ["statshares", "-m", point.path, "-f", "JSON"]
        process.standardOutput = file; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CoreKitError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard process.terminationStatus == 0,
              (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024,
              let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]], rows.count == 1,
              (rows[0]["SMB_VERSION"] as? String)?.hasPrefix("SMB_3") == true,
              rows[0]["ENCRYPTION_REQUIRED"] as? Bool == true,
              rows[0]["SIGNING_ON"] as? Bool == true else {
            throw CoreKitError.connection("SMB requires SMB3 with server-required share encryption and signing. Enable both on the server; Syncophant does not change macOS SMB settings.")
        }
    }

    public func list(path: String) async throws -> [RemoteEntry] { try await store().list(path: path) }
    public func stat(path: String) async throws -> RemoteEntry { try await store().stat(path: path) }
    public func read(path: String, offset: Int64, length: Int) async throws -> Data { try await store().read(path: path, offset: offset, length: length) }
    public func write(path: String, offset: Int64, data: Data) async throws { try await store().write(path: path, offset: offset, data: data) }
    public func createDirectory(path: String) async throws { try await store().createDirectory(path: path) }
    public func move(from: String, to: String) async throws {
        let from = try PathRules.normalize(from), to = try PathRules.normalize(to)
        guard from != "/", to != "/" else { throw CoreKitError.invalidPath("/") }
        let local = try await store()
        _ = try await local.stat(path: from)
        // SMB rename is share-relative; reject observed symlinks in both parent walks before sending it.
        for path in [from, to] {
            var parent = ""
            for component in PathRules.parent(of: path).split(separator: "/") {
                parent += "/" + component
                guard try await local.stat(path: parent).isDirectory else { throw CoreKitError.unsafePath(parent) }
            }
        }
        let client = try await authenticatedClient()
        try Task.checkCancellation()
        do {
            let source = try PathRules.normalize((rootPath == "/" ? "" : rootPath) + from)
            let target = try PathRules.normalize((rootPath == "/" ? "" : rootPath) + to)
            // Pinned libsmb2 sends FileRenameInformation.ReplaceIfExists=0; never pre-check then ordinary rename.
            try await client.moveItem(atPath: String(source.dropFirst()), toPath: String(target.dropFirst()))
        } catch {
            let error = error as NSError
            switch error.code {
            case Int(EEXIST), Int(ENOTEMPTY): throw CoreKitError.alreadyExists(to)
            case Int(ENOENT): throw CoreKitError.notFound(from)
            case Int(EACCES), Int(EAUTH), Int(EPERM): throw CoreKitError.authenticationFailed
            case Int(ETIMEDOUT): throw CoreKitError.timeout
            default: throw CoreKitError.connection("Encrypted SMB rename failed (\(error.code)); its outcome may require a refresh.")
            }
        }
    }

    private func authenticatedClient() async throws -> SMB2Manager {
        let client: SMB2Manager
        if let renameClient { client = renameClient }
        else {
            var server = URLComponents(url: url, resolvingAgainstBaseURL: false)!; server.path = ""
            guard let manager = SMB2Manager(url: server.url!, credential: URLCredential(user: username, password: password, persistence: .none)) else {
                throw CoreKitError.connection("Cannot initialize the encrypted SMB client.")
            }
            manager.timeout = 30; renameClient = manager; client = manager
        }
        try Task.checkCancellation()
        do { try await client.connectShare(name: share, encrypted: true) }
        catch {
            let error = error as NSError
            switch error.code {
            case Int(EACCES), Int(EAUTH), Int(EPERM): throw CoreKitError.authenticationFailed
            case Int(ETIMEDOUT): throw CoreKitError.timeout
            default: throw CoreKitError.connection("Encrypted SMB authentication failed (\(error.code)); check credentials and SMB3 encryption support.")
            }
        }
        return client
    }
    public func remove(path: String) async throws { try await store().remove(path: path) }
    public func checksum(path: String) async throws -> String { try await store().checksum(path: path) }
}
