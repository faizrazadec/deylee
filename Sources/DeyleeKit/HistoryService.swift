import Foundation

/// Manual segment edits from the History window, ported from the mutation half of
/// `src/main/ipc/handlers.ts`.
///
/// The rules the timer engine enforces for itself apply just as hard to a hand edit:
/// every stored segment belongs to exactly one local day, no two segments overlap, and
/// at most one segment is open app-wide. That is why nothing here is a plain UPDATE —
/// a span is split at midnight first, validated against *every* day it touches, and
/// only then written, inside one transaction.
///
/// Each call returns the day the user should be looking at afterwards plus the dates
/// whose totals moved, so the caller can invalidate exactly those and re-emit a
/// snapshot. It deliberately does not broadcast anything itself: the window layer owns
/// the fan-out and would otherwise send two updates for one edit.
@MainActor
public final class HistoryService {
    private let repo: Repository
    private let prefs: PreferencesStore
    private let zone: TimeZone
    private let clock: () -> EpochMs

    public init(
        repo: Repository,
        prefs: PreferencesStore,
        in zone: TimeZone = .current,
        now: @escaping () -> EpochMs = epochNow
    ) {
        self.repo = repo
        self.prefs = prefs
        self.zone = zone
        self.clock = now
    }

    /// What a successful mutation leaves behind.
    public struct Outcome: Sendable {
        /// The day the History window should select and re-read. `nil` only after a
        /// delete whose day row could not be read back, which is not worth an error.
        public let detail: DayDetail?
        /// Every date whose totals changed — the addressed day, the row's original day,
        /// and any day a midnight split spilled onto.
        public let affectedDates: [DateKey]

        public init(detail: DayDetail?, affectedDates: [DateKey]) {
            self.detail = detail
            self.affectedDates = affectedDates
        }
    }

    // MARK: - Create

    /// Adds a segment to `date`, splitting it across midnight if it runs past one.
    ///
    /// The addressed day row is created even when every piece lands on another day, so
    /// the window always gets back the day it was editing.
    public func createSegment(
        on date: DateKey, _ input: CreateSegmentInput
    ) throws -> Outcome {
        let now = clock()
        let candidate = SpanDraft(
            type: input.type, startedAt: input.startedAt, endedAt: input.endedAt
        )
        let pieces = splitAtMidnight(candidate, in: zone)
        let dates = uniqueDates([date] + pieces.map(\.date))

        if let error = validateSegment(
            Interval(candidate), against: try segments(on: dates, now: now), in: zone
        ) {
            throw error
        }

        let detail = try repo.transaction { () -> DayDetail? in
            let targetMinutes = currentTargetMinutes()
            _ = try repo.getOrCreateDay(date, targetMinutes: targetMinutes, now: now)
            for piece in pieces {
                let day = try repo.getOrCreateDay(
                    piece.date, targetMinutes: targetMinutes, now: now
                )
                try repo.insertSegment(
                    dayId: day.id, type: piece.type,
                    startedAt: piece.startedAt, endedAt: piece.endedAt,
                    // The note describes the whole span, so every piece keeps it rather
                    // than the tail silently losing it.
                    note: input.note, now: now
                )
            }
            return try repo.dayDetail(date, now: now)
        }

        guard let detail else {
            throw MutationError(code: .unknown, message: "The day could not be read back.")
        }
        return Outcome(detail: detail, affectedDates: dates)
    }

    // MARK: - Update

