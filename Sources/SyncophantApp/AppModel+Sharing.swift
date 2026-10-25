import Foundation
import UserNotifications
import CoreKit
import HetznerKit

/// How the person on the other end opens a shared folder. Each maps to a Hetzner sub-account access flag.
enum ShareProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case webdav, sftp, smb
    var id: String { rawValue }
    var label: String { switch self { case .webdav: "WebDAV"; case .sftp: "SFTP"; case .smb: "SMB" } }
    var hint: String { switch self { case .webdav: "browsers, Finder, phones"; case .sftp: "apps like Cyberduck"; case .smb: "Windows and NAS" } }
}

struct StorageShare: Identifiable, Codable {
    var id = UUID()
    let connectionID: UUID
    let boxID: Int
    let subaccountID: Int
    let path: String
    let username: String
    let host: String
    let createdAt: Date
    /// nil on shares made before access choices existed; those were read-only.
    var readOnly: Bool? = nil
    /// nil on older shares, which had SFTP only.
    var protocols: [ShareProtocol]? = nil
    /// nil means no end. Enforced by this Mac deleting the sub-account, so it happens when Syncophant runs.
    var expiresAt: Date? = nil

    var name: String { path == "/" ? path : (path as NSString).lastPathComponent }
    var isReadOnly: Bool { readOnly ?? true }
    var openWith: [ShareProtocol] { protocols ?? [.sftp] }

    func address(_ p: ShareProtocol) -> String {
        switch p {
        case .webdav: "https://\(host)"
        case .sftp: "sftp://\(username)@\(host):\(hetznerSFTPPort)"
        case .smb: "smb://\(host)/\(username)"
        }
    }
}

extension AppModel {
    var canShareSelection: Bool {
        guard !isDemo, let c = active, c.encryptionEnabled != true, selection.count == 1, let item = selection.first else { return false }
        return (c.provider == .s3 && !item.isDirectory) || (c.provider == .hetzner && item.isDirectory)
    }

    func beginSharing() { if canShareSelection { sharingItem = selection.first; open(.share) } }

    func createPresignedURL(path: String, expires: Int) async throws -> URL {
        guard let c = active, c.provider == .s3, c.encryptionEnabled != true,
              let store = try remoteStore(for: c) as? S3Store else { throw AppError.unavailable("Read links require an unencrypted S3 connection.") }
        guard try await store.stat(path: path).isDirectory == false else { throw AppError.unavailable("Choose a file to share.") }
        return try await store.presignedGET(path: path, expires: min(expires, 604_800))
    }

    /// Resolve the account's real box root before granting a subaccount access.
    func resolveHetznerBox(_ c: StorageConnection, client: HetznerClient) async throws -> (StorageBox, String) {
        let boxes = try await client.storageBoxes()
        for box in boxes {
            if box.username == c.username && box.server == c.host { return (box, "") }
            guard c.username.hasPrefix(box.username + "-sub") else { continue }
            if let sub = try await client.subaccounts(boxID: box.id).first(where: { $0.username == c.username && ($0.server == nil || $0.server == c.host) }),
               let home = sub.homeDirectory { return (box, home) }
        }
        throw AppError.unavailable("The Hetzner token does not identify this Storage Box login.")
    }

