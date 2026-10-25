import Foundation

/// One cloud drive API. Paths are full provider paths (the store's root already applied).
/// `inspect`, `get` and `put` follow `HTTPFileTransport`: `put` with no previous file is create-only
/// (`alreadyExists` when taken) and with a previous file is conditional on its version (`itemChanged`).
protocol CloudTransport: HTTPFileTransport {
    /// Children of a folder; `unsafePath` when the path is a file.
    func children(_ path: String) async throws -> [(name: String, info: HTTPFileInfo)]
    /// Create-only: `alreadyExists` when the name is taken.
    func makeDirectory(_ path: String) async throws
    /// No-clobber rename or move: `alreadyExists` when the destination is taken.
    func rename(_ from: String, to: String, info: HTTPFileInfo) async throws
    /// Deletes a file conditionally, or a folder the store has already checked is empty.
    func delete(_ path: String, info: HTTPFileInfo) async throws
    /// The signed-in account, for display.
    func account() async throws -> String
}

/// A cloud drive (Dropbox, OneDrive, Box, Google Drive) as a `RemoteStore`. Uploads spool to private
/// local files like WebDAV, then publish with one create-only or version-conditional upload.
/// Deleted items go to the service's own trash.
public actor CloudStore: RemoteStore {
    public nonisolated let service: OAuthService
    private let transport: any CloudTransport
    private let root: String
    private var uploads: [String: HTTPStagedUpload] = [:]
    private var busy: Set<String> = []

    public init(service: OAuthService, session: OAuthSession, rootPath: String = "/") throws {
        try self.init(service: service, transport: Self.transport(for: service, session: session, endpoints: nil), rootPath: rootPath)
    }

    init(service: OAuthService, transport: any CloudTransport, rootPath: String) throws {
        self.service = service; self.transport = transport; root = try PathRules.normalize(rootPath)
    }

    /// `endpoints` replaces the production base URLs, for local fixtures only.
    static func transport(for service: OAuthService, session: OAuthSession, endpoints: [URL]?) -> any CloudTransport {
        switch service {
        case .dropbox: DropboxTransport(session: session, bases: endpoints)
        case .onedrive: OneDriveTransport(session: session, bases: endpoints)
        case .box: BoxTransport(session: session, bases: endpoints)
        case .googledrive: GoogleDriveTransport(session: session, bases: endpoints)
        }
    }

    deinit { for upload in uploads.values { HTTPStoreSupport.cleanup(upload.file) } }

    public func accountName() async throws -> String { try await transport.account() }

    private func full(_ path: String) throws -> String {
        let path = try PathRules.normalize(path)
        if root == "/" { return path }
        return path == "/" ? root : root + path
    }

    public func list(path: String) async throws -> [RemoteEntry] {
        let path = try PathRules.normalize(path)
        return try await transport.children(full(path))
            .filter { !PathRules.isTemporary($0.name) }
            .map { $0.info.entry((path == "/" ? "" : path) + "/" + $0.name) }
            .sorted { $0.name < $1.name }
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let path = try PathRules.normalize(path)
        return try await transport.inspect(full(path)).entry(path)
    }

    public func checksum(path: String) async throws -> String { try await HTTPFileOperations.checksum(transport, path: full(path)) }

    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        try await HTTPFileOperations.read(transport, path: full(path), offset: offset, length: length)
    }

    public func prepareUpload(path: String) async throws {
        let path = try full(path)
        guard uploads[path] == nil, busy.insert(path).inserted else { throw CoreKitError.alreadyExists(path) }
        defer { busy.remove(path) }
        uploads[path] = try await HTTPFileOperations.stage(transport, path: path)
    }

    public func finishUpload(path: String) async throws {
        let path = try full(path)
        guard let upload = uploads[path], busy.insert(path).inserted else { throw CoreKitError.invalidPath(path) }
        defer { busy.remove(path); uploads.removeValue(forKey: path); HTTPStoreSupport.cleanup(upload.file) }
        try await transport.put(path, file: upload.file, previous: upload.previous)
    }

    public func write(path: String, offset: Int64, data: Data) async throws {
        let path = try full(path); try PathRules.validateRange(offset: offset, length: data.count)
        guard busy.insert(path).inserted else { throw CoreKitError.itemChanged(path) }
        defer { busy.remove(path) }
        if let upload = uploads[path] { try HTTPStoreSupport.patch(upload.file, offset: offset, data: data); return }
        let upload = try await HTTPFileOperations.stage(transport, path: path)
        defer { HTTPStoreSupport.cleanup(upload.file) }
        try HTTPStoreSupport.patch(upload.file, offset: offset, data: data)
        try await transport.put(path, file: upload.file, previous: upload.previous)
    }

    public func createDirectory(path: String) async throws {
        let path = try full(path)
        guard path != root else { throw CoreKitError.alreadyExists(path) }
        try await transport.makeDirectory(path)
    }

    public func move(from: String, to: String) async throws {
        let from = try full(from), to = try full(to)
        guard from != root, to != root, from != to else { throw CoreKitError.invalidPath(to) }
        guard !to.hasPrefix(from + "/") else { throw CoreKitError.invalidPath(to) }
        try await transport.rename(from, to: to, info: transport.inspect(from))
    }

    public func remove(path: String) async throws {
        let path = try full(path)
        guard path != root else { throw CoreKitError.invalidPath(path) }
        guard !busy.contains(path) else { throw CoreKitError.itemChanged(path) }
        if let upload = uploads.removeValue(forKey: path) { HTTPStoreSupport.cleanup(upload.file) }
        let info = try await transport.inspect(path)
        // ponytail: a file added between this check and the delete goes to the service's trash, not lost.
        if info.directory, !(try await transport.children(path).isEmpty) {
            throw CoreKitError.remote("Nonempty directories cannot be removed.")
        }
        try await transport.delete(path, info: info)
    }

    public func verifyWritePreconditions(path: String) async throws {
        try await HTTPFileOperations.verifyPreconditions(transport, path: full(path))
    }
}

