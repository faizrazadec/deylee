import Foundation
import Testing

@testable import DeyleeKit

/// Tests for midnight splitting, ported from `tests/midnight.test.ts`.
///
/// The invariants that matter to the repository are: pieces are contiguous, their
/// durations sum to the original span, every boundary is a real local midnight, and
/// each piece is tagged with the day it actually belongs to. Europe/Berlin makes
/// 2025-03-30 a 23-hour day and 2025-10-26 a 25-hour day, so a naive +24h boundary
/// would be caught here. The zone is pinned explicitly on every call — the machine
/// timezone must never be able to change the result.

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private let HOUR: Int64 = 3_600_000
private let MINUTE: Int64 = 60_000

private func midnightLocal(
    _ y: Int, _ m: Int, _ d: Int,
    _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, _ ms: Int = 0
) -> EpochMs {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    let comps = DateComponents(
        year: y, month: m, day: d,
        hour: h, minute: min, second: s, nanosecond: ms * 1_000_000
    )
    return calendar.date(from: comps)!.epochMs
}

private let midnightUTC = TimeZone(identifier: "UTC")!

/// Same wall clock, read in UTC — used only by the zone-threading tests.
private func midnightUTCAt(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> EpochMs {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = midnightUTC
    return calendar.date(
        from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)
    )!.epochMs
}

private func midnightSpan(
    _ type: SegmentType, _ startedAt: EpochMs, _ endedAt: EpochMs?
) -> SpanDraft {
    SpanDraft(type: type, startedAt: startedAt, endedAt: endedAt)
}

private func midnightKey(_ value: String) -> DateKey {
    DateKey(value)!
}

/// piece[n].endedAt must equal piece[n + 1].startedAt — no gaps, no double counting.
private func expectMidnightContiguous(_ pieces: [SplitPiece]) {
    guard pieces.count > 1 else { return }
    for i in 1..<pieces.count {
        #expect(pieces[i - 1].endedAt == pieces[i].startedAt)
    }
}

private func midnightClosedTotal(_ pieces: [SplitPiece]) throws -> Int64 {
    var total: Int64 = 0
    for piece in pieces {
        let endedAt = try #require(piece.endedAt, "expected every piece to be closed")
        total += endedAt - piece.startedAt
    }
    return total
}

@Suite struct MidnightCrossesMidnightTests {
    @Test func isFalseForASpanThatStartsAndEndsOnTheSameLocalDay() {
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 4, 9, 0), midnightLocal(2025, 8, 4, 17, 0)),
                in: berlin
            ) == false
        )
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 4, 0, 0), midnightLocal(2025, 8, 4, 23, 59)),
                in: berlin
            ) == false
        )
    }

    @Test func isFalseForAnOpenSpanItIsSplitWhenItClosesNotBefore() {
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 3, 22, 0), nil), in: berlin
            ) == false
        )
    }

    @Test func isFalseForReversedAndZeroLengthSpans() {
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 5, 1, 0), midnightLocal(2025, 8, 4, 23, 0)),
                in: berlin
            ) == false
        )
        let at = midnightLocal(2025, 8, 4, 12, 0)
        #expect(crossesMidnight(midnightSpan(.work, at, at), in: berlin) == false)
    }

    @Test func isTrueForASpanThatRunsIntoTheNextDay() {
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), midnightLocal(2025, 8, 5, 1, 30)),
                in: berlin
            )
        )
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), midnightLocal(2025, 8, 7, 5, 0)),
                in: berlin
            )
        )
    }

    @Test func isTrueForASpanEndingExactlyAtMidnightWhichSplitAtMidnightLeavesWhole() {
        // Midnight belongs to the following day key, so the cheap pre-check says "yes"
        // while the splitter still returns a single piece. Callers must not assume the
        // two agree.
        let ends = midnightSpan(
            .work, midnightLocal(2025, 8, 4, 21, 0), midnightLocal(2025, 8, 5, 0, 0)
        )
        #expect(crossesMidnight(ends, in: berlin))
        #expect(splitAtMidnight(ends, in: berlin).count == 1)
    }

    @Test func detectsTheCrossingOnBothDSTDays() {
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 3, 29, 23, 0), midnightLocal(2025, 3, 30, 1, 0)),
                in: berlin
            )
        )
        #expect(
            crossesMidnight(
                midnightSpan(.work, midnightLocal(2025, 10, 25, 23, 0), midnightLocal(2025, 10, 26, 1, 0)),
                in: berlin
            )
        )
    }

    /// Not expressible in the TS suite, which could only pin the zone via `TZ`.
    @Test func readsTheDayBoundaryFromThePassedZoneNotTheMachineZone() {
        // 21:30–22:30 UTC on 2025-08-04 is 23:30–00:30 in Berlin, so the same two
        // instants cross a day boundary in one zone and not in the other.
        let span = midnightSpan(
            .work, midnightUTCAt(2025, 8, 4, 21, 30), midnightUTCAt(2025, 8, 4, 22, 30)
        )
        #expect(crossesMidnight(span, in: midnightUTC) == false)
        #expect(crossesMidnight(span, in: berlin))
    }
}

