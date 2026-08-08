import Foundation
import Testing

@testable import DeyleeKit

/// Encryption of the store at rest.
///
/// These use real files in a throwaway directory rather than `:memory:`, because the
/// whole point is what ends up on disk — a memory database has no bytes to inspect.
///
/// Serialized because two of them point `DataStore` at a throwaway folder through its
/// one process-global environment override; run in parallel they would clobber each
/// other's path and open the wrong file.
@Suite(.serialized) struct Encryption {
    /// A fresh directory per test, removed after. Not the real store, ever.
    private static func scratch() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "deylee-enc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static let aKey: [UInt8] = Array(0..<32)
    private static let anotherKey: [UInt8] = Array(32..<64)

    @Test func aKeyedStoreReadsBackWhatItWrote() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "s.sqlite").path

        do {
            let db = try Database(path: path, key: Self.aKey)
            try db.execute("CREATE TABLE t (n INTEGER)")
            try db.run("INSERT INTO t (n) VALUES (?)", [.integer(7)])
        }
        let reopened = try Database(path: path, key: Self.aKey)
        let rows = try reopened.query("SELECT n FROM t") { $0.int64(0) }
        #expect(rows == [7])
    }

    @Test func theFileOnDiskIsNotPlaintext() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "s.sqlite").path

        let db = try Database(path: path, key: Self.aKey)
        try db.execute("CREATE TABLE t (secret TEXT)")
        try db.run("INSERT INTO t (secret) VALUES (?)", [.text("worked 9 to 5")])
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        #expect(!Database.isPlaintext(atPath: path))
        // The header bytes are not SQLite's, and the plaintext note is nowhere in
        // the file. A grep of the store must not turn up what it recorded.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
        #expect(bytes.range(of: Data("worked 9 to 5".utf8)) == nil)
    }

    @Test func theWrongKeyIsRefused() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "s.sqlite").path

        do {
            let db = try Database(path: path, key: Self.aKey)
            try db.execute("CREATE TABLE t (n INTEGER)")
        }
        #expect(throws: Database.Failure.self) {
            _ = try Database(path: path, key: Self.anotherKey)
        }
    }

    @Test func noKeyCannotOpenAnEncryptedFile() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "s.sqlite").path

        do {
            let db = try Database(path: path, key: Self.aKey)
            try db.execute("CREATE TABLE t (n INTEGER)")
        }
        // Opening succeeds — no key is applied — but the first read fails, which is
        // exactly the SQLite-browser experience the encryption is there to produce.
        let db = try Database(path: path)
        #expect(throws: Database.Failure.self) {
            try db.execute("SELECT count(*) FROM sqlite_master")
        }
    }

    @Test func migratesAPlaintextStoreInPlace() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Point DataStore at this directory, so open() operates on the throwaway.
        setenv(DataStore.folderOverrideEnvKey, dir.path, 1)
        defer { unsetenv(DataStore.folderOverrideEnvKey) }

        // Build a plaintext store the way the pre-encryption app would have.
        do {
            let db = try DataStore.open()
            _ = try Repository(db: db).getOrCreateDay(DateKey("2026-08-09")!, targetMinutes: 480, now: 1)
        }
        #expect(Database.isPlaintext(atPath: DataStore.databaseURL.path))

        // Now open with a key: the file must convert in place and keep its rows.
        do {
            let db = try DataStore.open(key: Self.aKey)
            let day = try Repository(db: db).findDay(DateKey("2026-08-09")!)
            #expect(day?.targetMinutes == 480)
        }
        #expect(!Database.isPlaintext(atPath: DataStore.databaseURL.path))

        // The stale WAL sidecars of the plaintext file must be gone, or a later
        // open would try to replay them against the encrypted file.
        let wal = DataStore.databaseURL.path + "-wal"
        #expect(!FileManager.default.fileExists(atPath: wal))

        // And a second keyed open is an ordinary open — no migration, same data.
        let db = try DataStore.open(key: Self.aKey)
        #expect(try Repository(db: db).findDay(DateKey("2026-08-09")!)?.targetMinutes == 480)
    }

    @Test func aPlaintextBackupOpensWithoutTheKey() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv(DataStore.folderOverrideEnvKey, dir.path, 1)
        defer { unsetenv(DataStore.folderOverrideEnvKey) }

        do {
            let db = try DataStore.open(key: Self.aKey)
            _ = try Repository(db: db).getOrCreateDay(DateKey("2026-08-09")!, targetMinutes: 300, now: 1)
        }
        let backup = dir.appending(path: "backup.sqlite")
        try DataStore.backup(to: backup, key: Self.aKey)

        #expect(Database.isPlaintext(atPath: backup.path))
        let opened = try Database(path: backup.path)
        let rows = try opened.query(
            "SELECT target_minutes FROM days WHERE date = '2026-08-09'"
        ) { $0.int64(0) }
        #expect(rows == [300])
    }
}
