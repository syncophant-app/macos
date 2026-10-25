import Foundation
import Security
import Testing
@testable import CoreKit

private struct CloudState: Decodable {
    struct Request: Decodable { let method: String; let path: String; let authorized: Bool }
    let paths: [String: [String]]
    let refreshes: [String: Int]
    let history: [Request]
}

/// The loopback Dropbox/Graph/Box/Drive fixture in scripts/fixtures/cloud_http.py.
private final class CloudFixture: @unchecked Sendable {
    let process: Process, directory: URL, endpoint: URL
    init(process: Process, directory: URL, endpoint: URL) { self.process = process; self.directory = directory; self.endpoint = endpoint }
    deinit {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    static func start() async throws -> CloudFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let ready = directory.appendingPathComponent("ready")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", root.appendingPathComponent("scripts/fixtures/cloud_http.py").path, "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline, process.isRunning {
            if let text = try? String(contentsOf: ready, encoding: .utf8), let endpoint = URL(string: text) {
                return CloudFixture(process: process, directory: directory, endpoint: endpoint)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        throw CoreKitError.connection("Cloud fixture did not start.")
    }

    func control(_ values: [String: Any]) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("__fixture/control")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    func state() async throws -> CloudState {
        let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("__fixture/state"))
        return try JSONDecoder().decode(CloudState.self, from: data)
    }

    func session(_ service: OAuthService, token: OAuthToken? = nil, vault: OAuthVault = .memory) -> OAuthSession {
        OAuthSession(service: service, client: OAuthClient(clientID: "fixture-client", clientSecret: "fixture-secret"),
                     token: token ?? Self.initialToken(service), vault: vault,
                     tokenURL: endpoint.appendingPathComponent("token/" + service.rawValue))
    }

    func store(_ service: OAuthService, root: String = "/", session: OAuthSession? = nil) throws -> CloudStore {
        let e = endpoint
        let bases: [URL] = switch service {
        case .dropbox: [e.appendingPathComponent("dropbox/api/2"), e.appendingPathComponent("dropbox/content/2")]
        case .onedrive: [e.appendingPathComponent("graph/v1.0")]
        case .box: [e.appendingPathComponent("box/api/2.0"), e.appendingPathComponent("box/upload/api/2.0")]
        case .googledrive: [e.appendingPathComponent("google/drive/v3"), e.appendingPathComponent("google/upload/drive/v3")]
        }
        return try CloudStore(service: service, transport: CloudStore.transport(for: service, session: session ?? self.session(service), endpoints: bases),
                              rootPath: root)
    }

    static func initialToken(_ service: OAuthService) -> OAuthToken {
        OAuthToken(accessToken: "access-" + service.rawValue, refreshToken: "refresh-" + service.rawValue, expiresAt: Date().addingTimeInterval(3600))
    }
}

/// A Keychain stand-in shared by two sessions, like the app and the File Provider extension.
private final class SharedVault: @unchecked Sendable {
    private let lock = NSLock()
    private var token: OAuthToken
    private(set) var saves = 0
    init(_ token: OAuthToken) { self.token = token }
    func vault(lockFile: URL) -> OAuthVault {
        OAuthVault(load: { [self] in lock.withLock { token } },
                   save: { [self] new in lock.withLock { token = new; saves += 1 } }, lockFile: lockFile)
    }
    var current: OAuthToken { lock.withLock { token } }
}

private func random(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes)
}

struct CloudStoreTests {
    @Test(arguments: OAuthService.allCases)
    func compatibilityPassesAndLeavesNothingBehind(_ service: OAuthService) async throws {
        let fixture = try await CloudFixture.start()
        _ = try await StoreCompatibility.verify(fixture.store(service))
        try await fixture.store(service).createDirectory(path: "/Sync Root")
        _ = try await StoreCompatibility.verify(fixture.store(service, root: "/Sync Root"))
        #expect(try await fixture.store(service).list(path: "/Sync Root").isEmpty)
        let state = try await fixture.state()
        #expect(state.paths[service.rawValue] == ["/Sync Root"])
        #expect(!state.history.contains { $0.path.hasPrefix("/download/") && $0.authorized })
        #expect(try await fixture.store(service).accountName().hasPrefix("fixture@"))
    }

