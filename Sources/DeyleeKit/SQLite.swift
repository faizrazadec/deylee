import Foundation

// Apple's SDKs ship SQLite as a Swift module; Linux ships only the C library, which
// `CSQLite` wraps. The names below are identical either way, so nothing after this
// line has to know which platform it is on.
#if canImport(SQLite3)
    import SQLite3
#else
    import CSQLite
#endif

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

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw Failure(code: code, message: message)
        }
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
}
