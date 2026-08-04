import Foundation
import Testing

@testable import DeyleeKit

/// Tests for the duration/aggregation maths.
///
/// Pinned to Europe/Berlin, so day-clipping is exercised against a 23-hour day
/// (2025-03-30) and a 25-hour day (2025-10-26) as well as ordinary ones. Instants are
/// always built with `durationLocal`, the counterpart of the TS suite's local
/// `new Date(y, m - 1, d, ...)` constructor.

private let durationBerlin = TimeZone(identifier: "Europe/Berlin")!

private let DURATION_HOUR: Int64 = 3_600_000
private let DURATION_MINUTE: Int64 = 60_000

private func durationLocal(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, _ ms: Int = 0
) -> EpochMs {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = durationBerlin
    let base = calendar.date(
        from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s)
    )!
    return base.epochMs + EpochMs(ms)
}

private func durationSpan(_ type: SegmentType, _ startedAt: EpochMs, _ endedAt: EpochMs?)
    -> SpanDraft
{
    SpanDraft(type: type, startedAt: startedAt, endedAt: endedAt)
}

private func durationSegment(
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

/// The TS suite spreads a partial over a base literal; Swift takes the same defaults
/// as arguments instead.
private func durationSnapshot(
    state: TimerState = .idle,
    date: DateKey = DateKey("2025-08-04")!,
    dayId: Int64? = 1,
    closedWorkedMs: Int64 = 0,
    closedBreakMs: Int64 = 0,
    openSegment: Segment? = nil,
    firstStartAt: EpochMs? = nil,
    lastEndAt: EpochMs? = nil,
    targetMinutes: Int = 480,
    asOf: EpochMs = durationLocal(2025, 8, 4, 12, 0)
) -> TimerSnapshot {
    TimerSnapshot(
        state: state,
        date: date,
        dayId: dayId,
        closedWorkedMs: closedWorkedMs,
        closedBreakMs: closedBreakMs,
        openSegment: openSegment,
        firstStartAt: firstStartAt,
        lastEndAt: lastEndAt,
        targetMinutes: targetMinutes,
        asOf: asOf
    )
}

@Suite struct DurationSpanDurationTests {
    @Test func measuresAClosedSpanEndToEnd() {
        #expect(
            spanDuration(
                durationSpan(.work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 11, 30))
            ) == 2 * DURATION_HOUR + 30 * DURATION_MINUTE
        )
    }

    @Test func measuresAnOpenSpanUpToNow() {
        let started = durationLocal(2025, 8, 4, 9, 0)
        #expect(
            spanDuration(durationSpan(.work, started, nil), now: durationLocal(2025, 8, 4, 10, 15))
                == DURATION_HOUR + 15 * DURATION_MINUTE
        )
    }

    @Test func isZeroForAReversedSpan() {
        #expect(
            spanDuration(
                durationSpan(.work, durationLocal(2025, 8, 4, 11, 0), durationLocal(2025, 8, 4, 9, 0))
            ) == 0
        )
    }

    @Test func isZeroForAZeroLengthSpan() {
        let at = durationLocal(2025, 8, 4, 9, 0)
        #expect(spanDuration(durationSpan(.break, at, at)) == 0)
    }

    @Test func isZeroForAnOpenSpanThatHasNotStartedYet() {
        let started = durationLocal(2025, 8, 4, 15, 0)
        #expect(
            spanDuration(durationSpan(.work, started, nil), now: durationLocal(2025, 8, 4, 9, 0)) == 0
        )
    }

    @Test func measuresRealElapsedTimeAcrossADSTTransitionNotWallClockHours() {
        // 00:00 CET to 12:00 CEST on the 23-hour day is only 11 real hours.
        #expect(
            spanDuration(
                durationSpan(.work, durationLocal(2025, 3, 30, 0, 0), durationLocal(2025, 3, 30, 12, 0))
            ) == 11 * DURATION_HOUR
        )
        // 00:00 CEST to 12:00 CET on the 25-hour day is 13 real hours.
        #expect(
            spanDuration(
                durationSpan(
                    .work, durationLocal(2025, 10, 26, 0, 0), durationLocal(2025, 10, 26, 12, 0)
                )
            ) == 13 * DURATION_HOUR
        )
    }

    @Test func defaultsNowToTheCurrentInstantForAnOpenSpan() {
        let measured = spanDuration(durationSpan(.work, epochNow() - 5 * DURATION_MINUTE, nil))
        #expect(measured >= 5 * DURATION_MINUTE)
        #expect(measured < 6 * DURATION_MINUTE)
    }
}

