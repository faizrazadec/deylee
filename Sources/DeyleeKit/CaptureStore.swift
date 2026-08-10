import Foundation

/// One screen capture, as the store holds it.
///
/// `bytes` is the encoded image. It is deliberately not loaded by the listing calls —
/// a day of captures is tens of megabytes and a Settings list wants none of it — so
/// ``CaptureSummary`` exists for browsing and this type for the one image on screen.
public struct Capture: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let uuid: String
    public let dayDate: DateKey
    public let segmentID: Int64?
    public let capturedAt: EpochMs
    public let width: Int
    public let height: Int
    public let bytes: Data
}

/// A capture without its image, for lists and counts.
public struct CaptureSummary: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let uuid: String
    public let dayDate: DateKey
    public let capturedAt: EpochMs
    public let byteCount: Int
}

/// Screen captures, held in the encrypted store.
///
/// Only present when the user has switched capture on; nothing here runs otherwise.
/// See `PRODUCT.md` §3 for the conditions that governs — the ones that matter to this
/// file are that the images are encrypted at rest because they live in the SQLCipher
/// database, and that deleting them is something the user can do at any moment and
/// which must reach every other device.
extension Repository {
    /// Record one capture. Returns the row id.
    ///
    /// `dirty = 1` by default, so it joins the existing push queue with no separate
    /// outbox. A capture taken while signed out simply waits, exactly as a segment
    /// does.
    @discardableResult
    public func insertCapture(
        dayDate: DateKey,
        segmentID: Int64?,
        capturedAt: EpochMs,
        width: Int,
        height: Int,
        bytes: Data,
        now: EpochMs
    ) throws -> Int64 {
        // The timestamp is interpolated rather than bound because `uuidV7SQL` names its
        // argument twice: a `?` there becomes two placeholders, silently shifting every
        // later binding by one. It is an Int64 this code produced, not input, so there
        // is nothing to inject — and migration 2 seeds ids the same way.
        try db.run(
            """
            INSERT INTO captures
                (uuid, day_date, segment_id, captured_at, width, height, bytes,
                 created_at, updated_at, dirty)
            VALUES (\(uuidV7SQL(millis: "\(capturedAt)")), ?, ?, ?, ?, ?, ?, ?, ?, 1)
            """,
            [
                .text(dayDate.description),
                segmentID.map { Database.Value.integer($0) } ?? .null,
                .integer(capturedAt),
                .integer(Int64(width)),
                .integer(Int64(height)),
                .blob(bytes),
                .integer(now),
                .integer(now),
            ]
        )
        return db.lastInsertRowID
    }

    /// Every live capture for a day, newest first, without the images.
    public func captureSummaries(on date: DateKey) throws -> [CaptureSummary] {
        try db.query(
            """
            SELECT id, uuid, day_date, captured_at, length(bytes)
              FROM captures
             WHERE day_date = ? AND deleted_at IS NULL
             ORDER BY captured_at DESC
            """,
            [.text(date.description)]
        ) { row in
            CaptureSummary(
                id: row.int64(0),
                uuid: row.text(1),
                dayDate: DateKey(row.text(2)) ?? date,
                capturedAt: row.int64(3),
                byteCount: row.int(4)
            )
        }
    }

    /// One capture with its image.
    public func capture(id: Int64) throws -> Capture? {
        try db.queryOne(
            """
            SELECT id, uuid, day_date, segment_id, captured_at, width, height, bytes
              FROM captures
             WHERE id = ? AND deleted_at IS NULL
            """,
            [.integer(id)]
        ) { row in
            Capture(
                id: row.int64(0),
                uuid: row.text(1),
                dayDate: DateKey(row.text(2)) ?? DateKey("1970-01-01")!,
                segmentID: row.optionalInt64(3),
                capturedAt: row.int64(4),
                width: row.int(5),
                height: row.int(6),
                bytes: row.blob(7)
            )
        }
    }

    /// How much of the store the live captures account for.
    public func captureFootprint() throws -> (count: Int, bytes: Int) {
        let row = try db.queryOne(
            "SELECT count(*), coalesce(sum(length(bytes)), 0) FROM captures WHERE deleted_at IS NULL"
        ) { ($0.int(0), $0.int(1)) }
        return row ?? (0, 0)
    }

    /// Tombstone one capture and release its bytes immediately.
    ///
    /// The row survives as a tombstone so the deletion travels — a device that already
    /// pulled this capture must be told to drop it, and a removed row cannot say
    /// anything. But the *image* is cleared here rather than kept until the tombstone
    /// syncs: a person deleting a screenshot means the picture, not the bookkeeping,
    /// and holding it any longer would be doing the opposite of what they asked.
    @discardableResult
    public func deleteCapture(_ id: Int64, now: EpochMs) throws -> Bool {
        try db.run(
            """
            UPDATE captures
               SET deleted_at = ?, updated_at = ?, dirty = 1, bytes = zeroblob(0)
             WHERE id = ? AND deleted_at IS NULL
            """,
            [.integer(now), .integer(now), .integer(id)]
        )
        return db.changes > 0
    }

    /// Tombstone every live capture. What the Settings button calls.
    @discardableResult
    public func deleteAllCaptures(now: EpochMs) throws -> Int {
        try db.run(
            """
            UPDATE captures
               SET deleted_at = ?, updated_at = ?, dirty = 1, bytes = zeroblob(0)
             WHERE deleted_at IS NULL
            """,
            [.integer(now), .integer(now)]
        )
        return db.changes
    }

    /// Tombstone captures older than `days`, so the store cannot grow without bound.
    ///
    /// Time-based rather than size-based on purpose: "keep the last fortnight" is a
    /// sentence somebody can hold in their head and predict, where "keep 2 GB" means
    /// the oldest capture disappears at a moment determined by screen resolution.
    @discardableResult
    public func sweepCaptures(olderThan days: Int, now: EpochMs) throws -> Int {
        let cutoff = now - EpochMs(days) * 86_400_000
        try db.run(
            """
            UPDATE captures
               SET deleted_at = ?, updated_at = ?, dirty = 1, bytes = zeroblob(0)
             WHERE deleted_at IS NULL AND captured_at < ?
            """,
            [.integer(now), .integer(now), .integer(cutoff)]
        )
        return db.changes
    }
}
