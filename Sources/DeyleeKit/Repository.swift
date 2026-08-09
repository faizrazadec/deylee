import Foundation

/// Every read and write of the SQLite file goes through this type.
///
/// Three invariants shape it:
///  - **No total is ever stored.** `dayDetail` / `range` derive `DayTotals` with
///    `dayTotals()`, so a crash, a manual edit or a clock change can never leave a
///    stale number behind.
///  - **Every stored segment belongs to exactly one local day.** That is why closing
///    a segment goes through `closeSegmentSplitting` instead of a plain UPDATE.
///  - **At most one segment is open app-wide**, which `findOpenSegment` relies on.
public final class Repository {
    /// Where the heartbeat records the last instant the app was known to be alive.
    public static let appStateHeartbeat = "heartbeat_at"
    /// Mirrors `segments_note_bounded` on the server. Two copies of one number, and
    /// the alternative is a row the app can create and never send.
    public static let maximumNoteLength = 2000

    // Internal rather than private: SyncStore.swift extends Repository.
    let db: Database
    private let zone: TimeZone

    public init(db: Database, in zone: TimeZone = .current) {
        self.db = db
        self.zone = zone
    }

    // MARK: - Days

    public func findDay(_ date: DateKey) throws -> Day? {
        try db.queryOne(
            "SELECT \(Self.dayColumns) FROM days WHERE date = ? AND deleted_at IS NULL",
            [.text(date.description)],
            row: Self.day
        )
    }

    /// Every row this writes carries a `uuid` and is left `dirty`.
    ///
    /// Both are what make the row visible to sync at all: the push queue selects
    /// `WHERE dirty = 1 AND uuid IS NOT NULL`, so a row missing either is queued and
    /// unsendable at the same time — it looks pending forever and never leaves the
    /// machine. `dirty` defaults to 1 in the schema; the uuid has to be minted here.
    ///
    /// UUIDv7 seeded from the row's own `created_at`, exactly as the backfill does, so
    /// ids sort in the order the rows were made and the server's pull order agrees
    /// with a client's insertion order for free.
    public func getOrCreateDay(_ date: DateKey, targetMinutes: Int, now: EpochMs) throws -> Day {
        if let existing = try findDay(date) { return existing }
        try db.run(
            """
            INSERT INTO days (uuid, date, created_at, ended_at, target_minutes, updated_at)
            VALUES (\(uuidV7SQL(millis: "\(now)")), ?, ?, NULL, ?, ?)
            """,
            [
                .text(date.description), .integer(now),
                .integer(Int64(targetMinutes)), .integer(now),
            ]
        )
        return Day(
            id: db.lastInsertRowID, date: date, createdAt: now,
            endedAt: nil, targetMinutes: targetMinutes
        )
    }

    /// `nil` clears the flag — the user pressed Start again after End Day.
    ///
    /// `dirty` and `updated_at` are set for the same reason they are on every other
    /// write here: an edit the server never hears about is an edit that silently
    /// reverts on the next device, and last-write-wins compares `updated_at`.
    @discardableResult
    public func setDayEnded(_ dayId: Int64, endedAt: EpochMs?, now: EpochMs) throws -> Day {
        try db.run(
            "UPDATE days SET ended_at = ?, updated_at = ?, dirty = 1 WHERE id = ?",
            [endedAt.map(Database.Value.integer) ?? .null, .integer(now), .integer(dayId)]
        )
        return try requireDay(dayId)
    }

    /// Re-stamps the target of an existing day. `getOrCreateDay` only ever stamps at
    /// creation, so this is the one path by which a changed preference reaches a day
    /// that has already started — and the caller is responsible for passing only that
    /// day, so a changed preference cannot rewrite history.
    @discardableResult
    public func setDayTarget(_ dayId: Int64, targetMinutes: Int, now: EpochMs) throws -> Day {
        try db.run(
            "UPDATE days SET target_minutes = ?, updated_at = ?, dirty = 1 WHERE id = ?",
            [.integer(Int64(targetMinutes)), .integer(now), .integer(dayId)]
        )
        return try requireDay(dayId)
    }

    private func requireDay(_ dayId: Int64) throws -> Day {
        guard let day = try db.queryOne(
            "SELECT \(Self.dayColumns) FROM days WHERE id = ? AND deleted_at IS NULL",
            [.integer(dayId)], row: Self.day
        ) else {
            throw RepositoryError.dayNotFound(dayId)
        }
        return day
    }

    // MARK: - Reads

    public func listSegments(dayId: Int64) throws -> [Segment] {
        try db.query(
            """
            SELECT \(Self.segmentColumns) FROM segments
             WHERE day_id = ? AND deleted_at IS NULL ORDER BY started_at ASC, id ASC
            """,
            [.integer(dayId)],
            row: Self.segment
        )
    }

    public func dayDetail(_ date: DateKey, now: EpochMs) throws -> DayDetail? {
        guard let day = try findDay(date) else { return nil }
        let segments = try listSegments(dayId: day.id)
        return DayDetail(
            day: day, segments: segments,
            totals: dayTotals(segments, date, now: now, in: zone)
        )
    }

