import CryptoKit
import Foundation
import SQLite3

/// The extension's local mirror of a share's namespace.
///
/// File Provider wants identifiers that stay the same for an item's whole life, but SMB only
/// offers paths (which change on rename) and file ids (which change when another client
/// safe-saves a document). The index hands out its own identifiers and maps them to
/// (parent, name, file id), matching server listings back to records by file id first and by
/// name second. Every change is appended to a log whose sequence numbers are the sync anchors.
public final class CloudIndex: @unchecked Sendable {
    public static let rootID = "NSFileProviderRootContainerItemIdentifier"

    public struct Record: Sendable, Hashable {
        public var id: String
        public var parentID: String
        public var name: String
        public var fileID: UInt64
        public var isDirectory: Bool
        public var size: Int64
        public var creationTime: UInt64
        public var modificationTime: UInt64
        public var changeTime: UInt64
        public var attributes: UInt32

        public var isRoot: Bool { id == CloudIndex.rootID }
        public var creationDate: Date? { FileTime.date(creationTime) }
        public var modificationDate: Date? { FileTime.date(modificationTime) }
        public var isHidden: Bool { attributes & SMBFileAttributes.hidden.rawValue != 0 }
        public var isReadOnly: Bool { attributes & SMBFileAttributes.readOnly.rawValue != 0 }

