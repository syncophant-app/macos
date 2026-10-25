import Foundation

public enum PathRules {
    public static let maximumReadLength = 16 * 1024 * 1024

    /// Paths are virtual, root-relative POSIX paths. Dot traversal is never normalized away.
    public static func normalize(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.contains("\\") else { throw CoreKitError.invalidPath(path) }
        let parts = path.split(separator: "/")
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw CoreKitError.invalidPath(path)
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func parent(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return "/" + parts.joined(separator: "/")
    }

    public static func name(of path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "/" }

    public static func isTemporary(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".ds_store" || lower == ".syncophant-trash" || lower.hasPrefix("._") || lower.hasPrefix("~$")
            || lower.hasPrefix(".~lock.") || lower.hasPrefix(".synco-")
            || lower.contains(".partial-") || lower.hasSuffix(".crdownload")
            || lower.hasSuffix(".download") || lower.hasSuffix(".part")
            || lower.hasSuffix(".tmp") || lower.hasSuffix(".swp")
            || lower.hasSuffix(".lck") || lower.hasSuffix(".idlk") || lower.hasSuffix("~")
    }

    public static func isVisible(path: String) -> Bool {
        path.split(separator: "/").allSatisfy { !isTemporary(String($0)) }
    }

    /// Leaves server paths untouched; suffixes every member of a case-insensitive collision.
    public static func displayNames(for entries: [RemoteEntry]) -> [String: String] {
        let groups = Dictionary(grouping: entries) { $0.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        var result: [String: String] = [:]
        for group in groups.values {
            for (index, entry) in group.sorted(by: { $0.path < $1.path }).enumerated() {
                result[entry.id] = group.count > 1 ? "\(entry.name) (case conflict \(index + 1))" : entry.name
            }
        }
        return result
    }

    static func validateRange(offset: Int64, length: Int) throws {
        guard offset >= 0, length >= 0, length <= maximumReadLength,
              offset <= Int64.max - Int64(length) else { throw CoreKitError.invalidRange }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
