import Foundation

/// One bounded warm window per connection; entries are never joined across revisions.
struct SFTPReadCache {
    static let capacity = 4 * 1024 * 1024
    private(set) var path: String?
    private var version = ""
    private var offset: Int64 = 0
    private(set) var data = Data()

    mutating func clear() { path = nil; version = ""; data = Data() }

    mutating func validate(path: String, version: String) {
        if self.path == path, self.version != version { clear() }
    }

    func read(path: String, version: String, offset: Int64, length: Int, fileSize: Int64) -> Data? {
        guard self.path == path, self.version == version, offset >= self.offset else { return nil }
        let start = offset - self.offset
        let count = min(Int64(length), max(0, fileSize - offset))
        guard start <= Int64(data.count), count <= Int64(data.count) - start else { return nil }
        return data.subdata(in: Int(start)..<Int(start + count))
    }

    mutating func insert(path: String, version: String, offset: Int64, data: Data) {
        guard data.count <= Self.capacity else { clear(); return }
        self.path = path; self.version = version; self.offset = offset; self.data = data
    }
}

/// These formats are probed, never assumed from the server's provider name or OS.
enum SFTPStatFormat: CaseIterable {
    case gnu, bsd

    func command(path: String) -> String {
        command(paths: [path])
    }

    func command(paths: [String]) -> String {
        let arguments = paths.map(PathRules.shellQuote).joined(separator: " ")
        switch self {
        case .gnu: return "stat -c '%d|%i|%s|%Y|%y|%z|%f' -- " + arguments
        case .bsd: return "stat -f '%d|%i|%z|%m|%.9Fm|%.9Fc|%p' " + arguments
        }
    }

    func parse(_ output: Data) -> SFTPStatRevision? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let row = text.trimmingCharacters(in: .newlines)
        let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7, fields.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }),
              let device = UInt64(fields[0]), let inode = UInt64(fields[1]), inode > 0,
              let size = Int64(fields[2]), size >= 0, let seconds = Int64(fields[3]),
              let mode = UInt32(fields[6], radix: self == .gnu ? 16 : 8), mode & 0o170000 == 0o100000 else { return nil }
        let pattern = self == .gnu
            ? #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.[0-9]{9} [+-][0-9]{4}$"#
            : #"^-?[0-9]+\.[0-9]{9}$"#
        guard fields[4].range(of: pattern, options: .regularExpression) != nil,
              fields[5].range(of: pattern, options: .regularExpression) != nil else { return nil }
        let ctimeFraction = fields[5].split(separator: ".").last!.prefix(9)
        // shortcut: zero-fraction ctime may come from a coarse filesystem; hash that file.
        let highResolution = ctimeFraction.contains(where: { $0 != "0" })
        return SFTPStatRevision(value: "\(self):\(device):\(inode):\(size):\(fields[4]):\(fields[5])",
                                size: size, modifiedSeconds: seconds, highResolution: highResolution)
    }
}

struct SFTPStatRevision {
    let value: String
    let size: Int64
    let modifiedSeconds: Int64
    let highResolution: Bool
}