@Suite struct DurationSpanDurationWithinDayTests {
    let day = DateKey("2025-08-04")!

    @Test func returnsTheWholeSpanWhenItSitsInsideTheDay() {
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 17, 0)),
                day,
                in: durationBerlin
            ) == 8 * DURATION_HOUR
        )
    }

    @Test func clipsASpanThatStartsBeforeTheDay() {
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 3, 22, 0), durationLocal(2025, 8, 4, 1, 30)),
                day,
                in: durationBerlin
            ) == DURATION_HOUR + 30 * DURATION_MINUTE
        )
    }

    @Test func clipsASpanThatEndsAfterTheDay() {
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 4, 22, 0), durationLocal(2025, 8, 5, 1, 30)),
                day,
                in: durationBerlin
            ) == 2 * DURATION_HOUR
        )
    }

    @Test func clipsASpanThatStartsBeforeAndEndsAfterTheDayToTheWholeDay() {
        let wide = durationSpan(
            .work, durationLocal(2025, 8, 3, 22, 0), durationLocal(2025, 8, 5, 3, 0)
        )
        #expect(spanDurationWithinDay(wide, day, in: durationBerlin) == 24 * DURATION_HOUR)
    }

    @Test func clipsAWholeDayOverlapTo23HoursOnTheSpringForwardDay() {
        let wide = durationSpan(
            .work, durationLocal(2025, 3, 29, 22, 0), durationLocal(2025, 3, 31, 3, 0)
        )
        #expect(
            spanDurationWithinDay(wide, DateKey("2025-03-30")!, in: durationBerlin)
                == 23 * DURATION_HOUR
        )
    }

    @Test func clipsAWholeDayOverlapTo25HoursOnTheFallBackDay() {
        let wide = durationSpan(
            .work, durationLocal(2025, 10, 25, 22, 0), durationLocal(2025, 10, 27, 3, 0)
        )
        #expect(
            spanDurationWithinDay(wide, DateKey("2025-10-26")!, in: durationBerlin)
                == 25 * DURATION_HOUR
        )
    }

    @Test func isZeroWhenTheSpanDoesNotTouchTheDayAtAll() {
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 1, 9, 0), durationLocal(2025, 8, 1, 17, 0)),
                day,
                in: durationBerlin
            ) == 0
        )
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 6, 9, 0), durationLocal(2025, 8, 6, 17, 0)),
                day,
                in: durationBerlin
            ) == 0
        )
    }

    @Test func isZeroForSpansThatMerelyTouchADayBoundary() {
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 3, 22, 0), durationLocal(2025, 8, 4, 0, 0)),
                day,
                in: durationBerlin
            ) == 0
        )
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 5, 0, 0), durationLocal(2025, 8, 5, 2, 0)),
                day,
                in: durationBerlin
            ) == 0
        )
    }

    @Test func isZeroForAReversedSpan() {
        #expect(
            spanDurationWithinDay(
                durationSpan(.work, durationLocal(2025, 8, 4, 17, 0), durationLocal(2025, 8, 4, 9, 0)),
                day,
                in: durationBerlin
            ) == 0
        )
    }

    @Test func measuresAnOpenSpanUpToNow() {
        let open = durationSpan(.work, durationLocal(2025, 8, 4, 9, 0), nil)
        #expect(
            spanDurationWithinDay(
                open, day, now: durationLocal(2025, 8, 4, 12, 30), in: durationBerlin
            ) == 3 * DURATION_HOUR + 30 * DURATION_MINUTE
        )
    }

    @Test func creditsTodayOnlyWithTodayForAnOpenSpanThatBeganYesterday() {
        let open = durationSpan(.work, durationLocal(2025, 8, 3, 23, 0), nil)
        #expect(
            spanDurationWithinDay(
                open, day, now: durationLocal(2025, 8, 4, 2, 30), in: durationBerlin
            ) == 2 * DURATION_HOUR + 30 * DURATION_MINUTE
        )
        #expect(
            spanDurationWithinDay(
                open,
                DateKey("2025-08-03")!,
                now: durationLocal(2025, 8, 4, 2, 30),
                in: durationBerlin
            ) == DURATION_HOUR
        )
    }

    @Test func stopsAnOpenSpanAtTheEndOfTheDayOnceNowHasMovedPastIt() {
        let open = durationSpan(.work, durationLocal(2025, 8, 4, 22, 0), nil)
        #expect(
            spanDurationWithinDay(
                open, day, now: durationLocal(2025, 8, 5, 6, 0), in: durationBerlin
            ) == 2 * DURATION_HOUR
        )
    }
}

