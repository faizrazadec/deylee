import Foundation
import Testing

import DaylyKit

/// Tests for overlap validation, ported from `tests/overlap.test.ts`.
///
/// The load-bearing rule is that intervals are half-open, `[startedAt, endedAt)`:
/// a pause immediately followed by a resume produces two segments that share an
/// instant, and that must stay legal or the timer could never pause.
///
/// The TS suite ran in whatever zone the machine had; every clock string it asserts is
/// local. Here the zone is pinned to Europe/Berlin and threaded through explicitly, so
/// the messages are reproducible on any machine.
private let overlapBerlin = TimeZone(identifier: "Europe/Berlin")!

private func overlapLocal(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0,
    in zone: TimeZone = overlapBerlin
) -> EpochMs {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let comps = DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: 0)
    return EpochMs((calendar.date(from: comps)!.timeIntervalSince1970 * 1_000).rounded())
}

/// Hours on 2025-08-04, the ordinary day every case in this file lives on.
private func overlapAt(_ h: Int, _ min: Int = 0, in zone: TimeZone = overlapBerlin) -> EpochMs {
    overlapLocal(2025, 8, 4, h, min, in: zone)
}

private func overlapInterval(_ startedAt: EpochMs, _ endedAt: EpochMs?) -> Interval {
    Interval(startedAt: startedAt, endedAt: endedAt)
}

private func overlapSegment(
    _ id: Int64, _ type: SegmentType, _ startedAt: EpochMs, _ endedAt: EpochMs?
) -> Segment {
    Segment(
        id: id,
        dayId: 1,
        type: type,
        startedAt: startedAt,
        endedAt: endedAt,
        note: nil,
        createdAt: startedAt,
        updatedAt: endedAt ?? startedAt
    )
}

@Suite struct OverlapIntervalsOverlapTests {
    @Test func isFalseForDisjointIntervalsInEitherArgumentOrder() {
        let a = overlapInterval(overlapAt(9), overlapAt(10))
        let b = overlapInterval(overlapAt(11), overlapAt(12))
        #expect(intervalsOverlap(a, b) == false)
        #expect(intervalsOverlap(b, a) == false)
    }

    @Test func isFalseWhenTheEndpointsMerelyTouchThePauseResumeBoundary() {
        let work = overlapInterval(overlapAt(9), overlapAt(12))
        let pause = overlapInterval(overlapAt(12), overlapAt(12, 45))
        #expect(intervalsOverlap(work, pause) == false)
        #expect(intervalsOverlap(pause, work) == false)
    }

    @Test func isTrueWhenTheIntervalsShareAnyPositiveLengthSpan() {
        let a = overlapInterval(overlapAt(9), overlapAt(12))
        let b = overlapInterval(overlapAt(11, 59), overlapAt(13))
        #expect(intervalsOverlap(a, b))
        #expect(intervalsOverlap(b, a))
    }

    @Test func isTrueWhenOneIntervalContainsTheOther() {
        let outer = overlapInterval(overlapAt(9), overlapAt(17))
        let inner = overlapInterval(overlapAt(11), overlapAt(12))
        #expect(intervalsOverlap(outer, inner))
        #expect(intervalsOverlap(inner, outer))
    }

    @Test func isTrueForIdenticalIntervals() {
        #expect(
            intervalsOverlap(
                overlapInterval(overlapAt(9), overlapAt(12)),
                overlapInterval(overlapAt(9), overlapAt(12))
            )
        )
    }

    @Test func treatsAnOpenEndedIntervalAsRunningForever() {
        let open = overlapInterval(overlapAt(9), nil)
        #expect(intervalsOverlap(open, overlapInterval(overlapAt(20), overlapAt(21))))
        #expect(intervalsOverlap(overlapInterval(overlapAt(20), overlapAt(21)), open))
        #expect(intervalsOverlap(open, overlapInterval(overlapAt(7), overlapAt(8))) == false)
    }

    @Test func letsAClosedIntervalEndExactlyWhereAnOpenOneBegins() {
        let closed = overlapInterval(overlapAt(9), overlapAt(12))
        let open = overlapInterval(overlapAt(12), nil)
        #expect(intervalsOverlap(closed, open) == false)
        #expect(intervalsOverlap(open, closed) == false)
    }

    @Test func isTrueForTwoOpenEndedIntervalsWhateverTheirStarts() {
        #expect(
            intervalsOverlap(
                overlapInterval(overlapAt(9), nil),
                overlapInterval(overlapAt(15), nil)
            )
        )
    }

    @Test func isFalseForAReversedIntervalThatNoLongerCoversAnything() {
        #expect(
            intervalsOverlap(
                overlapInterval(overlapAt(13), overlapAt(11)),
                overlapInterval(overlapAt(9), overlapAt(12))
            ) == false
        )
    }

    /// Not expressible in TS, where a segment and an interval are the same shape.
    @Test func readsItsBoundsOffAnySpan() {
        let segment = overlapSegment(1, .work, overlapAt(9), overlapAt(12))
        let draft = SpanDraft(type: .break, startedAt: overlapAt(11), endedAt: nil)
        #expect(Interval(segment) == overlapInterval(overlapAt(9), overlapAt(12)))
        #expect(Interval(draft) == overlapInterval(overlapAt(11), nil))
        #expect(intervalsOverlap(Interval(segment), Interval(draft)))
    }
}

