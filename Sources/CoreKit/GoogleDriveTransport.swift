import Foundation

/// Google Drive API v3, My Drive only. Experimental: Drive allows several items with the same name in one
/// folder and offers no write preconditions, so the no-overwrite and stale-version checks here are
/// client-side (look up, then write). A change made by someone else in between can still be overwritten
/// or duplicated. Names held by more than one item are hidden and refused; Google Docs are not files and
/// are skipped. Deletes move items to the Drive trash.
struct GoogleDriveTransport: CloudTransport {
    let session: OAuthSession
    let api: URL
    let upload: URL
    private let fields = "id,name,mimeType,size,modifiedTime,version,parents"
    private static let folderType = "application/vnd.google-apps.folder"

    init(session: OAuthSession, bases: [URL]?) {
        self.session = session
        api = bases?[0] ?? URL(string: "https://www.googleapis.com/drive/v3")!
        upload = bases?[1] ?? URL(string: "https://www.googleapis.com/upload/drive/v3")!
    }

    private func check(_ result: HTTPResult, path: String) throws {
        guard !(200..<300).contains(result.status) else { return }
        if result.status == 429 || (result.status == 403 && String(decoding: result.data, as: UTF8.self).contains("ateLimitExceeded")) {
            throw Cloud.busy(.googledrive)
        }
        try result.require([], path: path)
    }

    private func json(_ request: URLRequest, path: String, upload file: URL? = nil) async throws -> (Cloud.JSON, HTTPResult) {
        let result = try await session.send(request, upload: file)
        try check(result, path: path)
        return (result.data.isEmpty ? [:] : try Cloud.object(result), result)
    }

    private func isFolder(_ m: Cloud.JSON) -> Bool { m["mimeType"] as? String == Self.folderType }
    private func isGoogleDoc(_ m: Cloud.JSON) -> Bool {
        (m["mimeType"] as? String)?.hasPrefix("application/vnd.google-apps.") == true && !isFolder(m)
    }

    private func info(_ m: Cloud.JSON) -> HTTPFileInfo {
        HTTPFileInfo(size: isFolder(m) ? 0 : Cloud.int64(m["size"]), modified: Cloud.date(m["modifiedTime"]),
                     etag: Cloud.quoted("v" + String(Cloud.int64(m["version"]))), directory: isFolder(m))
    }

    private func id(_ m: Cloud.JSON) throws -> String {
        guard let id = m["id"] as? String else { throw CoreKitError.remote("Google Drive returned an item without an ID.") }
        return id
    }

