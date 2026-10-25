import Foundation
import CryptoKit

private struct S3Transport: HTTPFileTransport {
    let endpoint: URL
    let bucket: String
    let root: String
    let signing: S3Signing

    func key(_ path: String) throws -> String {
        let path = try PathRules.normalize(path)
        return (root == "/" ? "" : String(root.dropFirst()) + "/") + (path == "/" ? "" : String(path.dropFirst()))
    }
    func objectURL(_ path: String, directory: Bool = false) throws -> URL {
        let key = try key(path)
        let path = "/" + bucket + (key.isEmpty ? "/" : "/" + key)
        let url = try HTTPStoreSupport.url(endpoint, path: path)
        guard directory, !url.absoluteString.hasSuffix("/") else { return url }
        return URL(string: url.absoluteString + "/")!
    }
    func request(_ method: String, path: String, directory: Bool = false, bucketRequest: Bool = false,
                 query: [(String, String)] = [], headers: [String: String] = [:], body: Data? = nil,
                 upload: URL? = nil, output: URL? = nil, maximum: Int64 = 4 * 1024 * 1024) async throws -> HTTPResult {
        let url = bucketRequest ? try HTTPStoreSupport.url(endpoint, path: "/" + bucket + "/") : try objectURL(path, directory: directory)
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.percentEncodedQuery = S3Signing.query(query) }
        var request = URLRequest(url: c.url!); request.httpMethod = method; request.httpBody = body
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let digest: String
        if let upload { digest = try HTTPStoreSupport.hash(upload) }
        else { digest = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined() }
        signing.sign(&request, payloadHash: digest)
        return try await HTTPStoreSupport.request(request, upload: upload, output: output, maximum: maximum)
    }

    func listing(_ path: String) async throws -> [(String, HTTPFileInfo)] {
        let prefixKey = try key(path), prefix = prefixKey.isEmpty || prefixKey.hasSuffix("/") ? prefixKey : prefixKey + "/"
        var token: String?, tokens: Set<String> = [], result: [(String, HTTPFileInfo)] = [], seen: [String: Bool] = [:]
        repeat {
            var query = [("list-type", "2"), ("delimiter", "/"), ("prefix", prefix), ("max-keys", "1000")]
            if let token { query.append(("continuation-token", token)) }
            let response = try await request("GET", path: "/", bucketRequest: true, query: query)
            try response.require([200], path: path)
            let xml = try parseStorageXML(response.data)
            guard xml.name == "ListBucketResult" else { throw CoreKitError.remote("S3 returned an invalid object listing.") }
            for node in xml.children where node.name == "Contents" || node.name == "CommonPrefixes" {
                guard let key = node.value(node.name == "Contents" ? "Key" : "Prefix"), key.hasPrefix(prefix) else { throw CoreKitError.unsafePath("S3 listing prefix") }
                if key == prefix { continue }
                let directory = node.name == "CommonPrefixes" || key.hasSuffix("/")
                let suffix = String(key.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !suffix.isEmpty, !suffix.contains("/") else { throw CoreKitError.unsafePath(key) }
                let child = try PathRules.normalize((path == "/" ? "" : path) + "/" + suffix)
                let info: HTTPFileInfo
                if directory { info = HTTPFileInfo(size: 0, modified: Date(timeIntervalSince1970: 0), etag: nil, directory: true) }
                else {
                    guard let raw = node.value("Size"), let size = Int64(raw), size >= 0,
                          let rawDate = node.value("LastModified"), let date = Self.isoDate(rawDate) else { throw CoreKitError.remote("S3 returned invalid object metadata.") }
                    info = HTTPFileInfo(size: size, modified: date, etag: try HTTPStoreSupport.strongETag(node.value("ETag")), directory: false)
                }
                if let previous = seen[child] {
                    guard previous && directory else { throw CoreKitError.unsafePath("S3 has conflicting file and directory keys: " + child) }
                    continue
                }
                seen[child] = directory; result.append((child, info))
                guard result.count <= 1_000_000 else { throw CoreKitError.remote("S3 directory listing is too large.") }
            }
            if xml.value("IsTruncated") == "true" {
                guard let next = xml.value("NextContinuationToken"), !next.isEmpty, tokens.insert(next).inserted, tokens.count <= 10_000 else {
                    throw CoreKitError.remote("S3 returned invalid listing pagination.")
                }
                token = next
            } else { token = nil }
        } while token != nil
        return result
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func inspect(_ path: String) async throws -> HTTPFileInfo {
        if path == "/" {
            _ = try await listing(path)
            return HTTPFileInfo(size: 0, modified: Date(timeIntervalSince1970: 0), etag: nil, directory: true)
        }
        let response = try await request("HEAD", path: path)
        if response.status == 404 {
            let marker = try await request("HEAD", path: path, directory: true)
            if marker.status == 200 {
                guard marker["content-length"] == "0" else { throw CoreKitError.unsafePath(path) }
                return HTTPFileInfo(size: 0, modified: Date(timeIntervalSince1970: 0), etag: try HTTPStoreSupport.strongETag(marker["etag"]), directory: true)
            }
            try marker.require([404], path: path)
            if !(try await listing(path)).isEmpty { return HTTPFileInfo(size: 0, modified: Date(timeIntervalSince1970: 0), etag: nil, directory: true) }
            throw CoreKitError.notFound(path)
        }
        try response.require([200], path: path)
        guard let raw = response["content-length"], let size = Int64(raw), size >= 0 else { throw CoreKitError.remote("S3 returned an invalid object size.") }
        return HTTPFileInfo(size: size, modified: try HTTPStoreSupport.date(response["last-modified"]), etag: try HTTPStoreSupport.strongETag(response["etag"]), directory: false)
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
        let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard size >= 0, size <= 5 * 1024 * 1024 * 1024 * 1024 else { throw CoreKitError.remote("S3 uploads are limited to five TiB.") }
        if size <= 64 * 1024 * 1024 {
            let response = try await request("PUT", path: path, headers: headers, upload: file)
            if response.status == 412, previous == nil { throw CoreKitError.alreadyExists(path) }
            try response.require([200], path: path)
        } else { try await multipart(path, file: file, size: size, headers: headers, creating: previous == nil) }
    }

    private func multipart(_ path: String, file: URL, size: Int64, headers: [String: String], creating: Bool) async throws {
        let start = try await request("POST", path: path, query: [("uploads", "")])
        try start.require([200], path: path)
        let xml = try parseStorageXML(start.data)
        guard xml.name == "InitiateMultipartUploadResult", let id = xml.value("UploadId"), !id.isEmpty, id.utf8.count <= 4096 else {
            throw CoreKitError.remote("S3 did not return a valid multipart upload ID.")
        }
        do {
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            let partSize = max(Int64(16 * 1024 * 1024), ((size + 9999) / 10000 + 1024 * 1024 - 1) / (1024 * 1024) * (1024 * 1024))
            var sent: Int64 = 0, parts: [String] = [], number = 1
            while sent < size {
                try Task.checkCancellation()
                let part = try HTTPStoreSupport.temporary(); defer { HTTPStoreSupport.cleanup(part) }
                let output = try FileHandle(forWritingTo: part)
                do {
                    var remaining = min(partSize, size - sent)
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                        guard !data.isEmpty else { throw CoreKitError.sourceChanged }
                        try output.write(contentsOf: data); remaining -= Int64(data.count); sent += Int64(data.count)
                    }
                    try output.close()
                } catch { try? output.close(); throw error }
                let response = try await request("PUT", path: path, query: [("uploadId", id), ("partNumber", String(number))], upload: part)
                try response.require([200], path: path)
                let etag = try HTTPStoreSupport.strongETag(response["etag"])
                parts.append("<Part><PartNumber>\(number)</PartNumber><ETag>\(xmlEscape(etag))</ETag></Part>"); number += 1
            }
            let body = Data(("<CompleteMultipartUpload>" + parts.joined() + "</CompleteMultipartUpload>").utf8)
            let complete = try await request("POST", path: path, query: [("uploadId", id)], headers: headers.merging(["Content-Type": "application/xml"]) { _, new in new }, body: body)
            if complete.status == 412, creating { throw CoreKitError.alreadyExists(path) }
            try complete.require([200], path: path)
            let result = try parseStorageXML(complete.data)
            guard result.name == "CompleteMultipartUploadResult" else {
                if result.value("Code") == "PreconditionFailed", creating { throw CoreKitError.alreadyExists(path) }
                throw CoreKitError.remote("S3 failed to complete the multipart upload.")
            }
            _ = try HTTPStoreSupport.strongETag(result.value("ETag"))
        } catch {
            let transport = self
            _ = await Task.detached { try? await transport.request("DELETE", path: path, query: [("uploadId", id)]) }.value
            throw error
        }
    }
}