    /// Applies a patch to one segment. Fields left `nil` are untouched; an explicit
    /// `.some(nil)` end reopens the segment.
    public func updateSegment(_ patch: UpdateSegmentInput) throws -> Outcome {
        let now = clock()
        guard let existing = try repo.segment(id: patch.id) else {
            throw MutationError(code: .notFound, message: "That segment no longer exists.")
        }

        let merged = SpanDraft(
            type: patch.type ?? existing.type,
            startedAt: patch.startedAt ?? existing.startedAt,
            endedAt: patch.endedAt ?? existing.endedAt
        )
        let mergedNote: String? = patch.note ?? existing.note

        // At most one segment may be open app-wide; re-opening a closed one must not
        // create a second.
        if merged.endedAt == nil,
           let open = try repo.findOpenSegment(), open.id != existing.id {
            throw MutationError(
                code: .openSegmentConflict, message: "Another segment is still running."
            )
        }

        let pieces = splitAtMidnight(merged, in: zone)
        // The row's original date matters even when the edit moves it, because that
        // day's totals changed too.
        let dates = uniqueDates(
            [dateKeyOf(existing.startedAt, in: zone)] + pieces.map(\.date)
        )

        if let error = validateSegment(
            Interval(merged),
            against: try segments(on: dates, now: now),
            ignoring: existing.id,
            in: zone
        ) {
            throw error
        }

        guard let head = pieces.first else {
            throw MutationError(code: .unknown, message: "The day could not be read back.")
        }

        let detail = try repo.transaction { () -> DayDetail? in
            let targetMinutes = currentTargetMinutes()
            let headDay = try repo.getOrCreateDay(
                head.date, targetMinutes: targetMinutes, now: now
            )

            if headDay.id == existing.dayId {
                try repo.updateSegmentFields(
                    existing.id,
                    UpdateSegmentInput(
                        id: existing.id, type: head.type, startedAt: head.startedAt,
                        endedAt: .some(head.endedAt), note: .some(mergedNote)
                    ),
                    now: now
                )
            } else {
                // A row never moves between days — `day_id` is the filing rule the whole
                // schema rests on — so a segment dragged onto another date is re-filed.
                try repo.deleteSegment(existing.id)
                try repo.insertSegment(
                    dayId: headDay.id, type: head.type,
                    startedAt: head.startedAt, endedAt: head.endedAt,
                    note: mergedNote, now: now
                )
            }

            for piece in pieces.dropFirst() {
                let day = try repo.getOrCreateDay(
                    piece.date, targetMinutes: targetMinutes, now: now
                )
                try repo.insertSegment(
                    dayId: day.id, type: piece.type,
                    startedAt: piece.startedAt, endedAt: piece.endedAt,
                    note: mergedNote, now: now
                )
            }

            return try repo.dayDetail(head.date, now: now)
        }

        guard let detail else {
            throw MutationError(code: .unknown, message: "The day could not be read back.")
        }
        return Outcome(detail: detail, affectedDates: dates)
    }

    // MARK: - Delete

    /// Removes a segment. The segment the timer is still writing to is refused: deleting
    /// it would leave the engine holding an id that no longer exists.
    public func deleteSegment(_ id: Int64) throws -> Outcome {
        let now = clock()
        guard let existing = try repo.segment(id: id) else {
            throw MutationError(code: .notFound, message: "That segment no longer exists.")
        }
        if existing.isOpen {
            throw MutationError(
                code: .openSegmentConflict,
                message: "Stop the timer before deleting the segment it is still writing to."
            )
        }

        // Stored segments always start inside the day they are filed under — the splitter
        // guarantees it — so the start instant identifies the day without a second lookup.
        let date = dateKeyOf(existing.startedAt, in: zone)
        let removed = try repo.transaction { try repo.deleteSegment(id) }
        guard removed else {
            throw MutationError(code: .notFound, message: "That segment no longer exists.")
        }

        return Outcome(detail: try repo.dayDetail(date, now: now), affectedDates: [date])
    }

    // MARK: - Internals

    /// Every segment already stored on the days a candidate touches.
    ///
    /// A span that crosses midnight is checked against *both* days, not just the one the
    /// edit was addressed to, otherwise its tail could silently land on top of the next
    /// morning's work.
    private func segments(on dates: [DateKey], now: EpochMs) throws -> [Segment] {
        var existing: [Segment] = []
        for date in dates {
            if let detail = try repo.dayDetail(date, now: now) {
                existing.append(contentsOf: detail.segments)
            }
        }
        return existing
    }

    /// The target stamped onto any day row this edit has to create. Past days keep the
    /// target they were actually run against; only a brand new row takes the current
    /// preference.
    private func currentTargetMinutes() -> Int {
        hoursToMinutes(prefs.value(\.dailyTargetHours))
    }
}

/// Dates in first-seen order, without duplicates. Order matters only for tests and logs,
/// but a set would make both unreadable.
func uniqueDates(_ dates: [DateKey]) -> [DateKey] {
    var seen: Set<DateKey> = []
    var out: [DateKey] = []
    for date in dates where seen.insert(date).inserted {
        out.append(date)
    }
    return out
}
