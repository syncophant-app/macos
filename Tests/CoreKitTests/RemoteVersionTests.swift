import Foundation
import Darwin
import Testing
@testable import CoreKit

struct RemoteVersionTests {
    @Test func revisionIdentityIsSeparateFromChecksumAndLegacyJSON() throws {
        var entry = RemoteEntry(name: "file", path: "/file", isDirectory: false, size: 5,
                                modifiedAt: Date(timeIntervalSince1970: 1), remoteRevision: "inode:ctime")
        let version = entry.version
        entry.contentHash = String(repeating: "a", count: 64)
        #expect(entry.version == version)
        let legacy = Data(#"{"id":"/file","name":"file","path":"/file","isDirectory":false,"size":5,"modifiedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteEntry.self, from: legacy)
        #expect(decoded.remoteRevision == nil && decoded.contentHash == nil)
        #expect(try JSONDecoder().decode(RemoteEntry.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test func sameSizeSameMtimeRewriteAndReplacementChangeRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("first".utf8).write(to: file)
        let store = try LocalRemoteStore(root: root)
        let original = try await store.stat(path: "/file")
        var info = Darwin.stat()
        #expect(file.path.withCString { lstat($0, &info) } == 0)
        let times = [info.st_atimespec, info.st_mtimespec]
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("other".utf8))
        #expect(futimens(handle.fileDescriptor, times) == 0)
        try handle.close()
        let rewritten = try await store.stat(path: "/file")
        #expect(original.modifiedAt == rewritten.modifiedAt && original.size == rewritten.size)
        #expect(original.version != rewritten.version)
        #expect(original.contentHash == nil && rewritten.contentHash == nil)
        let replacement = root.appendingPathComponent("replacement")
        try Data("third".utf8).write(to: replacement)
        let replacementFD = Darwin.open(replacement.path, O_WRONLY)
        #expect(replacementFD >= 0)
        #expect(futimens(replacementFD, times) == 0)
        Darwin.close(replacementFD)
        #expect(rename(replacement.path, file.path) == 0)
        let replaced = try await store.stat(path: "/file")
        #expect(replaced.modifiedAt == original.modifiedAt && replaced.size == original.size)
        #expect(replaced.version != rewritten.version && replaced.version != original.version)
        #expect(try await store.read(path: "/file", offset: 0, length: 5) == Data("third".utf8))
        #expect(try await store.list(path: "/").first?.version == replaced.version)
    }

    @Test func statFormatsRequireCompleteHighResolutionRegularFileEvidence() throws {
        let gnu = "7|42|5|1700000000|2023-11-14 22:13:20.000000001 +0000|2023-11-14 22:13:21.987654321 +0000|81a4"
        let bsd = "7|42|5|1700000000|1700000000.000000001|1700000001.987654321|100644"
        for (format, row) in [(SFTPStatFormat.gnu, gnu), (.bsd, bsd)] {
            let revision = try #require(format.parse(Data(row.utf8)))
            #expect(revision.highResolution && revision.size == 5 && revision.modifiedSeconds == 1700000000)
            #expect(format.parse(Data((row + "\n" + row).utf8)) == nil)
            #expect(format.parse(Data(row.replacingOccurrences(of: "|42|", with: "|0|").utf8)) == nil)
            #expect(format.parse(Data(row.replacingOccurrences(of: "987654321", with: "000000000").utf8))?.highResolution == false)
            #expect(format.parse(Data(row.replacingOccurrences(of: "987654321", with: "987").utf8)) == nil)
        }
        #expect(SFTPStatFormat.gnu.parse(Data(gnu.replacingOccurrences(of: "81a4", with: "a1ff").utf8)) == nil)
        #expect(SFTPStatFormat.bsd.parse(Data(bsd.replacingOccurrences(of: "100644", with: "120777").utf8)) == nil)
        #expect(SFTPStatFormat.gnu.parse(Data("stat: not supported".utf8)) == nil)
    }

    @Test func warmWindowHonorsRevisionBoundsAndEOF() {
        var cache = SFTPReadCache()
        cache.insert(path: "/movie", version: "one", offset: 10, data: Data("abcdef".utf8))
        #expect(cache.read(path: "/movie", version: "one", offset: 12, length: 3, fileSize: 100) == Data("cde".utf8))
        #expect(cache.read(path: "/movie", version: "one", offset: 14, length: 4, fileSize: 16) == Data("ef".utf8))
        #expect(cache.read(path: "/movie", version: "one", offset: 14, length: 4, fileSize: 100) == nil)
        #expect(cache.read(path: "/movie", version: "two", offset: 10, length: 1, fileSize: 100) == nil)
        #expect(cache.read(path: "/other", version: "one", offset: 10, length: 1, fileSize: 100) == nil)
        #expect(cache.read(path: "/movie", version: "one", offset: 9, length: 1, fileSize: 100) == nil)
        cache.validate(path: "/movie", version: "two")
        #expect(cache.data.isEmpty && cache.path == nil)
        cache.insert(path: "/movie", version: "two", offset: 0, data: Data(count: SFTPReadCache.capacity + 1))
        #expect(cache.data.isEmpty)
    }
}