    private func query(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// The item at a path, or nil if nothing has that name. Ambiguous names are refused.
    private func lookup(_ path: String) async throws -> Cloud.JSON? {
        if path == "/" { return try await json(Cloud.request(Cloud.url(api, "files/root", query: ["fields": fields])), path: path).0 }
        let parent = try await folder(PathRules.parent(of: path)), name = PathRules.name(of: path)
        let q = "'\(query(parent))' in parents and name = '\(query(name))' and trashed = false"
        let page = try await json(Cloud.request(Cloud.url(api, "files", query: ["q": q, "fields": "files(\(fields))", "pageSize": "10"])), path: path).0
        let matches = (page["files"] as? [Cloud.JSON] ?? []).filter { $0["name"] as? String == name }
        guard matches.count <= 1 else {
            throw CoreKitError.remote("Google Drive has more than one item named “\(name)” in this folder. Rename one of them in Google Drive.")
        }
        return matches.first
    }

    private func existing(_ path: String) async throws -> Cloud.JSON {
        guard let m = try await lookup(path) else { throw CoreKitError.notFound(path) }
        if isGoogleDoc(m) { throw CoreKitError.unsafePath(path) }
        return m
    }

    // ponytail: resolves each level per call; cache folder IDs if deep trees are slow.
    private func folder(_ path: String) async throws -> String {
        let m = try await existing(path)
        guard isFolder(m) else { throw CoreKitError.unsafePath(path) }
        return try id(m)
    }

    func inspect(_ path: String) async throws -> HTTPFileInfo { info(try await existing(path)) }

    func children(_ path: String) async throws -> [(name: String, info: HTTPFileInfo)] {
        let parent = try await folder(path)
        var items: [Cloud.JSON] = [], token: String?
        repeat {
            var q = ["q": "'\(query(parent))' in parents and trashed = false", "fields": "nextPageToken,files(\(fields))", "pageSize": "1000"]
            if let token { q["pageToken"] = token }
            let page = try await json(Cloud.request(Cloud.url(api, "files", query: q)), path: path).0
            items += page["files"] as? [Cloud.JSON] ?? []
            token = page["nextPageToken"] as? String
        } while token != nil
        let names = items.compactMap { $0["name"] as? String }
        let duplicated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        return items.compactMap { m in
            guard let name = m["name"] as? String, !duplicated.contains(name), !isGoogleDoc(m) else { return nil }
            return (name, info(m))
        }
    }

    func get(_ path: String, info: HTTPFileInfo, offset: Int64?, length: Int?, output: URL?) async throws -> HTTPResult {
        let m = try await existing(path)
        guard self.info(m) == info else { throw CoreKitError.itemChanged(path) }
        var request = try Cloud.request(Cloud.url(api, "files/\(id(m))", query: ["alt": "media"]))
        if let range = Cloud.range(offset: offset, length: length) { request.setValue(range, forHTTPHeaderField: "Range") }
        return try await session.send(request, output: output, maximum: max(4096, length.map(Int64.init) ?? info.size))
    }

    func put(_ path: String, file: URL, previous: HTTPFileInfo?) async throws {
        let start: URLRequest
        if let previous {
            let m = try await existing(path)
            guard info(m) == previous else { throw CoreKitError.itemChanged(path) }
            start = try Cloud.request(Cloud.url(upload, "files/\(id(m))", query: ["uploadType": "resumable", "fields": "id"]), method: "PATCH", json: [String: Any]())
        } else {
            let parent = try await folder(PathRules.parent(of: path))
            if try await lookup(path) != nil { throw CoreKitError.alreadyExists(path) }
            start = try Cloud.request(Cloud.url(upload, "files", query: ["uploadType": "resumable", "fields": "id"]), method: "POST",
                                      json: ["name": PathRules.name(of: path), "parents": [parent]])
        }
        let (_, started) = try await json(start, path: path)
        guard let location = started["location"], let url = URL(string: location), url.scheme == "https" || url.host == "127.0.0.1" else {
            throw CoreKitError.remote("Google Drive did not start an upload.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await json(request, path: path, upload: file)
    }

    func makeDirectory(_ path: String) async throws {
        let parent = try await folder(PathRules.parent(of: path))
        if try await lookup(path) != nil { throw CoreKitError.alreadyExists(path) }
        _ = try await json(Cloud.request(Cloud.url(api, "files", query: ["fields": "id"]), method: "POST",
                                         json: ["name": PathRules.name(of: path), "mimeType": Self.folderType, "parents": [parent]]), path: path)
    }

    func rename(_ from: String, to: String, info: HTTPFileInfo) async throws {
        let source = try await existing(from)
        guard self.info(source) == info else { throw CoreKitError.itemChanged(from) }
        let newParent = try await folder(PathRules.parent(of: to))
        if try await lookup(to) != nil { throw CoreKitError.alreadyExists(to) }
        var q = ["fields": "id"]
        let oldParents = (source["parents"] as? [String] ?? []).joined(separator: ",")
        if PathRules.parent(of: from) != PathRules.parent(of: to) { q["addParents"] = newParent; q["removeParents"] = oldParents }
        _ = try await json(Cloud.request(Cloud.url(api, "files/\(id(source))", query: q), method: "PATCH",
                                         json: ["name": PathRules.name(of: to)]), path: to)
    }

    func delete(_ path: String, info: HTTPFileInfo) async throws {
        let m = try await existing(path)
        guard self.info(m) == info else { throw CoreKitError.itemChanged(path) }
        _ = try await json(Cloud.request(Cloud.url(api, "files/\(id(m))", query: ["fields": "id"]), method: "PATCH",
                                         json: ["trashed": true]), path: path)
    }

    func account() async throws -> String {
        let about = try await json(Cloud.request(Cloud.url(api, "about", query: ["fields": "user(emailAddress)"])), path: "/").0
        return (about["user"] as? Cloud.JSON)?["emailAddress"] as? String ?? "Google account"
    }
}