    /// Creates a sub-account whose home is `path`, with the chosen access and protocols. `step` reports live
    /// progress: 0 password, 1 account, 2 access confirmed.
    func createShare(path: String, token: String, readOnly: Bool, protocols: Set<ShareProtocol>, expiresAt: Date?,
                     step: @MainActor (Int) -> Void) async throws -> (StorageShare, String) {
        guard let c = active, !isDemo, c.provider == .hetzner, c.encryptionEnabled != true else { throw AppError.demoOnly }
        guard !protocols.isEmpty else { throw AppError.unavailable("Choose at least one way to open the folder.") }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.isEmpty ? HetznerToken.load() : token
        guard let secret, !secret.isEmpty else { throw AppError.unavailable("Enter a Hetzner API token to create this share.") }
        let client = HetznerClient(token: secret)
        noteContact(host: "api.hetzner.com", purpose: "Hetzner API · folder sharing")
        step(0)
        let password = try PasswordGenerator.make()
        let (box, accountHome) = try await resolveHetznerBox(c, client: client)
        let normalized = try PathRules.normalize(path)
        guard normalized != "/", try await remoteStore(for: c).stat(path: normalized).isDirectory else { throw AppError.unavailable("Choose a folder to share.") }
        let home = try StorageBoxPath.shareHomeDirectory(accountHome: accountHome, sftpRoot: c.rootPath, folder: normalized)
        step(1)
        let sub = try await client.createSubaccount(boxID: box.id, username: "Share-" + String(UUID().uuidString.prefix(8)), password: password,
                                                    homeDirectory: home, readOnly: readOnly, ssh: protocols.contains(.sftp),
                                                    samba: protocols.contains(.smb), webdav: protocols.contains(.webdav))
        step(2)
        let a = sub.accessSettings
        func matches(_ value: Bool?, _ wanted: Bool) -> Bool { value.map { $0 == wanted } ?? true }
        guard a?.readonly == readOnly, sub.homeDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == home,
              matches(a?.sshEnabled, protocols.contains(.sftp)), matches(a?.sambaEnabled, protocols.contains(.smb)),
              matches(a?.webdavEnabled, protocols.contains(.webdav)) else {
            try await client.deleteSubaccount(boxID: box.id, subaccountID: sub.id)
            throw AppError.unavailable("Hetzner did not confirm the requested access to this folder. The new account was removed.")
        }
        let share = StorageShare(connectionID: c.id, boxID: box.id, subaccountID: sub.id, path: normalized,
                                 username: sub.username, host: sub.server ?? box.server, createdAt: Date(),
                                 readOnly: readOnly, protocols: ShareProtocol.allCases.filter(protocols.contains), expiresAt: expiresAt)
        // Keep the generated password durable before showing it. Never place it in a URL or diagnostics.
        let updated = storageShares + [share]
        do {
            try KeychainSecretStore.set(password, for: share.id)
            try SharedJSON.save(updated, name: "shares.json")
        } catch {
            let cause = error
            do { try await client.deleteSubaccount(boxID: box.id, subaccountID: sub.id) }
            catch { throw AppError.unavailable("Local share saving failed and revocation was not confirmed. Check subaccount \(sub.id) on Storage Box \(box.id) in Hetzner Console before retrying.") }
            try? KeychainSecretStore.delete(for: share.id)
            throw cause
        }
        storageShares = updated
        if !token.isEmpty { try HetznerToken.save(token) }
        scheduleExpiryReminder(for: share)
        return (share, password)
    }

    func revokeShare(_ share: StorageShare) async throws {
        guard !isDemo, let token = HetznerToken.load() else { throw AppError.unavailable("A Hetzner API token is needed to stop this share.") }
        noteContact(host: "api.hetzner.com", purpose: "Hetzner API · stop folder sharing")
        do { try await HetznerClient(token: token).deleteSubaccount(boxID: share.boxID, subaccountID: share.subaccountID) }
        catch HetznerError.http(status: 404, _, _) { /* Already gone (removed in Hetzner Console). */ }
        let updated = storageShares.filter { $0.id != share.id }
        try SharedJSON.save(updated, name: "shares.json")
        storageShares = updated
        try KeychainSecretStore.delete(for: share.id)
        if notificationsUsable { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [share.id.uuidString]) }
    }

    /// Deletes every share whose end date has passed and tells the person. Needs to run at launch and then
    /// every few minutes: call `startShareExpiryMonitor()` from `AppModel.init`.
    func enforceShareExpiry() async {
        guard !isDemo else { return }
        for share in storageShares where (share.expiresAt ?? .distantFuture) <= Date() {
            do {
                try await revokeShare(share)
                say("Stopped sharing “\(share.name)”: its time ran out.")
            } catch {
                diagnostics.add("Could not stop expired share \(share.username): \(message(for: error))")
                say("“\(share.name)” has expired but is still shared: \(message(for: error))", error: true)
            }
        }
    }

    func startShareExpiryMonitor() {
        guard !isDemo, shareUI.expiryTask == nil else { return }
        shareUI.expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.enforceShareExpiry()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Notifications need a real app bundle; a bare `swift run` binary has none.
    private var notificationsUsable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func scheduleExpiryReminder(for share: StorageShare) {
        guard notificationsUsable, let end = share.expiresAt, end.timeIntervalSinceNow > 86_400 else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "“\(share.name)” stops being shared tomorrow"
        content.body = "Syncophant removes its account at \(end.formatted(date: .omitted, time: .shortened)) tomorrow."
        let fire = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: end.addingTimeInterval(-86_400))
        let request = UNNotificationRequest(identifier: share.id.uuidString, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: false))
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}
