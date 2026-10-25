import CryptoKit
import Darwin
import Foundation

/// Cloud drives that sign in with the person's own OAuth app. Syncophant ships no client IDs.
public enum OAuthService: String, Codable, CaseIterable, Identifiable, Sendable {
    case dropbox, onedrive, box, googledrive

    public var id: String { rawValue }
    public var provider: StorageProvider { StorageProvider(rawValue: rawValue)! }
    public var title: String {
        switch self { case .dropbox: "Dropbox"; case .onedrive: "OneDrive"; case .box: "Box"; case .googledrive: "Google Drive" }
    }
    /// Google Drive allows duplicate names and has no server-side write preconditions, so its
    /// no-overwrite and stale-write checks are client-side only.
    public var isExperimental: Bool { self == .googledrive }
    public var requiresSecret: Bool { self == .box || self == .googledrive }
    /// The host the connection check reaches.
    public var apiHost: String {
        switch self { case .dropbox: "api.dropboxapi.com"; case .onedrive: "graph.microsoft.com"; case .box: "api.box.com"; case .googledrive: "www.googleapis.com" }
    }
    public var consoleURL: URL {
        switch self {
        case .dropbox: URL(string: "https://www.dropbox.com/developers/apps")!
        case .onedrive: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!
        case .box: URL(string: "https://app.box.com/developers/console")!
        case .googledrive: URL(string: "https://console.cloud.google.com/apis/credentials")!
        }
    }
    /// What the person does in the provider's developer console, in order.
    public var setupSteps: [String] {
        switch self {
        case .dropbox: ["Create a Scoped access app with Full Dropbox access.",
                        "Under Permissions, turn on files.metadata.write, files.content.write, files.content.read and account_info.read.",
                        "Add the redirect URI below, then copy the App key."]
        case .onedrive: ["Register an app for personal and work accounts.",
                         "Add a Mobile and desktop redirect URI with the address below, and allow public client flows.",
                         "Copy the Application (client) ID."]
        case .box: ["Create a Custom App with User Authentication (OAuth 2.0).",
                    "Turn on Write all files and folders, and add the redirect URI below.",
                    "Copy the Client ID and Client Secret."]
        case .googledrive: ["Enable the Google Drive API and create an OAuth client of type Desktop app.",
                            "Set the consent screen’s publishing status to In production, or sign-ins expire after 7 days.",
                            "Copy the Client ID and Client secret."]
        }
    }

    public static let redirectURI = "http://localhost:53682/"
    public static let callbackPort: UInt16 = 53682

    var tokenURL: URL {
        switch self {
        case .dropbox: URL(string: "https://api.dropboxapi.com/oauth2/token")!
        case .onedrive: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case .box: URL(string: "https://api.box.com/oauth2/token")!
        case .googledrive: URL(string: "https://oauth2.googleapis.com/token")!
        }
    }
    private var scope: String? {
        switch self {
        case .onedrive: "offline_access Files.ReadWrite User.Read"
        case .googledrive: "https://www.googleapis.com/auth/drive"
        default: nil
        }
    }
    private var usesPKCE: Bool { self != .box }

    /// The browser page where the person approves access. `challenge` comes from `OAuthPKCE`.
    public func authorizationURL(clientID: String, state: String, challenge: String) -> URL {
        let base: String
        var items = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: Self.redirectURI), URLQueryItem(name: "state", value: state)]
        switch self {
        case .dropbox:
            base = "https://www.dropbox.com/oauth2/authorize"
            items.append(URLQueryItem(name: "token_access_type", value: "offline"))
        case .onedrive:
            base = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
            items.append(URLQueryItem(name: "response_mode", value: "query"))
        case .box:
            base = "https://account.box.com/api/oauth2/authorize"
        case .googledrive:
            base = "https://accounts.google.com/o/oauth2/v2/auth"
            items += [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent")]
        }
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        if usesPKCE {
            items += [URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        }
        var c = URLComponents(string: base)!
        c.queryItems = items
        return c.url!
    }

    /// Trades the code from the redirect for tokens.
    public func exchange(code: String, verifier: String, client: OAuthClient) async throws -> OAuthToken {
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI]
        if usesPKCE { form["code_verifier"] = verifier }
        return try await OAuthHTTP.token(self, url: tokenURL, form: form, client: client, previousRefresh: nil)
    }

    func refresh(_ refreshToken: String, client: OAuthClient, url: URL) async throws -> OAuthToken {
        try await OAuthHTTP.token(self, url: url, form: ["grant_type": "refresh_token", "refresh_token": refreshToken],
                                  client: client, previousRefresh: refreshToken)
    }

    fileprivate var tokenScope: String? { scope }
}

public struct OAuthClient: Codable, Hashable, Sendable {
    public var clientID: String
    public var clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = secret?.isEmpty == false ? secret : nil
    }
}

public struct OAuthToken: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
}