    @Test(arguments: OAuthService.allCases)
    func filesFoldersMovesAndNoClobber(_ service: OAuthService) async throws {
        let fixture = try await CloudFixture.start()
        let store = try fixture.store(service)
        try await store.createDirectory(path: "/Ünïcode dir")
        await #expect(throws: CoreKitError.self) { try await store.createDirectory(path: "/Ünïcode dir") }
        let data = Data("hello cloud world".utf8)
        try await store.write(path: "/Ünïcode dir/a b.txt", offset: 0, data: data)
        try await store.write(path: "/Ünïcode dir/other.txt", offset: 0, data: Data("other".utf8))
        #expect(try await store.list(path: "/Ünïcode dir").map(\.name) == ["a b.txt", "other.txt"])
        let entry = try await store.stat(path: "/Ünïcode dir/a b.txt")
        #expect(entry.size == Int64(data.count) && !entry.isDirectory && entry.remoteRevision != nil)
        #expect(try await store.read(path: "/Ünïcode dir/a b.txt", offset: 6, length: 5) == Data("cloud".utf8))
        await #expect(throws: CoreKitError.alreadyExists("/Ünïcode dir/other.txt")) {
            try await store.move(from: "/Ünïcode dir/a b.txt", to: "/Ünïcode dir/other.txt")
        }
        #expect(try await store.read(path: "/Ünïcode dir/other.txt", offset: 0, length: 100) == Data("other".utf8))
        try await store.move(from: "/Ünïcode dir/a b.txt", to: "/Ünïcode dir/renamed é.txt")
        try await store.move(from: "/Ünïcode dir", to: "/Moved dir")
        #expect(try await store.read(path: "/Moved dir/renamed é.txt", offset: 0, length: 100) == data)
        await #expect(throws: CoreKitError.self) { try await store.remove(path: "/Moved dir") }
        try await store.remove(path: "/Moved dir/renamed é.txt")
        try await store.remove(path: "/Moved dir/other.txt")
        try await store.remove(path: "/Moved dir")
        #expect(try await store.list(path: "/").isEmpty)
        await #expect(throws: CoreKitError.notFound("/Moved dir")) { try await store.stat(path: "/Moved dir") }
    }

    @Test(arguments: OAuthService.allCases)
    func expiredAccessTokenRefreshesOnce(_ service: OAuthService) async throws {
        let fixture = try await CloudFixture.start()
        let store = try fixture.store(service)
        try await fixture.control(["expire": service.rawValue])
        _ = try await store.list(path: "/")
        _ = try await store.list(path: "/")
        #expect(try await fixture.state().refreshes[service.rawValue] == 1)
    }

    @Test func rotatedRefreshTokenIsSavedAndSharedAcrossProcesses() async throws {
        let fixture = try await CloudFixture.start()
        let shared = SharedVault(CloudFixture.initialToken(.box))
        let lockFile = fixture.directory.appendingPathComponent("oauth.lock")
        let app = try fixture.store(.box, session: fixture.session(.box, vault: shared.vault(lockFile: lockFile)))
        try await fixture.control(["expire": "box"])
        _ = try await app.list(path: "/")
        #expect(shared.current.refreshToken == "refresh-box-1" && shared.saves == 1)
        // A second process still holding the old token must adopt the saved one: the old refresh token is spent.
        let extensionStore = try fixture.store(.box, session: fixture.session(.box, vault: shared.vault(lockFile: lockFile)))
        _ = try await extensionStore.list(path: "/")
        #expect(try await fixture.state().refreshes["box"] == 1)
        #expect(shared.saves == 1)
    }

    @Test(arguments: [OAuthService.dropbox, .box, .onedrive])
    func serversIgnoringPreconditionsAreRefused(_ service: OAuthService) async throws {
        let fixture = try await CloudFixture.start()
        try await fixture.control(["ignore": service.rawValue])
        await #expect(throws: CompatibilityProblem.self) { try await StoreCompatibility.verify(fixture.store(service)) }
    }

    @Test func googleDriveHidesAndRefusesDuplicateNames() async throws {
        let fixture = try await CloudFixture.start()
        for (name, data) in [("dup.txt", "one"), ("dup.txt", "two"), ("only.txt", "three")] {
            try await fixture.control(["seed": ["service": "googledrive", "parent": "/", "name": name, "data": data]])
        }
        let store = try fixture.store(.googledrive)
        #expect(try await store.list(path: "/").map(\.name) == ["only.txt"])
        await #expect(throws: CoreKitError.self) { try await store.stat(path: "/dup.txt") }
        await #expect(throws: CoreKitError.self) { try await store.write(path: "/dup.txt", offset: 0, data: Data("x".utf8)) }
    }

    static let largeUploads: [(OAuthService, Int)] = [(.onedrive, 5_242_897), (.box, 52_428_817)]

    @Test(arguments: largeUploads)
    func largeFilesUseUploadSessions(_ service: OAuthService, _ size: Int) async throws {
        let fixture = try await CloudFixture.start()
        let store = try fixture.store(service)
        let data = random(size)
        for round in 0..<2 {
            let content = round == 0 ? data : Data(data.reversed())
            try await store.prepareUpload(path: "/big.bin")
            var offset = 0
            while offset < content.count {
                let end = min(offset + 16 * 1024 * 1024, content.count)
                try await store.write(path: "/big.bin", offset: Int64(offset), data: content.subdata(in: offset..<end))
                offset = end
            }
            try await store.finishUpload(path: "/big.bin")
            #expect(try await store.stat(path: "/big.bin").size == Int64(size))
            #expect(try await store.read(path: "/big.bin", offset: Int64(size - 1000), length: 1000) == content.suffix(1000))
        }
        let state = try await fixture.state()
        #expect(state.history.contains { $0.path.contains("upload_sessions") || $0.path.hasPrefix("/graph-upload/") })
        #expect(!state.history.contains { $0.path.hasPrefix("/graph-upload/") && $0.authorized })
    }
}
