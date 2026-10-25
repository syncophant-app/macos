import Foundation
import CryptoKit
import Darwin

/// Six process-shared slots leave headroom below a Storage Box's ten-session limit.
public final class SSHConnectionLease: @unchecked Sendable {
    private let descriptor: Int32

    public init(directory: URL, host: String) throws {
        guard directory.isFileURL, !host.isEmpty else { throw CoreKitError.invalidPath(directory.path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CoreKitError.connection("Cannot open the shared SSH session budget.") }
        defer { Darwin.close(parent) }
        var budgetHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if budgetHost.hasSuffix(".your-storagebox.de"), let login = budgetHost.split(separator: ".").first,
           login.range(of: "^u[0-9]+(-sub[0-9]+)?$", options: .regularExpression) != nil {
            budgetHost = String(login.split(separator: "-").first!) + ".your-storagebox.de"
        }
        let key = SHA256.hash(data: Data(budgetHost.utf8)).map { String(format: "%02x", $0) }.joined()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while true {
            try Task.checkCancellation()
            for slot in 0..<6 {
                let fd = openat(parent, key + "-\(slot)", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw CoreKitError.connection("Cannot reserve a shared SSH session slot.") }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { descriptor = fd; return }
                let code = errno
                Darwin.close(fd)
                guard code == EWOULDBLOCK || code == EAGAIN else { throw CoreKitError.connection("Cannot lock the shared SSH session budget.") }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CoreKitError.connection("All six SSH sessions are busy. Close an idle connection and retry.")
            }
            usleep(50_000)
        }
    }

    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
