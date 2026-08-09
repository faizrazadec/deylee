import Foundation
import Testing

@testable import DeyleeKit

/// The upgrade path from a v1 store — a file written before sync existed — to v2.
///
/// These matter more than most tests here: the rows are somebody's real working
/// hours, already on disk, and the migration rewrites identity columns on every one
/// of them. A bug here is not a wrong number on screen, it is history that will
/// never sync or will sync twice.

/// A store at v1: schema as it shipped, version recorded, sync columns absent.
private func openV1Store() throws -> Database {
    let db = try Database(path: ":memory:")
    try db.execute("PRAGMA foreign_keys = ON")
    try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
    try migrations[0].up(db)
    try db.run("INSERT INTO schema_version (version) VALUES (1)")
    return db
}

/// Adds a day and one closed work segment, both stamped with `createdAt`.
@discardableResult
private func seedDay(_ db: Database, date: String, createdAt: Int64) throws -> Int64 {
    try db.run(
        "INSERT INTO days (date, created_at, target_minutes) VALUES (?, ?, ?)",
        [.text(date), .integer(createdAt), .integer(480)]
    )
    let dayID = db.lastInsertRowID
    try db.run(
        """
        INSERT INTO segments (day_id, type, started_at, ended_at, created_at, updated_at)
        VALUES (?, 'work', ?, ?, ?, ?)
        """,
        [.integer(dayID), .integer(createdAt), .integer(createdAt + 3_600_000),
         .integer(createdAt), .integer(createdAt)]
    )
    return dayID
}

private func uuids(_ db: Database, _ table: String, orderBy: String) throws -> [String] {
    try db.query("SELECT uuid FROM \(table) ORDER BY \(orderBy)") { $0.text(0) }
}

@Suite struct SchemaUpgradeToV2 {
    @Test func upgradesAV1StoreAndRecordsTheNewVersion() throws {
        let db = try openV1Store()
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)

        try runMigrations(db)

