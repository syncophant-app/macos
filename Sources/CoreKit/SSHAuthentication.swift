import Foundation
import Darwin

public enum SSHAuthentication: Codable, Equatable, Sendable {
    case password(String)
    case privateKey(contents: String, passphrase: String?)
    case agent(socketPath: String?)
}

public struct SSHKeyPair: Codable, Sendable {
    public let privateKey: String
    public let publicKey: String
}

/// Local OpenSSH tools never receive secrets in arguments or inherit standard input.
public enum SSHLocalTools {
    public static func generateKeyPair() throws -> SSHKeyPair {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("identity")
        _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "Syncophant Mac", "-f", key.path])
        return SSHKeyPair(privateKey: try String(contentsOf: key, encoding: .utf8),
                          publicKey: try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Syncophant-SSH-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CoreKitError.connection("Could not prepare the local SSH tool.")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning {
            do {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1_048_576 else { throw CoreKitError.timeout }
            } catch {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw error
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CoreKitError.connection("The local SSH tool failed. Check your SSH configuration or key file.") }
        let data = try Data(contentsOf: output)
        guard data.count < 1_048_576, let text = String(data: data, encoding: .utf8) else { throw CoreKitError.connection("The local SSH tool returned invalid output.") }
        return text
    }
}

public struct SSHConfiguration: Sendable, Equatable {
    public var hostName: String
    public var user: String
    public var port: Int
    public var identityFiles: [String]
    public var identityAgent: String?

    /// Resolve only passive connection settings. Match exec, proxies and local commands never reach ssh.
    public static func resolve(alias: String, configurationURL: URL) throws -> SSHConfiguration {
        guard validAlias(alias) else { throw CoreKitError.connection("Invalid SSH host alias.") }
        var remaining = 1_048_576, visited = Set<String>()
        let config = try sanitized(configurationURL, remaining: &remaining, visited: &visited, depth: 0)
        let directory = try SSHLocalTools.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(config.utf8).write(to: file)
        let output = try SSHLocalTools.run("/usr/bin/ssh", ["-G", "-F", file.path, "-o", "CanonicalizeHostname=no", "-o", "PermitLocalCommand=no", "--", alias])
        var result = SSHConfiguration(hostName: alias, user: NSUserName(), port: 22, identityFiles: [], identityAgent: nil)
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "hostname": result.hostName = value
            case "user": result.user = value
            case "port": result.port = Int(value) ?? 0
            case "identityfile": if value != "none" { result.identityFiles.append(value) }
            case "identityagent": if value != "none" { result.identityAgent = value }
            default: break
            }
        }
        guard !result.hostName.isEmpty, !result.user.isEmpty, (1...65535).contains(result.port) else { throw CoreKitError.connection("SSH configuration has an invalid endpoint.") }
        result.identityFiles = try result.identityFiles.map { try identityPath($0, alias: alias, configuration: result) }
        if let agent = result.identityAgent {
            if agent == "SSH_AUTH_SOCK" { result.identityAgent = ProcessInfo.processInfo.environment[agent] }
            else if agent.hasPrefix("$"), !agent.hasPrefix("${") { result.identityAgent = ProcessInfo.processInfo.environment[String(agent.dropFirst())] }
            else { result.identityAgent = try identityPath(agent, alias: alias, configuration: result) }
        }
        return result
    }

    public static func aliases(configurationURL: URL) throws -> [String] {
        var remaining = 1_048_576, visited = Set<String>()
        let config = try sanitized(configurationURL, remaining: &remaining, visited: &visited, depth: 0)
        var result: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            let words = try tokens(String(line))
            if words.first?.lowercased() == "host" {
                for alias in words.dropFirst() where validAlias(alias) && !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                    if !result.contains(alias) { result.append(alias) }
                }
            }
        }
        guard result.count <= 128 else { throw CoreKitError.connection("SSH config has more than 128 host aliases. Enter the connection manually.") }
        return result
    }

    private static func validAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.utf8.count < 256 && !alias.hasPrefix("-") && !alias.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" })
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func identityPath(_ path: String, alias: String, configuration: SSHConfiguration) throws -> String {
        let values: [Character: String] = ["%": "%", "d": FileManager.default.homeDirectoryForCurrentUser.path,
            "h": configuration.hostName, "n": alias, "p": String(configuration.port), "r": configuration.user,
            "u": NSUserName(), "i": String(getuid()), "l": ProcessInfo.processInfo.hostName,
            "L": String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "")]
        var expanded = "", token = false
        for character in path {
            if token {
                guard let value = values[character] else { throw CoreKitError.connection("SSH identity path uses an unsupported token. Choose the key or socket manually.") }
                expanded += value; token = false
            } else if character == "%" { token = true }
            else { expanded.append(character) }
        }
        guard !token else { throw CoreKitError.connection("SSH identity path has an unfinished token.") }
        let expression = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        for match in expression.matches(in: expanded, range: NSRange(expanded.startIndex..., in: expanded)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: expanded), let wholeRange = Range(match.range, in: expanded),
                  let value = ProcessInfo.processInfo.environment[String(expanded[keyRange])] else { throw CoreKitError.connection("SSH identity path needs an unavailable environment variable.") }
            expanded.replaceSubrange(wholeRange, with: value)
        }
        return expand(expanded)
    }

    private static func sanitized(_ url: URL, remaining: inout Int, visited: inout Set<String>, depth: Int) throws -> String {
        guard depth < 16, visited.count < 128 else { throw CoreKitError.connection("SSH config includes are too deeply nested.") }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard visited.insert(canonical).inserted else { throw CoreKitError.connection("SSH config contains a repeated include.") }
        defer { visited.remove(canonical) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: remaining + 1) ?? Data()
        remaining -= data.count
        guard remaining >= 0, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CoreKitError.connection("SSH config is too large or invalid.") }
        var output = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let words = try tokens(String(raw))
            guard let key = words.first?.lowercased() else { continue }
            if key == "match" { throw CoreKitError.connection("SSH config uses Match rules. Enter this connection manually; setup does not run Match commands.") }
            if key == "include" {
                for pattern in words.dropFirst() {
                    guard !pattern.contains("%"), !pattern.contains("$") else { throw CoreKitError.connection("SSH Include uses dynamic paths. Enter the connection manually.") }
                    let path = expand(pattern)
                    let absolute = path.hasPrefix("/") ? path : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").appendingPathComponent(path).path
                    var matches = glob_t()
                    let status = glob(absolute, 0, nil, &matches)
                    defer { globfree(&matches) }
                    guard status == 0 || status == GLOB_NOMATCH else { throw CoreKitError.connection("Could not expand SSH config Include.") }
                    guard matches.gl_pathc < 128 else { throw CoreKitError.connection("SSH config includes too many files.") }
                    for index in 0..<Int(matches.gl_pathc) {
                        if let path = matches.gl_pathv[index] { output += try sanitized(URL(fileURLWithPath: String(cString: path)), remaining: &remaining, visited: &visited, depth: depth + 1) }
                    }
                }
            } else if ["host", "hostname", "user", "port", "identityfile", "identityagent"].contains(key) {
                output += raw + "\n"
            }
        }
        return output
    }

    private static func tokens(_ line: String) throws -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false
        for character in line {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let current = quote { if character == current { quote = nil } else { word.append(character) }; continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "#" { break }
            if character == "=" && words.count == 1 && word.isEmpty { continue }
            if character.isWhitespace || (character == "=" && words.isEmpty) {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(character) }
        }
        guard quote == nil, !escaped else { throw CoreKitError.connection("SSH config has an unfinished quote or escape.") }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
