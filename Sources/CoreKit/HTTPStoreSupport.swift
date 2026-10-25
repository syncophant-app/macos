import Foundation
import CryptoKit

struct HTTPFileInfo: Equatable, Sendable {
    let size: Int64
    let modified: Date
    let etag: String?
    let directory: Bool

    func entry(_ path: String, hash: String? = nil) -> RemoteEntry {
        RemoteEntry(name: PathRules.name(of: path), path: path, isDirectory: directory,
                    size: size, modifiedAt: modified, contentHash: hash, remoteRevision: etag)
    }
}

struct HTTPResult: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
    subscript(_ name: String) -> String? { headers[name.lowercased()] }

    func require(_ statuses: Set<Int>, path: String) throws {
        guard !statuses.contains(status) else { return }
        switch status {
        case 401, 403: throw CoreKitError.authenticationFailed
        case 404: throw CoreKitError.notFound(path)
        case 409, 412: throw CoreKitError.itemChanged(path)
        case 300..<400: throw CoreKitError.connection("Storage redirects are refused; configure the final endpoint URL.")
        default: throw CoreKitError.remote("Storage server returned HTTP \(status).")
        }
    }
}

/// A request owns its session so cancellation never affects another operation. No redirects or shared credentials.
private final class HTTPRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<HTTPResult, any Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var failure: (any Error)?
    private let output: FileHandle?
    private let maximum: Int64
    private var received: Int64 = 0

    init(output: URL?, maximum: Int64) throws {
        self.maximum = maximum
        self.output = try output.map { try FileHandle(forWritingTo: $0) }
    }

    func run(_ request: URLRequest, upload: URL?) async throws -> HTTPResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = upload.map { session.uploadTask(with: request, fromFile: $0) } ?? session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation; self.task = task
                let cancelled = self.cancelled
                lock.unlock()
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            failure = CoreKitError.connection("Invalid storage response."); completionHandler(.cancel); return
        }
        self.response = response
        if dataTask.originalRequest?.httpMethod != "HEAD", response.expectedContentLength > maximum {
            failure = CoreKitError.remote("Storage response exceeds its allowed size.")
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= maximum else {
            failure = CoreKitError.remote("Storage response exceeds its allowed size."); dataTask.cancel(); return
        }
        do {
            if let output, response.map({ (200..<300).contains($0.statusCode) }) == true { try output.write(contentsOf: data) }
            else if self.data.count + data.count <= ((response.map { (200..<300).contains($0.statusCode) } == true) ? maximum : 4 * 1024 * 1024) { self.data.append(data) }
            else { throw CoreKitError.remote("Storage error response exceeds its allowed size.") }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { try? output?.close(); session.finishTasksAndInvalidate() }
        guard let continuation else { return }
        self.continuation = nil
        if let failure { continuation.resume(throwing: failure) }
        else if let error {
            let code = (error as NSError).code
            if code == NSURLErrorCancelled { continuation.resume(throwing: CancellationError()) }
            else if code == NSURLErrorTimedOut { continuation.resume(throwing: CoreKitError.timeout) }
            else { continuation.resume(throwing: CoreKitError.connection("Storage network request failed (\(code)).")) }
        } else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            continuation.resume(returning: HTTPResult(status: response.statusCode, headers: headers, data: data))
        } else { continuation.resume(throwing: CoreKitError.connection("Storage returned no response.")) }
    }
}

enum HTTPStoreSupport {
    static func endpoint(_ url: URL, allowInsecureLoopback: Bool) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              c.scheme == "https" || (allowInsecureLoopback && c.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              let decoded = c.percentEncodedPath.removingPercentEncoding,
              (try? PathRules.normalize(decoded.isEmpty ? "/" : decoded)) != nil else {
            throw CoreKitError.connection("Storage endpoint must be HTTPS without embedded credentials, query, fragment or traversal.")
        }
        return url
    }

