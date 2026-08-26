import Foundation

/// The timer state machine, and the only writer of timer segments.
///
/// Nothing about the current state is persisted: `TimerState` is derived from the one
/// open segment and today's day row every time it is read. That is what makes the app
/// crash-safe — a `kill -9` cannot leave a status column lying about what happened,
/// because there is no status column, only rows describing time that really elapsed.
///
/// Pause/resume boundaries share an instant: the closing segment ends at exactly the
/// moment the next one begins. Intervals are half-open, so that is a touch, not an
/// overlap, and no millisecond is ever lost or double-counted.
///
/// Every transition that cannot legally happen from the current state is a no-op that
/// returns the current snapshot. The UI disables those buttons, but the status-item
/// menu and the recovery prompts can all race each other, and throwing would be worse.
///
/// Confined to the main actor: the store is one small local file, every write is
/// sub-millisecond, and a single writer is a schema invariant rather than a
/// performance compromise.
@MainActor
public final class TimerEngine {
    private let repo: Repository
    private let prefs: PreferencesStore
    private let clock: () -> EpochMs
    private let zone: TimeZone
    private var listeners: [UUID: (TimerSnapshot) -> Void] = [:]
    /// The local date of the last snapshot handed to the listeners.
    ///
    /// Kept so the rollover tick can tell a date that has turned from one that has
    /// not. Nothing else recomputes it: the panel and the status item draw whatever
    /// snapshot they were last given, and with no timer running nothing was ever
    /// giving them a new one.
    private var lastEmittedDate: DateKey?

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

    // MARK: - Reads

    public func snapshot(now: EpochMs? = nil) throws -> TimerSnapshot {
        let now = now ?? clock()
        let date = dateKeyOf(now, in: zone)
        let day = try repo.findDay(date)
        // App-wide, not today-only: before the rollover tick, yesterday's still-open
        // segment is what decides the state.
        let open = try repo.findOpenSegment()
        let segments = try day.map { try repo.listSegments(dayId: $0.id) } ?? []

        // Only closed segments are summed here; the open one is sent along untouched so
        // views can recompute the live value on their own tick (`liveTotals`).
        let closed = segments.filter { !$0.isOpen }
        let totals = dayTotals(segments, date, now: now, in: zone)

        let state: TimerState
        if let open {
            state = open.type == .work ? .running : .paused
        } else if day?.endedAt != nil {
            state = .ended
        } else {
            state = .idle
        }

        return TimerSnapshot(
            state: state,
            date: date,
            dayId: day?.id,
            closedWorkedMs: sumWithinDay(closed, .work, date, now: now, in: zone),
            closedBreakMs: sumWithinDay(closed, .break, date, now: now, in: zone),
            openSegment: open,
            firstStartAt: totals.firstStartAt,
            lastEndAt: totals.lastEndAt,
            // The day row's stamped target wins so the panel and the History window
            // never disagree about whether a day met its goal. Past days therefore keep
            // the target they were actually run against; the day in progress is kept
            // current by `syncTodayTarget`.
            targetMinutes: day?.targetMinutes ?? currentTargetMinutes(),
            asOf: now
        )
    }

    // MARK: - Transitions

