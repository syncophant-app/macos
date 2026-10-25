import Foundation

/// Microsoft Graph, the signed-in user's own OneDrive, addressed by path (`/root:/a/b:`). The eTag is the
/// version; writes send `If-Match`, and creation uses `conflictBehavior=fail`, so the server enforces both
/// no-clobber rules. Deleted items go to the OneDrive recycle bin.
struct OneDriveTransport: CloudTransport {
    let session: OAuthSession
    let drive: URL
    let me: URL
    private let select = "id,name,size,eTag,lastModifiedDateTime,folder,file"

    init(session: OAuthSession, bases: [URL]?) {
        self.session = session
        let graph = bases?[0] ?? URL(string: "https://graph.microsoft.com/v1.0")!
        drive = graph.appendingPathComponent("me/drive"); me = graph.appendingPathComponent("me")
    }

    /// `/root` or `/root:/a/b:` plus an optional action such as `/children`.
    private func item(_ path: String, _ action: String = "", query: [String: String] = [:]) throws -> URL {
        var c = URLComponents(url: drive, resolvingAgainstBaseURL: false)!
        let encoded = path.split(separator: "/").map { HTTPStoreSupport.encode(String($0)) }.joined(separator: "/")
        c.percentEncodedPath += path == "/" ? "/root" + action : "/root:/" + encoded + ":" + action
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw CoreKitError.invalidPath(path) }
        return url
    }

    private func info(_ m: Cloud.JSON) throws -> HTTPFileInfo {
        let modified = Cloud.date(m["lastModifiedDateTime"])
        if m["folder"] != nil { return HTTPFileInfo(size: 0, modified: modified, etag: (m["eTag"] as? String).map(Cloud.quoted), directory: true) }
        guard m["file"] != nil, let etag = m["eTag"] as? String else { throw CoreKitError.unsafePath(m["name"] as? String ?? "") }
        return HTTPFileInfo(size: Cloud.int64(m["size"]), modified: modified, etag: Cloud.quoted(etag), directory: false)
    }

    private func check(_ result: HTTPResult, path: String, conflict: CoreKitError? = nil) throws {
        guard !(200..<300).contains(result.status) else { return }
        switch result.status {
        case 409: throw conflict ?? CoreKitError.alreadyExists(path)
        case 412, 423: throw CoreKitError.itemChanged(path)
        case 429, 503: throw Cloud.busy(.onedrive)
        default: try result.require([], path: path)
        }
    }

    private func send(_ request: URLRequest, path: String, upload: URL? = nil) async throws -> Cloud.JSON {
        let result = try await session.send(request, upload: upload)
        try check(result, path: path)
        return result.data.isEmpty ? [:] : try Cloud.object(result)
    }

    func inspect(_ path: String) async throws -> HTTPFileInfo {
        try info(await send(Cloud.request(item(path, query: ["$select": select])), path: path))
    }

    func children(_ path: String) async throws -> [(name: String, info: HTTPFileInfo)] {
        guard try await inspect(path).directory else { throw CoreKitError.unsafePath(path) }
        var next: URL? = try item(path, "/children", query: ["$select": select, "$top": "1000"])
        var rows: [(name: String, info: HTTPFileInfo)] = []
        while let url = next {
            let page = try await send(Cloud.request(url), path: path)
            for child in page["value"] as? [Cloud.JSON] ?? [] {
                // Skip OneNote notebooks and other packages that are neither files nor folders.
                guard let name = child["name"] as? String, let row = try? info(child) else { continue }
                rows.append((name, row))
            }
            next = (page["@odata.nextLink"] as? String).flatMap(URL.init(string:))
            if let next, next.host != drive.host { throw CoreKitError.remote("OneDrive returned an unexpected page address.") }
        }
        return rows
    }

    func get(_ path: String, info: HTTPFileInfo, offset: Int64?, length: Int?, output: URL?) async throws -> HTTPResult {
        let range = Cloud.range(offset: offset, length: length)
        var request = try Cloud.request(item(path, "/content"))
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let maximum = max(4096, length.map(Int64.init) ?? info.size)
        return try await Cloud.followDownload(session.send(request, output: output, maximum: maximum), range: range, output: output, maximum: maximum)
    }

    func put(_ path: String, file: URL, previous: HTTPFileInfo?) async throws {
        let size = try Cloud.fileSize(file)
        var headers: [String: String] = [:]
        if let previous { headers["If-Match"] = try HTTPStoreSupport.strongETag(previous.etag) }
        let conflict = previous == nil ? CoreKitError.alreadyExists(path) : CoreKitError.itemChanged(path)
        if size <= 4 * 1024 * 1024 {
            var request = try Cloud.request(item(path, "/content", query: ["@microsoft.graph.conflictBehavior": previous == nil ? "fail" : "replace"]),
                                            method: "PUT", headers: headers)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            try check(await session.send(request, upload: file), path: path, conflict: conflict)
            return
        }
        let created = try await session.send(Cloud.request(item(path, "/createUploadSession"), method: "POST",
            json: ["item": ["@microsoft.graph.conflictBehavior": previous == nil ? "fail" : "replace"]], headers: headers))
        try check(created, path: path, conflict: conflict)
        guard let address = try Cloud.object(created)["uploadUrl"] as? String, let upload = URL(string: address),
              upload.scheme == "https" || upload.host == "127.0.0.1" else { throw CoreKitError.remote("OneDrive did not start an upload session.") }
        // Chunks must be multiples of 320 KiB. The upload URL is pre-authorized: no bearer token.
        try await Cloud.chunks(of: file, size: 32 * 327_680) { part, data, offset in
            var request = URLRequest(url: upload)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(offset + Int64(data.count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            let result = try await HTTPStoreSupport.request(request, upload: part)
            try check(result, path: path, conflict: conflict)
        }
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await send(Cloud.request(item(PathRules.parent(of: path), "/children"), method: "POST",
                                         json: ["name": PathRules.name(of: path), "folder": [String: Any](),
                                                "@microsoft.graph.conflictBehavior": "fail"]), path: path)
    }

    func rename(_ from: String, to: String, info: HTTPFileInfo) async throws {
        let parent = PathRules.parent(of: to)
        let reference = parent == "/" ? "/drive/root:" : "/drive/root:" + parent
        var headers: [String: String] = [:]
        if let etag = info.etag { headers["If-Match"] = etag }
        _ = try await send(Cloud.request(item(from), method: "PATCH",
                                         json: ["name": PathRules.name(of: to), "parentReference": ["path": reference]], headers: headers), path: to)
    }

    func delete(_ path: String, info: HTTPFileInfo) async throws {
        var headers: [String: String] = [:]
        if let etag = info.etag { headers["If-Match"] = etag }
        let result = try await session.send(Cloud.request(item(path), method: "DELETE", headers: headers))
        try check(result, path: path, conflict: .itemChanged(path))
    }

    func account() async throws -> String {
        let json = try await send(Cloud.request(Cloud.url(me.deletingLastPathComponent(), "me", query: ["$select": "mail,userPrincipalName"])), path: "/")
        return (json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? "OneDrive account"
    }
}
