import Foundation
import CSQLite

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open metadata database."
            if let db { sqlite3_close(db) }
            throw CoreKitError.database(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
    }
    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> CoreKitError { .database(String(cString: sqlite3_errmsg(handle))) }
    func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw error() }
        }
        return statement
    }
    func run(_ sql: String, _ values: [String] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
}

public actor MetadataStore {
    private let db: SQLiteConnection
    private let hasFTS: Bool
    private static let columns = "id,path,name,is_directory,size,modified,pinned,content_hash,remote_revision,verified_version"

    public init(url: URL) throws {
        guard url.isFileURL else { throw CoreKitError.invalidPath(url.absoluteString) }
        let db = try SQLiteConnection(url: url)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        try db.execute("BEGIN IMMEDIATE")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS items (
              id TEXT PRIMARY KEY NOT NULL, path TEXT UNIQUE NOT NULL, parent TEXT NOT NULL,
              name TEXT NOT NULL, is_directory INTEGER NOT NULL, size INTEGER NOT NULL,
              modified REAL NOT NULL, pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent);
            """)
        let schema = try db.statement("PRAGMA table_info(items)")
        var hasContentHash = false, hasRemoteRevision = false, hasVerifiedVersion = false
        while sqlite3_step(schema) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(schema, 1)) == "content_hash" { hasContentHash = true }
            if String(cString: sqlite3_column_text(schema, 1)) == "remote_revision" { hasRemoteRevision = true }
            if String(cString: sqlite3_column_text(schema, 1)) == "verified_version" { hasVerifiedVersion = true }
        }
        sqlite3_finalize(schema)
        if !hasContentHash { try db.execute("ALTER TABLE items ADD COLUMN content_hash TEXT") }
        if !hasRemoteRevision { try db.execute("ALTER TABLE items ADD COLUMN remote_revision TEXT") }
        if !hasVerifiedVersion { try db.execute("ALTER TABLE items ADD COLUMN verified_version TEXT") }
        try db.execute("CREATE TABLE IF NOT EXISTS verified_uploads(path TEXT PRIMARY KEY NOT NULL,version TEXT NOT NULL,checksum TEXT NOT NULL)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS metadata_state (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL DEFAULT 0,
              mutation TEXT, lease_until REAL, source TEXT, destination TEXT
            );
            INSERT OR IGNORE INTO metadata_state(singleton) VALUES(1);
            CREATE TRIGGER IF NOT EXISTS metadata_revision_ai AFTER INSERT ON items BEGIN
              UPDATE metadata_state SET revision=revision+1 WHERE singleton=1;
            END;
            CREATE TRIGGER IF NOT EXISTS metadata_revision_au AFTER UPDATE ON items BEGIN
              UPDATE metadata_state SET revision=revision+1 WHERE singleton=1;
            END;
            CREATE TRIGGER IF NOT EXISTS metadata_revision_ad AFTER DELETE ON items BEGIN
              UPDATE metadata_state SET revision=revision+1 WHERE singleton=1;
            END;
            """)
        var fts = false
        do {
            try db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(name,path,content='items',content_rowid='rowid');
                CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                  INSERT INTO items_fts(rowid,name,path) VALUES(new.rowid,new.name,new.path);
                END;
                CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                  INSERT INTO items_fts(items_fts,rowid,name,path) VALUES('delete',old.rowid,old.name,old.path);
                END;
                CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
                  INSERT INTO items_fts(items_fts,rowid,name,path) VALUES('delete',old.rowid,old.name,old.path);
                  INSERT INTO items_fts(rowid,name,path) VALUES(new.rowid,new.name,new.path);
                END;
                """)
            fts = true
        } catch {
            // FTS5 is optional; a SQLite build without it still supports literal filename search.
            guard String(cString: sqlite3_errmsg(db.handle)).contains("no such module") else { throw error }
        }
        try db.execute("COMMIT")
        self.db = db; hasFTS = fts
    }

    public struct Snapshot: Sendable {
        public let revision: Int64
        public let items: [StoredItem]
    }

    /// One SQLite statement supplies both the generation and the entire tree, including an empty tree.
    public func snapshot() throws -> Snapshot {
        let statement = try db.statement("SELECT revision,\(Self.columns.split(separator: ",").map { "i." + $0 }.joined(separator: ",")) FROM metadata_state LEFT JOIN items i ON 1=1 WHERE singleton=1 ORDER BY i.path")
        defer { sqlite3_finalize(statement) }
        var revision: Int64 = 0, items: [StoredItem] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return Snapshot(revision: revision, items: items) }
            guard code == SQLITE_ROW else { throw db.error() }
            revision = sqlite3_column_int64(statement, 0)
            if sqlite3_column_type(statement, 1) != SQLITE_NULL { items.append(row(statement, offset: 1)) }
        }
    }

    /// Listings that overlap any metadata/namespace mutation are discarded across processes.
    public func refresh(store: any RemoteStore, path: String) async throws -> [StoredItem] {
        let parent = try PathRules.normalize(path)
        let before = try state()
        if before.mutation != nil {
            try checkLease(before)
            return try items(parentPath: parent)
        }
        let entries: [RemoteEntry]
        do {
            var listed = try await store.list(path: parent)
            // Finder's requested versions and change journal must use the same strong file identity.
            // Stores supply a cheap high-resolution revision where available, hashing only as a fallback.
            for index in listed.indices where !listed[index].isDirectory && listed[index].remoteRevision == nil {
                listed[index] = try await store.stat(path: listed[index].path)
            }
            entries = listed
        } catch {
            let after = try state()
            if after.mutation != nil || before.revision != after.revision {
                try checkLease(after)
                return try items(parentPath: parent)
            }
            throw error
        }
        return try transaction {
            let after = try state()
            guard after.mutation == nil, before.revision == after.revision else {
                try checkLease(after)
                return try items(parentPath: parent)
            }
            return try reconcileRows(entries, parentPath: parent)
        }
    }

    /// For already-owned local listings. Network callers must use refresh(store:path:).
    public func reconcile(_ entries: [RemoteEntry], parentPath: String) throws -> [StoredItem] {
        try transaction {
            try requireNoMutation()
            return try reconcileRows(entries, parentPath: parentPath)
        }
    }

    private func reconcileRows(_ entries: [RemoteEntry], parentPath: String) throws -> [StoredItem] {
        let parent = try PathRules.normalize(parentPath)
        var normalized: [RemoteEntry] = [], paths = Set<String>()
        for var entry in entries {
            entry.path = try PathRules.normalize(entry.path)
            guard entry.path != "/", PathRules.parent(of: entry.path) == parent,
                  entry.size >= 0, entry.modifiedAt.timeIntervalSince1970.isFinite,
                  paths.insert(entry.path).inserted else { throw CoreKitError.invalidPath(entry.path) }
            entry.name = PathRules.name(of: entry.path)
            if PathRules.isVisible(path: entry.path) { normalized.append(entry) }
        }
        let old = try rows("SELECT \(Self.columns) FROM items WHERE parent=?", [parent])
        let oldByPath = Dictionary(uniqueKeysWithValues: old.map { ($0.entry.path, $0) })
        let retained = Set(normalized.map(\.path))
        for item in old where !retained.contains(item.entry.path) {
            try deleteSubtree(item.entry.path)
        }
        for entry in normalized {
            if let previous = oldByPath[entry.path], previous.entry.version == entry.version,
               previous.entry.name == entry.name, previous.entry.isDirectory == entry.isDirectory { continue }
            let receipt = try db.statement("SELECT version FROM verified_uploads WHERE path=?", [entry.path])
            let verified: String
            if sqlite3_step(receipt) == SQLITE_ROW { verified = String(cString: sqlite3_column_text(receipt, 0)) }
            else { verified = "" }
            sqlite3_finalize(receipt)
            try db.run("""
                INSERT INTO items(id,path,parent,name,is_directory,size,modified,content_hash,remote_revision,verified_version) VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET name=excluded.name,is_directory=excluded.is_directory,
                size=excluded.size,modified=excluded.modified,content_hash=CASE
                      WHEN excluded.content_hash!='' THEN excluded.content_hash
                      WHEN items.size=excluded.size AND items.modified=excluded.modified
                           AND COALESCE(items.remote_revision,'')=COALESCE(excluded.remote_revision,'') THEN items.content_hash
                      ELSE NULL END,remote_revision=excluded.remote_revision,verified_version=excluded.verified_version
                """, [UUID().uuidString, entry.path, parent, entry.name, entry.isDirectory ? "1" : "0",
                      String(entry.size), String(entry.modifiedAt.timeIntervalSince1970), entry.contentHash ?? "", entry.remoteRevision ?? "", verified])
            if !entry.isDirectory {
                let prefix = entry.path + "/"
                try db.run("DELETE FROM items WHERE substr(path,1,length(?))=?", [prefix, prefix])
            }
        }
        return try items(parentPath: parent)
    }

    public func item(id: String) throws -> StoredItem? {
        try rows("SELECT \(Self.columns) FROM items WHERE id=?", [id]).first
    }

    public func items(parentPath: String) throws -> [StoredItem] {
        try rows("SELECT \(Self.columns) FROM items WHERE parent=? ORDER BY name COLLATE NOCASE,path", [PathRules.normalize(parentPath)])
    }

    public func search(_ query: String) throws -> [StoredItem] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        if hasFTS {
            let expression = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
            return try rows("SELECT \(Self.columns) FROM items WHERE rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?) ORDER BY name COLLATE NOCASE LIMIT 500", [expression])
        }
        return try rows("SELECT \(Self.columns) FROM items WHERE instr(lower(path),lower(?))>0 ORDER BY name COLLATE NOCASE LIMIT 500", [query])
    }

    /// Files changed on the storage since `date`, newest first.
    public func recent(since date: Date, limit: Int = 20) throws -> [StoredItem] {
        try rows("SELECT \(Self.columns) FROM items WHERE is_directory=0 AND modified>=CAST(? AS REAL) ORDER BY modified DESC LIMIT \(max(0, limit))",
                 [String(date.timeIntervalSince1970)])
    }

    public func move(id: String, to: String) throws {
        try transaction {
            try requireNoMutation()
            try moveRows(id: id, to: to)
        }
    }

    private func moveRows(id: String, to: String) throws {
        let target = try PathRules.normalize(to)
        guard target != "/", PathRules.isVisible(path: target) else { throw CoreKitError.invalidPath(target) }
        guard let item = try item(id: id) else { throw CoreKitError.notFound(id) }
        let source = item.entry.path
        if target == source { return }
        guard !target.hasPrefix(source + "/") else { throw CoreKitError.invalidPath(target) }
        let prefix = source + "/"
        let subtree = try rows("SELECT \(Self.columns) FROM items WHERE path=? OR substr(path,1,length(?))=?", [source, prefix, prefix])
        for child in subtree {
            let path = target + child.entry.path.dropFirst(source.count)
            let statement = try db.statement("SELECT 1 FROM items WHERE path=?", [path])
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else {
                if result == SQLITE_ROW { throw CoreKitError.alreadyExists(path) }
                throw db.error()
            }
        }
        for child in subtree {
            let path = target + child.entry.path.dropFirst(source.count)
            try db.run("UPDATE items SET path=?,parent=?,name=? WHERE id=?", [path, PathRules.parent(of: path), PathRules.name(of: path), child.id])
        }
    }

    /// Owns remote namespace changes and the matching identity update under a durable, bounded lease.
    public func move(store: any RemoteStore, id: String, to: String, trash: Bool = false) async throws {
        let target = try PathRules.normalize(to)
        guard target != "/", trash ? target.hasPrefix("/.syncophant-trash/") : PathRules.isVisible(path: target) else { throw CoreKitError.invalidPath(target) }
        let token = UUID().uuidString
        let source: String = try transaction {
            try requireNoMutation()
            guard let item = try item(id: id) else { throw CoreKitError.notFound(id) }
            let source = item.entry.path
            guard source != target, !target.hasPrefix(source + "/") else { throw CoreKitError.invalidPath(target) }
            if try rows("SELECT \(Self.columns) FROM items WHERE path=?", [target]).first != nil {
                throw CoreKitError.alreadyExists(target)
            }
            try db.run("UPDATE metadata_state SET revision=revision+1,mutation=?,lease_until=?,source=?,destination=? WHERE singleton=1",
                       [token, String(Date().addingTimeInterval(120).timeIntervalSince1970), source, target])
            return source
        }
        var remoteStarted = false, intermediateMoved = false, restored = false
        do {
            try Task.checkCancellation()
            remoteStarted = true
            if source.caseInsensitiveCompare(target) == .orderedSame {
                let parent = PathRules.parent(of: source)
                let intermediate = (parent == "/" ? "" : parent) + "/.synco-rename-" + token
                try await store.move(from: source, to: intermediate)
                intermediateMoved = true
                do { try await store.move(from: intermediate, to: target) }
                catch {
                    let original = error
                    // A failed rollback leaves the marker intact; never reconcile an uncertain namespace.
                    try await Task.detached { try await store.move(from: intermediate, to: source) }.value
                    restored = true
                    throw original
                }
            } else { try await store.move(from: source, to: target) }
        } catch {
            // A transport failure may have committed remotely; retain its intent for recovery.
            var unchanged = !remoteStarted || restored
            if !intermediateMoved {
                if case CoreKitError.alreadyExists = error { unchanged = true }
                if case CoreKitError.notFound = error { unchanged = true }
            }
            if unchanged { try clearMutation(token) }
            throw error
        }
        try transaction {
            guard try state().mutation == token else { throw CoreKitError.database("Remote move ownership was lost; cached identities were retained.") }
            if trash { try deleteSubtree(source) }
            else { try moveRows(id: id, to: target) }
            try clearMutationRows(token)
        }
    }

    /// Fences the short publication gap without assigning the original item's identity to a backup.
    /// Keep failed publications fenced unless their owner confirms the namespace is settled.
    public func withPublication<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let token = UUID().uuidString
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while true {
            try Task.checkCancellation()
            let acquired = try transaction {
                let current = try state()
                try checkLease(current)
                guard current.mutation == nil else { return false }
                try db.run("UPDATE metadata_state SET revision=revision+1,mutation=?,lease_until=?,source=NULL,destination=NULL WHERE singleton=1",
                           [token, String(Date().addingTimeInterval(120).timeIntervalSince1970)])
                return true
            }
            if acquired { break }
            guard ContinuousClock.now < deadline else { throw CoreKitError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
        do { try Task.checkCancellation() }
        catch {
            try clearMutation(token)
            throw error
        }
        let result: T
        do { result = try await body() }
        catch let failure as PublicationFailure {
            // Preserve the caller's cause even if SQLite cannot release the durable fence.
            if failure.namespaceSettled { try? clearMutation(token) }
            throw failure.cause
        }
        try clearMutation(token)
        return result
    }

    private struct State {
        let revision: Int64
        let mutation: String?
        let leaseUntil: Double
    }

    public struct InterruptedMutation: Sendable, Equatable {
        public let token: String
        public let leaseUntil: Date
        public let source: String?
        public let destination: String?
    }

    public enum RecoveryOutcome: Sendable { case keepOriginalPaths, acceptMovedPaths }

    public func interruptedMutation() throws -> InterruptedMutation? {
        let statement = try db.statement("SELECT mutation,lease_until,source,destination FROM metadata_state WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw db.error() }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, column))
        }
        return InterruptedMutation(token: optionalText(0)!, leaseUntil: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                   source: optionalText(2), destination: optionalText(3))
    }

    /// Only an explicit repair after stopping every writer may acknowledge an uncertain remote result.
    public func recoverMutation(token: String, outcome: RecoveryOutcome) throws {
        try transaction {
            guard let mutation = try interruptedMutation(), mutation.token == token,
                  mutation.leaseUntil <= Date() else { throw CoreKitError.database("The operation is still active or has changed. Recheck before repairing it.") }
            if case .acceptMovedPaths = outcome {
                guard let source = mutation.source, let destination = mutation.destination,
                      let item = try rows("SELECT \(Self.columns) FROM items WHERE path=?", [source]).first else {
                    throw CoreKitError.database("This operation has no recorded rename to accept.")
                }
                if destination.hasPrefix("/.syncophant-trash/") { try deleteSubtree(source) }
                else { try moveRows(id: item.id, to: destination) }
            }
            try clearMutationRows(token)
        }
    }

    private func state() throws -> State {
        let statement = try db.statement("SELECT revision,mutation,lease_until FROM metadata_state WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw db.error() }
        let mutation = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 1))
        return State(revision: sqlite3_column_int64(statement, 0), mutation: mutation, leaseUntil: sqlite3_column_double(statement, 2))
    }

    private func checkLease(_ state: State) throws {
        if state.mutation != nil, state.leaseUntil <= Date().timeIntervalSince1970 {
            // SFTP cannot fence a late rename: expiry is an error, never permission to delete UUIDs.
            throw CoreKitError.database("An interrupted remote mutation needs recovery. Cached identities were retained; automatic refresh is paused.")
        }
    }

    private func requireNoMutation() throws {
        let state = try state()
        try checkLease(state)
        guard state.mutation == nil else { throw CoreKitError.database("A remote mutation is in progress. Retry after it finishes.") }
    }

    private func clearMutation(_ token: String) throws {
        try transaction {
            guard try state().mutation == token else { throw CoreKitError.database("Remote mutation ownership was lost; cached identities were retained.") }
            try clearMutationRows(token)
        }
    }

    private func clearMutationRows(_ token: String) throws {
        try db.run("UPDATE metadata_state SET revision=revision+1,mutation=NULL,lease_until=NULL,source=NULL,destination=NULL WHERE singleton=1 AND mutation=?", [token])
    }

    public func setPinned(id: String, _ pinned: Bool) throws {
        try db.run("UPDATE items SET pinned=? WHERE id=?", [pinned ? "1" : "0", id])
    }

    public func recordVerification(_ receipt: UploadReceipt) throws {
        guard receipt.verified, receipt.checksum.count == 64, !receipt.remoteVersion.isEmpty,
              try PathRules.normalize(receipt.remotePath) == receipt.remotePath else { throw CoreKitError.invalidPath(receipt.remotePath) }
        try transaction {
            try db.run("INSERT INTO verified_uploads(path,version,checksum) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET version=excluded.version,checksum=excluded.checksum",
                       [receipt.remotePath, receipt.remoteVersion, receipt.checksum])
            try db.run("UPDATE items SET verified_version=? WHERE path=?", [receipt.remoteVersion, receipt.remotePath])
        }
    }

    private func deleteSubtree(_ path: String) throws {
        let prefix = path + "/"
        try db.run("DELETE FROM items WHERE path=? OR substr(path,1,length(?))=?", [path, prefix, prefix])
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.execute("BEGIN IMMEDIATE")
        do { let result = try body(); try db.execute("COMMIT"); return result }
        catch { try? db.execute("ROLLBACK"); throw error }
    }

    private func rows(_ sql: String, _ values: [String] = []) throws -> [StoredItem] {
        let statement = try db.statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [StoredItem] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw db.error() }
            result.append(row(statement))
        }
    }


    private func row(_ statement: OpaquePointer, offset: Int32 = 0) -> StoredItem {
        func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(statement, offset + column)) }
        let hash = sqlite3_column_type(statement, offset + 7) == SQLITE_NULL ? "" : text(7)
        let revision = sqlite3_column_type(statement, offset + 8) == SQLITE_NULL ? "" : text(8)
        let verified = sqlite3_column_type(statement, offset + 9) == SQLITE_NULL ? "" : text(9)
        let entry = RemoteEntry(name: text(2), path: text(1), isDirectory: sqlite3_column_int(statement, offset + 3) != 0,
                                size: sqlite3_column_int64(statement, offset + 4), modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 5)),
                                contentHash: hash.isEmpty ? nil : hash, remoteRevision: revision.isEmpty ? nil : revision)
        return StoredItem(id: text(0), entry: entry, isPinned: sqlite3_column_int(statement, offset + 6) != 0, verifiedVersion: verified.isEmpty ? nil : verified)
    }
}
