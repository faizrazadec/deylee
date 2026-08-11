import Foundation

/// Where Deylee's data lives, and how the native app adopts what the Electron build
/// left behind.
///
/// The Electron build stored everything in `~/Library/Application Support/deylee/`
/// (lower-case — Electron derived the folder from the package name, not the product
/// name). The native app keeps using that same folder and the same `deylee.sqlite`
/// file: the schema is identical, the version protocol is shared, and adopting the
/// file in place means the user's history simply carries over with nothing to
/// migrate, export or re-import.
public enum DataStore {
    public static let databaseFileName = "deylee.sqlite"
    /// Kept lower-case deliberately — this is the folder the Electron build created,
    /// and renaming it would strand the user's existing history.
    public static let folderName = "deylee"

    /// Overrides the data folder for a development run, so a build under test never
    /// opens the real history.
    public static let folderOverrideEnvKey = "DEYLEE_DATA_DIR"

    public static var folderURL: URL {
        if let override = ProcessInfo.processInfo.environment[folderOverrideEnvKey],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: folderName, directoryHint: .isDirectory)
    }

    public static var databaseURL: URL {
        folderURL.appending(path: databaseFileName, directoryHint: .notDirectory)
    }

    /// The Electron build's preference file, still sitting beside the database.
    /// Read once at first launch so settings carry over too.
    public static var legacyPreferencesURL: URL {
        folderURL.appending(path: "preferences.json", directoryHint: .notDirectory)
    }

    public static var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    /// Opens the store, creating the folder and running migrations.
    ///
    /// A `key` encrypts the store at rest. Pass it and an existing plaintext file is
    /// migrated to encrypted in place on first open; pass it and there is no file and
    /// the store is created encrypted from the start; pass `nil` and the store stays
    /// plaintext exactly as before. The key lives in the app's Keychain and never in
    /// this platform-free module — which is why it arrives as bytes.
    ///
    /// Throws `SchemaTooNewError` when the file was written by a newer build — the
    /// caller must refuse to start rather than write rows shaped for an older schema
    /// into it. Throws a `SQLITE_NOTADB` failure when a key is given that does not
    /// open an already-encrypted file.
    public static func open(key: [UInt8]? = nil) throws -> Database {
        try FileManager.default.createDirectory(
            at: folderURL, withIntermediateDirectories: true
        )
        if let key { try encryptInPlaceIfNeeded(key: key) }
        let db = try openDatabase(at: databaseURL.path, key: key)
        try runMigrations(db)
        return db
    }

    /// One-way migration of an existing plaintext store to encrypted.
    ///
    /// Does nothing when there is no file (a fresh store is created encrypted
    /// directly) or when the file is already encrypted (the header is not the
    /// plaintext magic). Otherwise it exports the plaintext database into a new
    /// encrypted file beside it, then swaps it in and removes the WAL sidecars,
    /// which belong to the plaintext file and mean nothing to the encrypted one.
    ///
    /// The swap is the risky moment, so it is ordered to survive a crash: the
    /// encrypted copy is built and closed first, and only then is the original
    /// replaced. A crash before the replace leaves the untouched plaintext store and
    /// a stray temp file; a crash after leaves the finished encrypted store. There is
    /// no window where a half-written file is the store of record.
    static func encryptInPlaceIfNeeded(key: [UInt8]) throws {
        guard databaseExists else { return }
        guard Database.isPlaintext(atPath: databaseURL.path) else { return }

        let temporaryURL = folderURL.appending(
            path: "deylee.encrypting.sqlite", directoryHint: .notDirectory
        )
        try? FileManager.default.removeItem(at: temporaryURL)

        // A scope, so the plaintext connection is closed before the file is replaced.
        do {
            let plaintext = try Database(path: databaseURL.path)
            try plaintext.exportEncrypted(toPath: temporaryURL.path, key: key)
        }

        // Prove the encrypted copy opens with the key before trusting it with the
        // only copy of the history.
        do {
            _ = try Database(path: temporaryURL.path, key: key)
        }

        let fileManager = FileManager.default
        try fileManager.removeItem(at: databaseURL)
        for sidecar in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + sidecar)
            try? fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporaryURL, to: databaseURL)
    }

    /// Copies the live database to `destination` as a portable, plaintext file.
    ///
    /// A `key` is required when the store is encrypted, to read it; the copy itself
    /// is always plaintext, because a backup the owner cannot open on another machine
    /// is not a backup. Reading through a live connection also means commits still in
    /// the `-wal` sidecar are included, where copying only the `.sqlite` file would
    /// silently drop them.
    /// Tables that must not travel in a backup.
    ///
    /// Nothing here is the owner's work, and all of it identifies them. `sync_state`
    /// holds the account this store belongs to and the id this install reports to the
    /// server — two values the person reading their own backup has no use for, and the
    /// only values in the file that say *whose* it is. `sync_quarantine` holds rows
    /// verbatim as the server sent them, which is machinery rather than history.
    ///
    /// The backup is deliberately plaintext so the owner can open it anywhere, which
    /// is exactly why the identifiers must not be in it: it is the one copy of this
    /// data that leaves the encrypted store and the machine.
    ///
    /// Nothing restores from this file — it is an export — so removing them costs
    /// nothing.
    /// `captures` is here for a different and larger reason than the other two.
    ///
    /// Screen captures live in the database precisely so they are encrypted at rest.
    /// This backup is deliberately *plaintext*, so that the owner can open it anywhere —
    /// which would make it the one unencrypted copy of every screenshot the app ever
    /// took, roughly half a gigabyte of it at the default retention, written to wherever
    /// somebody happened to save it. That would undo the entire reason the images are
    /// stored the way they are.
    ///
    /// The backup is an export of the owner's *hours*. Images are not hours, and the
    /// place to look at them is Settings -> Screen capture -> Review, one at a time.
    static let tablesWithheldFromBackup = ["sync_state", "sync_quarantine", "captures"]

    public static func backup(to destination: URL, key: [UInt8]? = nil) throws {
        let source = try Database(path: databaseURL.path, key: key)
        if key != nil {
            try source.exportPlaintext(toPath: destination.path)
        } else {
            // No key: the store is already plaintext, so the online backup API is
            // the faithful copy — page for page, WAL included.
            try source.backup(to: destination.path)
        }

        // Both paths copy every table, so the withholding happens once, here, on the
        // copy. `VACUUM` is not tidiness: a dropped table's pages stay in the file's
        // free list until it runs, and this file has no encryption to hide them.
        let copy = try Database(path: destination.path)
        for table in tablesWithheldFromBackup {
            try copy.execute("DROP TABLE IF EXISTS \(table);")
        }
        try copy.execute("VACUUM;")
    }
}
