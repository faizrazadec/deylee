import Foundation

/// Duration and aggregation logic, ported from `src/domain/duration.ts`.
///
/// Totals are *always* derived by summing segments. Nothing here reads or writes a
/// running counter, which is what makes the numbers survive crashes, restarts,
/// manual edits and machine sleep.

/// Duration of a single span. An open span (`endedAt == nil`) is measured up to
/// `now`. Never negative — a reversed or future-started span contributes zero.
public func spanDuration(_ span: some Span, now: EpochMs = epochNow()) -> Int64 {
    let end = span.endedAt ?? now
    return max(0, end - span.startedAt)
}

/// The portion of a span that falls inside the local calendar day `date`.
///
/// Segments are normally split at midnight when they are closed, so this is a no-op
/// for stored data. It matters for the *open* segment, which can run past midnight
/// before the splitter has had a chance to act.
public func spanDurationWithinDay(
    _ span: some Span,
    _ date: DateKey,
    now: EpochMs = epochNow(),
    in zone: TimeZone = .current
) -> Int64 {
    let dayStart = startOfDay(date, in: zone)
    let dayEnd = endOfDay(date, in: zone)
    let start = max(span.startedAt, dayStart)
    let end = min(span.endedAt ?? now, dayEnd)
    return max(0, end - start)
}

/// Sum the spans of one type, clipped to `date`.
public func sumWithinDay<S: Span>(
    _ spans: [S],
    _ type: SegmentType,
    _ date: DateKey,
    now: EpochMs = epochNow(),
    in zone: TimeZone = .current
) -> Int64 {
    var total: Int64 = 0
    for span in spans where span.type == type {
        total += spanDurationWithinDay(span, date, now: now, in: zone)
    }
    return total
}

/// Full derived totals for a day.
///
/// `firstStartAt` is the earliest segment start and `lastEndAt` the latest close;
/// `lastEndAt` is `nil` while any segment is still open, because the day has not
/// finished yet.
public func dayTotals(
    _ segments: [Segment],
    _ date: DateKey,
    now: EpochMs = epochNow(),
    in zone: TimeZone = .current
) -> DayTotals {
    var workedMs: Int64 = 0
    var breakMs: Int64 = 0
    var firstStartAt: EpochMs?
    var lastEndAt: EpochMs?
    var hasOpenSegment = false

    for segment in segments {
        let duration = spanDurationWithinDay(segment, date, now: now, in: zone)
        if segment.type == .work { workedMs += duration } else { breakMs += duration }

        // The raw, unclipped start — the day's first start is when the user actually
        // began, not where the clip window happens to fall.
        firstStartAt = firstStartAt.map { min($0, segment.startedAt) } ?? segment.startedAt
        if let endedAt = segment.endedAt {
            lastEndAt = lastEndAt.map { max($0, endedAt) } ?? endedAt
        } else {
            hasOpenSegment = true
        }
    }

    return DayTotals(
        workedMs: workedMs,
        breakMs: breakMs,
        firstStartAt: firstStartAt,
        lastEndAt: hasOpenSegment ? nil : lastEndAt,
        segmentCount: segments.count,
        hasOpenSegment: hasOpenSegment
    )
}

/// Totals as of `now`, for the 1s render tick.
///
/// The open segment's contribution is recomputed from timestamps every tick, and is
/// clamped to the start of the current local day so that a segment which ran across
/// midnight only credits today with today's share.
public func liveTotals(
    _ snapshot: TimerSnapshot,
    now: EpochMs = epochNow(),
    in zone: TimeZone = .current
) -> LiveTotals {
    var workedMs = snapshot.closedWorkedMs
    var breakMs = snapshot.closedBreakMs

    if let open = snapshot.openSegment {
        // Clamp to the current local midnight, not the snapshot's date, so the display
        // rolls over correctly if the app is left running past midnight.
        let dayStart = startOfDayAt(now, in: zone)
        let elapsed = max(0, now - max(open.startedAt, dayStart))
        if open.type == .work { workedMs += elapsed } else { breakMs += elapsed }
    }

    let targetMs = minutesToMs(max(0, snapshot.targetMinutes))
    return LiveTotals(
        workedMs: workedMs,
        breakMs: breakMs,
        // Deliberately unclamped, so callers can tell "met" from "well over".
        targetProgress: targetMs > 0 ? Double(workedMs) / Double(targetMs) : 0,
        targetMs: targetMs,
        remainingToTargetMs: targetMs - workedMs
    )
}

/// Rounds half towards positive infinity, matching JavaScript's `Math.round`, so a
/// target of 0.25 h and one of 7.5 h land on the same minute the Electron app stored.
///
/// Saturates rather than trapping. JavaScript numbers have no overflow, so the
/// Electron build survives an absurd target on a corrupt store; turning the same
/// value into a crash would be a regression, and every caller already treats an
/// out-of-range target as "no useful target".
public func hoursToMinutes(_ hours: Double) -> Int {
    let minutes = hours * 60
    guard minutes.isFinite else { return minutes < 0 ? Int.min : Int.max }
    let floor = minutes.rounded(.down)
    let rounded = minutes - floor >= 0.5 ? floor + 1 : floor
    if rounded >= Double(Int.max) { return Int.max }
    if rounded <= Double(Int.min) { return Int.min }
    return Int(rounded)
}

public func minutesToMs(_ minutes: Int) -> Int64 {
    saturatingMs(Int64(clamping: minutes), times: MS_PER_MINUTE)
}

public func hoursToMs(_ hours: Double) -> Int64 {
    let ms = (hours * Double(MS_PER_HOUR)).rounded()
    guard ms.isFinite else { return ms < 0 ? Int64.min : Int64.max }
    if ms >= Double(Int64.max) { return Int64.max }
    if ms <= Double(Int64.min) { return Int64.min }
    return Int64(ms)
}

/// Multiplies without trapping. A `target_minutes` value large enough to overflow can
/// only come from a hand-edited or corrupt database — the Electron build renders it
/// harmlessly as an unreachable target, so the native app must not die on it.
func saturatingMs(_ value: Int64, times factor: Int64) -> Int64 {
    let (product, overflowed) = value.multipliedReportingOverflow(by: factor)
    if !overflowed { return product }
    return (value < 0) == (factor < 0) ? Int64.max : Int64.min
}
