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
public let CURRENT_SCHEMA_VERSION = 5

/// The database on disk was written by a newer build of Deylee than this one.
///
/// Opening it anyway is the quiet way to lose history: this build would write rows
/// shaped for an older schema, ignore columns it does not know about, and let a
/// later rebuild take the newer ones with it. There is no down-migration to fall
/// back on, so the only safe answer is to not open the file at all.
public struct SchemaTooNewError: DeyleeError {
    public let storedVersion: Int
    public let supportedVersion: Int

    public var description: String {
        "The database was created by a newer version of Deylee (schema v\(storedVersion)); "
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

    // What sync needs from the local store.
    //
    // The integer primary keys stay exactly where they are: every query, every
    // foreign key and every `Int64` id in the models keeps working, and a v1 file
    // opens without rewriting a row. The sync identity is an additional column.
    //
    // Nothing here is Electron-compatible, and nothing needs to be — that build is
    // gone. A v1 file upgrades in place; a v2 file simply will not open in code
    // that predates this migration, which is what `schema_version` is for.
    Migration(version: 2) { db in
        try db.execute("""
            -- Identity that survives leaving this machine.
            --
            -- An AUTOINCREMENT id is unique in one file and meaningless outside it:
            -- two devices offline at once both mint `41`. UUIDv7 is generated where
            -- the row is born, sorts by creation time, and cannot collide.
            ALTER TABLE days     ADD COLUMN uuid TEXT;
            ALTER TABLE segments ADD COLUMN uuid TEXT;

            -- Tombstones. A row deleted here must still be *sent*, or the delete
            -- never reaches the phone and the row comes back on its next sync.
            ALTER TABLE days     ADD COLUMN deleted_at INTEGER;
            ALTER TABLE segments ADD COLUMN deleted_at INTEGER;

            -- The push queue, kept as a flag rather than an outbox table so a write
            -- and its enqueue cannot end up in different transactions.
            --
            -- Existing rows default to dirty: history that predates sync has never
            -- been sent, and the first sync should carry all of it up.
            ALTER TABLE days     ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE segments ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;

            -- The server's ordering for this row. NULL means never acknowledged.
            ALTER TABLE days     ADD COLUMN server_seq INTEGER;
            ALTER TABLE segments ADD COLUMN server_seq INTEGER;

            -- `segments` already tracks updated_at; `days` did not need to until
            -- last-write-wins started comparing it.
            ALTER TABLE days ADD COLUMN updated_at INTEGER;
            UPDATE days SET updated_at = created_at WHERE updated_at IS NULL;
            """)

        // Seeding each id from the row's own `created_at` rather than from now()
        // means backfilled ids sort into the order the rows were actually made, so
        // a lifetime of existing history reaches the server already in sequence.
        try db.run("UPDATE days     SET uuid = \(uuidV7SQL(millis: "created_at")) WHERE uuid IS NULL")
        try db.run("UPDATE segments SET uuid = \(uuidV7SQL(millis: "created_at")) WHERE uuid IS NULL")

        try db.execute("""
            -- Added as indexes rather than column constraints because SQLite cannot
            -- ALTER TABLE ADD COLUMN ... UNIQUE.
            CREATE UNIQUE INDEX IF NOT EXISTS idx_days_uuid     ON days(uuid);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_segments_uuid ON segments(uuid);

            -- Partial: the push queue is scanned on every sync and is empty most of
            -- the time.
            CREATE INDEX IF NOT EXISTS idx_days_dirty     ON days(dirty)     WHERE dirty = 1;
            CREATE INDEX IF NOT EXISTS idx_segments_dirty ON segments(dirty) WHERE dirty = 1;

            -- One row, forever. The CHECK is what makes that true rather than a
            -- convention some future writer forgets.
            CREATE TABLE IF NOT EXISTS sync_state (
              id             INTEGER PRIMARY KEY CHECK (id = 1),
              device_id      TEXT    NOT NULL,
              user_id        TEXT,
              cursor         INTEGER NOT NULL DEFAULT 0,
              last_synced_at INTEGER
            );
            """)

        // Identifies this installation for the life of the store. Generated once
        // here so every later sync has one to send without a first-run special case.
        try db.run("""
            INSERT OR IGNORE INTO sync_state (id, device_id, cursor)
            VALUES (1, \(uuidV7SQL(millis: "(strftime('%s','now') * 1000)")), 0)
            """)
    },

    // Remember which rows the server refused.
    //
    // `dirty` alone cannot express it. A rejected row keeps `dirty = 1`, so it is
    // offered again on the next cycle — every two minutes, plus every wake and every
    // activation — and the reasons the server refuses are structural rather than
    // transient: an overlap clashes next time too, an over-long note is over-long for
    // ever. The row is retried for the life of the install and can never succeed.
    //
    // Recorded against `updated_at` rather than as a flag, so the rejection is tied to
    // the version that was refused. Edit the row and `updated_at` moves past it, which
    // is what makes the retry resume without anything having to clear the mark.
    Migration(version: 4) { db in
        try db.execute("""
            ALTER TABLE days     ADD COLUMN rejected_at INTEGER;
            ALTER TABLE days     ADD COLUMN rejection_code TEXT;
            ALTER TABLE segments ADD COLUMN rejected_at INTEGER;
            ALTER TABLE segments ADD COLUMN rejection_code TEXT;
            """)
    },

    // Give an identity to everything written while the writer was not giving one.
    //
    // Migration 2 backfilled the rows that existed when it ran, and from then on the
    // inserts in `Repository` were supposed to mint their own. They did not name the
    // column at all, so every row created since — every day and segment anybody has
    // tracked — carries `uuid = NULL`. `pendingPush` selects
    // `WHERE dirty = 1 AND uuid IS NOT NULL`, so those rows sit queued and unsendable
    // at the same time: marked pending for ever, never offered to the server, and
    // invisible on every other device.
    //
    // The writer mints ids now. This is for the history already on disk, which would
    // otherwise stay stranded no matter how long sync ran.
    Migration(version: 3) { db in
        // Seeded from each row's own created_at, exactly as migration 2 does, so a
        // lifetime of backfilled history reaches the server already in order rather
        // than all bearing the instant of this upgrade.
        try db.run("UPDATE days     SET uuid = \(uuidV7SQL(millis: "created_at")) WHERE uuid IS NULL")
        try db.run("UPDATE segments SET uuid = \(uuidV7SQL(millis: "created_at")) WHERE uuid IS NULL")

        // Every one of them still needs sending. A row that was never sendable cannot
        // have been acknowledged, whatever `dirty` happens to say — and `markPushed`
        // only ever clears the flag for a uuid the server named back.
        try db.run("UPDATE days     SET dirty = 1 WHERE server_seq IS NULL")
        try db.run("UPDATE segments SET dirty = 1 WHERE server_seq IS NULL")
    },

    // Rows the server sent that this build could not read.
    //
    // They used to be dropped, and the cursor advanced past them anyway — which is a
    // deletion, not a skip, because the cursor only moves forwards and the protocol
    // has no way to ask for a row again. The case that produces them is exactly the
    // case where the row is meaningful: a newer server sending a shape this version
    // does not know yet.
    //
    // Keeping them verbatim answers both halves. Sync does not stall on a row it
    // cannot use, and an upgrade that teaches the app the new shape replays them.
    Migration(version: 5) { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS sync_quarantine (
                uuid       TEXT PRIMARY KEY,
                table_name TEXT    NOT NULL,
                seq        INTEGER NOT NULL,
                payload    TEXT    NOT NULL,
                first_seen INTEGER NOT NULL
            );
            """)
    },
]

/// A SQL expression yielding a UUIDv7 string, for generating ids set-at-a-time
/// inside a statement rather than row-by-row through Swift.
///
/// Layout is the RFC 9562 one: 48 bits of Unix millisecond timestamp, the version
/// nibble 7, the variant bits 10, and randomness filling the rest. Because the
/// timestamp leads, the ids sort chronologically as plain text — which is what lets
/// the server's pull order and a client's insertion order agree for free.
///
/// - Parameter millis: a SQL expression evaluating to epoch milliseconds. A column
///   name backfills each row from its own timestamp; `strftime` mints a fresh one.
func uuidV7SQL(millis: String) -> String {
    """
    (substr(printf('%012x', \(millis)), 1, 8) || '-' ||
     substr(printf('%012x', \(millis)), 9, 4) || '-' ||
     '7' || substr(lower(hex(randomblob(2))), 1, 3) || '-' ||
     substr('89ab', 1 + (abs(random()) % 4), 1) ||
     substr(lower(hex(randomblob(2))), 1, 3) || '-' ||
     lower(hex(randomblob(6))))
    """
}

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
public func openDatabase(at path: String, key: [UInt8]? = nil) throws -> Database {
    let db = try Database(path: path, key: key)
    // journal_mode is a property of the file itself, so it is applied first — before
    // anything has a chance to open a transaction in the old rollback journal mode.
    // With a key it is set after the key, which the Database initialiser has already
    // applied; SQLCipher needs the key before any statement, including this one.
    try db.execute("PRAGMA journal_mode = WAL")
    try db.execute("PRAGMA foreign_keys = ON")
    try db.execute("PRAGMA busy_timeout = 5000")
    try db.execute("PRAGMA synchronous = NORMAL")
    return db
}
