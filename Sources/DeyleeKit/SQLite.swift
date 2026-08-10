import Foundation

// SQLCipher, vendored and compiled as `CSQLCipher`, on every platform. Apple's own
// `SQLite3` module is deliberately not imported: it is the same C API but cannot
// open an encrypted file, so a build that reached for it would compile and then
// fail to read the store the moment a key was set.
import CSQLCipher

/// Thin wrapper over the system SQLite3 C API. Deylee's schema is small and its SQL
/// is written by hand — same stance as better-sqlite3 in the Electron app — so a
/// dependency-free wrapper beats an ORM. Not Sendable on purpose: the store that
/// owns a `Database` is responsible for confining it to one executor.
public final class Database {
    public struct Failure: DeyleeError {
        public let code: Int32
        public let message: String
        public var description: String { "sqlite error \(code): \(message)" }
    }

    public enum Value {
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null
    }

    fileprivate var handle: OpaquePointer?
    private var savepointDepth = 0

    public init(path: String, key: [UInt8]? = nil) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw Failure(code: code, message: message)
        }
        if let key {
            do {
                try applyKey(key)
            } catch {
                sqlite3_close_v2(handle)
                handle = nil
                throw error
            }
        }
    }

    /// Attach the encryption key, then force a read so a wrong key fails here rather
    /// than on the first query.
    ///
    /// The key goes in as a raw hex literal (`x'…'`), which tells SQLCipher to use
    /// the 32 bytes directly and skip the passphrase key-derivation — right for a
    /// key that is already random rather than a human's word. A file that will not
    /// open with the key reads as `SQLITE_NOTADB`, the same "file is not a database"
    /// a plaintext reader gets from an encrypted file; surfaced as a distinct
    /// failure so a caller can tell "wrong key" from "corrupt".
    private func applyKey(_ key: [UInt8]) throws {
        let hex = key.map { String(format: "%02x", $0) }.joined()
        try execute("PRAGMA key = \"x'\(hex)'\";")
        do {
            try execute("SELECT count(*) FROM sqlite_master;")
        } catch {
            throw Failure(
                code: SQLITE_NOTADB,
                message: "the store key does not open this file"
            )
        }
    }

    /// Whether an on-disk file is unencrypted. A plaintext SQLite database begins
    /// with the ASCII header "SQLite format 3\0"; an encrypted SQLCipher file begins
    /// with random salt. A file that does not exist, or is too short to tell, is not
    /// plaintext for this purpose — there is nothing to migrate.
    public static func isPlaintext(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = try? handle.read(upToCount: 16)
        return header == Data("SQLite format 3\0".utf8)
    }

    /// Copy this (plaintext) database into a new encrypted file at `path`.
    ///
    /// Uses `sqlcipher_export`, which reads through this live connection — so commits
    /// still sitting in the WAL sidecar are included, where a plain file copy would
    /// drop them — and writes a single, complete encrypted file. The caller swaps it
    /// into place; this only produces it.
    public func exportEncrypted(toPath path: String, key: [UInt8]) throws {
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try execute("ATTACH DATABASE '\(escaped)' AS encrypted KEY \"x'\(hex)'\";")
        try execute("SELECT sqlcipher_export('encrypted');")
        try execute("DETACH DATABASE encrypted;")
    }

    /// Copy this database into a new plaintext file at `path`, whatever this
    /// connection's own encryption. Attaching with an empty key means the
    /// destination has no codec, and `sqlcipher_export` decrypts on the way out.
    ///
    /// This is for a backup the owner asked for and must be able to open elsewhere —
    /// an encrypted copy only this Mac's Keychain could read would be no backup at
    /// all. It is the owner exporting their own hours, which they are entitled to do.
    public func exportPlaintext(toPath path: String) throws {
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try execute("ATTACH DATABASE '\(escaped)' AS plaintext KEY '';")
        try execute("SELECT sqlcipher_export('plaintext');")
        try execute("DETACH DATABASE plaintext;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Run a semicolon-separated SQL script with no parameters or results.
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw Failure(code: code, message: message)
        }
    }

    /// Run one statement to completion.
    public func run(_ sql: String, _ params: [Value] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure(code) }
    }

    /// Run one statement and map every result row.
    public func query<T>(_ sql: String, _ params: [Value] = [], row map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure(code) }
            rows.append(try map(Row(statement: statement)))
        }
    }

    /// Run one statement expected to produce at most one row.
    public func queryOne<T>(_ sql: String, _ params: [Value] = [], row map: (Row) throws -> T) throws -> T? {
        try query(sql, params, row: map).first
    }

    /// Copy this database to `path` with SQLite's online backup API.
    ///
    /// Safe to run while the timer is still writing: in WAL mode the newest commits
    /// live in the `-wal` sidecar, so a plain file copy of the `.sqlite` alone can
    /// silently miss them. This produces one consistent file instead.
    public func backup(to path: String) throws {
        let destination = try Database(path: path)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw destination.failure(sqlite3_errcode(destination.handle))
        }
        sqlite3_backup_step(backup, -1)
        let code = sqlite3_backup_finish(backup)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        Int(sqlite3_changes(handle))
    }

    /// Everything inside `body` commits atomically, or rolls back if it throws.
    ///
    /// Nesting is safe: an inner call is promoted to a SAVEPOINT, so a service may
    /// wrap a repository method that already wraps itself and only the outermost
    /// commit reaches the disk. This mirrors better-sqlite3, which the repository
    /// logic was written against.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let depth = savepointDepth
        let name = "deylee_sp_\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(name)")
        savepointDepth = depth + 1
        do {
            let result = try body()
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(name)")
            savepointDepth = depth
            return result
        } catch {
            if depth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(name)")
                try? execute("RELEASE \(name)")
            }
            savepointDepth = depth
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in params.enumerated() {
            let slot = Int32(index + 1)
            let bindCode: Int32
            switch value {
            case .integer(let v): bindCode = sqlite3_bind_int64(statement, slot, v)
            case .real(let v): bindCode = sqlite3_bind_double(statement, slot, v)
            case .text(let v): bindCode = sqlite3_bind_text(statement, slot, v, -1, transient)
            case .blob(let v):
                bindCode = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, slot, $0.baseAddress, Int32(v.count), transient)
                }
            case .null: bindCode = sqlite3_bind_null(statement, slot)
            }
            guard bindCode == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure(bindCode)
            }
        }
        return statement
    }

    fileprivate func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