@Suite struct DurationSumWithinDayTests {
    let day = DateKey("2025-08-04")!
    let spans: [SpanDraft] = [
        durationSpan(.work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 12, 0)),
        durationSpan(.break, durationLocal(2025, 8, 4, 12, 0), durationLocal(2025, 8, 4, 12, 45)),
        durationSpan(.work, durationLocal(2025, 8, 4, 12, 45), durationLocal(2025, 8, 4, 17, 0)),
        durationSpan(.break, durationLocal(2025, 8, 4, 17, 0), durationLocal(2025, 8, 4, 17, 15)),
    ]

    @Test func sumsOnlyTheRequestedType() {
        #expect(
            sumWithinDay(spans, .work, day, in: durationBerlin)
                == 7 * DURATION_HOUR + 15 * DURATION_MINUTE
        )
        #expect(sumWithinDay(spans, .break, day, in: durationBerlin) == DURATION_HOUR)
    }

    @Test func isZeroForAnEmptyList() {
        #expect(sumWithinDay([SpanDraft](), .work, day, in: durationBerlin) == 0)
    }

    @Test func isZeroWhenNothingMatchesTheType() {
        #expect(sumWithinDay([spans[0], spans[2]], .break, day, in: durationBerlin) == 0)
    }

    @Test func clipsEachSpanToTheDayBeforeSumming() {
        let straddling: [SpanDraft] = [
            durationSpan(.work, durationLocal(2025, 8, 3, 23, 0), durationLocal(2025, 8, 4, 1, 0)),
            durationSpan(.work, durationLocal(2025, 8, 4, 23, 0), durationLocal(2025, 8, 5, 2, 0)),
        ]
        #expect(sumWithinDay(straddling, .work, day, in: durationBerlin) == 2 * DURATION_HOUR)
        #expect(
            sumWithinDay(straddling, .work, DateKey("2025-08-03")!, in: durationBerlin)
                == DURATION_HOUR
        )
        #expect(
            sumWithinDay(straddling, .work, DateKey("2025-08-05")!, in: durationBerlin)
                == 2 * DURATION_HOUR
        )
    }

    @Test func includesTheOpenSpanMeasuredToNow() {
        let withOpen: [SpanDraft] = [
            durationSpan(.work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 12, 0)),
            durationSpan(.work, durationLocal(2025, 8, 4, 13, 0), nil),
        ]
        #expect(
            sumWithinDay(
                withOpen, .work, day, now: durationLocal(2025, 8, 4, 14, 30), in: durationBerlin
            ) == 4 * DURATION_HOUR + 30 * DURATION_MINUTE
        )
    }

    /// Not expressible in the TS suite, where `SpanLike` is structural: the Swift
    /// version is generic over `Span`, so stored rows sum exactly like drafts.
    @Test func sumsStoredSegmentsToo() {
        let segments = [
            durationSegment(1, .work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 12, 0)),
            durationSegment(2, .break, durationLocal(2025, 8, 4, 12, 0), durationLocal(2025, 8, 4, 12, 30)),
        ]
        #expect(sumWithinDay(segments, .work, day, in: durationBerlin) == 3 * DURATION_HOUR)
        #expect(sumWithinDay(segments, .break, day, in: durationBerlin) == 30 * DURATION_MINUTE)
    }
}

@Suite struct DurationDayTotalsTests {
    let day = DateKey("2025-08-04")!

