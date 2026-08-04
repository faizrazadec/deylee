import Foundation

/// Overlap validation, ported from `src/domain/overlap.ts`. Segments must never
/// overlap — not from the timer, and not from a manual edit in the History window.
///
/// Convention: intervals are half-open, `[startedAt, endedAt)`. Touching endpoints
/// (one segment ending exactly when the next begins) is *not* an overlap; that is
/// the normal shape of a pause/resume boundary.

public struct Interval: Equatable, Sendable {
    public var startedAt: EpochMs
    /// `nil` = open-ended; it conflicts with everything after `startedAt`.
    public var endedAt: EpochMs?

    public init(startedAt: EpochMs, endedAt: EpochMs?) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// The time range of a stored segment or an unsaved draft, with its type dropped.
    public init(_ span: some Span) {
        self.startedAt = span.startedAt
        self.endedAt = span.endedAt
    }
}

/// Stand-in for the TS `Number.POSITIVE_INFINITY`: an open interval runs forever, and
/// `Int64.max` is later than any instant a clock can produce.
private let openEnd: EpochMs = .max

private func upperBound(_ interval: Interval) -> EpochMs {
    interval.endedAt ?? openEnd
}

/// True when the two intervals share any positive-length span of time.
public func intervalsOverlap(_ a: Interval, _ b: Interval) -> Bool {
    a.startedAt < upperBound(b) && b.startedAt < upperBound(a)
}

/// The first stored segment that would conflict with `candidate`.
///
/// `ignoreId` excludes the segment being edited from its own comparison.
public func findOverlapping(
    _ candidate: Interval,
    in existing: [Segment],
    ignoring ignoreId: Int64? = nil
) -> Segment? {
    for segment in existing {
        if let ignoreId, segment.id == ignoreId { continue }
        if intervalsOverlap(candidate, Interval(segment)) { return segment }
    }
    return nil
}

/// Validate a proposed segment against the day's existing segments.
///
/// Returns `nil` when the candidate is legal, otherwise the error the user should
/// read. (The TS returns a `MutationResult` whose success arm carries the candidate
/// straight back, which the caller already holds here.)
///
/// Checks, in order: the range is well-formed, it is not zero-length, and it does
/// not overlap anything else.
public func validateSegment(
    _ candidate: Interval,
    against existing: [Segment],
    ignoring ignoreId: Int64? = nil,
    in zone: TimeZone = .current
) -> MutationError? {
    if let endedAt = candidate.endedAt {
        if endedAt < candidate.startedAt {
            return MutationError(code: .invalidRange, message: "End time is before the start time.")
        }
        if endedAt == candidate.startedAt {
            return MutationError(code: .invalidRange, message: "Start and end time are the same.")
        }
    }

    guard let clash = findOverlapping(candidate, in: existing, ignoring: ignoreId) else {
        return nil
    }
    let clashEnd = clash.endedAt.map { formatClock($0, in: zone) } ?? "now"
    return MutationError(
        code: .overlap,
        message: "Overlaps the \(clash.type.rawValue) segment from "
            + "\(formatClock(clash.startedAt, in: zone)) to \(clashEnd)."
    )
}

/// Validate instants that have not been proven to be instants yet.
///
/// The TS guarded with `Number.isFinite` because a failed parse in the History editor
/// arrives as `NaN` or `Infinity` and would otherwise sail through the comparisons.
/// `EpochMs` is an `Int64`, which has no such values, so on this side the same failure
/// surfaces one step earlier as a `nil` out of `fromTimeInputValue`. Feed those raw
/// results in here and the user sees the identical message.
///
/// `endedAt` is a double optional, matching `UpdateSegmentInput`: `.none` means the
/// field did not parse, `.some(nil)` means a deliberately open-ended segment.
public func validateSegment(
    startedAt: EpochMs?,
    endedAt: EpochMs??,
    against existing: [Segment],
    ignoring ignoreId: Int64? = nil,
    in zone: TimeZone = .current
) -> MutationError? {
    guard let startedAt else {
        return MutationError(code: .invalidRange, message: "Start time is not a valid instant.")
    }
    guard let endedAt else {
        return MutationError(code: .invalidRange, message: "End time is not a valid instant.")
    }
    return validateSegment(
        Interval(startedAt: startedAt, endedAt: endedAt),
        against: existing,
        ignoring: ignoreId,
        in: zone
    )
}

/// At most one segment may be open at a time, app-wide. Used as a guard before
/// opening a new one and as an invariant check after recovery.
public func findOpenSegments(_ segments: [Segment]) -> [Segment] {
    segments.filter { $0.endedAt == nil }
}