/// PKCE (RFC 7636) and the state value that ties a redirect to the request that started it.
public enum OAuthPKCE {
    public static func verifier() -> String { random(64) }
    public static func state() -> String { random(24) }
    public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    private static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Where a session reads and writes its latest token. Box and Microsoft rotate refresh tokens, so the app
/// and the File Provider extension must share one copy and refresh under one lock.
public struct OAuthVault: Sendable {
    public var load: @Sendable () throws -> OAuthToken?
    public var save: @Sendable (OAuthToken) throws -> Void
    /// A file both processes can `flock`; nil when only this process uses the token.
    public var lockFile: URL?
    public init(load: @escaping @Sendable () throws -> OAuthToken?, save: @escaping @Sendable (OAuthToken) throws -> Void, lockFile: URL?) {
        self.load = load; self.save = save; self.lockFile = lockFile
    }
    public static var memory: OAuthVault { OAuthVault(load: { nil }, save: { _ in }, lockFile: nil) }
}

/// Adds a fresh bearer token to requests, refreshing it shortly before it expires or once after a 401.
public actor OAuthSession {
    public nonisolated let service: OAuthService
    private let client: OAuthClient
    private let vault: OAuthVault
    private let tokenURL: URL
    private var token: OAuthToken
    private var refreshing: Task<OAuthToken, any Error>?

    public init(service: OAuthService, client: OAuthClient, token: OAuthToken, vault: OAuthVault = .memory) {
        self.init(service: service, client: client, token: token, vault: vault, tokenURL: service.tokenURL)
    }

    init(service: OAuthService, client: OAuthClient, token: OAuthToken, vault: OAuthVault, tokenURL: URL) {
        self.service = service; self.client = client; self.token = token; self.vault = vault; self.tokenURL = tokenURL
    }

    func authorization(force: Bool = false) async throws -> String {
        if !force, token.expiresAt.timeIntervalSinceNow > 60 { return "Bearer " + token.accessToken }
        if refreshing == nil {
            let stale = token, service = service, client = client, vault = vault, url = tokenURL
            refreshing = Task { try await Self.refresh(stale: stale, service: service, client: client, vault: vault, url: url) }
        }
        let task = refreshing!
        defer { refreshing = nil }
        token = try await task.value
        return "Bearer " + token.accessToken
    }

    /// Sends a request with the bearer token. A 401 means the request was not applied, so one retry
    /// with a refreshed token is safe even for writes.
    func send(_ request: URLRequest, upload: URL? = nil, output: URL? = nil, maximum: Int64 = 4 * 1024 * 1024) async throws -> HTTPResult {
        var request = request
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        let first = try await HTTPStoreSupport.request(request, upload: upload, output: output, maximum: maximum)
        guard first.status == 401 else { return first }
        request.setValue(try await authorization(force: true), forHTTPHeaderField: "Authorization")
        return try await HTTPStoreSupport.request(request, upload: upload, output: output, maximum: maximum)
    }

    private static func refresh(stale: OAuthToken, service: OAuthService, client: OAuthClient, vault: OAuthVault, url: URL) async throws -> OAuthToken {
        let fd = try vault.lockFile.map { url -> Int32 in
            let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CoreKitError.remote("Could not open the sign-in lock.") }
            // ponytail: blocks one thread while another process refreshes (about a second).
            guard flock(fd, LOCK_EX) == 0 else { Darwin.close(fd); throw CoreKitError.remote("Could not lock the sign-in.") }
            return fd
        }
        defer { if let fd { flock(fd, LOCK_UN); Darwin.close(fd) } }
        // Another process may already have refreshed (and rotated) the token.
        let latest = (try? vault.load()) ?? nil
        if let latest, latest.accessToken != stale.accessToken, latest.expiresAt.timeIntervalSinceNow > 60 { return latest }
        let fresh = try await service.refresh(latest?.refreshToken ?? stale.refreshToken, client: client, url: url)
        try vault.save(fresh)
        return fresh
    }
}

enum OAuthHTTP {
    static func token(_ service: OAuthService, url: URL, form: [String: String], client: OAuthClient, previousRefresh: String?) async throws -> OAuthToken {
        var form = form
        form["client_id"] = client.clientID
        if let secret = client.clientSecret { form["client_secret"] = secret }
        if let scope = service.tokenScope, service == .onedrive { form["scope"] = scope }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\(HTTPStoreSupport.encode($0.value))" }.joined(separator: "&").utf8)
        let result = try await HTTPStoreSupport.request(request)
        let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any] ?? [:]
        guard result.status == 200 else {
            if result.status == 400 || result.status == 401 { throw CoreKitError.authenticationFailed }
            throw CoreKitError.remote("\(service.title) sign-in returned HTTP \(result.status).")
        }
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = (json["refresh_token"] as? String) ?? previousRefresh, !refresh.isEmpty else {
            throw CoreKitError.remote("\(service.title) did not return a refresh token. Check the app’s offline access settings.")
        }
        let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return OAuthToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds))
    }
}