    /// Only days that exist in the table, ascending. Gaps are the caller's problem.
    ///
    /// One pass over the range rather than a query per day: History opens on a full
    /// month, which would otherwise be 31 round trips.
    public func range(_ range: DateRange, now: EpochMs) throws -> [DayDetail] {
        let rows = try db.query(
            """
            SELECT d.id             AS day_id,
                   d.date           AS day_date,
                   d.created_at     AS day_created_at,
                   d.ended_at       AS day_ended_at,
                   d.target_minutes AS day_target_minutes,
                   s.id             AS segment_id,
                   s.day_id         AS segment_day_id,
                   s.type           AS segment_type,
                   s.started_at     AS segment_started_at,
                   s.ended_at       AS segment_ended_at,
                   s.note           AS segment_note,
                   s.created_at     AS segment_created_at,
                   s.updated_at     AS segment_updated_at
              FROM days d
              LEFT JOIN segments s ON s.day_id = d.id AND s.deleted_at IS NULL
             WHERE d.date >= ? AND d.date <= ? AND d.deleted_at IS NULL
             ORDER BY d.date ASC, s.started_at ASC, s.id ASC
            """,
            [.text(range.from.description), .text(range.to.description)]
        ) { row -> (Day, Segment?) in
            let day = Day(
                id: row.int64(0),
                date: DateKey(row.text(1)) ?? todayKey(in: self.zone),
                createdAt: row.int64(2),
                endedAt: row.optionalInt64(3),
                targetMinutes: row.int(4)
            )
            // A LEFT JOIN nulls every segment column at once for a day with no
            // segments; checking the primary key is enough to tell the two apart.
            guard let segmentId = row.optionalInt64(5) else { return (day, nil) }
            let segment = Segment(
                id: segmentId,
                dayId: row.int64(6),
                type: Self.segmentType(row.text(7)),
                startedAt: row.int64(8),
                endedAt: row.optionalInt64(9),
                note: row.optionalText(10),
                createdAt: row.int64(11),
                updatedAt: row.int64(12)
            )
            return (day, segment)
        }

        // Rows arrive grouped by day and ordered within it, so a single pass is enough.
        var grouped: [(day: Day, segments: [Segment])] = []
        for (day, segment) in rows {
            if grouped.last?.day.id != day.id {
                grouped.append((day, []))
            }
            if let segment { grouped[grouped.count - 1].segments.append(segment) }
        }

        return grouped.map { entry in
            DayDetail(
                day: entry.day, segments: entry.segments,
                totals: dayTotals(entry.segments, entry.day.date, now: now, in: zone)
            )
        }
    }

    public func segment(id: Int64) throws -> Segment? {
        try db.queryOne(
            "SELECT \(Self.segmentColumns) FROM segments WHERE id = ? AND deleted_at IS NULL",
            [.integer(id)],
            row: Self.segment
        )
    }

    /// Oldest first: if a bug ever left two rows open, resolving them oldest-first
    /// drains the backlog instead of stranding an ancient one behind a newer one.
    public func findOpenSegment() throws -> Segment? {
        try db.queryOne(
            """
            SELECT \(Self.segmentColumns) FROM segments
             WHERE ended_at IS NULL AND deleted_at IS NULL
             ORDER BY started_at ASC, id ASC LIMIT 1
            """,
            row: Self.segment
        )
    }

    // MARK: - Segment writes

