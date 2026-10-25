import Foundation

private struct WebDAVTransport: HTTPFileTransport {
    let endpoint: URL
    let authorization: String

    func request(_ method: String, path: String, headers: [String: String] = [:], body: Data? = nil,
                 upload: URL? = nil, output: URL? = nil, maximum: Int64 = 4 * 1024 * 1024) async throws -> HTTPResult {
        var request = URLRequest(url: try HTTPStoreSupport.url(endpoint, path: path))
        request.httpMethod = method; request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await HTTPStoreSupport.request(request, upload: upload, output: output, maximum: maximum)
    }

    func properties(_ path: String, depth: Int) async throws -> [(String, HTTPFileInfo)] {
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>".utf8)
        let response = try await request("PROPFIND", path: path, headers: ["Depth": String(depth), "Content-Type": "application/xml; charset=utf-8"], body: body)
        try response.require([207], path: path)
        let root = try parseStorageXML(response.data)
        guard root.name == "multistatus" else { throw CoreKitError.remote("Storage returned an invalid WebDAV listing.") }
        var result: [(String, HTTPFileInfo)] = [], seen: Set<String> = []
        for node in root.children where node.name == "response" {
            guard let href = node.value("href") else { throw CoreKitError.remote("WebDAV listing omitted an item URL.") }
            let child = try virtualPath(href, requestPath: path)
            guard child == path || (depth == 1 && PathRules.parent(of: child) == path), seen.insert(child).inserted else {
                throw CoreKitError.unsafePath(child)
            }
            let successful = node.children.filter { $0.name == "propstat" && $0.value("status")?.split(separator: " ").dropFirst().first == "200" }
            let props = successful.compactMap { $0.child("prop") }.flatMap(\.children)
            func value(_ name: String) -> String? { props.first { $0.name == name }?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let directory = props.first { $0.name == "resourcetype" }?.child("collection") != nil
            guard !props.isEmpty, props.contains(where: { $0.name == "resourcetype" }) else {
                throw CoreKitError.remote("WebDAV listing omitted required properties.")
            }
            let size: Int64
            let etag: String?
            let modified: Date
            if directory { size = 0; etag = nil; modified = (try? HTTPStoreSupport.date(value("getlastmodified"))) ?? Date(timeIntervalSince1970: 0) }
            else {
                guard let raw = value("getcontentlength"), let length = Int64(raw), length >= 0 else { throw CoreKitError.remote("WebDAV returned an invalid file size.") }
                size = length; etag = try HTTPStoreSupport.strongETag(value("getetag")); modified = try HTTPStoreSupport.date(value("getlastmodified"))
            }
            result.append((child, HTTPFileInfo(size: size, modified: modified, etag: etag, directory: directory)))
        }
        return result
    }

    private func virtualPath(_ href: String, requestPath: String) throws -> String {
        let requestURL = try HTTPStoreSupport.url(endpoint, path: requestPath)
        guard let url = URL(string: href, relativeTo: requestURL)?.absoluteURL,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == endpoint.scheme, c.host == endpoint.host, c.port == endpoint.port,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              !c.percentEncodedPath.lowercased().contains("%2f"), !c.percentEncodedPath.lowercased().contains("%5c"),
              let decoded = c.percentEncodedPath.removingPercentEncoding else { throw CoreKitError.unsafePath("WebDAV item URL") }
        let full = try PathRules.normalize(decoded)
        let base = try PathRules.normalize(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!.percentEncodedPath.removingPercentEncoding!.isEmpty ? "/" : URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!.percentEncodedPath.removingPercentEncoding!)
        if full == base { return "/" }
        guard base == "/" || full.hasPrefix(base + "/") else { throw CoreKitError.unsafePath(full) }
        return try PathRules.normalize(base == "/" ? full : String(full.dropFirst(base.count)))
    }

    func inspect(_ path: String) async throws -> HTTPFileInfo {
        guard let info = try await properties(path, depth: 0).first(where: { $0.0 == path })?.1 else { throw CoreKitError.notFound(path) }
        return info
    }

    func get(_ path: String, info: HTTPFileInfo, offset: Int64?, length: Int?, output: URL?) async throws -> HTTPResult {
        var headers = ["If-Match": try HTTPStoreSupport.strongETag(info.etag)]
        if let offset, let length { headers["Range"] = "bytes=\(offset)-\(offset + Int64(length) - 1)" }
        return try await request("GET", path: path, headers: headers, output: output, maximum: max(4096, length.map(Int64.init) ?? info.size))
    }

    func put(_ path: String, file: URL, previous: HTTPFileInfo?) async throws {
        let headers: [String: String]
        if let previous { headers = ["If-Match": try HTTPStoreSupport.strongETag(previous.etag)] }
        else { headers = ["If-None-Match": "*"] }
        let response = try await request("PUT", path: path, headers: headers, upload: file)
        if response.status == 412, previous == nil { throw CoreKitError.alreadyExists(path) }
        try response.require([200, 201, 204], path: path)
    }
}

/// A conforming WebDAV server with strong ETags is required. Credentials are never persisted or redirected.
public actor WebDAVStore: RemoteStore {
    private let transport: WebDAVTransport
    private var uploads: [String: HTTPStagedUpload] = [:]
    private var busy: Set<String> = []
    public nonisolated var supportsDirectoryMove: Bool { false }

    public init(endpoint: URL, username: String, password: String, allowInsecureLoopback: Bool = false) throws {
        guard !username.contains(":"), !username.contains("\n"), !username.contains("\r") else { throw CoreKitError.authenticationFailed }
        transport = WebDAVTransport(endpoint: try HTTPStoreSupport.endpoint(endpoint, allowInsecureLoopback: allowInsecureLoopback),
                                    authorization: "Basic " + Data((username + ":" + password).utf8).base64EncodedString())
    }

    deinit { for upload in uploads.values { HTTPStoreSupport.cleanup(upload.file) } }

    public func list(path: String) async throws -> [RemoteEntry] {
        let path = try PathRules.normalize(path)
        let rows = try await transport.properties(path, depth: 1)
        guard rows.contains(where: { $0.0 == path && $0.1.directory }) else { throw CoreKitError.unsafePath(path) }
        return rows.filter { $0.0 != path && !PathRules.isTemporary(PathRules.name(of: $0.0)) }.map { $0.1.entry($0.0) }.sorted { $0.name < $1.name }
    }

    public func stat(path: String) async throws -> RemoteEntry { try await HTTPFileOperations.stat(transport, path: PathRules.normalize(path)) }
    public func checksum(path: String) async throws -> String { try await HTTPFileOperations.checksum(transport, path: PathRules.normalize(path)) }
    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        try await HTTPFileOperations.read(transport, path: PathRules.normalize(path), offset: offset, length: length)
    }

