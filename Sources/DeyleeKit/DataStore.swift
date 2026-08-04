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
    /// Throws `SchemaTooNewError` when the file was written by a newer build — the
    /// caller must refuse to start rather than write rows shaped for an older schema
    /// into it.
    public static func open() throws -> Database {
        try FileManager.default.createDirectory(
            at: folderURL, withIntermediateDirectories: true
        )
        let db = try openDatabase(at: databaseURL.path)
        try runMigrations(db)
        return db
    }

    /// Copies the live database to `destination` using SQLite's online backup API.
    ///
    /// A plain file copy would be wrong: in WAL mode the most recent commits live in
    /// the `-wal` sidecar, so copying only the `.sqlite` file can silently lose them.
    /// The backup API reads through a second connection and produces a single
    /// consistent file even while the timer is still writing.
    public static func backup(to destination: URL) throws {
        let source = try Database(path: databaseURL.path)
        try source.backup(to: destination.path)
    }
}
