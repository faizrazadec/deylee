import Foundation

/// The local half of the sync protocol: what is waiting to go up, and how what
/// comes down is applied.
///
/// Platform-free on purpose. This file knows nothing about HTTP, JSON or tokens —
/// it deals only in rows — so the whole push/pull decision can be tested against a
/// real SQLite file without a server, a network or a signed-in user.
///
/// See `docs/SYNC_PROTOCOL.md`, which this must not contradict.

// MARK: - Row shapes

/// A segment in the shape the protocol moves it: identified by uuid, and carrying
/// the local calendar day rather than a foreign key, because row ids are per-file
/// and mean nothing on another device.
public struct SyncSegment: Sendable, Equatable {
    public var uuid: String
    public var dayDate: DateKey
    public var type: SegmentType
    public var startedAt: EpochMs
    public var endedAt: EpochMs?
    public var note: String?
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var deletedAt: EpochMs?

    public init(
        uuid: String, dayDate: DateKey, type: SegmentType,
        startedAt: EpochMs, endedAt: EpochMs? = nil, note: String? = nil,
        createdAt: EpochMs, updatedAt: EpochMs, deletedAt: EpochMs? = nil
    ) {
        self.uuid = uuid
        self.dayDate = dayDate
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncDay: Sendable, Equatable {
    public var uuid: String
    public var date: DateKey
    public var targetMinutes: Int
    public var endedAt: EpochMs?
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var deletedAt: EpochMs?

    public init(
        uuid: String, date: DateKey, targetMinutes: Int, endedAt: EpochMs? = nil,
        createdAt: EpochMs, updatedAt: EpochMs, deletedAt: EpochMs? = nil
    ) {
        self.uuid = uuid
        self.date = date
        self.targetMinutes = targetMinutes
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// What this device has to say. Days precede segments within one batch so a server
/// that ever did enforce ordering would see the day first; the server does not
/// require it, but sending them jumbled would be gratuitous.
public struct PendingPush: Sendable, Equatable {
    public var days: [SyncDay]
    public var segments: [SyncSegment]

    public var isEmpty: Bool { days.isEmpty && segments.isEmpty }
    public var count: Int { days.count + segments.count }

    public init(days: [SyncDay] = [], segments: [SyncSegment] = []) {
        self.days = days
        self.segments = segments
    }
}

/// This installation's place in the protocol.
public struct SyncState: Sendable, Equatable {
    public var deviceID: String
    public var userID: String?
    /// Highest `seq` durably stored here. Zero means nothing has been pulled.
    public var cursor: Int64
    public var lastSyncedAt: EpochMs?

    public init(deviceID: String, userID: String?, cursor: Int64, lastSyncedAt: EpochMs?) {
        self.deviceID = deviceID
        self.userID = userID
        self.cursor = cursor
        self.lastSyncedAt = lastSyncedAt
    }
}

// MARK: - Store

extension Repository {
    // MARK: Sync state

    public func syncState() throws -> SyncState {
        let row = try db.queryOne(
            "SELECT device_id, user_id, cursor, last_synced_at FROM sync_state WHERE id = 1"
        ) { ($0.text(0), $0.optionalText(1), $0.int64(2), $0.optionalInt64(3)) }
        guard let row else {
            throw MutationError(code: .notFound, message: "The sync state row is missing.")
        }
        return SyncState(deviceID: row.0, userID: row.1, cursor: row.2, lastSyncedAt: row.3)
    }

    /// Claim every local row for a user, on first sign-in.
    ///
    /// History written before anyone signed in has no owner, and it must not be
    /// silently abandoned. Everything is already `dirty`, so simply recording the
    /// user is enough to make the next push carry all of it up.
    ///
    /// A *different* user signing in is refused rather than merged: two people's
    /// hours in one file cannot be told apart afterwards.
    public func claimLocalData(forUserID userID: String) throws {
        let current = try syncState()
        if let existing = current.userID, existing != userID {
            throw MutationError(
                code: .openSegmentConflict,
                message: "This store already belongs to another account. Sign out first."
            )
        }
        try db.run("UPDATE sync_state SET user_id = ? WHERE id = 1", [.text(userID)])
    }

    public func advanceCursor(to cursor: Int64, at now: EpochMs) throws {
        // Never backwards. A stale response arriving late must not rewind a cursor
        // that has since moved on, which would re-deliver rows already applied.
        try db.run(
            "UPDATE sync_state SET cursor = MAX(cursor, ?), last_synced_at = ? WHERE id = 1",
            [.integer(cursor), .integer(now)]
        )
    }

    // MARK: Push

    /// Rows this device has that the server has not acknowledged.
    public func pendingPush(limit: Int = 500) throws -> PendingPush {
        let days = try db.query(
            """
            SELECT uuid, date, target_minutes, ended_at, created_at, updated_at, deleted_at
            FROM days WHERE dirty = 1 AND uuid IS NOT NULL ORDER BY created_at LIMIT ?
            """,
            [.integer(Int64(limit))]
        ) { row in
            SyncDay(
                uuid: row.text(0), date: DateKey(row.text(1)) ?? .init(year: 1970, month: 1, day: 1)!,
                targetMinutes: row.int(2),
                endedAt: row.optionalInt64(3), createdAt: row.int64(4),
                updatedAt: row.optionalInt64(5) ?? row.int64(4), deletedAt: row.optionalInt64(6)
            )
        }

        let remaining = max(0, limit - days.count)
        let segments = remaining == 0 ? [] : try db.query(
            """
            SELECT s.uuid, d.date, s.type, s.started_at, s.ended_at, s.note,
                   s.created_at, s.updated_at, s.deleted_at
            FROM segments s JOIN days d ON d.id = s.day_id
            WHERE s.dirty = 1 AND s.uuid IS NOT NULL ORDER BY s.started_at LIMIT ?
            """,
            [.integer(Int64(remaining))]
        ) { row in
            SyncSegment(
                uuid: row.text(0),
                dayDate: DateKey(row.text(1)) ?? .init(year: 1970, month: 1, day: 1)!,
                type: SegmentType(rawValue: row.text(2)) ?? .work,
                startedAt: row.int64(3), endedAt: row.optionalInt64(4),
                note: row.optionalText(5), createdAt: row.int64(6),
                updatedAt: row.int64(7), deletedAt: row.optionalInt64(8)
            )
        }

        return PendingPush(days: days, segments: segments)
    }

    /// Mark rows the server accepted.
    ///
    /// Clearing `dirty` only for rows whose `updated_at` still matches what was sent
    /// is what makes a slow round trip safe: if the user edited the row while the
    /// request was in flight, it stays dirty and goes up again. Clearing
    /// unconditionally would drop that edit on the floor.
    public func markPushed(_ acknowledged: [(uuid: String, updatedAt: EpochMs)], table: SyncTable) throws {
        guard !acknowledged.isEmpty else { return }
        try db.transaction {
            for row in acknowledged {
                try db.run(
                    "UPDATE \(table.rawValue) SET dirty = 0 WHERE uuid = ? AND updated_at = ?",
                    [.text(row.uuid), .integer(row.updatedAt)]
                )
            }
        }
    }

    // MARK: Pull

    /// Apply rows from the server.
    ///
    /// Written with `dirty = 0`: these came *from* the server, and marking them dirty
    /// would push them straight back, forever.
    ///
    /// Last-write-wins is applied here as well as on the server, because a client
    /// must not let an older remote row overwrite a newer local edit made while the
    /// response was in flight.
    public func applyRemote(days: [SyncDay], segments: [SyncSegment], serverSeq: Int64) throws {
        try db.transaction {
            for day in days {
                try db.run(
                    """
                    INSERT INTO days (uuid, date, created_at, ended_at, target_minutes,
                                      updated_at, deleted_at, dirty, server_seq)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
                    ON CONFLICT(uuid) DO UPDATE SET
                        date           = excluded.date,
                        ended_at       = excluded.ended_at,
                        target_minutes = excluded.target_minutes,
                        updated_at     = excluded.updated_at,
                        deleted_at     = excluded.deleted_at,
                        dirty          = 0,
                        server_seq     = excluded.server_seq
                    WHERE excluded.updated_at > days.updated_at
                    """,
                    [.text(day.uuid), .text(day.date.description), .integer(day.createdAt),
                     day.endedAt.map { .integer($0) } ?? .null, .integer(Int64(day.targetMinutes)),
                     .integer(day.updatedAt), day.deletedAt.map { .integer($0) } ?? .null,
                     .integer(serverSeq)]
                )
            }

            for segment in segments {
                // A segment can arrive before the day it belongs to — the protocol
                // delivers commit order, not dependency order — so the day is created
                // on demand rather than assumed. It is not marked dirty: a day the
                // server already knows about must not be pushed back at it.
                let dayID = try localDayID(for: segment.dayDate, createdAt: segment.createdAt)
                try db.run(
                    """
                    INSERT INTO segments (uuid, day_id, type, started_at, ended_at, note,
                                          created_at, updated_at, deleted_at, dirty, server_seq)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                    ON CONFLICT(uuid) DO UPDATE SET
                        day_id     = excluded.day_id,
                        type       = excluded.type,
                        started_at = excluded.started_at,
                        ended_at   = excluded.ended_at,
                        note       = excluded.note,
                        updated_at = excluded.updated_at,
                        deleted_at = excluded.deleted_at,
                        dirty      = 0,
                        server_seq = excluded.server_seq
                    WHERE excluded.updated_at > segments.updated_at
                    """,
                    [.text(segment.uuid), .integer(dayID), .text(segment.type.rawValue),
                     .integer(segment.startedAt), segment.endedAt.map { .integer($0) } ?? .null,
                     segment.note.map { .text($0) } ?? .null, .integer(segment.createdAt),
                     .integer(segment.updatedAt), segment.deletedAt.map { .integer($0) } ?? .null,
                     .integer(serverSeq)]
                )
            }
        }
    }

    /// The local row id for a calendar day, creating it if this device has never
    /// seen that date.
    private func localDayID(for date: DateKey, createdAt: EpochMs) throws -> Int64 {
        if let existing = try db.queryOne(
            "SELECT id FROM days WHERE date = ?", [.text(date.description)]
        ) { $0.int64(0) } {
            return existing
        }
        try db.run(
            """
            INSERT INTO days (uuid, date, created_at, updated_at, target_minutes, dirty)
            VALUES (?, ?, ?, ?, ?, 0)
            """,
            [.text(UUID().uuidString.lowercased()), .text(date.description),
             .integer(createdAt), .integer(createdAt),
             // A placeholder. This day row exists only to host an arriving segment;
             // the real target comes with the server's own day row, which overwrites
             // it. Guessing here is harmless, and refusing to guess would mean
             // dropping the segment.
             .integer(480)]
        )
        return db.lastInsertRowID
    }
}

public enum SyncTable: String, Sendable {
    case days
    case segments
}
