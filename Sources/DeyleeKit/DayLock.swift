import Foundation

/// Past days are locked: once a day has ended, its recorded work and break time is final.
///
/// The server is the authority — it refuses the change by its own clock and hands back its
/// copy (the lock_past_days migration). This side exists so the History window refuses the
/// edit where it is typed rather than one sync later, and it judges "ended" by
/// `TrustedClock`, so a Mac whose date was set back cannot talk itself into an open day.
///
/// Still allowed on a locked day, matching the server: editing a note, and the timer's own
/// closing and discarding of a segment it left open. None of those go through the check.

/// How long after its midnight a day can still be corrected. Elapsed time after an
/// instant, not a calendar offset, so a fixed millisecond count is the right unit.
public let dayLockGraceMs: Int64 = 2 * 3_600_000

/// The instant `date` locks: its local midnight, by calendar arithmetic in `zone`, plus
/// the grace period.
public func dayLockInstant(_ date: DateKey, in zone: TimeZone = .current) -> EpochMs {
    endOfDay(date, in: zone) + dayLockGraceMs
}

public func isDayLocked(_ date: DateKey, now: EpochMs, in zone: TimeZone = .current) -> Bool {
    now >= dayLockInstant(date, in: zone)
}

/// What the History window says when it refuses. The server's own sentence, so the two
/// refusals read the same.
public let dayLockedMessage = "That day has ended, so its times can no longer change."

/// The server's time, carried forward on a clock the Mac's date setting cannot move.
///
/// Every sync response carries `serverTime`. Anchored to it, `now()` is that time plus
/// however long has passed since on `ContinuousClock` — which counts through sleep and
/// ignores changes to the wall clock. Before the first sync of a launch there is nothing
/// to anchor to and it falls back to the wall clock; the server still has the last word.
@MainActor
public final class TrustedClock {
    private let wall: () -> EpochMs
    private let elapsed: () -> Duration
    private var anchor: (serverTime: EpochMs, at: Duration)?

    /// `elapsed` is a monotonic reading from any fixed origin; only differences are used.
    public init(
        wall: @escaping () -> EpochMs = epochNow,
        elapsed: @escaping () -> Duration = TrustedClock.continuousElapsed
    ) {
        self.wall = wall
        self.elapsed = elapsed
    }

    public func anchor(serverTime: EpochMs) {
        anchor = (serverTime, elapsed())
    }

    public func now() -> EpochMs {
        guard let anchor else { return wall() }
        let (seconds, attoseconds) = (elapsed() - anchor.at).components
        return anchor.serverTime + seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    nonisolated private static let origin = ContinuousClock.now
    public nonisolated static func continuousElapsed() -> Duration {
        origin.duration(to: .now)
    }
}