/// Small JSON and upload helpers shared by the cloud transports.
enum Cloud {
    typealias JSON = [String: Any]

    static func request(_ url: URL, method: String = "GET", json: Any? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static func object(_ result: HTTPResult) throws -> JSON {
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? JSON else {
            throw CoreKitError.remote("The storage service returned an unreadable response.")
        }
        return json
    }

    static func url(_ base: URL, _ path: String, query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // `+` is a space to many servers; send it encoded.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    static func date(_ value: Any?) -> Date {
        guard let text = value as? String else { return Date(timeIntervalSince1970: 0) }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }

    static func quoted(_ value: String) -> String { value.hasPrefix("\"") ? value : "\"" + value + "\"" }
    static func unquoted(_ value: String?) throws -> String { String(try HTTPStoreSupport.strongETag(value).dropFirst().dropLast()) }

    static func fileSize(_ file: URL) throws -> Int64 {
        Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    /// Calls `body` with each chunk of `file`, staged in its own private file.
    static func chunks(of file: URL, size chunk: Int, isolation: isolated (any Actor)? = #isolation,
                       _ body: (_ part: URL, _ data: Data, _ offset: Int64) async throws -> Void) async throws {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            let part = try HTTPStoreSupport.temporary(); defer { HTTPStoreSupport.cleanup(part) }
            try data.write(to: part)
            try await body(part, data, offset)
            offset += Int64(data.count)
        }
    }

    /// Follows a download redirect to a pre-authorized URL without forwarding the bearer token.
    static func followDownload(_ result: HTTPResult, range: String?, output: URL?, maximum: Int64) async throws -> HTTPResult {
        guard (300..<400).contains(result.status) else { return result }
        guard let location = result["location"], let url = URL(string: location), url.scheme == "https" || url.host == "127.0.0.1" else {
            throw CoreKitError.remote("The storage service returned an invalid download address.")
        }
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return try await HTTPStoreSupport.request(request, output: output, maximum: maximum)
    }

    static func range(offset: Int64?, length: Int?) -> String? {
        guard let offset, let length else { return nil }
        return "bytes=\(offset)-\(offset + Int64(length) - 1)"
    }

    static func busy(_ service: OAuthService) -> CoreKitError {
        .remote("\(service.title) is limiting requests right now. Syncophant will try again.")
    }
}