        #expect(try readSchemaVersion(db) == CURRENT_SCHEMA_VERSION)
        #expect(CURRENT_SCHEMA_VERSION == 4)
    }

    @Test func backfillsAUuidOnEveryExistingRow() throws {
        let db = try openV1Store()
        for (i, date) in ["2026-08-01", "2026-08-02", "2026-08-03"].enumerated() {
            try seedDay(db, date: date, createdAt: 1_785_000_000_000 + Int64(i) * 86_400_000)
        }

        try runMigrations(db)

        let dayIDs = try uuids(db, "days", orderBy: "id")
        let segIDs = try uuids(db, "segments", orderBy: "id")
        #expect(dayIDs.count == 3)
        #expect(segIDs.count == 3)
        #expect(!dayIDs.contains { $0.isEmpty })
        #expect(Set(dayIDs + segIDs).count == 6, "ids must be unique across every row")
    }

    /// Version nibble 7 and variant bits 10, per RFC 9562. Not pedantry: a client
    /// that parses these expects a v7, and the server sorts on the assumption.
    @Test func backfilledIdsAreShapedLikeUuidV7() throws {
        let db = try openV1Store()
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)
        try runMigrations(db)

        let id = try uuids(db, "days", orderBy: "id")[0]
        let chars = Array(id)

        #expect(id.count == 36)
        #expect(chars[8] == "-" && chars[13] == "-" && chars[18] == "-" && chars[23] == "-")
        #expect(chars[14] == "7", "version nibble")
        #expect("89ab".contains(chars[19]), "variant nibble was \(chars[19])")
        #expect(id.lowercased() == id, "hex must be lower case")
    }

    /// The timestamp is seeded from the row's own created_at, so lexical order over
    /// the ids reproduces the order the rows were made. That is what lets a
    /// lifetime of backfilled history reach the server already in sequence.
    @Test func backfilledIdsSortIntoCreationOrder() throws {
        let db = try openV1Store()
        // Inserted newest-first, so row id order is the opposite of time order.
        try seedDay(db, date: "2026-08-03", createdAt: 1_785_200_000_000)
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)
        try seedDay(db, date: "2026-08-02", createdAt: 1_785_100_000_000)

        try runMigrations(db)

        let byTime = try uuids(db, "days", orderBy: "created_at")
        #expect(byTime == byTime.sorted(), "ids must sort chronologically as text")

        // And the prefix really is the timestamp, not just coincidentally ordered.
        let first = try db.queryOne(
            "SELECT uuid, created_at FROM days ORDER BY created_at LIMIT 1"
        ) { ($0.text(0), $0.int64(1)) }
        let (id, createdAt) = try #require(first)
        // `ll` matters: %x takes a 32-bit unsigned, which would silently truncate an
        // epoch-millisecond timestamp to its low half.
        let hex = String(format: "%012llx", createdAt)
        #expect(id.prefix(8) == hex.prefix(8))
        #expect(id.dropFirst(9).prefix(4) == hex.dropFirst(8).prefix(4))
    }

    /// History that predates sync has never been sent, so all of it must go up on
    /// the first sync. Defaulting to clean would silently strand it.
    @Test func existingRowsStartDirtyAndUnacknowledged() throws {
        let db = try openV1Store()
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)

        try runMigrations(db)

        let row = try db.queryOne(
            "SELECT dirty, server_seq IS NULL, deleted_at IS NULL FROM segments"
        ) { ($0.int(0), $0.int(1), $0.int(2)) }
        let (dirty, unacked, alive) = try #require(row)
        #expect(dirty == 1)
        #expect(unacked == 1, "server_seq must start NULL — nothing is acknowledged yet")
        #expect(alive == 1, "deleted_at must start NULL")
    }

    @Test func givesDaysAnUpdatedAtSeededFromCreatedAt() throws {
        let db = try openV1Store()
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)

        try runMigrations(db)

        let row = try db.queryOne("SELECT created_at, updated_at FROM days") {
            ($0.int64(0), $0.int64(1))
        }
        let (created, updated) = try #require(row)
        #expect(updated == created)
    }

    @Test func createsExactlyOneSyncStateRowWithADeviceId() throws {
        let db = try openV1Store()
        try runMigrations(db)

        let row = try db.queryOne("SELECT count(*), max(device_id), max(cursor) FROM sync_state") {
            ($0.int(0), $0.optionalText(1), $0.int64(2))
        }
        let (count, deviceID, cursor) = try #require(row)
        #expect(count == 1)
        #expect(cursor == 0, "a fresh store has pulled nothing")
        #expect(try #require(deviceID).count == 36)

        // The CHECK, not a convention, is what keeps it to one row.
        #expect(throws: (any Error).self) {
            try db.run("INSERT INTO sync_state (id, device_id) VALUES (2, 'x')")
        }
    }

    @Test func refusesTwoRowsSharingAUuid() throws {
        let db = try openV1Store()
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)
        try runMigrations(db)

        let taken = try uuids(db, "days", orderBy: "id")[0]
        #expect(throws: (any Error).self) {
            try db.run(
                "INSERT INTO days (date, created_at, target_minutes, uuid) VALUES (?, ?, ?, ?)",
                [.text("2026-09-09"), .integer(1), .integer(480), .text(taken)]
            )
        }
    }

    /// The app is killed mid-upgrade, or simply launched twice. Neither may mint a
    /// second identity for a row that already has one.
    @Test func runningTwiceChangesNothing() throws {
        let db = try openV1Store()
        try seedDay(db, date: "2026-08-01", createdAt: 1_785_000_000_000)

        try runMigrations(db)
        let before = try uuids(db, "days", orderBy: "id") + uuids(db, "segments", orderBy: "id")
        let deviceBefore = try db.queryOne("SELECT device_id FROM sync_state") { $0.text(0) }

        try runMigrations(db)
        let after = try uuids(db, "days", orderBy: "id") + uuids(db, "segments", orderBy: "id")
        let deviceAfter = try db.queryOne("SELECT device_id FROM sync_state") { $0.text(0) }

        #expect(before == after)
        #expect(deviceBefore == deviceAfter)
        #expect(try readSchemaVersion(db) == CURRENT_SCHEMA_VERSION)
    }

    @Test func upgradesAnEmptyStoreFromScratch() throws {
        let db = try Database(path: ":memory:")
        try db.execute("PRAGMA foreign_keys = ON")

        try runMigrations(db)

        #expect(try readSchemaVersion(db) == CURRENT_SCHEMA_VERSION)
        let count = try db.queryOne("SELECT count(*) FROM sync_state") { $0.int(0) }
        #expect(count == 1)
    }

    /// A v2 file must still be refused by a build that only knows v1 — the guard
    /// that keeps a downgrade from writing old-shaped rows into a new file.
    @Test func stillRefusesAFileFromANewerBuild() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        try db.run("INSERT INTO schema_version (version) VALUES (?)",
                   [.integer(Int64(CURRENT_SCHEMA_VERSION + 1))])

        #expect(throws: SchemaTooNewError.self) {
            try runMigrations(db)
        }
    }
}

