import Foundation
import Testing
@testable import DeyleeKit

/// Ported one-to-one from `tests/time.test.ts`.
///
/// The suite is pinned to Europe/Berlin, where 2025-03-30 is a 23-hour day
/// (02:00-03:00 never happens) and 2025-10-26 is a 25-hour day (02:00-03:00 happens
/// twice). Expected instants are built with `Calendar` component resolution rather
/// than by adding fixed offsets — adding offsets is exactly the mistake these helpers
/// exist to prevent, so it must never be how they are checked.

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private let HOUR: Int64 = 3_600_000
private let MINUTE: Int64 = 60_000
private let SECOND: Int64 = 1_000

private func local(
    _ y: Int, _ m: Int, _ d: Int,
    _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, _ ms: Int = 0,
    zone: TimeZone = berlin
) -> EpochMs {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let comps = DateComponents(
        year: y, month: m, day: d, hour: h, minute: min, second: s,
        nanosecond: ms * 1_000_000
    )
    return cal.date(from: comps)!.epochMs
}

private func hour(of ts: EpochMs, zone: TimeZone = berlin) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.component(.hour, from: Date(epochMs: ts))
}

private func k(_ s: String) -> DateKey {
    DateKey(s)!
}

@Suite struct Constants {
    @Test func plainMillisecondFactors() {
        #expect(MS_PER_SECOND == 1_000)
        #expect(MS_PER_MINUTE == 60_000)
        #expect(MS_PER_HOUR == 3_600_000)
    }
}

@Suite struct DateKeyOf {
    @Test func zeroPadsMonthAndDay() {
        #expect(dateKeyOf(local(2025, 8, 4, 14, 37), in: berlin) == k("2025-08-04"))
        #expect(dateKeyOf(local(2025, 1, 1, 0, 0), in: berlin) == k("2025-01-01"))
        #expect(dateKeyOf(local(2025, 12, 31, 23, 59, 59, 999), in: berlin) == k("2025-12-31"))
    }

    @Test func lastMillisecondStillBelongsToTheDay() {
        #expect(dateKeyOf(local(2025, 8, 4, 23, 59, 59, 999), in: berlin) == k("2025-08-04"))
        #expect(dateKeyOf(local(2025, 8, 5, 0, 0, 0, 0), in: berlin) == k("2025-08-05"))
    }

    @Test func stableAcrossBothDSTTransitions() {
        #expect(dateKeyOf(local(2025, 3, 30, 1, 59), in: berlin) == k("2025-03-30"))
        #expect(dateKeyOf(local(2025, 3, 30, 3, 0), in: berlin) == k("2025-03-30"))
        // Both occurrences of the repeated hour belong to 2025-10-26.
        #expect(dateKeyOf(local(2025, 10, 26, 2, 30), in: berlin) == k("2025-10-26"))
        #expect(dateKeyOf(local(2025, 10, 26, 2, 30) + HOUR, in: berlin) == k("2025-10-26"))
    }
}

@Suite struct IsDateKey {
    @Test func acceptsRealCalendarDates() {
        #expect(isDateKey("2025-08-04"))
        #expect(isDateKey("2024-02-29"))
        #expect(isDateKey("1999-12-31"))
    }

    @Test func rejectsMalformedShapes() {
        #expect(!isDateKey(""))
        #expect(!isDateKey("2025-8-04"))
        #expect(!isDateKey("20250804"))
        #expect(!isDateKey("2025-08-04T00:00:00Z"))
        #expect(!isDateKey("2025/08/04"))
    }

    @Test func rejectsDatesThatDoNotExist() {
        #expect(!isDateKey("2025-13-01"))
        #expect(!isDateKey("2025-00-10"))
        #expect(!isDateKey("2025-08-00"))
        #expect(!isDateKey("2025-08-32"))
        #expect(!isDateKey("2025-02-29"))
        #expect(!isDateKey("2025-02-30"))
        #expect(!isDateKey("2025-04-31"))
    }
}

@Suite struct StartAndEndOfDay {
    @Test func localMidnightAndNextLocalMidnight() {
        #expect(startOfDay(k("2025-08-04"), in: berlin) == local(2025, 8, 4))
        #expect(endOfDay(k("2025-08-04"), in: berlin) == local(2025, 8, 5))
        #expect(endOfDay(k("2025-08-04"), in: berlin) - startOfDay(k("2025-08-04"), in: berlin) == 24 * HOUR)
    }

