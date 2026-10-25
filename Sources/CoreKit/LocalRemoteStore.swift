import Foundation
import CryptoKit
import Darwin

public actor LocalRemoteStore: RemoteStore {
    private let rootFD: Int32

    public init(root: URL) throws {
        guard root.isFileURL else { throw CoreKitError.invalidPath(root.absoluteString) }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posix(root.path) }
        rootFD = fd
    }

    deinit { Darwin.close(rootFD) }

    public func list(path: String) throws -> [RemoteEntry] {
        try Task.checkCancellation()
        let path = try PathRules.normalize(path)
        let fd = try directory(path)
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw Self.posix(path) }
        defer { closedir(stream) }
        var entries: [RemoteEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let row = readdir(stream) else {
                if errno != 0 { throw Self.posix(path) }
                break
            }
            guard let name = withUnsafePointer(to: &row.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }) else { continue }
            if name == "." || name == ".." || PathRules.isTemporary(name) { continue }
            let child = (path == "/" ? "" : path) + "/" + name
            guard (try? PathRules.normalize(child)) != nil else { continue }
            var info = Darwin.stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw Self.posix(child)
            }
            guard Self.supported(info) else { continue }
            var entry = Self.entry(child, info)
            if !entry.isDirectory { entry.remoteRevision = Self.revision(info) }
            entries.append(entry)
        }
        return entries.sorted { $0.name < $1.name }
    }

    public func stat(path: String) throws -> RemoteEntry {
        try Task.checkCancellation()
        let path = try PathRules.normalize(path)
        var info = Darwin.stat()
        if path == "/" {
            guard fstat(rootFD, &info) == 0 else { throw Self.posix(path) }
        } else {
            let (fd, name) = try parent(path)
            defer { Darwin.close(fd) }
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posix(path) }
        }
        guard Self.supported(info) else { throw CoreKitError.unsafePath(path) }
        var entry = Self.entry(path, info)
        if !entry.isDirectory { entry.remoteRevision = Self.revision(info) }
        return entry
    }

    public func read(path: String, offset: Int64, length: Int) throws -> Data {
        try PathRules.validateRange(offset: offset, length: length)
        try Task.checkCancellation()
        let fd = try file(path, flags: O_RDONLY)
        defer { Darwin.close(fd) }
        var before = Darwin.stat()
        guard fstat(fd, &before) == 0 else { throw Self.posix(path) }
        var data = Data(count: length)
        var count = 0
        try data.withUnsafeMutableBytes { bytes in
            while count < length {
                try Task.checkCancellation()
                let n = pread(fd, bytes.baseAddress!.advanced(by: count), min(256 * 1024, length - count), offset + Int64(count))
                if n < 0 { if errno == EINTR { continue }; throw Self.posix(path) }
                if n == 0 { break }
                count += n
            }
        }
        data.count = count
        try validateFile(fd, path: path, before: before)
        return data
    }

    public func openUploadSource(path: String) throws -> LocalUploadSource {
        let path = try PathRules.normalize(path)
        let fd = try file(path, flags: O_RDONLY)
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw Self.posix(path) }
        var entry = Self.entry(path, info)
        entry.remoteRevision = Self.revision(info)
        return LocalUploadSource(descriptor: fd, version: entry.version)
    }

    public func write(path: String, offset: Int64, data: Data) throws {
        try PathRules.validateRange(offset: offset, length: data.count)
        try Task.checkCancellation()
        let fd = try file(path, flags: O_WRONLY | O_CREAT)
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var count = 0
            while count < data.count {
                try Task.checkCancellation()
                let n = pwrite(fd, bytes.baseAddress!.advanced(by: count), min(256 * 1024, data.count - count), offset + Int64(count))
                if n < 0 { if errno == EINTR { continue }; throw Self.posix(path) }
                guard n > 0 else { throw CoreKitError.remote("Write made no progress.") }
                count += n
            }
        }
        guard fsync(fd) == 0 else { throw Self.posix(path) }
    }

    public func createDirectory(path: String) throws {
        let (fd, name) = try parent(path)
        defer { Darwin.close(fd) }
        guard mkdirat(fd, name, 0o700) == 0 else { throw Self.posix(path) }
    }

    public func move(from: String, to: String) throws {
        let source = try PathRules.normalize(from), target = try PathRules.normalize(to)
        _ = try stat(path: source)
        let (sourceFD, sourceName) = try parent(source)
        defer { Darwin.close(sourceFD) }
        let (targetFD, targetName) = try parent(target)
        defer { Darwin.close(targetFD) }
        guard renameatx_np(sourceFD, sourceName, targetFD, targetName, UInt32(RENAME_EXCL)) == 0 else { throw Self.posix(target) }
    }

    public func remove(path: String) throws {
        let entry = try stat(path: path)
        let (fd, name) = try parent(path)
        defer { Darwin.close(fd) }
        guard unlinkat(fd, name, entry.isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw Self.posix(path) }
    }

    public func checksum(path: String) throws -> String {
        let fd = try file(path, flags: O_RDONLY)
        defer { Darwin.close(fd) }
        var before = Darwin.stat()
        guard fstat(fd, &before) == 0 else { throw Self.posix(path) }
        let digest = try Self.digest(fd, path: path)
        try validateFile(fd, path: path, before: before)
        return digest
    }

    private static func revision(_ info: Darwin.stat) -> String {
        "local:\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    private func validateFile(_ fd: Int32, path: String, before: Darwin.stat) throws {
        var after = Darwin.stat()
        guard fstat(fd, &after) == 0 else { throw Self.posix(path) }
        guard Self.revision(before) == Self.revision(after),
              try stat(path: path).remoteRevision == Self.revision(after) else { throw CoreKitError.itemChanged(path) }
    }

    private static func digest(_ fd: Int32, path: String) throws -> String {
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Self.posix(path) }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func directory(_ path: String) throws -> Int32 {
        var fd = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posix(path) }
        do {
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.posix(path) }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func parent(_ path: String) throws -> (Int32, String) {
        let path = try PathRules.normalize(path)
        guard path != "/" else { throw CoreKitError.invalidPath(path) }
        return (try directory(PathRules.parent(of: path)), PathRules.name(of: path))
    }

    private func file(_ path: String, flags: Int32) throws -> Int32 {
        let (parentFD, name) = try parent(path)
        defer { Darwin.close(parentFD) }
        let fd = openat(parentFD, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Self.posix(path) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw CoreKitError.unsafePath(path)
        }
        return fd
    }

    private static func supported(_ info: Darwin.stat) -> Bool {
        let mode = info.st_mode & S_IFMT
        return mode == S_IFREG || mode == S_IFDIR
    }

    private static func entry(_ path: String, _ info: Darwin.stat) -> RemoteEntry {
        RemoteEntry(name: PathRules.name(of: path), path: path, isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                    size: Int64(info.st_size), modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
    }

    private static func posix(_ path: String) -> CoreKitError {
        switch errno {
        case ENOENT: .notFound(path)
        case EEXIST: .alreadyExists(path)
        case ELOOP, ENOTDIR: .unsafePath(path)
        default: .remote("Filesystem error \(errno): \(String(cString: strerror(errno)))")
        }
    }
}