/// Migration 3 — history stranded by a writer that never minted ids.
///
/// Migration 2 backfilled what existed when it ran, and the inserts in `Repository`
/// were supposed to mint their own from then on. They did not name the column, so
/// every row created in between carries `uuid = NULL` — queued by `dirty` and skipped
/// by `pendingPush`, which requires both. This is the rescue for those rows, and it
/// runs against files holding somebody's real hours.
@Suite struct StrandedRowBackfill {
    /// A store already at v2 — so migration 2's own backfill has been and gone — with
    /// rows added afterwards by the writer that forgot the column. Exactly the shape
    /// of every installed store before the fix.
    private func openV2StoreWithStrandedRows() throws -> Database {
        let db = try Database(path: ":memory:")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        try migrations[0].up(db)
        try migrations[1].up(db)
        try db.run("INSERT INTO schema_version (version) VALUES (2)")

        // Written the way the old writer wrote: no uuid named at all.
        try db.run(
            "INSERT INTO days (date, created_at, target_minutes) VALUES ('2026-08-01', 1000, 480)")
        let dayID = db.lastInsertRowID
        try db.run(
            """
            INSERT INTO segments (day_id, type, started_at, ended_at, created_at, updated_at)
            VALUES (?, 'work', 2000, 5000, 2000, 2000)
            """,
            [.integer(dayID)]
        )
        return db
    }

    @Test func strandedRowsGetAnIdentityAndAreQueued() throws {
        let db = try openV2StoreWithStrandedRows()
        #expect(try db.queryOne("SELECT count(*) FROM days WHERE uuid IS NULL") { $0.int(0) } == 1)
        #expect(try db.queryOne("SELECT count(*) FROM segments WHERE uuid IS NULL") { $0.int(0) } == 1)

        try runMigrations(db)

        #expect(try db.queryOne("SELECT count(*) FROM days WHERE uuid IS NULL") { $0.int(0) } == 0)
        #expect(try db.queryOne("SELECT count(*) FROM segments WHERE uuid IS NULL") { $0.int(0) } == 0)
        // Stranded rows were never sendable, so they cannot have been acknowledged —
        // whatever `dirty` said before, every one of them still has to go up.
        #expect(try db.queryOne("SELECT count(*) FROM days WHERE dirty = 1") { $0.int(0) } == 1)
        #expect(try db.queryOne("SELECT count(*) FROM segments WHERE dirty = 1") { $0.int(0) } == 1)
    }

    /// Seeded from each row's own `created_at`, as migration 2 does, so a lifetime of
    /// rescued history reaches the server in the order it was lived rather than all
    /// bearing the instant of the upgrade.
    @Test func backfilledIdsSortInTheOrderTheRowsWereMade() throws {
        let db = try openV2StoreWithStrandedRows()
        try db.run(
            "INSERT INTO days (date, created_at, target_minutes) VALUES ('2026-07-01', 500, 480)")
        try runMigrations(db)

        let ordered = try db.query("SELECT uuid FROM days ORDER BY created_at") { $0.text(0) }
        #expect(ordered.count == 2)
        #expect(ordered == ordered.sorted(), "UUIDv7 ids must sort with their timestamps")
    }

    /// A row the server has already acknowledged must not be dragged back into the
    /// queue by the rescue — it would be pushed a second time for no reason.
    @Test func rowsTheServerAlreadyKnowsAreLeftAlone() throws {
        let db = try openV2StoreWithStrandedRows()
        try db.run("UPDATE days SET uuid = 'known', server_seq = 42, dirty = 0")

        try runMigrations(db)

        let (uuid, dirty) = try #require(
            db.queryOne("SELECT uuid, dirty FROM days") { ($0.text(0), $0.int(1)) }
        )
        #expect(uuid == "known", "an acknowledged row must keep its identity")
        #expect(dirty == 0, "and must not be queued again")
    }
}
