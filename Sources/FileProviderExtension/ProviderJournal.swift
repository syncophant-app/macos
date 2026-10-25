import Foundation

struct ProviderJournal: Codable {
    struct Item: Codable, Equatable {
        var path: String
        var version: String
        var parent: String { (path as NSString).deletingLastPathComponent }
    }
    struct Change: Codable {
        var revision: UInt64
        var updated: [String]
        var removedFrom: [String: String]
    }
    private var epoch = UUID().uuidString
    private var revision: UInt64 = 0
    private var items: [String: Item] = [:]
    private var log: [Change] = []

    var anchor: Data { Data("\(epoch):\(revision)".utf8) }

    mutating func update(_ next: [String: Item]) -> Bool {
        let updated = next.keys.filter { next[$0] != items[$0] }
        var removed: [String: String] = [:]
        for (id, item) in items where next[id]?.parent != item.parent { removed[id] = item.parent }
        guard !updated.isEmpty || !removed.isEmpty else { return false }
        revision += 1
        log.append(Change(revision: revision, updated: updated, removedFrom: removed))
        // shortcut: keep the latest 256 change batches; older anchors trigger a safe re-enumeration.
        if log.count > 256 { log.removeFirst(log.count - 256) }
        items = next
        return true
    }

    func changes(since anchor: Data, container: String?) throws -> (updated: Set<String>, deleted: Set<String>) {
        guard let text = String(data: anchor, encoding: .utf8) else { throw JournalError.expired }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == epoch, let previous = UInt64(parts[1]), previous <= revision,
              previous >= (log.first?.revision ?? 1) - 1 else { throw JournalError.expired }
        let batches = log.filter { $0.revision > previous }
        let changed = Set(batches.flatMap(\.updated))
        let updated = Set(changed.filter { id in
            guard let item = items[id] else { return false }
            return container == nil || item.parent == container
        })
        let deleted = Set(batches.flatMap { change in
            change.removedFrom.compactMap { id, parent -> String? in
                if let container { return parent == container && items[id]?.parent != container ? id : nil }
                return items[id] == nil ? id : nil
            }
        }).subtracting(updated)
        return (updated, deleted)
    }

    enum JournalError: Error { case expired }
}

enum DownloadRange {
    static func aligned(_ minimum: NSRange, alignment: Int, fileSize: Int) throws -> NSRange {
        guard alignment > 0, fileSize >= 0, minimum.location >= 0, minimum.location != NSNotFound,
              minimum.length >= 0, minimum.location <= Int.max - minimum.length else {
            throw RangeError.invalid
        }
        let start = min(minimum.location / alignment * alignment, fileSize)
        let needed = minimum.location + minimum.length - start
        let wanted = max(needed, 4 * 1_048_576)
        let available = fileSize - start
        if wanted >= available { return NSRange(location: start, length: available) }
        guard wanted <= Int.max - (alignment - 1) else { throw RangeError.invalid }
        return NSRange(location: start, length: min(available, (wanted + alignment - 1) / alignment * alignment))
    }
    enum RangeError: Error { case invalid }
}
