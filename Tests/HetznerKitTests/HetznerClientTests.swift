import Foundation
import XCTest
@testable import HetznerKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let json: String
        var headers: [String: String] = [:]
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var replies: [Reply] = []
        func reset(_ replies: [Reply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; requests = [] }
        func receive(_ request: URLRequest) -> Reply {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return replies.isEmpty ? Reply(status: 599, json: "{}") : replies.removeFirst()
        }
        func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class HetznerClientTests: XCTestCase {
    func testValidationReportsOnlyKnownFieldNamesWithoutEchoingSecrets() async throws {
        let client = client([.init(status: 422, json: #"{"error":{"code":"invalid_input","message":"fixture-secret-must-not-be-shown","details":{"fields":[{"name":"password","messages":["fixture-secret"]},{"name":"home_directory"},{"name":"fixture-secret"}]}}}"#)])
        do {
            _ = try await client.createSubaccount(boxID: 42, username: "Mac", password: "fixture-secret", homeDirectory: "Syncophant")
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("password"))
            XCTAssertTrue(error.localizedDescription.contains("home directory"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }
    }

    private func client(_ replies: [StubProtocol.Reply]) -> HetznerClient {
        StubProtocol.state.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return HetznerClient(token: "test-token", session: URLSession(configuration: config))
    }

    func testInitializationIsOfflineAndBoxesPaginateWithNestedStats() async throws {
        let client = client([
            .init(status: 200, json: #"{"storage_boxes":[{"id":1,"name":"Mac","server":"u1.your-storagebox.de","username":"u1","status":"active","storage_box_type":{"name":"bx11","size":1099511627776},"location":{"name":"fsn1","city":"Falkenstein"},"stats":{"size":42},"access_settings":{"ssh_enabled":true,"reachable_externally":false}}],"meta":{"pagination":{"next_page":2}}}"#),
            .init(status: 200, json: #"{"storage_boxes":[{"id":2,"name":"Pending","server":null,"username":null,"status":"initializing"}],"meta":{"pagination":{"next_page":null}}}"#)
        ])
        XCTAssertTrue(StubProtocol.state.captured().isEmpty)
        let boxes = try await client.storageBoxes()
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].diskQuota, 1_099_511_627_776)
        XCTAssertEqual(boxes[0].diskUsage, 42)
        XCTAssertEqual(boxes[0].typeName, "bx11")
        XCTAssertEqual(boxes[0].locationName, "Falkenstein")
        XCTAssertNil(boxes[1].typeName)
        XCTAssertEqual(boxes[0].accessSettings?.sshEnabled, true)
        XCTAssertTrue(boxes[0].isReady)
        XCTAssertEqual(boxes[1].server, "")
        XCTAssertFalse(boxes[1].isReady)
        let requests = StubProtocol.state.captured()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.hetzner.com/v1/storage_boxes?page=1&per_page=50")
        XCTAssertEqual(requests[1].url?.query, "page=2&per_page=50")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertNil(requests[0].httpBody)
    }

    func testSnapshotsPaginateAndDecodeBothDateForms() async throws {
        let client = client([
            .init(status: 200, json: #"{"snapshots":[{"id":1,"name":"first","created":"2025-02-12T11:35:19.123Z"}],"meta":{"pagination":{"next_page":2}}}"#),
            .init(status: 200, json: #"{"snapshots":[{"id":2,"name":"second","created":"2025-02-12T11:35:19+01:00"}]}"#)
        ])
        let snapshots = try await client.snapshots(boxID: 42)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertNotNil(snapshots[0].createdAt)
        XCTAssertNotNil(snapshots[1].createdAt)
        XCTAssertEqual(StubProtocol.state.captured()[0].url?.path, "/v1/storage_boxes/42/snapshots")
        let encoded = try JSONEncoder().encode(snapshots[0])
        XCTAssertEqual(try JSONDecoder().decode(StorageSnapshot.self, from: encoded).name, "first")
    }

    func testCreateSnapshotWaitsThenFetchesRealResource() async throws {
        let client = client([
            .init(status: 201, json: #"{"snapshot":{"id":9,"storage_box":42},"action":{"id":7,"status":"running","error":null}}"#),
            .init(status: 200, json: #"{"action":{"id":7,"status":"success","error":null}}"#),
            .init(status: 200, json: #"{"snapshot":{"id":9,"name":"2026-10-24","description":"Before change","created":"2026-10-24T12:00:00Z"}}"#)
        ])
        let snapshot = try await client.createSnapshot(boxID: 42, description: "Before change")
        XCTAssertEqual(snapshot.name, "2026-10-24")
        let requests = StubProtocol.state.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET"])
        XCTAssertEqual(requests[1].url?.path, "/v1/storage_boxes/42/actions/7")
        XCTAssertEqual(requests[2].url?.path, "/v1/storage_boxes/42/snapshots/9")
        XCTAssertEqual(try body(requests[0])["description"] as? String, "Before change")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSubaccountSendsDisplayNameAndExplicitAccessSettings() async throws {
        let client = client([
            .init(status: 201, json: #"{"subaccount":{"id":8,"storage_box":42},"action":{"id":7,"status":"success","error":null}}"#),
            .init(status: 200, json: #"{"subaccount":{"id":8,"username":"u42-sub1","server":"u42-sub1.your-storagebox.de","name":"MacBook","home_directory":"Syncophant","access_settings":{"ssh_enabled":true,"readonly":false}}}"#)
        ])
        let account = try await client.createSubaccount(boxID: 42, username: "MacBook", password: "test-password", homeDirectory: "Syncophant")
        XCTAssertEqual(account.username, "u42-sub1")
        XCTAssertEqual(account.accessSettings?.readonly, false)
        let requests = StubProtocol.state.captured()
        XCTAssertEqual(requests[0].url?.path, "/v1/storage_boxes/42/subaccounts")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let json = try body(requests[0])
        XCTAssertEqual(json["name"] as? String, "MacBook")
        XCTAssertNil(json["username"])
        XCTAssertEqual(json["password"] as? String, "test-password")
        XCTAssertEqual(json["home_directory"] as? String, "Syncophant")
        XCTAssertEqual(json["access_settings"] as? [String: Bool], ["ssh_enabled": true, "reachable_externally": true, "readonly": false])
        XCTAssertEqual(requests[1].url?.path, "/v1/storage_boxes/42/subaccounts/8")
    }

    func testReadOnlyShareUsesScopedHomeAndRevocationWaitsForAction() async throws {
        let client = client([
            .init(status: 201, json: #"{"subaccount":{"id":8},"action":{"id":7,"status":"success"}}"#),
            .init(status: 200, json: #"{"subaccount":{"id":8,"username":"u42-sub9","home_directory":"Documents/Shared","access_settings":{"readonly":true,"ssh_enabled":true}}}"#),
            .init(status: 201, json: #"{"action":{"id":10,"status":"running"}}"#),
            .init(status: 200, json: #"{"action":{"id":10,"status":"success"}}"#)
        ])
        let account = try await client.createSubaccount(boxID: 42, username: "Shared folder", password: "fixture-password!", homeDirectory: "Documents/Shared", readOnly: true)
        XCTAssertEqual(account.accessSettings?.readonly, true)
        try await client.deleteSubaccount(boxID: 42, subaccountID: account.id)
        let requests = StubProtocol.state.captured()
        XCTAssertEqual(try body(requests[0])["home_directory"] as? String, "Documents/Shared")
        XCTAssertEqual((try body(requests[0])["access_settings"] as? [String: Bool])?["readonly"], true)
        XCTAssertEqual(requests[2].httpMethod, "DELETE")
        XCTAssertEqual(requests[2].url?.path, "/v1/storage_boxes/42/subaccounts/8")
        XCTAssertEqual(requests[3].url?.path, "/v1/storage_boxes/42/actions/10")
    }

    func testShareSubaccountSendsProtocolFlags() async throws {
        let client = client([
            .init(status: 201, json: #"{"subaccount":{"id":8},"action":{"id":7,"status":"success"}}"#),
            .init(status: 200, json: #"{"subaccount":{"id":8,"username":"u42-sub9","home_directory":"Work","access_settings":{"readonly":false,"ssh_enabled":false,"samba_enabled":true,"webdav_enabled":true,"reachable_externally":true}}}"#)
        ])
        let account = try await client.createSubaccount(boxID: 42, username: "Share", password: "fixture-password!", homeDirectory: "Work",
                                                        readOnly: false, ssh: false, samba: true, webdav: true)
        XCTAssertEqual(account.accessSettings?.webdavEnabled, true)
        XCTAssertEqual(account.accessSettings?.sambaEnabled, true)
        let access = try body(StubProtocol.state.captured()[0])["access_settings"] as? [String: Bool]
        XCTAssertEqual(access, ["ssh_enabled": false, "reachable_externally": true, "samba_enabled": true, "webdav_enabled": true, "readonly": false])
    }

    func testInvalidHomeDirectoriesNeverReachTheAPI() async throws {
        let client = client([])
        for path in ["", "/", "/Syncophant", "../private", "Backups/../private", "Backups//Mac", "My Mac", "Backups/\nMac"] {
            do {
                _ = try await client.createSubaccount(boxID: 42, username: "Mac", password: "fixture-password!", homeDirectory: path)
                XCTFail("Accepted invalid home directory")
            } catch HetznerError.invalidInput { }
        }
        XCTAssertTrue(StubProtocol.state.captured().isEmpty)
    }

    func testShareMapsSFTPRootToMainAccountRelativeFolder() throws {
        XCTAssertEqual(try StorageBoxPath.shareHomeDirectory(accountHome: "", sftpRoot: "/home", folder: "/Photos"), "Photos")
        XCTAssertEqual(try StorageBoxPath.shareHomeDirectory(accountHome: "Syncophant", sftpRoot: "/home", folder: "/Photos"), "Syncophant/Photos")
        XCTAssertEqual(try StorageBoxPath.shareHomeDirectory(accountHome: ".", sftpRoot: "/home/Backups", folder: "/Mac"), "Backups/Mac")
        XCTAssertThrowsError(try StorageBoxPath.shareHomeDirectory(accountHome: "Syncophant", sftpRoot: "/", folder: "/Photos"))
        XCTAssertThrowsError(try StorageBoxPath.shareHomeDirectory(accountHome: "Syncophant", sftpRoot: "/home-other", folder: "/Photos"))
        XCTAssertThrowsError(try StorageBoxPath.shareHomeDirectory(accountHome: "Syncophant", sftpRoot: "/home", folder: "/../private"))
    }

    func testAccessUpdateUsesFlatPartialSettingsAndRejectsFailedAction() async throws {
        let client = client([.init(status: 201, json: #"{"action":{"id":7,"status":"error","error":{"code":"action_failed","message":"secret"}}}"#)])
        do { try await client.updateAccess(boxID: 42, ssh: true, externalReachability: false); XCTFail("Expected failure") }
        catch HetznerError.actionFailed(let id, let code) { XCTAssertEqual(id, 7); XCTAssertEqual(code, "action_failed") }
        let requests = StubProtocol.state.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/v1/storage_boxes/42/actions/update_access_settings")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(try body(requests[0]) as? [String: Bool], ["ssh_enabled": true, "reachable_externally": false])
    }

    func testShowSnapshotFolderSendsOnlyZFSFlagAndWaitsForAction() async throws {
        let client = client([
            .init(status: 201, json: #"{"action":{"id":11,"status":"running","error":null}}"#),
            .init(status: 200, json: #"{"action":{"id":11,"status":"success","error":null}}"#)
        ])
        try await client.updateAccessSettings(boxID: 42, StorageAccessSettings(zfsEnabled: true))
        let requests = StubProtocol.state.captured()
        XCTAssertEqual(requests.map(\.url?.path), ["/v1/storage_boxes/42/actions/update_access_settings", "/v1/storage_boxes/42/actions/11"])
        XCTAssertEqual(requests.map(\.url?.host), ["api.hetzner.com", "api.hetzner.com"])
        // Omitted flags are left unchanged by Hetzner, so SSH, Samba and WebDAV keep their current values.
        XCTAssertEqual(try body(requests[0]) as? [String: Bool], ["zfs_enabled": true])
        do { try await client.updateAccessSettings(boxID: 42, StorageAccessSettings(readonly: true)); XCTFail("Expected failure") }
        catch HetznerError.invalidInput {}
        XCTAssertEqual(StubProtocol.state.captured().count, 2)
    }

    func testSnapshotsDecodeAutomaticFlag() async throws {
        let client = client([.init(status: 200, json: #"{"snapshots":[{"id":1,"name":"a","is_automatic":true},{"id":2,"name":"b","description":"Before update","is_automatic":false},{"id":3,"name":"c"}]}"#)])
        let snapshots = try await client.snapshots(boxID: 42)
        XCTAssertEqual(snapshots.map(\.isAutomatic), [true, false, nil])
        XCTAssertEqual(try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(snapshots[1])).isAutomatic, false)
    }

    func testRateLimitIsExposedWithoutRetryOrServerMessage() async throws {
        let client = client([.init(status: 429, json: #"{"error":{"code":"rate_limit_exceeded","message":"test-token test-password"}}"#, headers: ["Retry-After": "30"])])
        do { _ = try await client.storageBoxes(); XCTFail("Expected failure") }
        catch HetznerError.http(let status, let code, let retry) {
            XCTAssertEqual(status, 429); XCTAssertEqual(code, "rate_limit_exceeded"); XCTAssertEqual(retry, 30)
            XCTAssertFalse(HetznerError.http(status: status, code: code, retryAfter: retry).localizedDescription.contains("test-token"))
        }
        XCTAssertEqual(StubProtocol.state.captured().count, 1)
    }

    func testNonJSONHTTPErrorAndMalformedSuccessAreNotSuccess() async throws {
        let client = client([.init(status: 503, json: "unavailable"), .init(status: 200, json: #"{"storage_boxes":[{"id":"broken"}]}"#)])
        do { _ = try await client.storageBoxes(); XCTFail("Expected failure") }
        catch HetznerError.http(let status, let code, _) { XCTAssertEqual(status, 503); XCTAssertNil(code) }
        do { _ = try await client.storageBoxes(); XCTFail("Expected decoding failure") }
        catch is DecodingError {}
    }

    func testRepeatedPageAndInvalidInputsStop() async throws {
        let client = client([.init(status: 200, json: #"{"storage_boxes":[],"meta":{"pagination":{"next_page":1}}}"#)])
        do { _ = try await client.storageBoxes(); XCTFail("Expected pagination failure") }
        catch HetznerError.invalidPagination {}
        do { _ = try await client.snapshots(boxID: -1); XCTFail("Expected validation failure") }
        catch HetznerError.invalidInput {}
        XCTAssertEqual(StubProtocol.state.captured().count, 1)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let direct = request.httpBody { data = direct }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        } else { throw HetznerError.invalidResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