    static func url(_ endpoint: URL, path: String) throws -> URL {
        let path = try PathRules.normalize(path)
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let base = c.percentEncodedPath.hasSuffix("/") ? String(c.percentEncodedPath.dropLast()) : c.percentEncodedPath
        c.percentEncodedPath = base + (path == "/" ? "/" : path.split(separator: "/").map { "/" + encode(String($0)) }.joined())
        guard let url = c.url else { throw CoreKitError.invalidPath(path) }
        return url
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    static func request(_ request: URLRequest, upload: URL? = nil, output: URL? = nil,
                        maximum: Int64 = 4 * 1024 * 1024) async throws -> HTTPResult {
        try Task.checkCancellation()
        return try await HTTPRequest(output: output, maximum: maximum).run(request, upload: upload)
    }

    static func date(_ value: String?) throws -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let value, let date = formatter.date(from: value) else { throw CoreKitError.remote("Storage returned an invalid modification date.") }
        return date
    }

    static func strongETag(_ value: String?) throws -> String {
        guard let value, value.hasPrefix("\""), value.hasSuffix("\""), value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw CoreKitError.remote("Storage must supply strong ETags for safe conditional operations.")
        }
        return value
    }

    static func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("syncophant-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("content")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw CoreKitError.remote("Cannot create private upload staging file.")
        }
        return file
    }

    static func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try file.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }; hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func patch(_ url: URL, offset: Int64, data: Data) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset)); try file.write(contentsOf: data); try file.synchronize()
    }
}

protocol HTTPFileTransport: Sendable {
    func inspect(_ path: String) async throws -> HTTPFileInfo
    func get(_ path: String, info: HTTPFileInfo, offset: Int64?, length: Int?, output: URL?) async throws -> HTTPResult
    func put(_ path: String, file: URL, previous: HTTPFileInfo?) async throws
}

struct HTTPStagedUpload: Sendable {
    let file: URL
    let previous: HTTPFileInfo?
}

enum HTTPFileOperations {
    static func stage(_ transport: any HTTPFileTransport, path: String) async throws -> HTTPStagedUpload {
        guard path != "/" else { throw CoreKitError.invalidPath(path) }
        let file = try HTTPStoreSupport.temporary()
        do {
            let info: HTTPFileInfo?
            do { info = try await transport.inspect(path) } catch CoreKitError.notFound { info = nil }
            if let info {
                guard !info.directory else { throw CoreKitError.unsafePath(path) }
                let response = try await transport.get(path, info: info, offset: nil, length: nil, output: file)
                try response.require([200], path: path)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size.map(Int64.init) == info.size, try await transport.inspect(path) == info else { throw CoreKitError.itemChanged(path) }
            }
            return HTTPStagedUpload(file: file, previous: info)
        } catch { HTTPStoreSupport.cleanup(file); throw error }
    }

    static func read(_ transport: any HTTPFileTransport, path: String, offset: Int64, length: Int) async throws -> Data {
        try PathRules.validateRange(offset: offset, length: length)
        let info = try await transport.inspect(path)
        guard !info.directory else { throw CoreKitError.unsafePath(path) }
        if length == 0 || offset >= info.size { return Data() }
        let count = Int(min(Int64(length), info.size - offset))
        let response = try await transport.get(path, info: info, offset: offset, length: count, output: nil)
        try response.require([206], path: path)
        guard response["content-range"] == "bytes \(offset)-\(offset + Int64(count) - 1)/\(info.size)", response.data.count == count,
              try await transport.inspect(path) == info else { throw CoreKitError.itemChanged(path) }
        return response.data
    }

    static func stat(_ transport: any HTTPFileTransport, path: String) async throws -> RemoteEntry {
        let info = try await transport.inspect(path)
        return info.entry(path)
    }

    static func checksum(_ transport: any HTTPFileTransport, path: String, expected: HTTPFileInfo? = nil) async throws -> String {
        let info: HTTPFileInfo
        if let expected { info = expected } else { info = try await transport.inspect(path) }
        guard !info.directory else { throw CoreKitError.unsafePath(path) }
        let file = try HTTPStoreSupport.temporary(); defer { HTTPStoreSupport.cleanup(file) }
        let result = try await transport.get(path, info: info, offset: nil, length: nil, output: file)
        try result.require([200], path: path)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == info.size, try await transport.inspect(path) == info else { throw CoreKitError.itemChanged(path) }
        return try HTTPStoreSupport.hash(file)
    }
}
