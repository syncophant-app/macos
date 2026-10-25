import Foundation
import Testing
@testable import CoreKit

struct SSHAuthenticationTests {
    @Test func authenticationRoundTrips() throws {
        let values: [SSHAuthentication] = [.password("local-fixture"), .privateKey(contents: "fixture", passphrase: "pass"), .agent(socketPath: "/tmp/agent")]
        for value in values {
            #expect(try JSONDecoder().decode(SSHAuthentication.self, from: JSONEncoder().encode(value)) == value)
        }
    }

    @Test func generatedEd25519KeyPairIsUsableByOpenSSH() throws {
        let pair = try SSHLocalTools.generateKeyPair()
        #expect(pair.privateKey.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(pair.publicKey.hasPrefix("ssh-ed25519 "))
        let directory = try SSHLocalTools.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key")
        try Data(pair.privateKey.utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let derived = try SSHLocalTools.run("/usr/bin/ssh-keygen", ["-y", "-f", key.path]).split(separator: " ").prefix(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(derived == pair.publicKey.split(separator: " ").prefix(2).joined(separator: " "))
    }

    @Test func configIncludesDefaultsIdentitiesAndNoLocalCommands() throws {
        let directory = try SSHLocalTools.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let include = directory.appendingPathComponent("included")
        let marker = directory.appendingPathComponent("MUST-NOT-EXIST")
        try "Host storage other\n  HostName storage.example.test\n  User storage-user\n  Port 2222\n  IdentityFile \"~/identity with spaces\"\n  IdentityFile %d/.ssh/%h-%r-%p-%%\n  IdentityAgent /tmp/configured-agent\n".write(to: include, atomically: true, encoding: .utf8)
        try "Include \(include.path)\nHost *\n  User ignored-default\n  ProxyCommand touch \(marker.path)\n  LocalCommand touch \(marker.path)\n  PermitLocalCommand yes\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(try SSHConfiguration.aliases(configurationURL: config) == ["storage", "other"])
        let result = try SSHConfiguration.resolve(alias: "storage", configurationURL: config)
        #expect(result.hostName == "storage.example.test")
        #expect(result.user == "storage-user" && result.port == 2222)
        #expect(result.identityFiles.contains(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("identity with spaces").path))
        #expect(result.identityAgent == "/tmp/configured-agent")
        #expect(result.identityFiles.contains(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/storage.example.test-storage-user-2222-%").path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func refusesMatchExecAndRecursiveIncludes() throws {
        let directory = try SSHLocalTools.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config"), marker = directory.appendingPathComponent("MUST-NOT-EXIST")
        try "Host sample\nMatch exec \"touch \(marker.path)\"\n User root\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(throws: CoreKitError.self) { try SSHConfiguration.resolve(alias: "sample", configurationURL: config) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try "Include \(config.path)\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(throws: CoreKitError.self) { try SSHConfiguration.aliases(configurationURL: config) }
        #expect(throws: CoreKitError.self) { try SSHConfiguration.resolve(alias: "-oProxyCommand=bad", configurationURL: config) }
        try "Include ${HOME}/.ssh/config\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(throws: CoreKitError.self) { try SSHConfiguration.aliases(configurationURL: config) }
    }
}
