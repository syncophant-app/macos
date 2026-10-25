import Foundation
import CoreKit

// Compile with CachePolicy.swift, SharedConfig.swift and CacheBudget.swift, linking CoreKit.
// Pure checks only: no domain registration, cache eviction, shared-config writes, or remote I/O.
@main
struct CacheSelfCheck {
    static func main() throws {
        let policy = try CachePolicy()
        assert(policy.sizeGB == 5 && policy.budgetBytes == 5_000_000_000)
        let minimum = try CachePolicy(sizeGB: 1), maximum = try CachePolicy(sizeGB: 500)
        assert(minimum.budgetBytes == 1_000_000_000 && maximum.budgetBytes == 500_000_000_000)
        for size in [0, -1, 501] {
            do { _ = try CachePolicy(sizeGB: size); assertionFailure("Invalid budget accepted") }
            catch {}
            let data = Data("{\"sizeGB\":\(size)}".utf8)
            do { _ = try JSONDecoder().decode(CachePolicy.self, from: data); assertionFailure("Invalid persisted budget accepted") }
            catch {}
        }
        let decoded = try JSONDecoder().decode(CachePolicy.self, from: JSONEncoder().encode(policy))
        assert(decoded.sizeGB == policy.sizeGB)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func candidate(_ id: String, _ bytes: Int64, _ days: Double, pinned: Bool = false,
                       safe: Bool = true) -> CacheBudget.Candidate {
            .init(id: id, bytes: bytes, lastUsed: now.addingTimeInterval(-days * 86400), pinned: pinned, safe: safe)
        }
        let recent = candidate("recent", 40, 1)
        let older = candidate("older", 30, 2)
        let aged = candidate("aged", 20, 31)
        let pinned = candidate("pinned", 90, 100, pinned: true)
        let dirty = candidate("dirty", 80, 100, safe: false)
        func selected(_ items: [CacheBudget.Candidate], _ total: Int64, _ budget: Int64) -> [String] {
            CacheBudget.selection(items, total: total, budget: budget, now: now).map(\.id)
        }
        assert(selected([recent, older], 70, 45) == ["older"])
        assert(selected([recent, aged], 60, 100) == ["aged"])
        assert(selected([candidate("boundary", 20, 30)], 20, 100).isEmpty)
        assert(selected([pinned, dirty, recent, older], 240, 100) == ["older", "recent"])
        assert(selected([pinned, dirty], 170, 100).isEmpty)
        assert(selected([.init(id: "unknown-age", bytes: 50, lastUsed: nil, pinned: false, safe: true)], 50, 1).isEmpty)
        assert(selected([candidate("zero", 0, 100)], 0, 1).isEmpty)
        assert(selected([candidate("b", 10, 1), candidate("a", 10, 1)], 20, 10) == ["a"])

        func stored(_ path: String, pinned: Bool = false, directory: Bool = false) -> StoredItem {
            .init(id: path, entry: .init(name: PathRules.name(of: path), path: path,
                                        isDirectory: directory, size: 0, modifiedAt: now), isPinned: pinned)
        }
        let folder = stored("/pin", pinned: true, directory: true)
        let nested = stored("/pin/sub", directory: true)
        let child = stored("/pin/sub/file")
        assert(CacheBudget.protection(child, in: [folder.entry.path: folder, nested.entry.path: nested]) == true)
        assert(CacheBudget.protection(stored("/pinned-file", pinned: true), in: [:]) == true)
        assert(CacheBudget.protection(stored("/plain"), in: [:]) == false)
        assert(CacheBudget.protection(child, in: [:]) == nil)
        assert(CacheBudget.protection(stored("/pin-sibling"), in: [folder.entry.path: folder]) == false)
        let status = CacheStatus(budgetBytes: 100, cachedBytes: 170, pinnedBytes: 90, blockedBytes: 80)
        assert(!status.enforced && !status.measurementComplete)
        let saved = try JSONDecoder().decode(CacheStatus.self, from: JSONEncoder().encode(status))
        assert(saved.cachedBytes == 170 && saved.pinnedBytes == 90 && saved.blockedBytes == 80)
        print("Cache self-check passed: validated budgets, round trips, oldest-first/age limits, pins, dirty/unknown retention, blocked over-budget status.")
    }
}