    @Test func springForwardDayIs23Hours() {
        #expect(startOfDay(k("2025-03-30"), in: berlin) == local(2025, 3, 30))
        #expect(endOfDay(k("2025-03-30"), in: berlin) == local(2025, 3, 31))
        #expect(endOfDay(k("2025-03-30"), in: berlin) - startOfDay(k("2025-03-30"), in: berlin) == 23 * HOUR)
    }

    @Test func skipsTwoAMOnTheSpringForwardDay() {
        // Two hours after local midnight the wall clock already reads 03:00.
        #expect(hour(of: startOfDay(k("2025-03-30"), in: berlin) + 2 * HOUR) == 3)
    }

    @Test func fallBackDayIs25Hours() {
        #expect(startOfDay(k("2025-10-26"), in: berlin) == local(2025, 10, 26))
        #expect(endOfDay(k("2025-10-26"), in: berlin) == local(2025, 10, 27))
        #expect(endOfDay(k("2025-10-26"), in: berlin) - startOfDay(k("2025-10-26"), in: berlin) == 25 * HOUR)
    }

    @Test func repeatsTwoAMOnTheFallBackDay() {
        let base = startOfDay(k("2025-10-26"), in: berlin)
        #expect(hour(of: base + 2 * HOUR) == 2)
        #expect(hour(of: base + 3 * HOUR) == 2)
    }

    @Test func rollsOverMonthAndYearBoundaries() {
        #expect(endOfDay(k("2025-08-31"), in: berlin) == local(2025, 9, 1))
        #expect(endOfDay(k("2024-12-31"), in: berlin) == local(2025, 1, 1))
        #expect(endOfDay(k("2024-02-28"), in: berlin) == local(2024, 2, 29))
    }

    @Test func resolvesAMidnightGapForward() {
        // Chile springs forward at midnight: 2025-09-07 starts at 01:00 in Santiago.
        let santiago = TimeZone(identifier: "America/Santiago")!
        let start = startOfDay(k("2025-09-07"), in: santiago)
        #expect(hour(of: start, zone: santiago) == 1)
        #expect(dateKeyOf(start, in: santiago) == k("2025-09-07"))
    }
}

@Suite struct DayBoundarySnapping {
    @Test func snapsAnInstantToItsOwnLocalDayBoundaries() {
        let ts = local(2025, 8, 4, 14, 37, 12, 345)
        #expect(startOfDayAt(ts, in: berlin) == local(2025, 8, 4))
        #expect(nextMidnightAfter(ts, in: berlin) == local(2025, 8, 5))
    }

    @Test func idempotentAtMidnight() {
        #expect(startOfDayAt(local(2025, 8, 4), in: berlin) == local(2025, 8, 4))
        #expect(nextMidnightAfter(local(2025, 8, 4), in: berlin) == local(2025, 8, 5))
    }

    @Test func dstCorrectBoundaries() {
        #expect(nextMidnightAfter(local(2025, 3, 30, 12, 0), in: berlin) == local(2025, 3, 31))
        #expect(nextMidnightAfter(local(2025, 10, 26, 12, 0), in: berlin) == local(2025, 10, 27))
        #expect(startOfDayAt(local(2025, 3, 30, 23, 59), in: berlin) == local(2025, 3, 30))
    }
}

@Suite struct AddDays {
    @Test func shiftsByWholeCalendarDays() {
        #expect(addDays(k("2025-08-04"), 1) == k("2025-08-05"))
        #expect(addDays(k("2025-08-04"), 0) == k("2025-08-04"))
        #expect(addDays(k("2025-08-04"), -1) == k("2025-08-03"))
        #expect(addDays(k("2025-08-04"), 7) == k("2025-08-11"))
    }

    @Test func crossesMonthYearAndLeapBoundaries() {
        #expect(addDays(k("2025-08-31"), 1) == k("2025-09-01"))
        #expect(addDays(k("2024-12-31"), 1) == k("2025-01-01"))
        #expect(addDays(k("2025-01-01"), -1) == k("2024-12-31"))
        #expect(addDays(k("2024-02-28"), 1) == k("2024-02-29"))
        #expect(addDays(k("2025-02-28"), 1) == k("2025-03-01"))
    }

    @Test func crossesBothDSTTransitions() {
        #expect(addDays(k("2025-03-29"), 1) == k("2025-03-30"))
        #expect(addDays(k("2025-03-30"), 1) == k("2025-03-31"))
        #expect(addDays(k("2025-03-31"), -1) == k("2025-03-30"))
        #expect(addDays(k("2025-10-25"), 1) == k("2025-10-26"))
        #expect(addDays(k("2025-10-26"), 1) == k("2025-10-27"))
        #expect(addDays(k("2025-10-27"), -1) == k("2025-10-26"))
    }
}