@Suite struct OverlapFindOverlappingTests {
    let existing = [
        overlapSegment(1, .work, overlapAt(9), overlapAt(12)),
        overlapSegment(2, .break, overlapAt(12), overlapAt(12, 45)),
        overlapSegment(3, .work, overlapAt(12, 45), overlapAt(17)),
    ]

    @Test func returnsNilWhenNothingConflicts() {
        #expect(findOverlapping(overlapInterval(overlapAt(17), overlapAt(18)), in: existing) == nil)
        #expect(findOverlapping(overlapInterval(overlapAt(7), overlapAt(9)), in: existing) == nil)
        #expect(findOverlapping(overlapInterval(overlapAt(9), overlapAt(12)), in: []) == nil)
    }

    @Test func returnsTheFirstConflictingSegmentInListOrder() {
        // Spans all three; the first one encountered wins.
        #expect(findOverlapping(overlapInterval(overlapAt(10), overlapAt(16)), in: existing)?.id == 1)
        #expect(
            findOverlapping(overlapInterval(overlapAt(12, 30), overlapAt(16)), in: existing)?.id == 2
        )
        #expect(findOverlapping(overlapInterval(overlapAt(13), overlapAt(16)), in: existing)?.id == 3)
    }

    @Test func ignoresTheSegmentBeingEdited() {
        // Nudging segment 2's end later only clashes with itself and with segment 3.
        #expect(
            findOverlapping(
                overlapInterval(overlapAt(12), overlapAt(12, 30)), in: existing, ignoring: 2
            ) == nil
        )
        #expect(
            findOverlapping(
                overlapInterval(overlapAt(12), overlapAt(13)), in: existing, ignoring: 2
            )?.id == 3
        )
    }

    @Test func onlyIgnoresTheIdItWasGiven() {
        #expect(
            findOverlapping(
                overlapInterval(overlapAt(10), overlapAt(11)), in: existing, ignoring: 3
            )?.id == 1
        )
        #expect(
            findOverlapping(
                overlapInterval(overlapAt(10), overlapAt(11)), in: existing, ignoring: 999
            )?.id == 1
        )
    }

    @Test func findsAConflictWithAStoredOpenSegment() {
        let withOpen = [overlapSegment(7, .work, overlapAt(9), nil)]
        #expect(findOverlapping(overlapInterval(overlapAt(22), overlapAt(23)), in: withOpen)?.id == 7)
        #expect(findOverlapping(overlapInterval(overlapAt(7), overlapAt(9)), in: withOpen) == nil)
    }

    /// Not expressible in TS, where `ignoreId` was an optional parameter rather than a
    /// value that can itself be absent.
    @Test func ignoresNothingWhenNoIdIsGiven() {
        #expect(
            findOverlapping(
                overlapInterval(overlapAt(10), overlapAt(11)), in: existing, ignoring: nil
            )?.id == 1
        )
    }
}

@Suite struct OverlapValidateSegmentTests {
    let existing = [
        overlapSegment(1, .work, overlapAt(9), overlapAt(12)),
        overlapSegment(2, .break, overlapAt(12), overlapAt(12, 45)),
    ]

    @Test func acceptsAWellFormedCandidateInFreeTime() {
        let candidate = overlapInterval(overlapAt(13), overlapAt(17))
        #expect(validateSegment(candidate, against: existing, in: overlapBerlin) == nil)
    }

