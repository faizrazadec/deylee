import Foundation

/// Schema creation and versioned migration, ported from `src/main/db/migrations.ts`.
///
/// Migrations are an ordered, append-only list. Each one is gated on the stored
/// version and every statement is `IF NOT EXISTS`, so running this against an
/// up-to-date file is a no-op and running it against a half-migrated one — the app
/// was killed mid-upgrade — cannot corrupt anything: the whole batch commits or
/// rolls back as a unit.
///
/// No table here stores a total. Totals are derived from `segments`, which is what
/// keeps them correct after a crash or an edit.
///
/// The version protocol must stay byte-compatible with the Electron build: both
/// implementations read and write the same `schema_version` table, and both refuse
/// a file from a newer build outright.

/// Bump this in lock-step with a new entry in `migrations`.
public let CURRENT_SCHEMA_VERSION = 1

/// The database on disk was written by a newer build of Dayly than this one.
///
/// Opening it anyway is the quiet way to lose history: this build would write rows
/// shaped for an older schema, ignore columns it does not know about, and let a
/// later rebuild take the newer ones with it. There is no down-migration to fall
/// back on, so the only safe answer is to not open the file at all.
public struct SchemaTooNewError: DaylyError {
    public let storedVersion: Int
    public let supportedVersion: Int

    public var description: String {
        "The database was created by a newer version of Dayly (schema v\(storedVersion)); "
            + "this build supports up to v\(supportedVersion)."
    }
}

struct Migration: Sendable {
    let version: Int
    let up: @Sendable (Database) throws -> Void
}

let migrations: [Migration] = [
    Migration(version: 1) { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS days (
              id             INTEGER PRIMARY KEY AUTOINCREMENT,
              date           TEXT    NOT NULL UNIQUE,
              created_at     INTEGER NOT NULL,
              ended_at       INTEGER,
              target_minutes INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS segments (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              day_id     INTEGER NOT NULL REFERENCES days(id) ON DELETE CASCADE,
              type       TEXT    NOT NULL CHECK (type IN ('work','break')),
              started_at INTEGER NOT NULL,
              ended_at   INTEGER,
              note       TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_segments_day ON segments(day_id, started_at);

            -- Partial index: the open-segment lookup runs on every snapshot, and there
            -- is at most one matching row in the whole table.
            CREATE INDEX IF NOT EXISTS idx_segments_open ON segments(ended_at) WHERE ended_at IS NULL;

            CREATE TABLE IF NOT EXISTS app_state (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
    },
]

public func runMigrations(_ db: Database) throws {
    // Bootstrapped outside the migration list because reading the current version
    // requires the table to already exist.
    try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")

    let current = try readSchemaVersion(db)

    // Checked before anything is applied and before any write, so a downgrade leaves
    // the file exactly as the newer build left it.
    if current > CURRENT_SCHEMA_VERSION {
        throw SchemaTooNewError(storedVersion: current, supportedVersion: CURRENT_SCHEMA_VERSION)
    }

    let pending = migrations
        .filter { $0.version > current && $0.version <= CURRENT_SCHEMA_VERSION }
        .sorted { $0.version < $1.version }
    if pending.isEmpty { return }

    try db.transaction {
        for migration in pending {
            try migration.up(db)
            try db.run("DELETE FROM schema_version")
            try db.run("INSERT INTO schema_version (version) VALUES (?)", [.integer(Int64(migration.version))])
        }
    }
}

/// 0 means "empty file" — every migration is pending.
func readSchemaVersion(_ db: Database) throws -> Int {
    try db.queryOne("SELECT version FROM schema_version ORDER BY version DESC LIMIT 1") {
        $0.int(0)
    } ?? 0
}

/// Open the one SQLite connection the app owns.
///
/// The pragma choices are deliberate and must match the Electron build, because the
/// two share the file:
///  - WAL keeps readers from blocking the writer, and is what makes an online backup
///    safe to run while the timer is still ticking.
///  - `synchronous = NORMAL` is the correct pairing with WAL: a power loss can cost
///    the last commit, never the file. FULL would fsync on every 30 s heartbeat.
///  - `foreign_keys` is off by default in SQLite, so `ON DELETE CASCADE` from
///    `segments` to `days` only works if it is turned on for every connection.
///  - `busy_timeout` covers the short lock a backup or WAL checkpoint takes.
public func openDatabase(at path: String) throws -> Database {
    let db = try Database(path: path)
    // journal_mode is a property of the file itself, so it is applied first — before
    // anything has a chance to open a transaction in the old rollback journal mode.
    try db.execute("PRAGMA journal_mode = WAL")
    try db.execute("PRAGMA foreign_keys = ON")
    try db.execute("PRAGMA busy_timeout = 5000")
    try db.execute("PRAGMA synchronous = NORMAL")
    return db
}
