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
                message: "This store already belongs to another account."
            )
        }
        try db.run("UPDATE sync_state SET user_id = ? WHERE id = 1", [.text(userID)])
    }

    /// Hand this machine's history to a different account, keeping every row.
    ///
    /// `claimLocalData` refuses the switch because it cannot know whether the person
    /// at the keyboard means it. This is the deliberate way through, and callers must
    /// only reach it once that has been confirmed — nothing here asks.
    ///
    /// Every live row is given a **fresh uuid**, and that is the part which is not
    /// optional. A uuid is the row's identity on the server, where `days.id` and
    /// `segments.id` are global primary keys rather than keys within an account.
    /// Pushing an inherited uuid would therefore land in the server's
    /// `ON CONFLICT (id) DO UPDATE`, against a row the *previous* owner still owns:
    /// last-write-wins would overwrite their history with this machine's copy, while
    /// the new owner — whose pull is filtered by `user_id` — would never see the row
    /// arrive at all. Fresh ids make this an honest copy into the new account and
    /// leave the old one exactly as it was.
    ///
    /// The cursor resets for a related reason: it counts the previous owner's place
    /// in the server's sequence, which says nothing about the new account. Keeping it
    /// would skip every row already in that account's history.
    public func transferLocalData(toUserID userID: String) throws {
        try db.transaction {
            // Seeded from each row's own created_at, exactly as the backfill does, so
            // re-identified history still sorts into the order it was lived in.
            //
            // `updated_at` is deliberately left alone. It is the client's claim about
            // when the edit was made, and these rows were not edited — they were
            // re-identified. Nothing is lost by keeping it honest, because a fresh
            // uuid always takes the server's INSERT branch and never has a
            // last-write-wins comparison to win.
            for table in ["days", "segments"] {
                try db.run("""
                    UPDATE \(table)
                    SET uuid = \(uuidV7SQL(millis: "created_at")),
                        dirty = 1,
                        server_seq = NULL
                    WHERE deleted_at IS NULL
                    """)

                // Tombstones described rows in the previous account. The new account
                // never had them, so there is nothing to delete there — they stay on
                // disk as this store's own record and are never pushed.
                try db.run(
                    "UPDATE \(table) SET dirty = 0, server_seq = NULL WHERE deleted_at IS NOT NULL"
                )
            }

            try db.run(
                """
                UPDATE sync_state
                SET user_id = ?, cursor = 0, last_synced_at = NULL
                WHERE id = 1
                """,
                [.text(userID)]
            )
        }
    }

    /// The account this store belongs to, when it is not the one signing in.
    ///
    /// Nil when the store is unclaimed or already belongs to `userID` — in both cases
    /// `claimLocalData` will simply succeed and there is nothing to ask about.
    public func ownerToDisplace(signingInAs userID: String) throws -> String? {
        guard let existing = try syncState().userID, existing != userID else { return nil }
        return existing
    }

    public func advanceCursor(to cursor: Int64, at now: EpochMs) throws {
        // Never backwards. A stale response arriving late must not rewind a cursor
        // that has since moved on, which would re-deliver rows already applied.
        try db.run(
            "UPDATE sync_state SET cursor = MAX(cursor, ?), last_synced_at = ? WHERE id = 1",
            [.integer(cursor), .integer(now)]
        )
    }

    /// Rewind to the start and pull everything again.
    ///
    /// The one case where going backwards is right: the server has been restored from
    /// a backup, its sequence has rewound, and this device's cursor is ahead of any
    /// row the server can offer. `WHERE seq > cursor` then matches nothing for ever —
    /// a client that pulls silently and indefinitely nothing at all.
    ///
    /// Deliberately not `advanceCursor(to: 0)`, which is `MAX(cursor, 0)` and does
    /// nothing whatsoever. Re-delivery is safe: rows are matched by uuid and upserted.
    public func rewindCursor(at now: EpochMs) throws {
        try db.run(
            "UPDATE sync_state SET cursor = 0, last_synced_at = ? WHERE id = 1",
            [.integer(now)]
        )
    }

    // MARK: Push

    /// Rows this device has that the server has not acknowledged.
    public func pendingPush(limit: Int = 500) throws -> PendingPush {
        let days = try db.query(
            """
            SELECT uuid, date, target_minutes, ended_at, created_at, updated_at, deleted_at
            FROM days
            WHERE dirty = 1 AND uuid IS NOT NULL
              AND (rejected_at IS NULL OR rejected_at < updated_at)
            ORDER BY created_at LIMIT ?
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
            WHERE s.dirty = 1 AND s.uuid IS NOT NULL
              AND (s.rejected_at IS NULL OR s.rejected_at < s.updated_at)
            ORDER BY s.started_at LIMIT ?
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

    /// Record that the server refused a row, so it stops being offered.
    ///
    /// Stamped with the row's own `updated_at`, not with now. The mark says "this
    /// version was refused", so editing the row moves `updated_at` past it and the
    /// row rejoins the queue without anything having to clear the mark — which is the
    /// only resolution there is, since every reason the server gives is structural.
    public func markRejected(
        _ rejected: [(uuid: String, updatedAt: EpochMs, code: String)], table: SyncTable
    ) throws {
        guard !rejected.isEmpty else { return }
        try db.transaction {
            for row in rejected {
                try db.run(
                    """
                    UPDATE \(table.rawValue) SET rejected_at = ?, rejection_code = ?
                     WHERE uuid = ? AND updated_at = ?
                    """,
                    [.integer(row.updatedAt), .text(row.code), .text(row.uuid),
                     .integer(row.updatedAt)]
                )
            }
        }
    }

    /// A segment the server refused, addressed the way the app already holds it.
    ///
    /// By local `id` rather than `uuid` because that is what a `Segment` on screen
    /// carries, and the date because finding the row is the whole difficulty: knowing
    /// that *something* was refused is no use without knowing which day to open.
    public struct RejectedSegment: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let date: DateKey
        public let code: String

        public init(id: Int64, date: DateKey, code: String) {
            self.id = id
            self.date = date
            self.code = code
        }
    }

    /// Every segment the server refused and will refuse again, oldest first.
    ///
    /// Same condition as the one `pendingPush` uses to skip them, so the two can never
    /// disagree about which rows are stuck: a row marked against a version older than
    /// its current one has been edited since and is queued again, not stuck.
    public func rejectedSegments() throws -> [RejectedSegment] {
        try db.query(
            """
            SELECT s.id, d.date, s.rejection_code
            FROM segments s JOIN days d ON d.id = s.day_id
            WHERE s.rejected_at IS NOT NULL AND s.rejected_at >= s.updated_at
              AND s.deleted_at IS NULL
            ORDER BY s.started_at
            """
        ) { row in
            RejectedSegment(
                id: row.int64(0),
                // A date that will not parse cannot be navigated to, and the row is
                // already in a bad way; the epoch is a visible wrong answer rather
                // than a crash.
                date: DateKey(row.text(1)) ?? DateKey(year: 1970, month: 1, day: 1)!,
                code: row.text(2)
            )
        }
    }

    /// Rows the server refused and will refuse again, for anything that wants to show
    /// them. Nothing does yet — see the note on `markRejected`.
    public func rejectedRows(table: SyncTable) throws -> [(uuid: String, code: String)] {
        try db.query(
            """
            SELECT uuid, rejection_code FROM \(table.rawValue)
             WHERE rejected_at IS NOT NULL AND rejected_at >= updated_at
               AND deleted_at IS NULL
            """
        ) { ($0.text(0), $0.text(1)) }
    }

    // MARK: Quarantine

    /// A row the server sent that this build could not read.
    public struct QuarantinedRow: Sendable, Equatable {
        public let uuid: String
        public let table: SyncTable
        public let seq: Int64
        /// The row exactly as it arrived. Kept verbatim on purpose: the whole reason it
        /// is here is that this version does not know what the fields mean, so anything
        /// this version reshapes on the way in is a guess.
        public let payload: String
        public let firstSeen: EpochMs

        public init(uuid: String, table: SyncTable, seq: Int64, payload: String, firstSeen: EpochMs) {
            self.uuid = uuid
            self.table = table
            self.seq = seq
            self.payload = payload
            self.firstSeen = firstSeen
        }
    }

    /// Set a row aside instead of dropping it.
    ///
    /// The cursor may then advance past it without losing it, which is the point: it
    /// only moves forwards and the protocol has no way to ask for one row again, so a
    /// row skipped before this existed was a row deleted on this device for ever.
    ///
    /// Keyed by uuid, so a later version of the same row replaces the earlier one —
    /// there is no value in replaying a stale copy of something the server has since
    /// changed. `first_seen` survives the replacement so the age of the problem is
    /// still readable.
    public func quarantine(_ rows: [QuarantinedRow]) throws {
        guard !rows.isEmpty else { return }
        try db.transaction {
            for row in rows {
                try db.run(
                    """
                    INSERT INTO sync_quarantine (uuid, table_name, seq, payload, first_seen)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(uuid) DO UPDATE SET
                        table_name = excluded.table_name,
                        seq        = excluded.seq,
                        payload    = excluded.payload
                    """,
                    [.text(row.uuid), .text(row.table.rawValue), .integer(row.seq),
                     .text(row.payload), .integer(row.firstSeen)]
                )
            }
        }
    }

    /// Everything set aside, oldest first, so a replay applies them in the order the
    /// server issued them.
    public func quarantined() throws -> [QuarantinedRow] {
        try db.query(
            """
            SELECT uuid, table_name, seq, payload, first_seen
            FROM sync_quarantine ORDER BY seq
            """
        ) { row in
            QuarantinedRow(
                uuid: row.text(0),
                table: SyncTable(rawValue: row.text(1)) ?? .days,
                seq: row.int64(2),
                payload: row.text(3),
                firstSeen: row.int64(4)
            )
        }
    }

    /// Forget rows that have since been applied.
    public func releaseFromQuarantine(_ uuids: [String]) throws {
        guard !uuids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: uuids.count).joined(separator: ",")
        try db.run(
            "DELETE FROM sync_quarantine WHERE uuid IN (\(placeholders))",
            uuids.map { .text($0) }
        )
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
    /// Returns the number of rows it could not apply. Zero is the only healthy answer;
    /// anything else means the local schema refused something the server considers
    /// current, and that row is now missing until the server sends it again.
    @discardableResult
    public func applyRemote(days: [SyncDay], segments: [SyncSegment], serverSeq: Int64) throws -> Int {
        var refused = 0
        try db.transaction {
            for day in days {
                // Each row in its own savepoint, as the server already does per change.
                // A page applied all-or-nothing is what turns one unusable row into a
                // permanent stall: the batch rolls back, the cursor stays put — quite
                // correctly, since nothing was applied — and the next sync fetches the
                // same page, fails on the same row, and repeats every two minutes for
                // ever. Losing one row is bad; losing sync is worse.
                do {
                    try db.transaction {
                        // A tombstone for a row this device has never held is nothing to
                        // do. Inserting it would materialise a deleted day that only
                        // stands in the way of the live one for the same date.
                        if day.deletedAt != nil, try !knowsDay(uuid: day.uuid) { return }
                        try adoptServerDayIdentity(day)
                        try upsert(day, serverSeq: serverSeq)
                    }
                } catch {
                    refused += 1
                }
            }

            for segment in segments {
                do {
                    try db.transaction { try upsert(segment, serverSeq: serverSeq) }
                } catch {
                    refused += 1
                }
            }
        }
        return refused
    }

    private func knowsDay(uuid: String) throws -> Bool {
        try db.queryOne("SELECT 1 FROM days WHERE uuid = ?", [.text(uuid)]) { _ in true } ?? false
    }

    /// Give the local row for this date the identity the server uses for it.
    ///
    /// `days.date` is unique locally, so a day arriving under a uuid this device has
    /// never seen — for a date it already has under a different one — cannot simply be
    /// inserted. Both rows are the same calendar day; only the names differ.
    ///
    /// The two names arise constantly. Two devices offline on the same morning each
    /// mint their own id for it. `transferLocalData` re-issues every local row, then
    /// resets the cursor, so the next pull delivers the whole account under ids this
    /// machine has never seen. A segment arriving before its day makes a placeholder
    /// with an invented id, which the real day then contradicts.
    ///
    /// Adopting rather than choosing: the server has already decided which uuid owns
    /// this date, and following that is what makes every device agree. The local row
    /// keeps its integer id, so its segments stay attached without being re-pointed.
    private func adoptServerDayIdentity(_ day: SyncDay) throws {
        // Only a live row lays claim to a date, and only when this device does not
        // already hold that uuid somewhere — renaming onto a name already in use
        // trades this collision for one on the uuid index.
        try db.run(
            """
            UPDATE days SET uuid = ?
             WHERE date = ?
               AND (uuid IS NULL OR uuid <> ?)
               AND NOT EXISTS (SELECT 1 FROM days other WHERE other.uuid = ?)
            """,
            [.text(day.uuid), .text(day.date.description), .text(day.uuid), .text(day.uuid)]
        )
    }

    private func upsert(_ day: SyncDay, serverSeq: Int64) throws {
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

    private func upsert(_ segment: SyncSegment, serverSeq: Int64) throws {
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