    @Test func acceptsACandidateThatExactlyAbutsItsNeighbours() {
        #expect(
            validateSegment(
                overlapInterval(overlapAt(12, 45), overlapAt(17)), against: existing,
                in: overlapBerlin
            ) == nil
        )
        #expect(
            validateSegment(
                overlapInterval(overlapAt(7), overlapAt(9)), against: existing, in: overlapBerlin
            ) == nil
        )
    }

    @Test func acceptsAnOpenEndedCandidateThatStartsAfterEverythingElse() {
        #expect(
            validateSegment(
                overlapInterval(overlapAt(12, 45), nil), against: existing, in: overlapBerlin
            ) == nil
        )
    }

    @Test func acceptsAnEditOfAnExistingSegmentWhenItIsExcludedFromTheComparison() {
        #expect(
            validateSegment(
                overlapInterval(overlapAt(9), overlapAt(11, 30)), against: existing, ignoring: 1,
                in: overlapBerlin
            ) == nil
        )
    }

    @Test func rejectsAReversedRange() {
        let result = validateSegment(
            overlapInterval(overlapAt(17), overlapAt(13)), against: existing, in: overlapBerlin
        )
        #expect(
            result
                == MutationError(code: .invalidRange, message: "End time is before the start time.")
        )
    }

    @Test func rejectsAZeroLengthRange() {
        let result = validateSegment(
            overlapInterval(overlapAt(13), overlapAt(13)), against: existing, in: overlapBerlin
        )
        #expect(
            result
                == MutationError(code: .invalidRange, message: "Start and end time are the same.")
        )
    }

    /// The TS fed `NaN` / `Infinity` straight into the interval; `EpochMs` is an `Int64`
    /// and cannot hold those, so the unparsed-input overload carries the same two checks.
    @Test func rejectsInstantsThatNeverParsed() {
        #expect(
            validateSegment(
                startedAt: nil, endedAt: .some(overlapAt(13)), against: existing, in: overlapBerlin
            ) == MutationError(code: .invalidRange, message: "Start time is not a valid instant.")
        )
        #expect(
            validateSegment(
                startedAt: overlapAt(13), endedAt: nil, against: existing, in: overlapBerlin
            ) == MutationError(code: .invalidRange, message: "End time is not a valid instant.")
        )
        #expect(
            validateSegment(
                startedAt: nil, endedAt: .some(nil), against: existing, in: overlapBerlin
            ) == MutationError(code: .invalidRange, message: "Start time is not a valid instant.")
        )
    }

    /// An unparsed start beats an unparsed end, as in the TS check order.
    @Test func reportsTheStartFirstWhenNeitherInstantParsed() {
        #expect(
            validateSegment(startedAt: nil, endedAt: nil, against: existing, in: overlapBerlin)
                == MutationError(code: .invalidRange, message: "Start time is not a valid instant.")
        )
    }

    /// Parsed instants take the same path as the plain-interval entry point.
    @Test func acceptsParsedInstantsThroughTheUnparsedInputOverload() {
        #expect(
            validateSegment(
                startedAt: overlapAt(13), endedAt: .some(overlapAt(17)), against: existing,
                in: overlapBerlin
            ) == nil
        )
        #expect(
            validateSegment(
                startedAt: overlapAt(12, 45), endedAt: .some(nil), against: existing,
                in: overlapBerlin
            ) == nil
        )
    }

    @Test func checksTheRangeBeforeTheOverlapSoAReversedClashReportsTheRange() {
        let result = validateSegment(
            overlapInterval(overlapAt(12), overlapAt(10)), against: existing, in: overlapBerlin
        )
        #expect(result?.code == .invalidRange)
    }

    @Test func rejectsAnOverlapAndNamesTheClashingSegmentInLocalWallClockTime() {
        let result = validateSegment(
            overlapInterval(overlapAt(11), overlapAt(13)), against: existing, in: overlapBerlin
        )
        #expect(
            result
                == MutationError(
                    code: .overlap,
                    message: "Overlaps the work segment from 09:00 to 12:00."
                )
        )
    }

    @Test func describesAClashWithAnOpenSegmentAsEndingNow() {
        let result = validateSegment(
            overlapInterval(overlapAt(15), overlapAt(16)),
            against: [overlapSegment(9, .break, overlapAt(14), nil)],
            in: overlapBerlin
        )
        #expect(
            result
                == MutationError(
                    code: .overlap,
                    message: "Overlaps the break segment from 14:00 to now."
                )
        )
    }

    @Test func rejectsAnOpenEndedCandidateThatSwallowsALaterSegment() {
        let result = validateSegment(
            overlapInterval(overlapAt(11), nil), against: existing, in: overlapBerlin
        )
        #expect(result?.code == .overlap)
    }

    @Test func acceptsAnythingWhenThereAreNoOtherSegments() {
        #expect(
            validateSegment(
                overlapInterval(overlapAt(9), overlapAt(17)), against: [], in: overlapBerlin
            ) == nil
        )
    }

    /// The TS suite could not pin a zone — it read the machine's. The clash message is
    /// wall-clock, so the zone it is rendered in is part of the contract.
    @Test func rendersTheClashInTheZoneItWasGiven() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let result = validateSegment(
            overlapInterval(overlapAt(11), overlapAt(13)), against: existing, in: newYork
        )
        #expect(
            result
                == MutationError(
                    code: .overlap,
                    message: "Overlaps the work segment from 03:00 to 06:00."
                )
        )
    }
}

@Suite struct OverlapFindOpenSegmentsTests {
    @Test func returnsOnlyTheSegmentsWithNoEnd() {
        let segments = [
            overlapSegment(1, .work, overlapAt(9), overlapAt(12)),
            overlapSegment(2, .break, overlapAt(12), nil),
            overlapSegment(3, .work, overlapAt(13), nil),
        ]
        #expect(findOpenSegments(segments).map(\.id) == [2, 3])
    }

    @Test func returnsAnEmptyListWhenEverythingIsClosed() {
        #expect(findOpenSegments([overlapSegment(1, .work, overlapAt(9), overlapAt(12))]).isEmpty)
        #expect(findOpenSegments([]).isEmpty)
    }
}