func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}

/// Path-style S3 with SigV4 and conditional writes. Servers must implement conditional PUT, completion and DELETE.
public actor S3Store: RemoteStore {
    private let transport: S3Transport
    private var uploads: [String: HTTPStagedUpload] = [:]
    private var busy: Set<String> = []
    public nonisolated var publicationMode: PublicationMode { .copyPreservingSource }
    public nonisolated var supportsDirectoryMove: Bool { false }
    public nonisolated var supportsConditionalReplacement: Bool { true }

    public init(endpoint: URL, bucket: String, region: String, accessKey: String, secretKey: String,
                sessionToken: String? = nil, rootPath: String = "/", allowInsecureLoopback: Bool = false) throws {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard (3...63).contains(bucket.utf8.count), bucket.unicodeScalars.allSatisfy(safe.contains), !bucket.contains(".."),
              !region.isEmpty, region.utf8.count <= 128, region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !accessKey.isEmpty, accessKey.utf8.count <= 256, !accessKey.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "," }),
              !secretKey.isEmpty, sessionToken?.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) != true else {
            throw CoreKitError.connection("Invalid S3 bucket, region or credentials.")
        }
        transport = S3Transport(endpoint: try HTTPStoreSupport.endpoint(endpoint, allowInsecureLoopback: allowInsecureLoopback),
                                bucket: bucket, root: try PathRules.normalize(rootPath),
                                signing: S3Signing(accessKey: accessKey, secretKey: secretKey, region: region, sessionToken: sessionToken))
    }
    deinit { for upload in uploads.values { HTTPStoreSupport.cleanup(upload.file) } }

    public func list(path: String) async throws -> [RemoteEntry] {
        let path = try PathRules.normalize(path)
        guard try await transport.inspect(path).directory else { throw CoreKitError.unsafePath(path) }
        return try await transport.listing(path).filter { !PathRules.isTemporary(PathRules.name(of: $0.0)) }.map { $0.1.entry($0.0) }.sorted { $0.name < $1.name }
    }
    public func stat(path: String) async throws -> RemoteEntry { try await HTTPFileOperations.stat(transport, path: PathRules.normalize(path)) }
    public func checksum(path: String) async throws -> String { try await HTTPFileOperations.checksum(transport, path: PathRules.normalize(path)) }
    public func verifyWritePreconditions(path: String) async throws {
        try await HTTPFileOperations.verifyPreconditions(transport, path: PathRules.normalize(path))
    }
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
        do { _ = try await transport.inspect(path); throw CoreKitError.alreadyExists(path) } catch CoreKitError.notFound { }
        guard try await transport.inspect(PathRules.parent(of: path)).directory else { throw CoreKitError.unsafePath(path) }
        let response = try await transport.request("PUT", path: path, directory: true, headers: ["If-None-Match": "*"], body: Data())
        if response.status == 412 { throw CoreKitError.alreadyExists(path) }
        try response.require([200], path: path)
    }
    public func move(from: String, to: String) async throws {
        _ = try PathRules.normalize(from); _ = try PathRules.normalize(to)
        throw CoreKitError.remote("S3 has no atomic rename. Publishing copies to a new name and retains the source; rename and trash are unavailable.")
    }
    public func publish(from: String, to: String) async throws {
        let from = try PathRules.normalize(from), to = try PathRules.normalize(to)
        guard from != "/", to != "/", from != to else { throw CoreKitError.invalidPath(to) }
        let upload = try await HTTPFileOperations.stage(transport, path: from)
        defer { HTTPStoreSupport.cleanup(upload.file) }
        guard let source = upload.previous, !source.directory else { throw CoreKitError.notFound(from) }
        try await transport.put(to, file: upload.file, previous: nil)
    }
    public func replace(from: String, to: String, expectedVersion: String) async throws {
        let from = try PathRules.normalize(from), to = try PathRules.normalize(to)
        guard from != "/", to != "/", from != to else { throw CoreKitError.invalidPath(to) }
        let target = try await transport.inspect(to)
        guard !target.directory, target.entry(to).version == expectedVersion else { throw CoreKitError.itemChanged(to) }
        let upload = try await HTTPFileOperations.stage(transport, path: from)
        defer { HTTPStoreSupport.cleanup(upload.file) }
        guard upload.previous != nil else { throw CoreKitError.notFound(from) }
        try await transport.put(to, file: upload.file, previous: target)
    }
    public func remove(path: String) async throws {
        let path = try PathRules.normalize(path); guard path != "/" else { throw CoreKitError.invalidPath(path) }
        guard !busy.contains(path) else { throw CoreKitError.itemChanged(path) }
        if let upload = uploads.removeValue(forKey: path) { HTTPStoreSupport.cleanup(upload.file) }
        let info = try await transport.inspect(path)
        if info.directory {
            guard try await transport.listing(path).isEmpty else { throw CoreKitError.remote("Nonempty directories cannot be removed.") }
            guard info.etag != nil else { throw CoreKitError.notFound(path) }
        }
        let response = try await transport.request("DELETE", path: path, directory: info.directory, headers: ["If-Match": try HTTPStoreSupport.strongETag(info.etag)])
        try response.require([204], path: path)
    }

    /// The URL grants read access until expiry (temporary credentials may expire earlier). Treat it as a secret.
    public func presignedGET(path: String, expires: Int = 3600) throws -> URL {
        let path = try PathRules.normalize(path); guard path != "/" else { throw CoreKitError.invalidPath(path) }
        return try transport.signing.presignedGET(transport.objectURL(path), expires: expires)
    }
}