        /// Changes whenever the bytes (may) have changed.
        public var contentVersion: Data {
            var w = Data(count: 16)
            w.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt64(bitPattern: size).littleEndian, toByteOffset: 0, as: UInt64.self)
                raw.storeBytes(of: modificationTime.littleEndian, toByteOffset: 8, as: UInt64.self)
            }
            return w
        }

        /// Changes whenever anything File Provider shows about the item changes.
        public var metadataVersion: Data {
            var hasher = SHA256()
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(parentID.utf8))
            for value in [creationTime, modificationTime, changeTime, UInt64(attributes)] {
                withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
            }
            return Data(hasher.finalize().prefix(16))
        }

        func sameContents(as other: Record) -> Bool {
            parentID == other.parentID && name == other.name && fileID == other.fileID && isDirectory == other.isDirectory
                && size == other.size && creationTime == other.creationTime && modificationTime == other.modificationTime
                && changeTime == other.changeTime && attributes == other.attributes
        }
    }

    public enum IndexError: Error, CustomStringConvertible {
        case database(String)
        case anchorExpired

        public var description: String {
            switch self {
            case .database(let message): "Index database error: \(message)"
            case .anchorExpired: "The sync anchor is no longer available."
            }
        }
    }

    public struct Changes: Sendable {
        public var updated: [Record]
        public var deleted: [String]
        public var anchor: Int64
        public var moreComing: Bool
    }

    private let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    /// Identifies this database; anchors from another incarnation are rejected.
    public let epoch: String

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY NOT NULL,
                parent TEXT NOT NULL,
                name TEXT NOT NULL,
                folded TEXT NOT NULL,
                fileID INTEGER NOT NULL,
                isDir INTEGER NOT NULL,
                size INTEGER NOT NULL,
                btime INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                ctime INTEGER NOT NULL,
                attrs INTEGER NOT NULL,
                scannedAt REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent, folded);
            CREATE INDEX IF NOT EXISTS items_fileID ON items(fileID) WHERE fileID != 0;
            CREATE TABLE IF NOT EXISTS changes (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL,
                deleted INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS changes_id ON changes(id, seq);
            CREATE TABLE IF NOT EXISTS dirty (path TEXT PRIMARY KEY NOT NULL, recursive INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            """)
        if let existing = try database.scalarText("SELECT value FROM meta WHERE key = 'epoch'") {
            epoch = existing
        } else {
            let fresh = UUID().uuidString
            try database.prepare("INSERT INTO meta(key, value) VALUES('epoch', ?)").run([.text(fresh)])
            epoch = fresh
        }
        db = database
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Lookups

    private static let columns = "id, parent, name, fileID, isDir, size, btime, mtime, ctime, attrs"

    private static func record(_ s: SQLiteStatement) -> Record {
        Record(id: s.text(0), parentID: s.text(1), name: s.text(2), fileID: UInt64(bitPattern: s.int(3)),
               isDirectory: s.int(4) != 0, size: s.int(5), creationTime: UInt64(bitPattern: s.int(6)),
               modificationTime: UInt64(bitPattern: s.int(7)), changeTime: UInt64(bitPattern: s.int(8)),
               attributes: UInt32(truncatingIfNeeded: s.int(9)))
    }

    public func record(id: String) throws -> Record? {
        try locked {
            let s = try db.cached("SELECT \(Self.columns) FROM items WHERE id = ?").bind([.text(id)])
            return try s.step() ? Self.record(s) : nil
        }
    }

    public func record(fileID: UInt64) throws -> Record? {
        guard fileID != 0 else { return nil }
        return try locked {
            let s = try db.cached("SELECT \(Self.columns) FROM items WHERE fileID = ? LIMIT 1")
                .bind([.int(Int64(bitPattern: fileID))])
            return try s.step() ? Self.record(s) : nil
        }
    }

    public func children(of parentID: String) throws -> [Record] {
        try locked {
            let s = try db.cached("SELECT \(Self.columns) FROM items WHERE parent = ? AND id != parent").bind([.text(parentID)])
            var out: [Record] = []
            while try s.step() { out.append(Self.record(s)) }
            return out
        }
    }

    public func child(of parentID: String, named name: String) throws -> Record? {
        try locked {
            let s = try db.cached("SELECT \(Self.columns) FROM items WHERE parent = ? AND folded = ? AND id != parent LIMIT 1")
                .bind([.text(parentID), .text(Self.fold(name))])
            return try s.step() ? Self.record(s) : nil
        }
    }

    /// The share path of an item ("" for the root), or nil when it isn't indexed.
    public func path(of id: String) throws -> String? {
        if id == Self.rootID { return "" }
        return try locked {
            var names: [String] = []
            var current = id
            for _ in 0..<512 {
                guard let entry = try self.record(id: current) else { return nil }
                if entry.isRoot { return names.reversed().joined(separator: "/") }
                names.append(entry.name)
                current = entry.parentID
            }
            return nil
        }
    }

    /// Resolves a share path to an item id by walking the names from the root.
    public func id(forPath path: String) throws -> String? {
        var current = Self.rootID
        for component in SMBPath.normalize(path).split(separator: "/") {
            guard let next = try child(of: current, named: String(component)) else { return nil }
            current = next.id
        }
        return current
    }

    public var count: Int {
        (try? locked { try db.scalarInt("SELECT COUNT(*) FROM items") }) ?? 0
    }

    static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Mutations

    /// Inserts or updates the root's attributes.
    @discardableResult
    public func updateRoot(_ item: SMBItem) throws -> Record {
        try locked {
            var root = Self.makeRecord(item, id: Self.rootID, parentID: Self.rootID)
            root.name = ""
            try write(root, logIfChanged: true)
            return root
        }
    }

    /// Records a server item under `parentID`, reusing `id` (or the record with the same file
    /// id, or the same name) when there is one, otherwise minting a new identifier.
    @discardableResult
    public func upsert(_ item: SMBItem, parentID: String, id: String? = nil) throws -> Record {
        try locked {
            var existing: Record?
            if let id { existing = try self.record(id: id) }
            if existing == nil { existing = try self.record(fileID: item.fileID) }
            if existing == nil { existing = try child(of: parentID, named: item.name) }
            let fresh = Self.makeRecord(item, id: existing?.id ?? id ?? Self.newID(), parentID: parentID)
            try write(fresh, logIfChanged: true)
            return fresh
        }
    }

    /// Brings a directory's children in line with a fresh server listing and returns them.
    @discardableResult
    public func reconcile(directory parentID: String, with items: [SMBItem]) throws -> [Record] {
        try locked {
            try db.transaction {
                let existing = try children(of: parentID)
                var byName: [String: Record] = [:]
                for record in existing { byName[Self.fold(record.name)] = record }
                var matched = Set<String>()
                var results: [Record] = []
                results.reserveCapacity(items.count)

                for item in items where !Self.isIgnored(item.name) {
                    var id: String?
                    if let byFile = try self.record(fileID: item.fileID), !matched.contains(byFile.id), !byFile.isRoot {
                        id = byFile.id
                    } else if let byNameRecord = byName[Self.fold(item.name)], !matched.contains(byNameRecord.id) {
                        id = byNameRecord.id
                    }
                    let fresh = Self.makeRecord(item, id: id ?? Self.newID(), parentID: parentID)
                    matched.insert(fresh.id)
                    try write(fresh, logIfChanged: true)
                    results.append(fresh)
                }
                for stale in existing where !matched.contains(stale.id) {
                    // Gone, unless an earlier step of this pass moved it into this directory.
                    if let current = try self.record(id: stale.id), current.parentID == parentID {
                        try removeSubtree(stale.id)
                    }
                }
                try db.cached("UPDATE items SET scannedAt = ? WHERE id = ?")
                    .run([.real(Date().timeIntervalSince1970), .text(parentID)])
                return results
            }
        }
    }

    /// Removes an item and everything below it, logging the deletions.
    public func remove(id: String) throws {
        try locked { try db.transaction { try removeSubtree(id) } }
    }

    /// Rewrites a record (rename, move, new content), keeping its identifier.
    @discardableResult
    public func replace(id: String, with item: SMBItem, parentID: String) throws -> Record {
        try locked {
            let fresh = Self.makeRecord(item, id: id, parentID: parentID)
            try write(fresh, logIfChanged: true)
            return fresh
        }
    }

    private func removeSubtree(_ id: String) throws {
        var stack = [id]
        var all: [String] = []
        while let current = stack.popLast() {
            all.append(current)
            let s = try db.cached("SELECT id FROM items WHERE parent = ? AND id != parent").bind([.text(current)])
            while try s.step() { stack.append(s.text(0)) }
        }
        let delete = try db.cached("DELETE FROM items WHERE id = ?")
        let log = try db.cached("INSERT INTO changes(id, deleted) VALUES(?, 1)")
        for item in all {
            try delete.run([.text(item)])
            try log.run([.text(item)])
        }
    }

    private func write(_ record: Record, logIfChanged: Bool) throws {
        let previous = try self.record(id: record.id)
        if let previous, previous.sameContents(as: record) { return }
        try db.cached("""
            INSERT INTO items(id, parent, name, folded, fileID, isDir, size, btime, mtime, ctime, attrs)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET parent = excluded.parent, name = excluded.name, folded = excluded.folded,
                fileID = excluded.fileID, isDir = excluded.isDir, size = excluded.size, btime = excluded.btime,
                mtime = excluded.mtime, ctime = excluded.ctime, attrs = excluded.attrs
            """).run([
                .text(record.id), .text(record.parentID), .text(record.name), .text(Self.fold(record.name)),
                .int(Int64(bitPattern: record.fileID)), .int(record.isDirectory ? 1 : 0), .int(record.size),
                .int(Int64(bitPattern: record.creationTime)), .int(Int64(bitPattern: record.modificationTime)),
                .int(Int64(bitPattern: record.changeTime)), .int(Int64(record.attributes)),
            ])
        if logIfChanged {
            try db.cached("INSERT INTO changes(id, deleted) VALUES(?, 0)").run([.text(record.id)])
        }
    }

    static func makeRecord(_ item: SMBItem, id: String, parentID: String) -> Record {
        Record(id: id, parentID: parentID, name: item.name, fileID: item.fileID, isDirectory: item.isDirectory,
               size: item.isDirectory ? 0 : item.size, creationTime: item.creationTime,
               modificationTime: item.lastWriteTime, changeTime: item.changeTime, attributes: item.attributes.rawValue)
    }

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Server-side names the cloud volume never shows.
    public static func isIgnored(_ name: String) -> Bool {
        name == "." || name == ".." || name.hasPrefix(SMBClient.temporaryPrefix)
    }

    // MARK: Change log

    public var currentAnchor: Int64 {
        let value = (try? locked { try db.scalarInt("SELECT COALESCE(MAX(seq), 0) FROM changes") }) ?? 0
        return Int64(value)
    }

    /// Latest state of everything that changed after `anchor`, oldest first.
    public func changes(since anchor: Int64, limit: Int = 500) throws -> Changes {
        try locked {
            let minSeq = try db.scalarText("SELECT value FROM meta WHERE key = 'minSeq'")
            let floor = minSeq.flatMap { Int64($0) } ?? 0
            guard anchor >= floor else { throw IndexError.anchorExpired }
            let s = try db.cached("""
                SELECT c.seq, c.id, c.deleted FROM changes c
                WHERE c.seq > ? AND c.seq = (SELECT MAX(seq) FROM changes WHERE id = c.id)
                ORDER BY c.seq LIMIT ?
                """).bind([.int(anchor), .int(Int64(limit))])
            var rows: [(Int64, String, Bool)] = []
            while try s.step() { rows.append((s.int(0), s.text(1), s.int(2) != 0)) }
            var updated: [Record] = []
            var deleted: [String] = []
            for (_, id, isDeleted) in rows {
                if !isDeleted, let current = try self.record(id: id) {
                    updated.append(current)
                } else {
                    deleted.append(id)
                }
            }
            let moreComing = rows.count == limit
            let maxSeq = Int64(try db.scalarInt("SELECT COALESCE(MAX(seq), 0) FROM changes"))
            let next = moreComing ? (rows.last?.0 ?? anchor) : maxSeq
            return Changes(updated: updated, deleted: deleted, anchor: max(next, anchor), moreComing: moreComing)
        }
    }

    /// Drops old log entries; anchors before the cut become invalid (the system re-enumerates).
    public func pruneChanges(keeping: Int = 50_000) throws {
        try locked {
            let maxSeq = Int64(try db.scalarInt("SELECT COALESCE(MAX(seq), 0) FROM changes"))
            let cut = maxSeq - Int64(keeping)
            guard cut > 0 else { return }
            try db.cached("DELETE FROM changes WHERE seq <= ?").run([.int(cut)])
            try db.cached("INSERT INTO meta(key, value) VALUES('minSeq', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
                .run([.text(String(cut))])
        }
    }

    /// Every record, for working-set enumeration after an anchor reset.
    public func allRecords(offset: Int, limit: Int) throws -> [Record] {
        try locked {
            let s = try db.cached("SELECT \(Self.columns) FROM items WHERE id != ? ORDER BY rowid LIMIT ? OFFSET ?")
                .bind([.text(Self.rootID), .int(Int64(limit)), .int(Int64(offset))])
            var out: [Record] = []
            while try s.step() { out.append(Self.record(s)) }
            return out
        }
    }

    // MARK: Dirty directories and rescans

    public func markDirty(_ path: String, recursive: Bool) throws {
        try locked {
            try db.cached("""
                INSERT INTO dirty(path, recursive) VALUES(?, ?)
                ON CONFLICT(path) DO UPDATE SET recursive = max(recursive, excluded.recursive)
                """).run([.text(SMBPath.normalize(path)), .int(recursive ? 1 : 0)])
        }
    }

    public var pendingDirtyCount: Int {
        (try? locked { try db.scalarInt("SELECT COUNT(*) FROM dirty") }) ?? 0
    }

    /// Takes (and clears) the dirty marks.
    public func takeDirty(limit: Int = 200) throws -> [(path: String, recursive: Bool)] {
        try locked {
            try db.transaction {
                let s = try db.cached("SELECT path, recursive FROM dirty LIMIT ?").bind([.int(Int64(limit))])
                var out: [(path: String, recursive: Bool)] = []
                while try s.step() { out.append((s.text(0), s.int(1) != 0)) }
                let delete = try db.cached("DELETE FROM dirty WHERE path = ?")
                for entry in out { try delete.run([.text(entry.path)]) }
                return out
            }
        }
    }

    /// Directories the system has listed, least recently scanned first.
    public func listedDirectories(scannedBefore date: Date, limit: Int) throws -> [String] {
        try locked {
            let s = try db.cached("""
                SELECT id FROM items WHERE isDir = 1 AND scannedAt > 0 AND scannedAt < ? ORDER BY scannedAt LIMIT ?
                """).bind([.real(date.timeIntervalSince1970), .int(Int64(limit))])
            var out: [String] = []
            while try s.step() { out.append(s.text(0)) }
            return out
        }
    }

    /// Whether the system has enumerated this directory before.
    public func isListed(_ id: String) throws -> Bool {
        try locked {
            let s = try db.cached("SELECT scannedAt FROM items WHERE id = ?").bind([.text(id)])
            return try s.step() && s.real(0) > 0
        }
    }

    /// Listed directories below (and including) `id`.
    public func listedDirectories(under id: String) throws -> [String] {
        try locked {
            var out: [String] = []
            var stack = [id]
            while let current = stack.popLast() {
                if let entry = try self.record(id: current), entry.isDirectory || entry.isRoot { out.append(current) }
                let s = try db.cached("SELECT id FROM items WHERE parent = ? AND isDir = 1 AND scannedAt > 0 AND id != parent")
                    .bind([.text(current)])
                while try s.step() { stack.append(s.text(0)) }
            }
            return out
        }
    }
}

// MARK: - SQLite

enum SQLValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

/// Minimal SQLite wrapper. Not thread-safe by itself; `CloudIndex` serializes access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: SQLiteStatement] = [:]
    private var transactionDepth = 0

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw CloudIndex.IndexError.database(message)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw CloudIndex.IndexError.database(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CloudIndex.IndexError.database("\(errorMessage) in \(sql)")
        }
        return SQLiteStatement(statement, database: self)
    }

    /// Prepared once, reused (and reset) afterwards.
    func cached(_ sql: String) throws -> SQLiteStatement {
        if let statement = statements[sql] { return statement.reset() }
        let statement = try prepare(sql)
        statements[sql] = statement
        return statement
    }

    func scalarInt(_ sql: String) throws -> Int {
        let s = try cached(sql)
        return try s.step() ? Int(s.int(0)) : 0
    }

    func scalarText(_ sql: String) throws -> String? {
        let s = try cached(sql)
        guard try s.step(), sqlite3_column_type(s.handle, 0) != SQLITE_NULL else { return nil }
        return s.text(0)
    }

    /// Nested calls join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    let handle: OpaquePointer
    private unowned let database: SQLiteDatabase

    init(_ handle: OpaquePointer, database: SQLiteDatabase) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    @discardableResult
    func reset() -> SQLiteStatement {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        return self
    }

    @discardableResult
    func bind(_ values: [SQLValue]) -> SQLiteStatement {
        reset()
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(handle, index, v)
            case .real(let v): sqlite3_bind_double(handle, index, v)
            case .text(let v): sqlite3_bind_text(handle, index, v, -1, Self.transient)
            case .null: sqlite3_bind_null(handle, index)
            }
        }
        return self
    }

    /// True while there are rows.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw CloudIndex.IndexError.database(database.errorMessage)
        }
    }

    func run(_ values: [SQLValue]) throws {
        bind(values)
        while try step() {}
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: pointer)
    }
}