@Suite struct DaysBetween {
    @Test func countsWholeCalendarDaysSigned() {
        #expect(daysBetween(from: k("2025-08-04"), to: k("2025-08-04")) == 0)
        #expect(daysBetween(from: k("2025-08-04"), to: k("2025-08-11")) == 7)
        #expect(daysBetween(from: k("2025-08-11"), to: k("2025-08-04")) == -7)
    }

    @Test func unaffectedByDSTDays() {
        #expect(daysBetween(from: k("2025-03-29"), to: k("2025-03-31")) == 2)
        #expect(daysBetween(from: k("2025-03-31"), to: k("2025-03-29")) == -2)
        #expect(daysBetween(from: k("2025-10-25"), to: k("2025-10-27")) == 2)
        #expect(daysBetween(from: k("2025-10-27"), to: k("2025-10-25")) == -2)
    }

    @Test func spansMonthsAndYears() {
        #expect(daysBetween(from: k("2024-12-30"), to: k("2025-01-02")) == 3)
        #expect(daysBetween(from: k("2024-02-01"), to: k("2024-03-01")) == 29)
        #expect(daysBetween(from: k("2025-02-01"), to: k("2025-03-01")) == 28)
    }
}

@Suite struct EachDay {
    @Test func inclusiveAtBothEnds() {
        #expect(eachDay(from: k("2025-08-04"), to: k("2025-08-07")) == [
            k("2025-08-04"), k("2025-08-05"), k("2025-08-06"), k("2025-08-07"),
        ])
    }

    @Test func singleDayWhenBothEndsMatch() {
        #expect(eachDay(from: k("2025-08-04"), to: k("2025-08-04")) == [k("2025-08-04")])
    }

    @Test func emptyWhenReversed() {
        #expect(eachDay(from: k("2025-08-07"), to: k("2025-08-04")) == [])
    }

    @Test func emitsEveryDSTDayExactlyOnce() {
        #expect(eachDay(from: k("2025-03-29"), to: k("2025-03-31")) == [
            k("2025-03-29"), k("2025-03-30"), k("2025-03-31"),
        ])
        #expect(eachDay(from: k("2025-10-25"), to: k("2025-10-27")) == [
            k("2025-10-25"), k("2025-10-26"), k("2025-10-27"),
        ])
    }
}

@Suite struct TodayKey {
    @Test func derivesTheLocalKeyOfTheSuppliedInstant() {
        #expect(todayKey(now: local(2025, 8, 4, 0, 0), in: berlin) == k("2025-08-04"))
        #expect(todayKey(now: local(2025, 8, 4, 23, 59, 59, 999), in: berlin) == k("2025-08-04"))
    }
}

@Suite struct WeekBounds {
    // 2025-08-03 Sun, 2025-08-04 Mon, 2025-08-06 Wed, 2025-08-09 Sat, 2025-08-10 Sun.
    @Test func anchorsMidweekToMondayWhenWeeksStartOnMonday() {
        #expect(startOfWeek(k("2025-08-06"), weekStartsOn: .monday) == k("2025-08-04"))
        #expect(endOfWeek(k("2025-08-06"), weekStartsOn: .monday) == k("2025-08-10"))
    }

    @Test func anchorsTheSameDateToSundayWhenWeeksStartOnSunday() {
        #expect(startOfWeek(k("2025-08-06"), weekStartsOn: .sunday) == k("2025-08-03"))
        #expect(endOfWeek(k("2025-08-06"), weekStartsOn: .sunday) == k("2025-08-09"))
    }

    @Test func sundayEndsAMondayWeekAndStartsASundayWeek() {
        #expect(startOfWeek(k("2025-08-03"), weekStartsOn: .monday) == k("2025-07-28"))
        #expect(endOfWeek(k("2025-08-03"), weekStartsOn: .monday) == k("2025-08-03"))
        #expect(startOfWeek(k("2025-08-03"), weekStartsOn: .sunday) == k("2025-08-03"))
        #expect(endOfWeek(k("2025-08-03"), weekStartsOn: .sunday) == k("2025-08-09"))
    }

    @Test func leavesTheAnchorDayUnmoved() {
        #expect(startOfWeek(k("2025-08-04"), weekStartsOn: .monday) == k("2025-08-04"))
        #expect(startOfWeek(k("2025-08-10"), weekStartsOn: .sunday) == k("2025-08-10"))
    }