/// One result row, valid only inside the `query` mapping closure.
public struct Row {
    let statement: OpaquePointer

    public func int64(_ column: Int) -> Int64 {
        sqlite3_column_int64(statement, Int32(column))
    }

    public func int(_ column: Int) -> Int {
        Int(int64(column))
    }

    public func double(_ column: Int) -> Double {
        sqlite3_column_double(statement, Int32(column))
    }

    public func text(_ column: Int) -> String {
        sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) } ?? ""
    }

    public func isNull(_ column: Int) -> Bool {
        sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL
    }

    public func optionalInt64(_ column: Int) -> Int64? {
        isNull(column) ? nil : int64(column)
    }

    public func optionalText(_ column: Int) -> String? {
        isNull(column) ? nil : text(column)
    }

    /// Copies the bytes out rather than wrapping the pointer.
    ///
    /// SQLite owns that buffer only until the statement is stepped or finalized, and
    /// both happen before a caller could use it — `query` steps in a loop and
    /// finalizes in a `defer`. A `Data` viewing the pointer would be reading freed
    /// memory by the time it was read, which is the kind of bug that works in a test
    /// and corrupts an image in the field.
    public func blob(_ column: Int) -> Data {
        guard let pointer = sqlite3_column_blob(statement, Int32(column)) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, Int32(column)))
        return Data(bytes: pointer, count: count)
    }
}