    /// IDLE or ENDED → RUNNING. Restarting after End Day un-finalises the same day.
    @discardableResult
    public func start() throws -> TimerSnapshot {
        let now = clock()
        // IDLE and ENDED are exactly the states with no open segment anywhere.
        guard try repo.findOpenSegment() == nil else { return try snapshot(now: now) }

        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            try openAt(.work, at: now, targetMinutes: targetMinutes, now: now)
        }
        return try emit()
    }

    /// RUNNING → PAUSED.
    @discardableResult
    public func pause() throws -> TimerSnapshot {
        try switchOpenSegment(from: .work, to: .break)
    }

    /// PAUSED → RUNNING.
    @discardableResult
    public func resume() throws -> TimerSnapshot {
        try switchOpenSegment(from: .break, to: .work)
    }

    /// RUNNING or PAUSED → ENDED.
    @discardableResult
    public func endDay() throws -> TimerSnapshot {
        let now = clock()
        guard let open = try repo.findOpenSegment() else { return try snapshot(now: now) }

        let at = max(now, open.startedAt)
        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            try repo.closeSegmentSplitting(open.id, endedAt: at, targetMinutes: targetMinutes, now: now)
            // The day finalised is the one `at` falls in, which is also the day the
            // final piece of a midnight-crossing segment was attributed to.
            let day = try repo.getOrCreateDay(dateKeyOf(at, in: zone), targetMinutes: targetMinutes, now: now)
            try repo.setDayEnded(day.id, endedAt: at, now: now)
        }
        return try emit()
    }

    // MARK: - Plans

    @discardableResult
    public func apply(_ plan: RecoveryPlan) throws -> TimerSnapshot {
        let now = clock()
        switch plan {
        case .resume:
            // The segment is already open and already counting — nothing to write.
            return try snapshot(now: now)

        case .close(let segmentId, let endedAt):
            guard let segment = try repo.segment(id: segmentId), segment.isOpen else {
                return try snapshot(now: now)
            }
            let at = max(endedAt, segment.startedAt)
            let targetMinutes = currentTargetMinutes()
            try repo.transaction {
                // A zero-length close would leave a phantom row in the day list; there
                // is nothing worth keeping, so the segment goes instead.
                if at <= segment.startedAt {
                    try repo.deleteSegment(segment.id, now: now)
                } else {
                    try repo.closeSegmentSplitting(
                        segment.id, endedAt: at, targetMinutes: targetMinutes, now: now
                    )
                }
            }
            return try emit()

        case .discard(let segmentId):
            guard try repo.segment(id: segmentId) != nil else { return try snapshot(now: now) }
            try repo.transaction { try repo.deleteSegment(segmentId, now: now) }
            return try emit()
        }
    }

    @discardableResult
    public func apply(_ plan: IdlePlan) throws -> TimerSnapshot {
        let now = clock()
        guard case .trim(let segmentId, let endedAt, let resumeAt) = plan else {
            return try snapshot(now: now)
        }
        guard let segment = try repo.segment(id: segmentId), segment.isOpen else {
            return try snapshot(now: now)
        }

        // Trim to the instant the user went idle, then pick up again now, so the idle
        // stretch is absent from the record rather than recorded as anything.
        let closeAt = min(max(endedAt, segment.startedAt), resumeAt)
        if closeAt <= segment.startedAt { return try snapshot(now: now) }

        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            try repo.closeSegmentSplitting(
                segment.id, endedAt: closeAt, targetMinutes: targetMinutes, now: now
            )
            try openAt(segment.type, at: resumeAt, targetMinutes: targetMinutes, now: now)
        }
        return try emit()
    }

    /// Closes the open work segment at `at` because the machine slept or locked.
    public func suspend(at: EpochMs) throws {
        let now = clock()
        // A break already accounts for the gap, so only work is cut short here.
        guard let open = try repo.findOpenSegment(), open.type == .work else { return }

        let endedAt = min(max(at, open.startedAt), now)
        // Nothing to keep and nothing to close — leave the segment running rather than
        // storing an empty row; the wake handler will find it still open and stand down.
        if endedAt <= open.startedAt { return }

        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            try repo.closeSegmentSplitting(
                open.id, endedAt: endedAt, targetMinutes: targetMinutes, now: now
            )
        }
        _ = try emit()
    }

    @discardableResult
    public func apply(_ plan: WakePlan) throws -> TimerSnapshot {
        let now = clock()
        // The suspend never closed anything (a break was open, or the gap was empty),
        // so the timer is already in the right state and a second open segment would
        // corrupt the one-open-segment invariant.
        guard try repo.findOpenSegment() == nil else { return try snapshot(now: now) }

        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            switch plan {
            case .recordBreak(let breakStartedAt, let breakEndedAt, let workStartsAt):
                try insertClosedSpan(
                    .break, startedAt: breakStartedAt, endedAt: breakEndedAt,
                    targetMinutes: targetMinutes, now: now
                )
                try openAt(.work, at: workStartsAt, targetMinutes: targetMinutes, now: now)
            case .resumeWork(let workStartsAt):
                try openAt(.work, at: workStartsAt, targetMinutes: targetMinutes, now: now)
            }
        }
        return try emit()
    }

    // MARK: - Midnight

    /// Splits the open segment when it has run past local midnight, so each calendar
    /// day owns its own rows even if nobody touched the app. Called on a short
    /// interval, so the no-work path stays two indexed reads.
    @discardableResult
    public func rollOverMidnight(now: EpochMs? = nil) throws -> TimerSnapshot {
        let now = now ?? clock()
        guard let open = try repo.findOpenSegment(),
              let split = splitOpenSpanAt(open, now: now, in: zone)
        else {
            // Nothing is running, so there is no span to split — but the date can
            // still have turned, and until this emitted, nobody was told.
            //
            // That is what left the panel showing yesterday after a day was ended:
            // this tick ran every second, found nothing open, computed a snapshot and
            // dropped it on the floor. The listeners went on drawing the last one they
            // were handed until some other action emitted — pressing Start, usually,
            // which is a poor way to learn what day it is.
            if lastEmittedDate != dateKeyOf(now, in: zone) {
                return try emit(now: now)
            }
            return try snapshot(now: now)
        }

        let boundary = split.reopened.startedAt
        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            // The repository owns row identity when a close spans several days: the
            // original row becomes the first piece and the rest are inserted against
            // their own days.
            try repo.closeSegmentSplitting(
                open.id, endedAt: boundary, targetMinutes: targetMinutes, now: now
            )
            try openAt(split.reopened.type, at: boundary, targetMinutes: targetMinutes, now: now)
        }
        return try emit()
    }

    // MARK: - Preferences

    /// Re-stamps the current day's target from the preference. Returns the dates that
    /// changed.
    ///
    /// Only the day in progress is touched: a target is stamped onto a day row at
    /// creation so History reports every past day against the goal it was actually run
    /// against, and changing the preference must not rewrite that record.
    ///
    /// Deliberately silent — it neither emits a snapshot nor broadcasts anything,
    /// because the caller is already announcing the preference change and would
    /// otherwise send two updates for one edit. The returned dates are what it needs
    /// to do that.
    public func syncTodayTarget() throws -> [DateKey] {
        // The engine's own clock, not the wall clock, so a test that fakes the clock
        // sees the same day here as everywhere else. Read once, so the date and the
        // `updated_at` the write stamps cannot come from two different instants.
        let now = clock()
        let date = dateKeyOf(now, in: zone)
        // No row yet: nothing is stamped, and whoever creates it will stamp the
        // preference as it stands then.
        guard let day = try repo.findDay(date) else { return [] }

        let targetMinutes = currentTargetMinutes()
        // The preference can be re-saved unchanged, and a write plus a redraw for an
        // identical value is pure churn.
        if day.targetMinutes == targetMinutes { return [] }

        try repo.setDayTarget(day.id, targetMinutes: targetMinutes, now: now)
        return [date]
    }

    // MARK: - Listeners

    @discardableResult
    public func onSnapshot(_ listener: @escaping (TimerSnapshot) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    public func removeListener(_ token: UUID) {
        listeners[token] = nil
    }

    @discardableResult
    public func emit(now: EpochMs? = nil) throws -> TimerSnapshot {
        let snapshot = try snapshot(now: now)
        lastEmittedDate = snapshot.date
        // Copied so a listener that unsubscribes itself cannot disturb the iteration.
        for listener in Array(listeners.values) {
            listener(snapshot)
        }
        return snapshot
    }

    // MARK: - Internals

    /// The target stamped onto a day row when it is created.
    private func currentTargetMinutes() -> Int {
        hoursToMinutes(prefs.value(\.dailyTargetHours))
    }

    /// Closes the open segment of type `from` and opens one of type `to` at the same
    /// instant. Wrong-state calls (nothing open, or the other type open) are no-ops.
    private func switchOpenSegment(from: SegmentType, to: SegmentType) throws -> TimerSnapshot {
        let now = clock()
        guard let open = try repo.findOpenSegment(), open.type == from else {
            return try snapshot(now: now)
        }

        // Guards against a backwards clock jump producing a reversed segment.
        let at = max(now, open.startedAt)
        let targetMinutes = currentTargetMinutes()
        try repo.transaction {
            try repo.closeSegmentSplitting(
                open.id, endedAt: at, targetMinutes: targetMinutes, now: now
            )
            try openAt(to, at: at, targetMinutes: targetMinutes, now: now)
        }
        return try emit()
    }

    /// Opens a segment on the day containing `at`, un-finalising that day if needed.
    private func openAt(
        _ type: SegmentType, at: EpochMs, targetMinutes: Int, now: EpochMs
    ) throws {
        let day = try repo.getOrCreateDay(
            dateKeyOf(at, in: zone), targetMinutes: targetMinutes, now: now
        )
        // A day with time running on it is by definition not finished.
        if day.endedAt != nil { try repo.setDayEnded(day.id, endedAt: nil, now: now) }
        try repo.insertSegment(
            dayId: day.id, type: type, startedAt: at, endedAt: nil, now: now
        )
    }

    /// Stores an already-finished span as one row per local day it covers.
    private func insertClosedSpan(
        _ type: SegmentType, startedAt: EpochMs, endedAt: EpochMs,
        targetMinutes: Int, now: EpochMs
    ) throws {
        let pieces = splitAtMidnight(
            SpanDraft(type: type, startedAt: startedAt, endedAt: endedAt), in: zone
        )
        for piece in pieces {
            guard let pieceEnd = piece.endedAt, pieceEnd > piece.startedAt else { continue }
            let day = try repo.getOrCreateDay(
                piece.date, targetMinutes: targetMinutes, now: now
            )
            try repo.insertSegment(
                dayId: day.id, type: type,
                startedAt: piece.startedAt, endedAt: pieceEnd, now: now
            )
        }
    }
}