    @Test func isAllZerosAndNilsForADayWithNoSegments() {
        #expect(
            dayTotals([], day, now: durationLocal(2025, 8, 4, 12, 0), in: durationBerlin)
                == DayTotals(
                    workedMs: 0,
                    breakMs: 0,
                    firstStartAt: nil,
                    lastEndAt: nil,
                    segmentCount: 0,
                    hasOpenSegment: false
                )
        )
    }

    @Test func derivesWorkedBreakFirstStartLastEndAndTheSegmentCount() {
        let segments = [
            durationSegment(1, .work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 12, 0)),
            durationSegment(2, .break, durationLocal(2025, 8, 4, 12, 0), durationLocal(2025, 8, 4, 12, 45)),
            durationSegment(3, .work, durationLocal(2025, 8, 4, 12, 45), durationLocal(2025, 8, 4, 17, 30)),
        ]

        #expect(
            dayTotals(segments, day, now: durationLocal(2025, 8, 4, 18, 0), in: durationBerlin)
                == DayTotals(
                    workedMs: 7 * DURATION_HOUR + 45 * DURATION_MINUTE,
                    breakMs: 45 * DURATION_MINUTE,
                    firstStartAt: durationLocal(2025, 8, 4, 9, 0),
                    lastEndAt: durationLocal(2025, 8, 4, 17, 30),
                    segmentCount: 3,
                    hasOpenSegment: false
                )
        )
    }

    @Test func takesTheEarliestStartAndLatestEndRegardlessOfStorageOrder() {
        let segments = [
            durationSegment(3, .work, durationLocal(2025, 8, 4, 14, 0), durationLocal(2025, 8, 4, 17, 30)),
            durationSegment(1, .work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 12, 0)),
            durationSegment(2, .break, durationLocal(2025, 8, 4, 12, 0), durationLocal(2025, 8, 4, 14, 0)),
        ]
        let totals = dayTotals(
            segments, day, now: durationLocal(2025, 8, 4, 18, 0), in: durationBerlin
        )
        #expect(totals.firstStartAt == durationLocal(2025, 8, 4, 9, 0))
        #expect(totals.lastEndAt == durationLocal(2025, 8, 4, 17, 30))
    }

    @Test func reportsLastEndAtAsNilWhileASegmentIsStillOpen() {
        let segments = [
            durationSegment(1, .work, durationLocal(2025, 8, 4, 9, 0), durationLocal(2025, 8, 4, 12, 0)),
            durationSegment(2, .break, durationLocal(2025, 8, 4, 12, 0), durationLocal(2025, 8, 4, 12, 30)),
            durationSegment(3, .work, durationLocal(2025, 8, 4, 12, 30), nil),
        ]
        let totals = dayTotals(
            segments, day, now: durationLocal(2025, 8, 4, 15, 0), in: durationBerlin
        )

        #expect(totals.hasOpenSegment)
        #expect(totals.lastEndAt == nil)
        #expect(totals.firstStartAt == durationLocal(2025, 8, 4, 9, 0))
        #expect(totals.workedMs == 5 * DURATION_HOUR + 30 * DURATION_MINUTE)
        #expect(totals.breakMs == 30 * DURATION_MINUTE)
        #expect(totals.segmentCount == 3)
    }

    @Test func countsAnOpenBreakIntoTheBreakBucket() {
        let segments = [durationSegment(1, .break, durationLocal(2025, 8, 4, 12, 0), nil)]
        let totals = dayTotals(
            segments, day, now: durationLocal(2025, 8, 4, 12, 20), in: durationBerlin
        )
        #expect(totals.breakMs == 20 * DURATION_MINUTE)
        #expect(totals.workedMs == 0)
        #expect(totals.hasOpenSegment)
    }

    @Test func clipsASegmentThatLeaksPastMidnightToTheDayBeingTotalled() {
        let segments = [
            durationSegment(1, .work, durationLocal(2025, 8, 4, 22, 0), durationLocal(2025, 8, 5, 2, 0))
        ]
        #expect(
            dayTotals(segments, day, now: durationLocal(2025, 8, 5, 9, 0), in: durationBerlin)
                .workedMs == 2 * DURATION_HOUR
        )
        #expect(
            dayTotals(
                segments,
                DateKey("2025-08-05")!,
                now: durationLocal(2025, 8, 5, 9, 0),
                in: durationBerlin
            ).workedMs == 2 * DURATION_HOUR
        )
    }

    @Test func clipsAgainstThe23hAnd25hDays() {
        let short = [
            durationSegment(1, .work, durationLocal(2025, 3, 30, 0, 0), durationLocal(2025, 3, 31, 0, 0))
        ]
        #expect(
            dayTotals(
                short,
                DateKey("2025-03-30")!,
                now: durationLocal(2025, 3, 31, 9, 0),
                in: durationBerlin
            ).workedMs == 23 * DURATION_HOUR
        )

        let long = [
            durationSegment(1, .work, durationLocal(2025, 10, 26, 0, 0), durationLocal(2025, 10, 27, 0, 0))
        ]
        #expect(
            dayTotals(
                long,
                DateKey("2025-10-26")!,
                now: durationLocal(2025, 10, 27, 9, 0),
                in: durationBerlin
            ).workedMs == 25 * DURATION_HOUR
        )
    }

    /// Not expressible in the TS suite: `firstStartAt` keeps the raw, unclipped start
    /// even when the clipped duration credited to the day is much shorter.
    @Test func firstStartAtKeepsTheRawStartOfASegmentThatBeganBeforeTheDay() {
        let segments = [
            durationSegment(1, .work, durationLocal(2025, 8, 3, 22, 0), durationLocal(2025, 8, 4, 1, 0))
        ]
        let totals = dayTotals(
            segments, day, now: durationLocal(2025, 8, 4, 9, 0), in: durationBerlin
        )
        #expect(totals.firstStartAt == durationLocal(2025, 8, 3, 22, 0))
        #expect(totals.workedMs == DURATION_HOUR)
    }
}

