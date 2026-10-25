import Foundation

/// The API uses paths relative to the main account; port-23 SFTP exposes each account at /home.
public enum StorageBoxPath {
    public static let sftpRoot = "/home"

    public static func validateHomeDirectory(_ path: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./_-")
        guard !path.isEmpty, path.utf8.count <= 999, !path.hasPrefix("/"),
              path.unicodeScalars.allSatisfy(allowed.contains),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
            throw HetznerError.invalidInput("home directory: use a relative folder with letters, numbers, dots, underscores or hyphens")
        }
    }

    public static func shareHomeDirectory(accountHome: String, sftpRoot: String, folder: String) throws -> String {
        guard sftpRoot == self.sftpRoot || sftpRoot.hasPrefix(self.sftpRoot + "/"), folder.hasPrefix("/") else {
            throw HetznerError.invalidInput("SFTP root: reconnect this Storage Box with /home as its root before sharing")
        }
        let root = String(sftpRoot.dropFirst(self.sftpRoot.count))
        let parts = [accountHome, root, folder].flatMap { $0.split(separator: "/") }
        guard !parts.contains("..") else { throw HetznerError.invalidInput("home directory") }
        let home = parts.filter { $0 != "." }.joined(separator: "/")
        try validateHomeDirectory(home)
        return home
    }
}
