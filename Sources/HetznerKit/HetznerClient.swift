import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HetznerError: Error, Sendable, LocalizedError {
    case invalidInput(String)
    case invalidResponse
    case http(status: Int, code: String?, retryAfter: TimeInterval?)
    case actionFailed(id: Int, code: String?)
    case actionTimedOut(id: Int)
    case invalidPagination
    case validation(fields: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let field): "Invalid Hetzner request: \(field)."
        case .invalidResponse: "Hetzner returned an invalid response."
        case .http(let status, _, _): "Hetzner API request failed (HTTP \(status))."
        case .actionFailed(let id, _): "Hetzner action \(id) failed."
        case .actionTimedOut(let id): "Hetzner action \(id) is still pending. Check its state before retrying."
        case .invalidPagination: "Hetzner returned invalid pagination."
        case .validation(let fields): "Hetzner rejected \(fields.joined(separator: ", ")). Check these fields and retry."
        }
    }
}

/// Foundation-only client for https://api.hetzner.com/v1.
///
/// Schema verified against https://docs.hetzner.cloud/hetzner.spec.json (2026-10-24).
/// No request is sent until a public operation is invoked. Mutations are never retried.
/// Creation and access changes wait for the returned action (up to 120 polls, one second apart).
/// A timeout or cancellation can leave an operation running remotely; inspect before retrying.
/// Snapshot restoration is intentionally absent: file recovery belongs to the SFTP layer,
/// and full-box rollback is destructive. API credentials are neither persisted nor logged.
public struct HetznerClient: Sendable {
    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token; self.session = session
    }

    public func storageBoxes() async throws -> [StorageBox] {
        try await pages(path: "storage_boxes", key: "storage_boxes")
    }

    public func snapshots(boxID: Int) async throws -> [StorageSnapshot] {
        try validate(boxID)
        return try await pages(path: "storage_boxes/\(boxID)/snapshots", key: "snapshots")
    }

    public func createSnapshot(boxID: Int, description: String) async throws -> StorageSnapshot {
        try validate(boxID)
        let result: SnapshotCreation = try await request("storage_boxes/\(boxID)/snapshots", method: "POST",
                                                        body: JSONEncoder().encode(SnapshotBody(description: description)))
        try await wait(result.action, boxID: boxID)
        let resource: SnapshotResponse = try await request("storage_boxes/\(boxID)/snapshots/\(result.snapshot.id)")
        return resource.snapshot
    }

    /// `username` is a display name; Hetzner generates the actual login returned in `.username`.
    /// By default this enables SSH and external access for the new subaccount only. `samba` and `webdav`
    /// are sent only when given, so omitted flags keep Hetzner's defaults.
    public func createSubaccount(boxID: Int, username: String, password: String,
                                 homeDirectory: String, readOnly: Bool = false,
                                 ssh: Bool = true, samba: Bool? = nil, webdav: Bool? = nil,
                                 reachableExternally: Bool = true) async throws -> StorageSubaccount {
        try validate(boxID)
        guard !username.isEmpty, username.count <= 50 else { throw HetznerError.invalidInput("subaccount name") }
        guard !password.isEmpty else { throw HetznerError.invalidInput("password") }
        try StorageBoxPath.validateHomeDirectory(homeDirectory)
        let body = SubaccountBody(name: username, password: password, homeDirectory: homeDirectory, access: SubaccountAccess(ssh: ssh, external: reachableExternally, samba: samba, webdav: webdav, readonly: readOnly))
        let result: SubaccountCreation = try await request("storage_boxes/\(boxID)/subaccounts", method: "POST",
                                                          body: JSONEncoder().encode(body))
        try await wait(result.action, boxID: boxID)
        let resource: SubaccountResponse = try await request("storage_boxes/\(boxID)/subaccounts/\(result.subaccount.id)")
        return resource.subaccount
    }

    public func subaccounts(boxID: Int) async throws -> [StorageSubaccount] {
        try validate(boxID)
        return try await pages(path: "storage_boxes/\(boxID)/subaccounts", key: "subaccounts")
    }

    public func deleteSubaccount(boxID: Int, subaccountID: Int) async throws {
        try validate(boxID); try validate(subaccountID)
        let response: ActionResponse = try await request("storage_boxes/\(boxID)/subaccounts/\(subaccountID)", method: "DELETE")
        try await wait(response.action, boxID: boxID)
    }

    public func updateAccess(boxID: Int, ssh: Bool, externalReachability: Bool) async throws {
        try await updateAccessSettings(boxID: boxID, StorageAccessSettings(sshEnabled: ssh, reachableExternally: externalReachability))
    }

    /// Partial update of the main account's access settings: only non-nil fields are sent, and Hetzner
    /// leaves every omitted setting unchanged. `zfsEnabled` shows or hides the snapshot folder.
    public func updateAccessSettings(boxID: Int, _ settings: StorageAccessSettings) async throws {
        try validate(boxID)
        guard settings.readonly == nil else { throw HetznerError.invalidInput("read-only applies to sub-accounts only") }
        let result: ActionResponse = try await request("storage_boxes/\(boxID)/actions/update_access_settings", method: "POST",
                                                       body: JSONEncoder().encode(settings))
        try await wait(result.action, boxID: boxID)
    }

    private func validate(_ id: Int) throws {
        guard id > 0 else { throw HetznerError.invalidInput("storage box ID") }
    }

    private func pages<T: Decodable & Sendable>(path: String, key: String) async throws -> [T] {
        var page = 1
        var values: [T] = []
        while true {
            let response: Page<T> = try await request(path, query: [URLQueryItem(name: "page", value: String(page)),
                                                                   URLQueryItem(name: "per_page", value: "50")])
            guard let items = response.values[key] else { throw HetznerError.invalidResponse }
            values += items
            guard let next = response.nextPage else { return values }
            guard next > page else { throw HetznerError.invalidPagination }
            page = next
        }
    }

    private func wait(_ initial: Action, boxID: Int) async throws {
        var action = initial
        for _ in 0..<120 {
            switch action.status {
            case "success": return
            case "error": throw HetznerError.actionFailed(id: action.id, code: action.error?.code)
            case "running": break
            default: throw HetznerError.invalidResponse
            }
            try await Task.sleep(for: .seconds(1))
            let result: ActionResponse = try await request("storage_boxes/\(boxID)/actions/\(action.id)")
            action = result.action
        }
        if action.status == "success" { return }
        if action.status == "error" { throw HetznerError.actionFailed(id: action.id, code: action.error?.code) }
        throw HetznerError.actionTimedOut(id: action.id)
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
                                       query: [URLQueryItem] = []) async throws -> T {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains(where: { $0.isNewline }) else { throw HetznerError.invalidInput("API token") }
        var components = URLComponents(string: "https://api.hetzner.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HetznerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let labels = ["password": "the generated password", "home_directory": "the home directory", "name": "the sub-account name", "access_settings": "the access settings", "description": "the description"]
            let inUse = envelope?.error.code == "uniqueness_error"
            let fields = envelope?.error.details?.fields?.compactMap { labels[$0.name].map { inUse ? $0 + " (already in use)" : $0 } } ?? []
            if !fields.isEmpty { throw HetznerError.validation(fields: Array(Set(fields)).sorted()) }
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                ?? http.value(forHTTPHeaderField: "Retry-After").flatMap { value in
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
                }
                ?? http.value(forHTTPHeaderField: "RateLimit-Reset").flatMap(Double.init).map { max(0, $0 - Date().timeIntervalSince1970) }
            throw HetznerError.http(status: http.statusCode, code: envelope?.error.code, retryAfter: retry)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct APIError: Decodable {
    let code: String
    let details: Details?
    struct Details: Decodable { let fields: [Field]? }
    struct Field: Decodable { let name: String }
}
private struct ErrorResponse: Decodable { let error: APIError }
private struct Action: Decodable { let id: Int; let status: String; let error: APIError? }
private struct ActionResponse: Decodable { let action: Action }
private struct Reference: Decodable { let id: Int }
private struct SnapshotCreation: Decodable { let snapshot: Reference; let action: Action }
private struct SubaccountCreation: Decodable { let subaccount: Reference; let action: Action }
private struct SnapshotResponse: Decodable { let snapshot: StorageSnapshot }
private struct SubaccountResponse: Decodable { let subaccount: StorageSubaccount }
private struct SnapshotBody: Encodable { let description: String }
private struct SubaccountBody: Encodable {
    let name: String; let password: String; let homeDirectory: String
    let access: SubaccountAccess
    enum CodingKeys: String, CodingKey { case name, password, homeDirectory = "home_directory", access = "access_settings" }
}
private struct SubaccountAccess: Encodable {
    let ssh: Bool
    let external: Bool
    let samba: Bool?
    let webdav: Bool?
    let readonly: Bool
    enum CodingKeys: String, CodingKey {
        case ssh = "ssh_enabled", external = "reachable_externally", samba = "samba_enabled", webdav = "webdav_enabled", readonly
    }
}
private struct Page<T: Decodable>: Decodable {
    let values: [String: [T]]
    let nextPage: Int?
    private struct Meta: Decodable {
        let pagination: Pagination
        struct Pagination: Decodable { let next_page: Int? }
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        nextPage = try c.decodeIfPresent(Meta.self, forKey: Key(stringValue: "meta")!)?.pagination.next_page
        var values: [String: [T]] = [:]
        for key in c.allKeys where key.stringValue != "meta" {
            values[key.stringValue] = try c.decode([T].self, forKey: key)
        }
        self.values = values
    }
}