    public func prepareUpload(path: String) async throws {
        let path = try PathRules.normalize(path)
        guard uploads[path] == nil, busy.insert(path).inserted else { throw CoreKitError.alreadyExists(path) }
        defer { busy.remove(path) }
        uploads[path] = try await HTTPFileOperations.stage(transport, path: path)
    }

    public func finishUpload(path: String) async throws {
        let path = try PathRules.normalize(path)
        guard let upload = uploads[path], busy.insert(path).inserted else { throw CoreKitError.invalidPath(path) }
        defer { busy.remove(path); uploads.removeValue(forKey: path); HTTPStoreSupport.cleanup(upload.file) }
        try await transport.put(path, file: upload.file, previous: upload.previous)
    }

    public func write(path: String, offset: Int64, data: Data) async throws {
        let path = try PathRules.normalize(path); try PathRules.validateRange(offset: offset, length: data.count)
        guard busy.insert(path).inserted else { throw CoreKitError.itemChanged(path) }
        defer { busy.remove(path) }
        if let upload = uploads[path] { try HTTPStoreSupport.patch(upload.file, offset: offset, data: data); return }
        let upload = try await HTTPFileOperations.stage(transport, path: path)
        defer { HTTPStoreSupport.cleanup(upload.file) }
        try HTTPStoreSupport.patch(upload.file, offset: offset, data: data)
        try await transport.put(path, file: upload.file, previous: upload.previous)
    }

    public func createDirectory(path: String) async throws {
        let path = try PathRules.normalize(path); guard path != "/" else { throw CoreKitError.alreadyExists(path) }
        let response = try await transport.request("MKCOL", path: path)
        if response.status == 405 { throw CoreKitError.alreadyExists(path) }
        try response.require([201], path: path)
    }

    public func move(from: String, to: String) async throws {
        let from = try PathRules.normalize(from), to = try PathRules.normalize(to)
        guard from != "/", to != "/" else { throw CoreKitError.invalidPath("/") }
        let info = try await transport.inspect(from)
        guard !info.directory else { throw CoreKitError.remote("WebDAV cannot guarantee atomic collection renames; directory moves are unavailable.") }
        let response = try await transport.request("MOVE", path: from, headers: ["Destination": try HTTPStoreSupport.url(transport.endpoint, path: to).absoluteString,
                                                                               "Overwrite": "F", "If-Match": try HTTPStoreSupport.strongETag(info.etag)])
        if response.status == 412 { throw CoreKitError.alreadyExists(to) }
        try response.require([201], path: to)
    }

    public func remove(path: String) async throws {
        let path = try PathRules.normalize(path); guard path != "/" else { throw CoreKitError.invalidPath(path) }
        guard !busy.contains(path) else { throw CoreKitError.itemChanged(path) }
        if let upload = uploads.removeValue(forKey: path) { HTTPStoreSupport.cleanup(upload.file) }
        let info = try await transport.inspect(path)
        if !info.directory {
            let response = try await transport.request("DELETE", path: path, headers: ["If-Match": try HTTPStoreSupport.strongETag(info.etag)])
            try response.require([200, 204], path: path); return
        }
        // WebDAV DELETE is recursive; an exclusive infinity lock makes the emptiness check safe.
        let body = Data("<d:lockinfo xmlns:d=\"DAV:\"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype></d:lockinfo>".utf8)
        let lock = try await transport.request("LOCK", path: path, headers: ["Depth": "infinity", "Timeout": "Second-300", "Content-Type": "application/xml"], body: body)
        if lock.status == 405 || lock.status == 501 {
            throw CoreKitError.remote("WebDAV requires exclusive collection locking for safe directory deletion; this server does not support it.")
        }
        try lock.require([200], path: path)
        guard let token = lock["lock-token"], token.hasPrefix("<"), token.hasSuffix(">"), token.utf8.count <= 2048,
              !token.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let active = try parseStorageXML(lock.data).child("lockdiscovery")?.child("activelock"),
              active.child("lockscope")?.child("exclusive") != nil, active.value("depth") == "infinity" else {
            throw CoreKitError.remote("WebDAV did not grant the exclusive collection lock required for safe deletion.")
        }
        do {
            let rows = try await transport.properties(path, depth: 1)
            guard rows.allSatisfy({ $0.0 == path }) else { throw CoreKitError.remote("Nonempty directories cannot be removed.") }
            let response = try await transport.request("DELETE", path: path, headers: ["If": "(\(token))"])
            try response.require([200, 204], path: path)
        } catch {
            let transport = self.transport
            _ = await Task.detached { try? await transport.request("UNLOCK", path: path, headers: ["Lock-Token": token]) }.value
            throw error
        }
    }
}
