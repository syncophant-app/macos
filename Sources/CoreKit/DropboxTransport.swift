import Foundation

/// Dropbox API v2. Paths are addressed directly; `rev` is the version. Uploads use mode `add` (create-only)
/// or `update` with the expected rev and `strict_conflict`, and moves never auto-rename, so the server
/// enforces both no-clobber rules.
struct DropboxTransport: CloudTransport {
    let session: OAuthSession
    let api: URL
    let content: URL

    init(session: OAuthSession, bases: [URL]?) {
        self.session = session
        api = bases?[0] ?? URL(string: "https://api.dropboxapi.com/2")!
        content = bases?[1] ?? URL(string: "https://content.dropboxapi.com/2")!
    }

    private func dropboxPath(_ path: String) -> String { path == "/" ? "" : path }

    private func info(_ m: Cloud.JSON) throws -> HTTPFileInfo {
        switch m[".tag"] as? String {
        case "file":
            guard let rev = m["rev"] as? String else { throw CoreKitError.remote("Dropbox returned a file without a revision.") }
            return HTTPFileInfo(size: Cloud.int64(m["size"]), modified: Cloud.date(m["server_modified"]), etag: Cloud.quoted(rev), directory: false)
        case "folder":
            return HTTPFileInfo(size: 0, modified: Date(timeIntervalSince1970: 0), etag: nil, directory: true)
        default:
            throw CoreKitError.notFound(m["path_display"] as? String ?? "")
        }
    }

    /// Dropbox reports most failures as HTTP 409 with an `error_summary` path such as `path/not_found/`.
    private func check(_ result: HTTPResult, path: String, conflict: CoreKitError? = nil) throws {
        guard !(200..<300).contains(result.status) else { return }
        if result.status == 409 {
            let summary = (try? Cloud.object(result))?["error_summary"] as? String ?? ""
            if summary.contains("not_found") { throw CoreKitError.notFound(path) }
            if summary.contains("conflict") { throw conflict ?? CoreKitError.alreadyExists(path) }
            if summary.contains("not_folder") { throw CoreKitError.unsafePath(path) }
            if summary.contains("malformed_path") || summary.contains("disallowed_name") { throw CoreKitError.invalidPath(path) }
            throw CoreKitError.remote("Dropbox refused the request (\(summary.split(separator: "/").first ?? "error")).")
        }
        if result.status == 429 { throw Cloud.busy(.dropbox) }
        try result.require([], path: path)
    }

    private func rpc(_ endpoint: String, _ body: Any, path: String, conflict: CoreKitError? = nil) async throws -> Cloud.JSON {
        let result = try await session.send(try Cloud.request(api.appendingPathComponent(endpoint), method: "POST", json: body))
        try check(result, path: path, conflict: conflict)
        return try Cloud.object(result)
    }

    /// `Dropbox-API-Arg` must be ASCII, so other characters are sent as JSON escapes.
    private func argument(_ value: Any) throws -> String {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        return text.utf16.map { $0 < 0x80 ? String(UnicodeScalar($0)!) : String(format: "\\u%04x", $0) }.joined()
    }

    private func contentRequest(_ endpoint: String, _ arg: Any) throws -> URLRequest {
        var request = URLRequest(url: content.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue(try argument(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        return request
    }

    func inspect(_ path: String) async throws -> HTTPFileInfo {
        if path == "/" { return HTTPFileInfo(size: 0, modified: Date(timeIntervalSince1970: 0), etag: nil, directory: true) }
        return try info(await rpc("files/get_metadata", ["path": path], path: path))
    }

    func children(_ path: String) async throws -> [(name: String, info: HTTPFileInfo)] {
        var page = try await rpc("files/list_folder", ["path": dropboxPath(path), "limit": 2000], path: path)
        var rows: [(name: String, info: HTTPFileInfo)] = []
        while true {
            for entry in page["entries"] as? [Cloud.JSON] ?? [] where entry[".tag"] as? String != "deleted" {
                if let name = entry["name"] as? String { rows.append((name, try info(entry))) }
            }
            guard page["has_more"] as? Bool == true, let cursor = page["cursor"] as? String else { return rows }
            page = try await rpc("files/list_folder/continue", ["cursor": cursor], path: path)
        }
    }

    func get(_ path: String, info: HTTPFileInfo, offset: Int64?, length: Int?, output: URL?) async throws -> HTTPResult {
        // Downloading by rev returns exactly the observed version or fails.
        var request = try contentRequest("files/download", ["path": "rev:" + Cloud.unquoted(info.etag)])
        if let range = Cloud.range(offset: offset, length: length) { request.setValue(range, forHTTPHeaderField: "Range") }
        let result = try await session.send(request, output: output, maximum: max(4096, length.map(Int64.init) ?? info.size))
        if result.status == 409 { try check(result, path: path, conflict: CoreKitError.itemChanged(path)) }
        return result
    }

    func put(_ path: String, file: URL, previous: HTTPFileInfo?) async throws {
        let mode: Any = try previous.map { [".tag": "update", "update": try Cloud.unquoted($0.etag)] as [String: Any] } ?? "add"
        let commit: [String: Any] = ["path": path, "mode": mode, "autorename": false, "mute": true, "strict_conflict": true]
        let conflict = previous == nil ? CoreKitError.alreadyExists(path) : CoreKitError.itemChanged(path)
        let size = try Cloud.fileSize(file)
        if size <= 128 * 1024 * 1024 {
            var request = try contentRequest("files/upload", commit)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            try check(await session.send(request, upload: file), path: path, conflict: conflict)
            return
        }
        let empty = try HTTPStoreSupport.temporary()
        defer { HTTPStoreSupport.cleanup(empty) }
        var start = try contentRequest("files/upload_session/start", ["close": false])
        start.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let started = try await session.send(start, upload: empty)
        try check(started, path: path)
        guard let id = try Cloud.object(started)["session_id"] as? String else { throw CoreKitError.remote("Dropbox did not start an upload session.") }
        try await Cloud.chunks(of: file, size: 64 * 1024 * 1024) { part, _, offset in
            var append = try contentRequest("files/upload_session/append_v2", ["cursor": ["session_id": id, "offset": offset], "close": false])
            append.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            try check(await session.send(append, upload: part), path: path)
        }
        var finish = try contentRequest("files/upload_session/finish", ["cursor": ["session_id": id, "offset": size], "commit": commit])
        finish.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        try check(await session.send(finish, upload: empty), path: path, conflict: conflict)
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await rpc("files/create_folder_v2", ["path": path, "autorename": false], path: path)
    }

    func rename(_ from: String, to: String, info: HTTPFileInfo) async throws {
        _ = try await rpc("files/move_v2", ["from_path": from, "to_path": to, "autorename": false, "allow_ownership_transfer": false],
                          path: to)
    }

    func delete(_ path: String, info: HTTPFileInfo) async throws {
        var body: [String: Any] = ["path": path]
        if !info.directory { body["parent_rev"] = try Cloud.unquoted(info.etag) }
        _ = try await rpc("files/delete_v2", body, path: path, conflict: CoreKitError.itemChanged(path))
    }

    func account() async throws -> String {
        let json = try await rpc("users/get_current_account", NSNull(), path: "/")
        return json["email"] as? String ?? "Dropbox account"
    }
}
