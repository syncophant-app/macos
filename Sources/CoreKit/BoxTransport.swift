import CryptoKit
import Foundation

/// Box API 2.0. Box addresses items by ID, so paths resolve folder by folder through a cache that is
/// re-checked (name and parent) on every use. Uploads, renames and deletes send `If-Match` with the etag,
/// creation fails with 409 when the name is taken, and folders delete with `recursive=false`.
actor BoxTransport: CloudTransport {
    private let session: OAuthSession
    private let api: URL
    private let upload: URL
    private let fields = "id,type,name,size,modified_at,etag,parent"
    private var ids: [String: String] = [:]

    init(session: OAuthSession, bases: [URL]?) {
        self.session = session
        api = bases?[0] ?? URL(string: "https://api.box.com/2.0")!
        upload = bases?[1] ?? URL(string: "https://upload.box.com/api/2.0")!
    }

    private func check(_ result: HTTPResult, path: String, conflict: CoreKitError? = nil) throws {
        guard !(200..<300).contains(result.status) else { return }
        switch result.status {
        case 409: throw conflict ?? CoreKitError.alreadyExists(path)
        case 412: throw CoreKitError.itemChanged(path)
        case 429: throw Cloud.busy(.box)
        case 400 where (try? Cloud.object(result))?["code"] as? String == "folder_not_empty":
            throw CoreKitError.remote("Nonempty directories cannot be removed.")
        default: try result.require([], path: path)
        }
    }

    private func json(_ request: URLRequest, path: String, upload file: URL? = nil, conflict: CoreKitError? = nil) async throws -> Cloud.JSON {
        let result = try await session.send(request, upload: file)
        try check(result, path: path, conflict: conflict)
        return result.data.isEmpty ? [:] : try Cloud.object(result)
    }

    private func info(_ m: Cloud.JSON) -> HTTPFileInfo {
        let folder = m["type"] as? String == "folder"
        return HTTPFileInfo(size: folder ? 0 : Cloud.int64(m["size"]), modified: Cloud.date(m["modified_at"]),
                            etag: (m["etag"] as? String).map(Cloud.quoted), directory: folder)
    }

    private func forget(_ path: String) { ids = ids.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }

    /// The item at a path, with its metadata. Cached IDs are trusted only if the name and parent still match.
    private func item(_ path: String) async throws -> Cloud.JSON {
        if path == "/" { return try await json(Cloud.request(Cloud.url(api, "folders/0", query: ["fields": fields])), path: path) }
        let parentPath = PathRules.parent(of: path), name = PathRules.name(of: path)
        let parent = try await item(parentPath)
        guard parent["type"] as? String == "folder", let parentID = parent["id"] as? String else { throw CoreKitError.unsafePath(parentPath) }
        if let id = ids[path] {
            for kind in ["files", "folders"] {
                let result = try await session.send(Cloud.request(Cloud.url(api, "\(kind)/\(id)", query: ["fields": fields])))
                guard result.status == 200, let m = try? Cloud.object(result) else { continue }
                if m["name"] as? String == name, (m["parent"] as? Cloud.JSON)?["id"] as? String == parentID { return m }
                break
            }
            ids[path] = nil
        }
        for child in try await entries(parentID, path: parentPath) where child["name"] as? String == name {
            ids[path] = child["id"] as? String
            return child
        }
        throw CoreKitError.notFound(path)
    }

    private func entries(_ folderID: String, path: String) async throws -> [Cloud.JSON] {
        var rows: [Cloud.JSON] = [], marker: String?
        repeat {
            var query = ["fields": fields, "limit": "1000", "usemarker": "true"]
            if let marker { query["marker"] = marker }
            let page = try await json(Cloud.request(Cloud.url(api, "folders/\(folderID)/items", query: query)), path: path)
            rows += (page["entries"] as? [Cloud.JSON] ?? []).filter { ["file", "folder"].contains($0["type"] as? String) }
            marker = (page["next_marker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while marker != nil
        return rows
    }

    private func id(_ m: Cloud.JSON) throws -> String {
        guard let id = m["id"] as? String else { throw CoreKitError.remote("Box returned an item without an ID.") }
        return id
    }

    func inspect(_ path: String) async throws -> HTTPFileInfo { info(try await item(path)) }

    func children(_ path: String) async throws -> [(name: String, info: HTTPFileInfo)] {
        let folder = try await item(path)
        guard folder["type"] as? String == "folder" else { throw CoreKitError.unsafePath(path) }
        return try await entries(id(folder), path: path).compactMap { child in
            guard let name = child["name"] as? String else { return nil }
            if let childID = child["id"] as? String { ids[(path == "/" ? "" : path) + "/" + name] = childID }
            return (name, info(child))
        }
    }

    func get(_ path: String, info: HTTPFileInfo, offset: Int64?, length: Int?, output: URL?) async throws -> HTTPResult {
        let m = try await item(path)
        guard m["type"] as? String == "file" else { throw CoreKitError.unsafePath(path) }
        let range = Cloud.range(offset: offset, length: length)
        var request = try Cloud.request(Cloud.url(api, "files/\(id(m))/content"))
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let maximum = max(4096, length.map(Int64.init) ?? info.size)
        return try await Cloud.followDownload(session.send(request, output: output, maximum: maximum), range: range, output: output, maximum: maximum)
    }

    func put(_ path: String, file: URL, previous: HTTPFileInfo?) async throws {
        let name = PathRules.name(of: path)
        let parent = try await item(PathRules.parent(of: path))
        guard parent["type"] as? String == "folder" else { throw CoreKitError.unsafePath(PathRules.parent(of: path)) }
        let parentID = try id(parent)
        var existingID: String?
        var headers: [String: String] = [:]
        if let previous {
            existingID = try id(await item(path))
            headers["If-Match"] = try Cloud.unquoted(previous.etag)
        }
        let conflict = previous == nil ? CoreKitError.alreadyExists(path) : CoreKitError.itemChanged(path)
        let size = try Cloud.fileSize(file)
        let created: Cloud.JSON
        if size <= 50 * 1024 * 1024 {
            created = try await simpleUpload(file, name: name, parentID: parentID, existingID: existingID, headers: headers, path: path, conflict: conflict)
        } else {
            created = try await chunkedUpload(file, size: size, name: name, parentID: parentID, existingID: existingID, headers: headers, path: path, conflict: conflict)
        }
        if let newID = (created["entries"] as? [Cloud.JSON])?.first?["id"] as? String { ids[path] = newID }
    }

    private func simpleUpload(_ file: URL, name: String, parentID: String, existingID: String?, headers: [String: String],
                              path: String, conflict: CoreKitError) async throws -> Cloud.JSON {
        let boundary = "syncophant-" + UUID().uuidString
        let attributes: [String: Any] = existingID == nil ? ["name": name, "parent": ["id": parentID]] : ["name": name]
        let body = try HTTPStoreSupport.temporary(); defer { HTTPStoreSupport.cleanup(body) }
        let out = try FileHandle(forWritingTo: body)
        do {
            try out.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n").utf8))
            try out.write(contentsOf: JSONSerialization.data(withJSONObject: attributes))
            try out.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try out.close()
        } catch { try? out.close(); throw error }
        let target = existingID.map { "files/\($0)/content" } ?? "files/content"
        var request = try Cloud.request(Cloud.url(upload, target), method: "POST", headers: headers)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return try await json(request, path: path, upload: body, conflict: conflict)
    }

    private func chunkedUpload(_ file: URL, size: Int64, name: String, parentID: String, existingID: String?, headers: [String: String],
                               path: String, conflict: CoreKitError) async throws -> Cloud.JSON {
        let target = existingID.map { "files/\($0)/upload_sessions" } ?? "files/upload_sessions"
        let body: [String: Any] = existingID == nil ? ["folder_id": parentID, "file_size": size, "file_name": name] : ["file_size": size]
        let session = try await json(Cloud.request(Cloud.url(upload, target), method: "POST", json: body, headers: headers), path: path, conflict: conflict)
        guard let sessionID = session["id"] as? String, let partSize = (session["part_size"] as? NSNumber)?.intValue, partSize > 0 else {
            throw CoreKitError.remote("Box did not start an upload session.")
        }
        var parts: [Data] = [], whole = Insecure.SHA1()
        try await Cloud.chunks(of: file, size: partSize) { part, data, offset in
            whole.update(data: data)
            var request = try Cloud.request(Cloud.url(upload, "files/upload_sessions/\(sessionID)"), method: "PUT", headers: [
                "Content-Range": "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(size)",
                "Digest": "sha=" + Data(Insecure.SHA1.hash(data: data)).base64EncodedString()])
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let uploaded = try await json(request, path: path, upload: part)["part"] {
                parts.append(try JSONSerialization.data(withJSONObject: uploaded))
            }
        }
        var commitHeaders = headers
        commitHeaders["Digest"] = "sha=" + Data(whole.finalize()).base64EncodedString()
        let commit = try Cloud.request(Cloud.url(upload, "files/upload_sessions/\(sessionID)/commit"), method: "POST",
                                       json: ["parts": try parts.map { try JSONSerialization.jsonObject(with: $0) }], headers: commitHeaders)
        for _ in 0..<30 {
            let result = try await self.session.send(commit)
            if result.status == 202 {
                let wait = Double(result["retry-after"] ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(max(wait, 1), 10)))
                continue
            }
            try check(result, path: path, conflict: conflict)
            return try Cloud.object(result)
        }
        throw CoreKitError.timeout
    }

    func makeDirectory(_ path: String) async throws {
        let parent = try await item(PathRules.parent(of: path))
        guard parent["type"] as? String == "folder" else { throw CoreKitError.unsafePath(PathRules.parent(of: path)) }
        let created = try await json(Cloud.request(Cloud.url(api, "folders", query: ["fields": fields]), method: "POST",
                                                   json: ["name": PathRules.name(of: path), "parent": ["id": try id(parent)]]), path: path)
        ids[path] = created["id"] as? String
    }

    func rename(_ from: String, to: String, info: HTTPFileInfo) async throws {
        let source = try await item(from)
        let parent = try await item(PathRules.parent(of: to))
        guard parent["type"] as? String == "folder" else { throw CoreKitError.unsafePath(PathRules.parent(of: to)) }
        let kind = source["type"] as? String == "folder" ? "folders" : "files"
        var headers: [String: String] = [:]
        if let etag = source["etag"] as? String { headers["If-Match"] = etag }
        _ = try await json(Cloud.request(Cloud.url(api, "\(kind)/\(id(source))", query: ["fields": fields]), method: "PUT",
                                         json: ["name": PathRules.name(of: to), "parent": ["id": try id(parent)]], headers: headers), path: to)
        forget(from); forget(to)
    }

    func delete(_ path: String, info: HTTPFileInfo) async throws {
        let m = try await item(path)
        guard self.info(m) == info else { throw CoreKitError.itemChanged(path) }
        var headers: [String: String] = [:]
        if let etag = m["etag"] as? String { headers["If-Match"] = etag }
        let url = info.directory ? Cloud.url(api, "folders/\(try id(m))", query: ["recursive": "false"]) : Cloud.url(api, "files/\(try id(m))")
        _ = try await json(Cloud.request(url, method: "DELETE", headers: headers), path: path, conflict: .itemChanged(path))
        forget(path)
    }

    func account() async throws -> String {
        try await json(Cloud.request(Cloud.url(api, "users/me", query: ["fields": "login"])), path: "/")["login"] as? String ?? "Box account"
    }
}
