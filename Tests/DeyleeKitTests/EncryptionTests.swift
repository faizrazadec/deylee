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

    /// The backup is plaintext so the owner can open it anywhere, which makes it the one
    /// copy of this data outside the encrypted store. Screen captures must not travel in
    /// it: that would be every screenshot the app ever took, in the clear, wherever the
    /// file was saved — undoing the reason the images live in the database at all.
    @Test func aBackupCarriesNoScreenCaptures() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv(DataStore.folderOverrideEnvKey, dir.path, 1)
        defer { unsetenv(DataStore.folderOverrideEnvKey) }

        do {
            let db = try DataStore.open(key: Self.aKey)
            let repo = Repository(db: db)
            _ = try repo.getOrCreateDay(DateKey("2026-08-10")!, targetMinutes: 480, now: 1)
            try repo.insertCapture(
                dayDate: DateKey("2026-08-10")!, segmentID: nil, capturedAt: 1_000,
                width: 10, height: 10, bytes: Data("SCREENSHOTPIXELS".utf8), now: 1_000
            )
        }
        let backup = dir.appending(path: "backup.sqlite")
        try DataStore.backup(to: backup, key: Self.aKey)

        // The hours are there...
        let opened = try Database(path: backup.path)
        let hours = try opened.query(
            "SELECT target_minutes FROM days WHERE date = '2026-08-10'"
        ) { $0.int64(0) }
        #expect(hours == [480])

        // ...the table is not, and neither are the pixels anywhere in the file.
        let tables = try opened.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='captures'"
        ) { $0.text(0) }
        #expect(tables.isEmpty, "captures must not travel in a plaintext export")
        let raw = try Data(contentsOf: backup)
        #expect(raw.range(of: Data("SCREENSHOTPIXELS".utf8)) == nil)
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

    /// A backup carries the owner's hours and nothing that says whose they are.
    ///
    /// `sqlcipher_export` copies every table, so `sync_state` — the account this store
    /// belongs to, and the id this install reports to the server — used to travel into
    /// a deliberately plaintext file the owner may put anywhere. Neither value means
    /// anything to the person reading their own backup, and together they are the only
    /// thing in it that identifies them.
    @Test func aBackupCarriesTheHoursAndNotTheIdentifiers() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv(DataStore.folderOverrideEnvKey, dir.path, 1)
        defer { unsetenv(DataStore.folderOverrideEnvKey) }

        let accountID = "11111111-2222-7333-8444-555555555555"
        do {
            let db = try DataStore.open(key: Self.aKey)
            let repo = Repository(db: db)
            _ = try repo.getOrCreateDay(DateKey("2026-08-09")!, targetMinutes: 300, now: 1)
            try repo.claimLocalData(forUserID: accountID)
            // Present in the live store — this is not a test that never wrote it.
            #expect(try repo.syncState().userID == accountID)
        }

        let backup = dir.appending(path: "backup.sqlite")
        try DataStore.backup(to: backup, key: Self.aKey)
        let opened = try Database(path: backup.path)

        for table in DataStore.tablesWithheldFromBackup {
            let present = try opened.query(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                [.text(table)]
            ) { $0.int64(0) }
            #expect(present == [0], "\(table) must not travel in a backup")
        }

        // The hours are still all there — withholding must not cost the owner their
        // own history, which is the entire point of the file.
        let rows = try opened.query(
            "SELECT target_minutes FROM days WHERE date = '2026-08-09'"
        ) { $0.int64(0) }
        #expect(rows == [300])

        // And the identifier is not lingering in a dropped page, which is why the
        // copy is vacuumed rather than merely dropped from.
        let raw = try Data(contentsOf: backup)
        #expect(
            raw.range(of: Data(accountID.utf8)) == nil,
            "the account id is still readable in the file's bytes"
        )
    }
}