@Suite struct MidnightSplitAtMidnightTests {
    @Test func returnsASameDaySpanUnchangedTaggedWithItsDay() {
        let same = midnightSpan(
            .work, midnightLocal(2025, 8, 4, 9, 0), midnightLocal(2025, 8, 4, 17, 0)
        )
        #expect(
            splitAtMidnight(same, in: berlin) == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 4, 9, 0),
                    endedAt: midnightLocal(2025, 8, 4, 17, 0),
                    date: midnightKey("2025-08-04")
                )
            ]
        )
    }

    @Test func splitsASpanCrossingOneMidnightIntoTwoContiguousPieces() throws {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), midnightLocal(2025, 8, 5, 1, 30)),
            in: berlin
        )

        #expect(
            pieces == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 4, 22, 0),
                    endedAt: midnightLocal(2025, 8, 5, 0, 0),
                    date: midnightKey("2025-08-04")
                ),
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 5, 0, 0),
                    endedAt: midnightLocal(2025, 8, 5, 1, 30),
                    date: midnightKey("2025-08-05")
                ),
            ]
        )
        expectMidnightContiguous(pieces)
        #expect(try midnightClosedTotal(pieces) == 3 * HOUR + 30 * MINUTE)
    }

    @Test func preservesTheSegmentTypeOnEveryPiece() {
        let pieces = splitAtMidnight(
            midnightSpan(.break, midnightLocal(2025, 8, 4, 23, 30), midnightLocal(2025, 8, 5, 0, 30)),
            in: berlin
        )
        #expect(pieces.map(\.type) == [.break, .break])
    }

    @Test func splitsASpanAcrossSeveralDaysIntoOnePiecePerDay() throws {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), midnightLocal(2025, 8, 7, 5, 0)),
            in: berlin
        )

        #expect(
            pieces.map(\.date) == [
                midnightKey("2025-08-04"),
                midnightKey("2025-08-05"),
                midnightKey("2025-08-06"),
                midnightKey("2025-08-07"),
            ]
        )
        #expect(
            pieces.map(\.endedAt) == [
                midnightLocal(2025, 8, 5, 0, 0),
                midnightLocal(2025, 8, 6, 0, 0),
                midnightLocal(2025, 8, 7, 0, 0),
                midnightLocal(2025, 8, 7, 5, 0),
            ]
        )
        expectMidnightContiguous(pieces)
        #expect(try midnightClosedTotal(pieces) == 55 * HOUR)
    }

    @Test func doesNotEmitAnEmptyTrailingPieceForASpanEndingExactlyAtMidnight() {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 8, 4, 21, 0), midnightLocal(2025, 8, 5, 0, 0)),
            in: berlin
        )

        #expect(
            pieces == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 4, 21, 0),
                    endedAt: midnightLocal(2025, 8, 5, 0, 0),
                    date: midnightKey("2025-08-04")
                )
            ]
        )
    }

    @Test func doesNotEmitAnEmptyTrailingPieceAfterAMultiDaySpanEndingAtMidnight() {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 8, 4, 21, 0), midnightLocal(2025, 8, 6, 0, 0)),
            in: berlin
        )
        #expect(pieces.count == 2)
        #expect(
            pieces[1] == SplitPiece(
                type: .work,
                startedAt: midnightLocal(2025, 8, 5, 0, 0),
                endedAt: midnightLocal(2025, 8, 6, 0, 0),
                date: midnightKey("2025-08-05")
            )
        )
    }

    @Test func returnsAnOpenSpanAsASingleOpenPiece() {
        #expect(
            splitAtMidnight(
                midnightSpan(.work, midnightLocal(2025, 8, 3, 22, 0), nil), in: berlin
            ) == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 3, 22, 0),
                    endedAt: nil,
                    date: midnightKey("2025-08-03")
                )
            ]
        )
    }

    @Test func returnsAReversedSpanUnchangedLeavingRejectionToTheCaller() {
        let reversed = midnightSpan(
            .work, midnightLocal(2025, 8, 5, 1, 0), midnightLocal(2025, 8, 4, 23, 0)
        )
        #expect(
            splitAtMidnight(reversed, in: berlin) == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 5, 1, 0),
                    endedAt: midnightLocal(2025, 8, 4, 23, 0),
                    date: midnightKey("2025-08-05")
                )
            ]
        )
    }

    @Test func returnsAZeroLengthSpanUnchanged() {
        let at = midnightLocal(2025, 8, 4, 12, 0)
        #expect(
            splitAtMidnight(midnightSpan(.break, at, at), in: berlin) == [
                SplitPiece(type: .break, startedAt: at, endedAt: at, date: midnightKey("2025-08-04"))
            ]
        )
    }

    @Test func splitsAcrossThe23HourSpringForwardDayAtTheRightInstants() throws {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 3, 29, 23, 0), midnightLocal(2025, 3, 31, 1, 0)),
            in: berlin
        )

        #expect(
            pieces.map(\.date) == [
                midnightKey("2025-03-29"),
                midnightKey("2025-03-30"),
                midnightKey("2025-03-31"),
            ]
        )
        #expect(
            pieces.map(\.startedAt) == [
                midnightLocal(2025, 3, 29, 23, 0),
                midnightLocal(2025, 3, 30, 0, 0),
                midnightLocal(2025, 3, 31, 0, 0),
            ]
        )
        #expect(try midnightClosedTotal([pieces[1]]) == 23 * HOUR)
        expectMidnightContiguous(pieces)
        #expect(try midnightClosedTotal(pieces) == 25 * HOUR)
    }

    @Test func splitsAcrossThe25HourFallBackDayAtTheRightInstants() throws {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 10, 25, 23, 0), midnightLocal(2025, 10, 27, 1, 0)),
            in: berlin
        )

        #expect(
            pieces.map(\.date) == [
                midnightKey("2025-10-25"),
                midnightKey("2025-10-26"),
                midnightKey("2025-10-27"),
            ]
        )
        #expect(
            pieces.map(\.startedAt) == [
                midnightLocal(2025, 10, 25, 23, 0),
                midnightLocal(2025, 10, 26, 0, 0),
                midnightLocal(2025, 10, 27, 0, 0),
            ]
        )
        #expect(try midnightClosedTotal([pieces[1]]) == 25 * HOUR)
        expectMidnightContiguous(pieces)
        #expect(try midnightClosedTotal(pieces) == 27 * HOUR)
    }

    @Test func splitsASpanThatEndsInsideTheSkippedHourOfThe23HourDay() throws {
        // 02:30 does not exist on 2025-03-30; `Calendar` resolves it forward to 03:30
        // CEST, exactly as the JS `Date` constructor does. The clock then reads 3h30m
        // past midnight but only 2h30m of real time has elapsed.
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 3, 29, 22, 0), midnightLocal(2025, 3, 30, 2, 30)),
            in: berlin
        )

        #expect(pieces.count == 2)
        #expect(pieces[1].startedAt == midnightLocal(2025, 3, 30, 0, 0))
        #expect(try midnightClosedTotal([pieces[0]]) == 2 * HOUR)
        #expect(try midnightClosedTotal([pieces[1]]) == 2 * HOUR + 30 * MINUTE)
        #expect(try midnightClosedTotal(pieces) == 4 * HOUR + 30 * MINUTE)
    }

    /// Not expressible in the TS suite, which could only pin the zone via `TZ`.
    @Test func splitsAtTheBoundariesOfThePassedZoneNotTheMachineZone() {
        let span = midnightSpan(
            .work, midnightUTCAt(2025, 8, 4, 21, 30), midnightUTCAt(2025, 8, 4, 22, 30)
        )
        let inUTC = splitAtMidnight(span, in: midnightUTC)
        let inBerlin = splitAtMidnight(span, in: berlin)

        #expect(inUTC.count == 1)
        #expect(inUTC[0].date == midnightKey("2025-08-04"))
        #expect(inBerlin.count == 2)
        #expect(inBerlin.map(\.date) == [midnightKey("2025-08-04"), midnightKey("2025-08-05")])
        #expect(inBerlin[0].endedAt == midnightLocal(2025, 8, 5, 0, 0))
    }

    /// A whole 25-hour day is one piece, not two — the boundary walk never adds a
    /// fixed 24 hours.
    @Test func keepsAWholeFallBackDayAsASinglePiece() throws {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 10, 26, 0, 0), midnightLocal(2025, 10, 27, 0, 0)),
            in: berlin
        )
        #expect(pieces.count == 1)
        #expect(pieces[0].date == midnightKey("2025-10-26"))
        #expect(try midnightClosedTotal(pieces) == 25 * HOUR)
    }

    /// Every piece is tagged with the day its own start falls in.
    @Test func tagsEveryPieceWithTheDayOfItsOwnStart() {
        let pieces = splitAtMidnight(
            midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), midnightLocal(2025, 8, 7, 5, 0)),
            in: berlin
        )
        for piece in pieces {
            #expect(piece.date == dateKeyOf(piece.startedAt, in: berlin))
        }
    }
}