    @Test func sevenDayWeeksEvenAcrossDST() {
        #expect(startOfWeek(k("2025-03-30"), weekStartsOn: .monday) == k("2025-03-24"))
        #expect(endOfWeek(k("2025-03-30"), weekStartsOn: .monday) == k("2025-03-30"))
        #expect(startOfWeek(k("2025-10-26"), weekStartsOn: .sunday) == k("2025-10-26"))
        #expect(endOfWeek(k("2025-10-26"), weekStartsOn: .sunday) == k("2025-11-01"))
        #expect(daysBetween(
            from: startOfWeek(k("2025-10-26"), weekStartsOn: .monday),
            to: endOfWeek(k("2025-10-26"), weekStartsOn: .monday)
        ) == 6)
    }
}

@Suite struct MonthBounds {
    @Test func bracketsAnOrdinaryMonth() {
        #expect(startOfMonth(k("2025-08-15")) == k("2025-08-01"))
        #expect(endOfMonth(k("2025-08-15")) == k("2025-08-31"))
    }

    @Test func handlesALeapYearFebruary() {
        #expect(startOfMonth(k("2024-02-10")) == k("2024-02-01"))
        #expect(endOfMonth(k("2024-02-10")) == k("2024-02-29"))
    }

    @Test func handlesANonLeapFebruary() {
        #expect(endOfMonth(k("2025-02-10")) == k("2025-02-28"))
    }

    @Test func handlesDecemberAndTheDSTMonths() {
        #expect(startOfMonth(k("2025-12-05")) == k("2025-12-01"))
        #expect(endOfMonth(k("2025-12-05")) == k("2025-12-31"))
        #expect(endOfMonth(k("2025-03-30")) == k("2025-03-31"))
        #expect(endOfMonth(k("2025-10-26")) == k("2025-10-31"))
        #expect(endOfMonth(k("2025-04-01")) == k("2025-04-30"))
    }
}

@Suite struct FormatHM {
    @Test func rendersWithoutPaddingTheHour() {
        #expect(formatHM(0) == "0:00")
        #expect(formatHM(MINUTE) == "0:01")
        #expect(formatHM(HOUR) == "1:00")
        #expect(formatHM(6 * HOUR + 24 * MINUTE) == "6:24")
    }

    @Test func doesNotWrapAt24Hours() {
        #expect(formatHM(25 * HOUR) == "25:00")
        #expect(formatHM(100 * HOUR + 30 * MINUTE) == "100:30")
    }

    @Test func truncatesAndClampsNegatives() {
        #expect(formatHM(MINUTE - 1) == "0:00")
        #expect(formatHM(2 * MINUTE - 1) == "0:01")
        #expect(formatHM(-1) == "0:00")
        #expect(formatHM(-5 * HOUR) == "0:00")
    }
}

@Suite struct FormatHMS {
    @Test func rendersWithPaddedMinutesAndSeconds() {
        #expect(formatHMS(0) == "0:00:00")
        #expect(formatHMS(HOUR + 2 * MINUTE + 3 * SECOND) == "1:02:03")
        #expect(formatHMS(6 * HOUR + 24 * MINUTE + 59 * SECOND) == "6:24:59")
    }

    @Test func doesNotWrapAt24Hours() {
        #expect(formatHMS(25 * HOUR + SECOND) == "25:00:01")
    }

    @Test func truncatesSubSecondsAndClampsNegatives() {
        #expect(formatHMS(999) == "0:00:00")
        #expect(formatHMS(SECOND - 1) == "0:00:00")
        #expect(formatHMS(-1) == "0:00:00")
        #expect(formatHMS(-90 * SECOND) == "0:00:00")
    }
}

@Suite struct FormatCompactSuite {
    @Test func dropsTheHourPartUnderAnHour() {
        #expect(formatCompact(0) == "0m")
        #expect(formatCompact(24 * MINUTE) == "24m")
        #expect(formatCompact(59 * MINUTE) == "59m")
    }

    @Test func dropsTheMinutePartOnAWholeHour() {
        #expect(formatCompact(HOUR) == "1h")
        #expect(formatCompact(25 * HOUR) == "25h")
    }

    @Test func rendersBothPartsOtherwise() {
        #expect(formatCompact(HOUR + 24 * MINUTE) == "1h 24m")
        #expect(formatCompact(7 * HOUR + 45 * MINUTE) == "7h 45m")
    }