@Suite struct DurationLiveTotalsTests {
    let targetMs = 480 * DURATION_MINUTE

    @Test func returnsTheClosedTotalsWhenNothingIsOpen() {
        let live = liveTotals(
            durationSnapshot(closedWorkedMs: 4 * DURATION_HOUR, closedBreakMs: 30 * DURATION_MINUTE),
            now: durationLocal(2025, 8, 4, 14, 0),
            in: durationBerlin
        )

        #expect(live.workedMs == 4 * DURATION_HOUR)
        #expect(live.breakMs == 30 * DURATION_MINUTE)
        #expect(live.targetMs == targetMs)
        #expect(abs(live.targetProgress - 0.5) < 1e-10)
        #expect(live.remainingToTargetMs == 4 * DURATION_HOUR)
    }

    @Test func addsAnOpenWorkSegmentToTheWorkedBucketOnly() {
        let live = liveTotals(
            durationSnapshot(
                state: .running,
                closedWorkedMs: 4 * DURATION_HOUR,
                closedBreakMs: 30 * DURATION_MINUTE,
                openSegment: durationSegment(9, .work, durationLocal(2025, 8, 4, 13, 0), nil)
            ),
            now: durationLocal(2025, 8, 4, 14, 30),
            in: durationBerlin
        )

        #expect(live.workedMs == 5 * DURATION_HOUR + 30 * DURATION_MINUTE)
        #expect(live.breakMs == 30 * DURATION_MINUTE)
        #expect(live.remainingToTargetMs == 2 * DURATION_HOUR + 30 * DURATION_MINUTE)
    }

    @Test func addsAnOpenBreakSegmentToTheBreakBucketOnly() {
        let live = liveTotals(
            durationSnapshot(
                state: .paused,
                closedWorkedMs: 4 * DURATION_HOUR,
                closedBreakMs: 30 * DURATION_MINUTE,
                openSegment: durationSegment(9, .break, durationLocal(2025, 8, 4, 13, 0), nil)
            ),
            now: durationLocal(2025, 8, 4, 13, 45),
            in: durationBerlin
        )

        #expect(live.workedMs == 4 * DURATION_HOUR)
        #expect(live.breakMs == DURATION_HOUR + 15 * DURATION_MINUTE)
    }