    @discardableResult
    public func insertSegment(
        dayId: Int64, type: SegmentType, startedAt: EpochMs, endedAt: EpochMs?,
        note: String? = nil, now: EpochMs
    ) throws -> Segment {
        try db.run(
            """
            INSERT INTO segments
                (uuid, day_id, type, started_at, ended_at, note, created_at, updated_at)
            VALUES (\(uuidV7SQL(millis: "\(now)")), ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .integer(dayId), .text(type.rawValue), .integer(startedAt),
                endedAt.map(Database.Value.integer) ?? .null,
                note.map(Database.Value.text) ?? .null,
                .integer(now), .integer(now),
            ]
        )
        return Segment(
            id: db.lastInsertRowID, dayId: dayId, type: type,
            startedAt: startedAt, endedAt: endedAt, note: note,
            createdAt: now, updatedAt: now
        )
    }

    /// Every mutable column is written every time; the patch is merged over the
    /// current row first, which keeps this a single reusable statement rather than
    /// SQL assembled per call.
    @discardableResult
    public func updateSegmentFields(
        _ id: Int64, _ patch: UpdateSegmentInput, now: EpochMs
    ) throws -> Segment {
        guard var next = try segment(id: id) else {
            throw RepositoryError.segmentNotFound(id)
        }
        if let type = patch.type { next.type = type }
        if let startedAt = patch.startedAt { next.startedAt = startedAt }
        // A plain `if let` would swallow an explicit nil, and nil is exactly how a
        // segment is reopened or a note is cleared — hence the double optional.
        if let endedAt = patch.endedAt { next.endedAt = endedAt }
        if let note = patch.note { next.note = note }
        next.updatedAt = now

        // The server refuses a note past 2000 characters, and the local store used to
        // let one be written happily — producing a row that could never be pushed and
        // whose only symptom was a sentence in a status line. Refused at the point of
        // editing instead, where the person can still do something about it.
        if let note = next.note, note.count > Self.maximumNoteLength {
            throw MutationError(
                code: .invalidRange,
                message: "A note can be at most \(Self.maximumNoteLength) characters."
            )
        }

        try db.run(
            """
            UPDATE segments
               SET type = ?, started_at = ?, ended_at = ?, note = ?, updated_at = ?, dirty = 1
             WHERE id = ?
            """,
            [
                .text(next.type.rawValue), .integer(next.startedAt),
                next.endedAt.map(Database.Value.integer) ?? .null,
                next.note.map(Database.Value.text) ?? .null,
                .integer(now), .integer(id),
            ]
        )
        return next
    }

    /// Tombstoned, not removed.
    ///
    /// A row deleted with `DELETE` cannot be sent, because there is nothing left to
    /// send — so the delete never reaches the other devices, and the row is handed
    /// back to this one on its next pull. Deleting time and watching it return is
    /// worse than the delete not working at all.
    ///
    /// `deleted_at IS NULL` in the predicate makes this idempotent: deleting an
    /// already-deleted row changes nothing and reports false, which is what the
    /// callers checking the result mean by it.
    @discardableResult
    public func deleteSegment(_ id: Int64, now: EpochMs) throws -> Bool {
        try db.run(
            """
            UPDATE segments SET deleted_at = ?, updated_at = ?, dirty = 1
             WHERE id = ? AND deleted_at IS NULL
            """,
            [.integer(now), .integer(now), .integer(id)]
        )
        return db.changes > 0
    }

    /// Close `id` at `endedAt`, splitting at every local midnight it crosses.
    /// The original row becomes the first piece; later pieces are inserted against
    /// their own days (created on demand with `targetMinutes`). Returns every
    /// resulting piece, ordered.
    @discardableResult
    public func closeSegmentSplitting(
        _ id: Int64, endedAt: EpochMs, targetMinutes: Int, now: EpochMs
    ) throws -> [Segment] {
        try db.transaction {
            guard let original = try segment(id: id) else {
                throw RepositoryError.segmentNotFound(id)
            }

            let split = splitAtMidnight(
                SpanDraft(type: original.type, startedAt: original.startedAt, endedAt: endedAt),
                in: zone
            )
            guard let first = split.first else { return [] }

            // The first piece keeps the original row: its id is what the snapshot, the
            // idle prompt and any in-flight recovery are holding on to, so it has to
            // survive the close. Its day_id already matches the day it starts in.
            var pieces = [try updateSegmentFields(
                id, UpdateSegmentInput(id: id, endedAt: .some(first.endedAt)), now: now
            )]

            for piece in split.dropFirst() {
                let day = try getOrCreateDay(piece.date, targetMinutes: targetMinutes, now: now)
                pieces.append(try insertSegment(
                    dayId: day.id, type: piece.type,
                    startedAt: piece.startedAt, endedAt: piece.endedAt,
                    // The note described the whole span, so each piece keeps it rather
                    // than the tail silently losing it.
                    note: original.note, now: now
                ))
            }
            return pieces
        }
    }

    // MARK: - App state

    public func appState(_ key: String) throws -> String? {
        try db.queryOne("SELECT value FROM app_state WHERE key = ?", [.text(key)]) { $0.text(0) }
    }

    public func setAppState(_ key: String, _ value: String) throws {
        try db.run(
            """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(key), .text(value)]
        )
    }

    // MARK: - Lifecycle

    /// Nesting is safe — see `Database.transaction`.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    // MARK: - Row mapping

    private static let dayColumns = "id, date, created_at, ended_at, target_minutes"
    private static let segmentColumns =
        "id, day_id, type, started_at, ended_at, note, created_at, updated_at"

    /// The CHECK constraint on `segments.type` guarantees one of exactly two values,
    /// so anything unexpected reads as work rather than failing the whole query.
    private static func segmentType(_ raw: String) -> SegmentType {
        raw == "break" ? .break : .work
    }

    private static func day(_ row: Row) -> Day {
        Day(
            id: row.int64(0),
            date: DateKey(row.text(1)) ?? todayKey(),
            createdAt: row.int64(2),
            endedAt: row.optionalInt64(3),
            targetMinutes: row.int(4)
        )
    }

    private static func segment(_ row: Row) -> Segment {
        Segment(
            id: row.int64(0),
            dayId: row.int64(1),
            type: segmentType(row.text(2)),
            startedAt: row.int64(3),
            endedAt: row.optionalInt64(4),
            note: row.optionalText(5),
            createdAt: row.int64(6),
            updatedAt: row.int64(7)
        )
    }
}

public enum RepositoryError: DeyleeError {
    case dayNotFound(Int64)
    case segmentNotFound(Int64)

    public var description: String {
        switch self {
        case .dayNotFound(let id): "Day \(id) does not exist."
        case .segmentNotFound(let id): "Segment \(id) does not exist."
        }
    }
}