    @Test func clampsNegativesToZero() {
        #expect(formatCompact(-1) == "0m")
        #expect(formatCompact(-3 * HOUR) == "0m")
    }
}

@Suite struct ClockAndDateFormatting {
    @Test func rendersTheLocalWallClockZeroPadded() {
        #expect(formatClock(local(2025, 8, 4, 9, 5), in: berlin) == "09:05")
        #expect(formatClock(local(2025, 8, 4, 23, 59), in: berlin) == "23:59")
        #expect(formatClock(local(2025, 8, 4, 0, 0), in: berlin) == "00:00")
        #expect(formatClockSeconds(local(2025, 8, 4, 9, 5, 7), in: berlin) == "09:05:07")
    }

    @Test func readsThePostTransitionWallClockAcrossDST() {
        // 02:00 does not exist on 2025-03-30, so midnight + 2h reads 03:00.
        #expect(formatClock(startOfDay(k("2025-03-30"), in: berlin) + 2 * HOUR, in: berlin) == "03:00")
        // 02:30 happens twice on 2025-10-26; both render identically.
        #expect(formatClock(local(2025, 10, 26, 2, 30), in: berlin) == "02:30")
        #expect(formatClock(local(2025, 10, 26, 2, 30) + HOUR, in: berlin) == "02:30")
    }

    @Test func includesWeekdayDayMonthAndYear() {
        let rendered = formatDateLong(k("2025-08-04"), locale: Locale(identifier: "en_US"))
        #expect(rendered.contains("2025"))
        #expect(rendered.contains("4"))
    }
}

@Suite struct TimeInputValues {
    @Test func combinesADateKeyWithALocalTimeOfDay() {
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:30", in: berlin) == local(2025, 8, 4, 9, 30))
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "00:00", in: berlin) == local(2025, 8, 4, 0, 0))
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "23:59", in: berlin) == local(2025, 8, 4, 23, 59))
    }

    @Test func acceptsOptionalSecondsAndZeroesMilliseconds() {
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:30:45", in: berlin) == local(2025, 8, 4, 9, 30, 45))
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:30", in: berlin) == local(2025, 8, 4, 9, 30, 0, 0))
    }

    @Test func roundTripsThroughToTimeInputValue() throws {
        for time in ["00:00", "07:05", "12:00", "18:45", "23:59"] {
            let ts = try #require(fromTimeInputValue(date: k("2025-08-04"), time: time, in: berlin))
            #expect(toTimeInputValue(ts, in: berlin) == time)
        }
    }

    @Test func dropsSecondsOnTheWayBackOut() throws {
        let ts = try #require(fromTimeInputValue(date: k("2025-08-04"), time: "09:30:45", in: berlin))
        #expect(toTimeInputValue(ts, in: berlin) == "09:30")
    }

    @Test func roundTripsTheRepeatedHourToItsFirstOccurrence() throws {
        let ts = try #require(fromTimeInputValue(date: k("2025-10-26"), time: "02:30", in: berlin))
        #expect(ts == local(2025, 10, 26, 2, 30))
        #expect(toTimeInputValue(ts, in: berlin) == "02:30")
    }

    @Test func resolvesTheNonExistentHourForward() throws {
        // 02:30 never happens on 2025-03-30; resolution lands on 03:30 and that is
        // the only sane instant to store. Callers must re-read the field after saving.
        let ts = try #require(fromTimeInputValue(date: k("2025-03-30"), time: "02:30", in: berlin))
        #expect(ts == local(2025, 3, 30, 3, 30))
        #expect(toTimeInputValue(ts, in: berlin) == "03:30")
    }

    @Test func rejectsTheWrongNumberOfComponents() {
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "0930", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "9", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:30:45:00", in: berlin) == nil)
    }

    @Test func rejectsNonIntegerComponents() {
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "ab:cd", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:3o", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "9.5:30", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:30.5", in: berlin) == nil)
    }

    @Test func rejectsOutOfRangeComponents() {
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "24:00", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "-1:00", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:60", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:-1", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:30:60", in: berlin) == nil)
    }

    // Regression guard carried over from the TS suite: permissive number parsing must
    // not let strings that are plainly not `HH:MM` through.
    @Test func rejectsComponentsOnlyLooseParsingWouldAccept() {
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "0x10:30", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "1e1:30", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: " 9:30", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "+9:30", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: "09:", in: berlin) == nil)
        #expect(fromTimeInputValue(date: k("2025-08-04"), time: ":30", in: berlin) == nil)
    }
}