    @Test func clampsAnOpenSegmentThatBeganYesterdayToTodayLocalMidnight() {
        let live = liveTotals(
            durationSnapshot(
                state: .running,
                openSegment: durationSegment(9, .work, durationLocal(2025, 8, 3, 22, 0), nil)
            ),
            now: durationLocal(2025, 8, 4, 2, 30),
            in: durationBerlin
        )

        #expect(live.workedMs == 2 * DURATION_HOUR + 30 * DURATION_MINUTE)
    }

    @Test func clampsToTheCurrentLocalMidnightEvenWhenItIs25HoursFromThePreviousOne() {
        let live = liveTotals(
            durationSnapshot(
                state: .running,
                date: DateKey("2025-10-26")!,
                openSegment: durationSegment(9, .work, durationLocal(2025, 10, 25, 23, 0), nil)
            ),
            now: durationLocal(2025, 10, 26, 1, 0),
            in: durationBerlin
        )

        #expect(live.workedMs == DURATION_HOUR)
    }

    @Test func contributesNothingForAnOpenSegmentThatHasNotStartedYet() {
        let live = liveTotals(
            durationSnapshot(
                state: .running,
                closedWorkedMs: DURATION_HOUR,
                openSegment: durationSegment(9, .work, durationLocal(2025, 8, 4, 16, 0), nil)
            ),
            now: durationLocal(2025, 8, 4, 15, 0),
            in: durationBerlin
        )

        #expect(live.workedMs == DURATION_HOUR)
    }

    @Test func letsProgressExceed1AndRemainingGoNegativePastTheTarget() {
        let live = liveTotals(
            durationSnapshot(closedWorkedMs: 9 * DURATION_HOUR, targetMinutes: 480),
            now: durationLocal(2025, 8, 4, 19, 0),
            in: durationBerlin
        )

        #expect(abs(live.targetProgress - 1.125) < 1e-10)
        #expect(live.remainingToTargetMs == -DURATION_HOUR)
    }

    @Test func reportsZeroProgressForAZeroTargetInsteadOfDividingByZero() {
        let live = liveTotals(
            durationSnapshot(closedWorkedMs: 3 * DURATION_HOUR, targetMinutes: 0),
            now: durationLocal(2025, 8, 4, 12, 0),
            in: durationBerlin
        )

        #expect(live.targetMs == 0)
        #expect(live.targetProgress == 0)
        #expect(live.remainingToTargetMs == -3 * DURATION_HOUR)
    }

    @Test func treatsANegativeTargetAsZero() {
        let live = liveTotals(
            durationSnapshot(closedWorkedMs: DURATION_HOUR, targetMinutes: -60),
            now: durationLocal(2025, 8, 4, 12, 0),
            in: durationBerlin
        )

        #expect(live.targetMs == 0)
        #expect(live.targetProgress == 0)
    }

    /// Not expressible in the TS suite: the open segment is clamped to the *current*
    /// local midnight, so a snapshot whose `date` is stale still credits only today.
    @Test func ignoresTheSnapshotDateWhenClampingTheOpenSegment() {
        let live = liveTotals(
            durationSnapshot(
                state: .running,
                date: DateKey("2025-08-03")!,
                openSegment: durationSegment(9, .work, durationLocal(2025, 8, 3, 9, 0), nil)
            ),
            now: durationLocal(2025, 8, 4, 3, 0),
            in: durationBerlin
        )

        #expect(live.workedMs == 3 * DURATION_HOUR)
    }
}

@Suite struct DurationUnitConversionTests {
    @Test func roundsHoursToWholeMinutes() {
        #expect(hoursToMinutes(8) == 480)
        #expect(hoursToMinutes(7.5) == 450)
        #expect(hoursToMinutes(0) == 0)
        #expect(hoursToMinutes(0.26) == 16)
    }

    @Test func convertsMinutesAndHoursToMilliseconds() {
        #expect(minutesToMs(90) == 90 * DURATION_MINUTE)
        #expect(minutesToMs(0) == 0)
        #expect(hoursToMs(2.5) == Int64(2.5 * Double(DURATION_HOUR)))
    }

    /// Not expressible in the TS suite: JS `Math.round` breaks ties upward, so the
    /// Swift port must not use "away from zero" rounding.
    @Test func breaksMinuteTiesUpwardLikeJavaScript() {
        #expect(hoursToMinutes(0.125) == 8)
        #expect(hoursToMinutes(-0.125) == -7)
    }
}
