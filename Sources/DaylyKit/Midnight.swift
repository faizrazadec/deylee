import Foundation

/// Midnight-crossover splitting, ported from `src/domain/midnight.ts`.
///
/// A segment that spans local midnight is stored as one piece per calendar day, so
/// every stored segment belongs to exactly one day and day totals need no special
/// cases. Splitting happens when a segment is closed, when the app notices the clock
/// has rolled over, and when a manual edit stretches a segment across a boundary.
///
/// The boundaries come from `nextMidnightAfter`, which uses local calendar maths, so
/// 23-hour and 25-hour DST days split at the right instants.

/// The outcome of rolling an open span over a midnight boundary.
public struct OpenSpanSplit: Equatable, Sendable {
    /// The finished pieces, one per elapsed local day, in ascending order.
    public var closed: [SplitPiece]
    /// The still-running piece, starting at the local midnight that begins today.
    public var reopened: SplitPiece

    public init(closed: [SplitPiece], reopened: SplitPiece) {
        self.closed = closed
        self.reopened = reopened
    }
}

/// True when the span is closed and ends on a later local day than it started.
public func crossesMidnight(_ span: some Span, in zone: TimeZone = .current) -> Bool {
    guard let endedAt = span.endedAt else { return false }
    if endedAt <= span.startedAt { return false }
    return dateKeyOf(span.startedAt, in: zone) != dateKeyOf(endedAt, in: zone)
}

/// Split a span at every local midnight it crosses.
///
/// - An open span is returned as a single open piece; it is split later, when closed.
/// - A zero-length or reversed span is returned unchanged as a single piece, so the
///   caller's validation (not this function) decides whether to reject it.
/// - A piece that would end exactly at midnight does not produce an empty next piece.
///
/// The returned pieces are contiguous and in ascending order: piece[n].endedAt
/// equals piece[n+1].startedAt.
public func splitAtMidnight(_ span: some Span, in zone: TimeZone = .current) -> [SplitPiece] {
    guard let endedAt = span.endedAt else {
        return [SplitPiece(
            type: span.type,
            startedAt: span.startedAt,
            endedAt: nil,
            date: dateKeyOf(span.startedAt, in: zone)
        )]
    }

    if endedAt <= span.startedAt {
        return [SplitPiece(
            type: span.type,
            startedAt: span.startedAt,
            endedAt: endedAt,
            date: dateKeyOf(span.startedAt, in: zone)
        )]
    }

    var pieces: [SplitPiece] = []
    var cursor = span.startedAt

    // Strict `<` is what keeps a span that lands exactly on a boundary from
    // emitting a zero-length piece for the day it never actually reached.
    while cursor < endedAt {
        let boundary = nextMidnightAfter(cursor, in: zone)
        let pieceEnd = min(boundary, endedAt)
        pieces.append(SplitPiece(
            type: span.type,
            startedAt: cursor,
            endedAt: pieceEnd,
            date: dateKeyOf(cursor, in: zone)
        ))
        cursor = pieceEnd
    }

    return pieces
}

/// Split an open span at midnight *as of* `now`, for the case where the app has been
/// left running past midnight: the piece up to the boundary is closed and a new open
/// piece begins at the boundary.
///
/// Returns `nil` when the span has not yet crossed a boundary, so the caller can
/// cheaply do nothing on the common path.
public func splitOpenSpanAt(
    _ span: some Span,
    now: EpochMs,
    in zone: TimeZone = .current
) -> OpenSpanSplit? {
    guard span.endedAt == nil else { return nil }
    let boundary = nextMidnightAfter(span.startedAt, in: zone)
    if now < boundary { return nil }

    // Local midnight at or before `now`. For a span that has been open for several
    // days the reopened piece deliberately absorbs start-of-today → now as live time.
    let startOfCurrentDay = startOfDayAt(now, in: zone)

    let closedPieces = splitAtMidnight(
        SpanDraft(type: span.type, startedAt: span.startedAt, endedAt: startOfCurrentDay),
        in: zone
    )

    return OpenSpanSplit(
        closed: closedPieces,
        reopened: SplitPiece(
            type: span.type,
            startedAt: startOfCurrentDay,
            endedAt: nil,
            date: dateKeyOf(now, in: zone)
        )
    )
}
