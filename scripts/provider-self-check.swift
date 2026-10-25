import Foundation

@main
struct ProviderSelfCheck {
    static func main() throws {
        let range = try DownloadRange.aligned(NSRange(location: 5_000_123, length: 500), alignment: 4096, fileSize: 20_000_000)
        assert(range.location % 4096 == 0 && range.length % 4096 == 0)
        assert(range.location <= 5_000_123 && NSMaxRange(range) >= 5_000_623)
        let tail = try DownloadRange.aligned(NSRange(location: 999, length: 1), alignment: 512, fileSize: 1000)
        assert(NSMaxRange(tail) == 1000)
        do {
            _ = try DownloadRange.aligned(NSRange(location: Int.max - 1, length: 5), alignment: 4096, fileSize: Int.max)
            assertionFailure("Overflowing ranges must be rejected")
        } catch DownloadRange.RangeError.invalid {}

        var journal = ProviderJournal()
        let first = journal.anchor
        assert(journal.update(["file": .init(path: "/a.txt", version: "v1")]))
        let created = try journal.changes(since: first, container: "/")
        assert(created.updated == ["file"] && created.deleted.isEmpty)
        let beforeMove = journal.anchor
        assert(journal.update(["file": .init(path: "/folder/a.txt", version: "v1")]))
        let oldParent = try journal.changes(since: beforeMove, container: "/")
        let newParent = try journal.changes(since: beforeMove, container: "/folder")
        assert(oldParent.deleted == ["file"] && newParent.updated == ["file"])
        let working = try journal.changes(since: beforeMove, container: nil)
        assert(working.deleted.isEmpty && working.updated == ["file"])
        let saved = try JSONEncoder().encode(journal)
        var restored = try JSONDecoder().decode(ProviderJournal.self, from: saved)
        assert(restored.anchor == journal.anchor)
        let beforeDelete = restored.anchor
        assert(restored.update([:]))
        let removed = try restored.changes(since: beforeDelete, container: nil)
        assert(removed.deleted == ["file"])
        do { _ = try ProviderJournal().changes(since: first, container: nil); assertionFailure("Foreign anchor accepted") }
        catch ProviderJournal.JournalError.expired {}
        print("Provider self-check passed: aligned ranges, overflow, create/move/delete changes, durable anchors.")
    }
}