@Suite struct MidnightSplitOpenSpanAtTests {
    @Test func returnsNilForAClosedSpan() {
        #expect(
            splitOpenSpanAt(
                midnightSpan(.work, midnightLocal(2025, 8, 4, 9, 0), midnightLocal(2025, 8, 4, 17, 0)),
                now: midnightLocal(2025, 8, 5, 9, 0),
                in: berlin
            ) == nil
        )
    }

    @Test func returnsNilWhileTheOpenSpanIsStillOnItsOwnDay() {
        let open = midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), nil)
        #expect(splitOpenSpanAt(open, now: midnightLocal(2025, 8, 4, 23, 30), in: berlin) == nil)
        #expect(
            splitOpenSpanAt(
                open, now: midnightLocal(2025, 8, 4, 23, 59, 59, 999), in: berlin
            ) == nil
        )
    }

    @Test func splitsOnceNowHasReachedMidnightExactly() throws {
        let open = midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), nil)
        let result = try #require(
            splitOpenSpanAt(open, now: midnightLocal(2025, 8, 5, 0, 0), in: berlin)
        )

        #expect(
            result.closed == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 8, 4, 22, 0),
                    endedAt: midnightLocal(2025, 8, 5, 0, 0),
                    date: midnightKey("2025-08-04")
                )
            ]
        )
        #expect(
            result.reopened == SplitPiece(
                type: .work,
                startedAt: midnightLocal(2025, 8, 5, 0, 0),
                endedAt: nil,
                date: midnightKey("2025-08-05")
            )
        )
    }

    @Test func closesAtMidnightAndReopensThereOnceNowIsPastTheBoundary() throws {
        let open = midnightSpan(.break, midnightLocal(2025, 8, 4, 23, 15), nil)
        let result = try #require(
            splitOpenSpanAt(open, now: midnightLocal(2025, 8, 5, 0, 30), in: berlin)
        )

        #expect(
            result.closed == [
                SplitPiece(
                    type: .break,
                    startedAt: midnightLocal(2025, 8, 4, 23, 15),
                    endedAt: midnightLocal(2025, 8, 5, 0, 0),
                    date: midnightKey("2025-08-04")
                )
            ]
        )
        #expect(result.reopened.startedAt == midnightLocal(2025, 8, 5, 0, 0))
        #expect(result.reopened.endedAt == nil)
        #expect(result.reopened.type == .break)
    }

    @Test func emitsOneClosedPiecePerElapsedDayWhenTheAppRanForDays() throws {
        let open = midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), nil)
        let result = try #require(
            splitOpenSpanAt(open, now: midnightLocal(2025, 8, 6, 10, 0), in: berlin)
        )

        let closed = result.closed
        #expect(closed.map(\.date) == [midnightKey("2025-08-04"), midnightKey("2025-08-05")])
        expectMidnightContiguous(closed)
        #expect(try midnightClosedTotal(closed) == 26 * HOUR)
        #expect(
            result.reopened == SplitPiece(
                type: .work,
                startedAt: midnightLocal(2025, 8, 6, 0, 0),
                endedAt: nil,
                date: midnightKey("2025-08-06")
            )
        )
        // The reopened piece continues exactly where the last closed one stopped.
        #expect(closed[closed.count - 1].endedAt == result.reopened.startedAt)
    }

    @Test func usesTheRealLocalMidnightAcrossThe23HourDay() throws {
        let open = midnightSpan(.work, midnightLocal(2025, 3, 29, 23, 0), nil)
        let result = try #require(
            splitOpenSpanAt(open, now: midnightLocal(2025, 3, 30, 12, 0), in: berlin)
        )

        #expect(
            result.closed == [
                SplitPiece(
                    type: .work,
                    startedAt: midnightLocal(2025, 3, 29, 23, 0),
                    endedAt: midnightLocal(2025, 3, 30, 0, 0),
                    date: midnightKey("2025-03-29")
                )
            ]
        )
        #expect(result.reopened.startedAt == midnightLocal(2025, 3, 30, 0, 0))
        #expect(result.reopened.date == midnightKey("2025-03-30"))
    }

    @Test func usesTheRealLocalMidnightAcrossThe25HourDay() throws {
        let open = midnightSpan(.work, midnightLocal(2025, 10, 25, 23, 0), nil)
        let result = try #require(
            splitOpenSpanAt(open, now: midnightLocal(2025, 10, 26, 12, 0), in: berlin)
        )

        #expect(try midnightClosedTotal(result.closed) == HOUR)
        #expect(result.reopened.startedAt == midnightLocal(2025, 10, 26, 0, 0))
        #expect(result.reopened.date == midnightKey("2025-10-26"))
    }

    @Test func isIdempotentReRunningItOnTheReopenedPieceDoesNothingOnTheSameDay() throws {
        let open = midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), nil)
        let first = try #require(
            splitOpenSpanAt(open, now: midnightLocal(2025, 8, 5, 0, 30), in: berlin)
        )

        let reopened = midnightSpan(.work, first.reopened.startedAt, nil)
        #expect(splitOpenSpanAt(reopened, now: midnightLocal(2025, 8, 5, 0, 30), in: berlin) == nil)
    }

    /// Not expressible in the TS suite: the reopened piece deliberately absorbs
    /// start-of-today → now, so nothing between the last closed piece and the live
    /// timer is lost.
    @Test func leavesStartOfTodayToNowInsideTheReopenedOpenPiece() throws {
        let open = midnightSpan(.work, midnightLocal(2025, 8, 4, 22, 0), nil)
        let now = midnightLocal(2025, 8, 6, 10, 0)
        let result = try #require(splitOpenSpanAt(open, now: now, in: berlin))

        let accountedFor = try midnightClosedTotal(result.closed)
            + (now - result.reopened.startedAt)
        #expect(accountedFor == now - open.startedAt)
    }

    /// Not expressible in the TS suite, which could only pin the zone via `TZ`.
    @Test func rollsOverAtThePassedZonesMidnightNotTheMachineZones() {
        // 22:30 UTC on 2025-08-04 is already 00:30 on 2025-08-05 in Berlin.
        let open = midnightSpan(.work, midnightLocal(2025, 8, 4, 20, 0), nil)
        let now = midnightUTCAt(2025, 8, 4, 22, 30)
        #expect(splitOpenSpanAt(open, now: now, in: midnightUTC) == nil)
        #expect(splitOpenSpanAt(open, now: now, in: berlin) != nil)
    }
}
