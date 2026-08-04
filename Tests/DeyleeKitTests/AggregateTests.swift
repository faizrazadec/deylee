import Foundation
import Testing

@testable import DeyleeKit

/// Tests for the History range roll-ups.
///
/// The one rule that is easy to get wrong and expensive to get wrong is the daily
/// average: it divides by *active* days, so a month of weekends must not drag it down.

private let aggregateHour: Int64 = 3_600_000
private let aggregateMinute: Int64 = 60_000

/// The vitest suite runs under `TZ=Europe/Berlin`; pin the same zone explicitly so the
/// fixtures land on the same wall-clock instants on any machine.
private let aggregateBerlin = TimeZone(identifier: "Europe/Berlin")!

private func aggregateKey(_ value: String) -> DateKey {
    DateKey(value)!
}

private func aggregateRange(_ from: String, _ to: String) -> DateRange {
    DateRange(from: aggregateKey(from), to: aggregateKey(to))
}

private func aggregateInstantOn(_ date: DateKey, _ hour: Int) -> EpochMs {
    fromTimeInputValue(date: date, time: "\(hour):00", in: aggregateBerlin)!
}

/// A realistic `DayDetail`: the segments and the totals agree, so a reader can see
/// where each number in the expectations comes from.
///
/// Segment ids are positional rather than drawn from a running counter, so building
/// the same day twice yields equal values — Swift compares by value, not identity.
private func aggregateDetail(
    _ date: String,
    targetMinutes: Int = 480,
    workedMs: Int64 = 0,
    breakMs: Int64 = 0
) -> DayDetail {
    let key = aggregateKey(date)
    var segments: [Segment] = []
    var cursor = aggregateInstantOn(key, 9)

    func push(_ type: SegmentType, _ duration: Int64) {
        let startedAt = cursor
        let endedAt = startedAt + duration
        segments.append(Segment(
            id: Int64(segments.count + 1),
            dayId: 1,
            type: type,
            startedAt: startedAt,
            endedAt: endedAt,
            note: nil,
            createdAt: startedAt,
            updatedAt: endedAt
        ))
        cursor = endedAt
    }

    if workedMs > 0 { push(.work, workedMs) }
    if breakMs > 0 { push(.break, breakMs) }

    return DayDetail(
        day: Day(
            id: 1,
            date: key,
            createdAt: aggregateInstantOn(key, 9),
            endedAt: nil,
            targetMinutes: targetMinutes
        ),
        segments: segments,
        totals: DayTotals(
            workedMs: workedMs,
            breakMs: breakMs,
            firstStartAt: segments.first?.startedAt,
            lastEndAt: segments.last?.endedAt,
            segmentCount: segments.count,
            hasOpenSegment: false
        )
    )
}

@Suite("aggregate: summariseRange")
struct AggregateSummariseRangeTests {
    let range = aggregateRange("2025-08-04", "2025-08-10")
    let days = [
        aggregateDetail("2025-08-04", workedMs: 8 * aggregateHour, breakMs: 45 * aggregateMinute),
        aggregateDetail("2025-08-05", workedMs: 6 * aggregateHour, breakMs: 30 * aggregateMinute),
        aggregateDetail("2025-08-06", workedMs: 9 * aggregateHour, breakMs: 60 * aggregateMinute),
        aggregateDetail("2025-08-07", breakMs: 20 * aggregateMinute),
    ]

    @Test("sums worked and break time across the range")
    func sumsWorkedAndBreak() {
        let summary = summariseRange(range, days: days)
        #expect(summary.totalWorkedMs == 23 * aggregateHour)
        #expect(summary.totalBreakMs == 2 * aggregateHour + 35 * aggregateMinute)
    }

    @Test("echoes the range back and copies the day list")
    func echoesRangeAndCopiesDays() {
        var summary = summariseRange(range, days: days)
        #expect(summary.range == range)
        #expect(summary.days == days)

        summary.days.removeAll()
        #expect(days.count == 4)
    }

    @Test("counts only days with recorded work as active")
    func countsOnlyWorkedDaysAsActive() {
        // 2025-08-07 has a break but no work, so it is not an active day.
        #expect(summariseRange(range, days: days).activeDayCount == 3)
    }

    @Test("divides the average by active days, not by calendar days in the range")
    func averageDividesByActiveDays() {
        let summary = summariseRange(range, days: days)
        // 23h over 3 active days — dividing by the 7 calendar days would give 3h17m.
        #expect(summary.averageWorkedMsPerActiveDay == 23 * aggregateHour / 3)
        #expect(summary.averageWorkedMsPerActiveDay != 23 * aggregateHour / 7)
    }

    @Test("reports a zero average when nothing was worked")
    func zeroAverageWhenNothingWorked() {
        let idle = summariseRange(range, days: [
            aggregateDetail("2025-08-04", breakMs: 30 * aggregateMinute),
            aggregateDetail("2025-08-05"),
        ])

        #expect(idle.activeDayCount == 0)
        #expect(idle.averageWorkedMsPerActiveDay == 0)
        #expect(idle.totalWorkedMs == 0)
        #expect(idle.totalBreakMs == 30 * aggregateMinute)
        #expect(idle.targetMetCount == 0)
    }

    @Test("is all zeros for an empty range")
    func allZerosForEmptyRange() {
        let empty = summariseRange(range, days: [])
        #expect(empty.days.isEmpty)
        #expect(empty.totalWorkedMs == 0)
        #expect(empty.totalBreakMs == 0)
        #expect(empty.activeDayCount == 0)
        #expect(empty.averageWorkedMsPerActiveDay == 0)
        #expect(empty.targetMetCount == 0)
    }

    @Test("counts a day that meets its target exactly")
    func countsExactTargetMet() {
        // 08-04 hits 8h against a 480-minute target, 08-06 exceeds it, 08-05 falls short.
        #expect(summariseRange(range, days: days).targetMetCount == 2)
    }

    @Test("compares each day against its own stored target")
    func comparesAgainstOwnTarget() {
        let mixed = [
            aggregateDetail("2025-08-04", targetMinutes: 240, workedMs: 4 * aggregateHour),
            aggregateDetail("2025-08-05", targetMinutes: 480, workedMs: 4 * aggregateHour),
        ]
        #expect(summariseRange(range, days: mixed).targetMetCount == 1)
    }

    @Test("never counts a day with a zero target as met")
    func neverCountsZeroTarget() {
        let untargeted = [
            aggregateDetail("2025-08-04", targetMinutes: 0, workedMs: 8 * aggregateHour),
            aggregateDetail("2025-08-05", targetMinutes: 0),
        ]
        let summary = summariseRange(range, days: untargeted)

        #expect(summary.targetMetCount == 0)
        #expect(summary.activeDayCount == 1)
    }

    @Test("never counts a day with a negative target as met")
    func neverCountsNegativeTarget() {
        let summary = summariseRange(range, days: [
            aggregateDetail("2025-08-04", targetMinutes: -60, workedMs: 8 * aggregateHour),
        ])

        #expect(summary.targetMetCount == 0)
        #expect(summary.activeDayCount == 1)
    }

    @Test("truncates the average rather than carrying a fraction of a millisecond")
    func averageTruncates() {
        let summary = summariseRange(range, days: [
            aggregateDetail("2025-08-04", workedMs: 1),
            aggregateDetail("2025-08-05", workedMs: 2),
        ])

        #expect(summary.totalWorkedMs == 3)
        #expect(summary.activeDayCount == 2)
        #expect(summary.averageWorkedMsPerActiveDay == 1)
    }
}

@Suite("aggregate: densifyRange")
struct AggregateDensifyRangeTests {
    @Test("produces one entry per day of the range, in order")
    func oneEntryPerDayInOrder() {
        let range = aggregateRange("2025-08-04", "2025-08-10")
        let dense = densifyRange(range, days: [
            aggregateDetail("2025-08-05", workedMs: 6 * aggregateHour),
            aggregateDetail("2025-08-08", workedMs: 7 * aggregateHour),
        ])

        #expect(dense.dates.map(\.description) == [
            "2025-08-04",
            "2025-08-05",
            "2025-08-06",
            "2025-08-07",
            "2025-08-08",
            "2025-08-09",
            "2025-08-10",
        ])
        #expect(dense[aggregateKey("2025-08-04")] == nil)
        #expect(dense[aggregateKey("2025-08-05")]?.totals.workedMs == 6 * aggregateHour)
        #expect(dense[aggregateKey("2025-08-06")] == nil)
        #expect(dense[aggregateKey("2025-08-07")] == nil)
        #expect(dense[aggregateKey("2025-08-08")]?.totals.workedMs == 7 * aggregateHour)
        #expect(dense[aggregateKey("2025-08-10")] == nil)
    }

    @Test("fills the whole range with nils when there is no data")
    func fillsWithNilsWhenNoData() {
        let dense = densifyRange(aggregateRange("2025-08-04", "2025-08-06"), days: [])
        #expect(dense.count == 3)
        #expect(dense.allSatisfy { $0.detail == nil })
    }

    @Test("drops days that fall outside the range")
    func dropsDaysOutsideRange() {
        let dense = densifyRange(aggregateRange("2025-08-04", "2025-08-05"), days: [
            aggregateDetail("2025-08-01", workedMs: aggregateHour),
            aggregateDetail("2025-08-05", workedMs: 2 * aggregateHour),
            aggregateDetail("2025-08-09", workedMs: 3 * aggregateHour),
        ])

        #expect(dense.count == 2)
        #expect(dense.contains(aggregateKey("2025-08-01")) == false)
        #expect(dense.contains(aggregateKey("2025-08-09")) == false)
        #expect(dense[aggregateKey("2025-08-05")]?.totals.workedMs == 2 * aggregateHour)
    }

    @Test("handles a single-day range")
    func handlesSingleDayRange() {
        let only = aggregateDetail("2025-08-04", workedMs: aggregateHour)
        let dense = densifyRange(aggregateRange("2025-08-04", "2025-08-04"), days: [only])
        #expect(dense.count == 1)
        #expect(dense[aggregateKey("2025-08-04")] == only)
    }

    @Test("is empty for a reversed range")
    func emptyForReversedRange() {
        let dense = densifyRange(aggregateRange("2025-08-10", "2025-08-04"), days: [
            aggregateDetail("2025-08-05", workedMs: aggregateHour),
        ])
        #expect(dense.count == 0)
    }

    @Test("emits every day of a DST week exactly once")
    func emitsEveryDSTDayOnce() {
        let dense = densifyRange(aggregateRange("2025-03-29", "2025-03-31"), days: [
            aggregateDetail("2025-03-30", workedMs: 3 * aggregateHour),
        ])

        #expect(dense.dates.map(\.description) == ["2025-03-29", "2025-03-30", "2025-03-31"])
        #expect(dense[aggregateKey("2025-03-30")]?.totals.workedMs == 3 * aggregateHour)
    }

    @Test("distinguishes a covered empty day from a day outside the range")
    func coveredEmptyDayIsNotOutsideTheRange() {
        let dense = densifyRange(aggregateRange("2025-08-04", "2025-08-05"), days: [])

        #expect(dense.contains(aggregateKey("2025-08-04")))
        #expect(dense[aggregateKey("2025-08-04")] == nil)
        #expect(dense.contains(aggregateKey("2025-08-06")) == false)
        #expect(dense[aggregateKey("2025-08-06")] == nil)
    }
}

@Suite("aggregate: weekRange")
struct AggregateWeekRangeTests {
    // 2025-08-03 Sun, 2025-08-04 Mon, 2025-08-06 Wed, 2025-08-09 Sat, 2025-08-10 Sun.
    @Test("runs Monday to Sunday when weeks start on Monday")
    func mondayWeek() {
        #expect(
            weekRange(aggregateKey("2025-08-06"), weekStartsOn: .monday)
                == aggregateRange("2025-08-04", "2025-08-10")
        )
    }

    @Test("runs Sunday to Saturday when weeks start on Sunday")
    func sundayWeek() {
        #expect(
            weekRange(aggregateKey("2025-08-06"), weekStartsOn: .sunday)
                == aggregateRange("2025-08-03", "2025-08-09")
        )
    }

    @Test("places a Sunday at the end of a Monday week and the start of a Sunday week")
    func sundayAtEitherEnd() {
        #expect(
            weekRange(aggregateKey("2025-08-10"), weekStartsOn: .monday)
                == aggregateRange("2025-08-04", "2025-08-10")
        )
        #expect(
            weekRange(aggregateKey("2025-08-10"), weekStartsOn: .sunday)
                == aggregateRange("2025-08-10", "2025-08-16")
        )
    }

    @Test("spans month boundaries")
    func spansMonthBoundaries() {
        #expect(
            weekRange(aggregateKey("2025-08-01"), weekStartsOn: .monday)
                == aggregateRange("2025-07-28", "2025-08-03")
        )
    }

    @Test("stays seven days long across a DST transition")
    func sevenDaysAcrossDST() {
        #expect(
            weekRange(aggregateKey("2025-03-30"), weekStartsOn: .monday)
                == aggregateRange("2025-03-24", "2025-03-30")
        )
        #expect(
            weekRange(aggregateKey("2025-10-26"), weekStartsOn: .monday)
                == aggregateRange("2025-10-20", "2025-10-26")
        )
    }
}

@Suite("aggregate: monthRange")
struct AggregateMonthRangeTests {
    @Test("brackets an ordinary month")
    func ordinaryMonth() {
        #expect(monthRange(aggregateKey("2025-08-15")) == aggregateRange("2025-08-01", "2025-08-31"))
        #expect(monthRange(aggregateKey("2025-08-01")) == aggregateRange("2025-08-01", "2025-08-31"))
        #expect(monthRange(aggregateKey("2025-08-31")) == aggregateRange("2025-08-01", "2025-08-31"))
    }

    @Test("gives a leap-year February 29 days")
    func leapFebruary() {
        #expect(monthRange(aggregateKey("2024-02-10")) == aggregateRange("2024-02-01", "2024-02-29"))
        #expect(monthRange(aggregateKey("2024-02-29")) == aggregateRange("2024-02-01", "2024-02-29"))
    }

    @Test("gives a non-leap February 28 days")
    func nonLeapFebruary() {
        #expect(monthRange(aggregateKey("2025-02-10")) == aggregateRange("2025-02-01", "2025-02-28"))
    }

    @Test("handles 30-day months, December and the DST months")
    func thirtyDayMonthsAndDST() {
        #expect(monthRange(aggregateKey("2025-04-15")) == aggregateRange("2025-04-01", "2025-04-30"))
        #expect(monthRange(aggregateKey("2025-12-31")) == aggregateRange("2025-12-01", "2025-12-31"))
        #expect(monthRange(aggregateKey("2025-03-30")) == aggregateRange("2025-03-01", "2025-03-31"))
        #expect(monthRange(aggregateKey("2025-10-26")) == aggregateRange("2025-10-01", "2025-10-31"))
    }
}

@Suite("aggregate: subRange")
struct AggregateSubRangeTests {
    let loaded = [
        aggregateDetail("2025-08-03", workedMs: 2 * aggregateHour),
        aggregateDetail("2025-08-04", workedMs: 8 * aggregateHour),
        aggregateDetail("2025-08-06", workedMs: 9 * aggregateHour),
        aggregateDetail("2025-08-11", workedMs: 5 * aggregateHour),
    ]

    @Test("summarises only the days inside the sub-range, inclusive of both ends")
    func summarisesOnlyDaysInside() {
        let summary = subRange(loaded, range: weekRange(aggregateKey("2025-08-06"), weekStartsOn: .monday))

        #expect(summary.range == aggregateRange("2025-08-04", "2025-08-10"))
        #expect(summary.days.map(\.day.date.description) == ["2025-08-04", "2025-08-06"])
        #expect(summary.totalWorkedMs == 17 * aggregateHour)
        #expect(summary.activeDayCount == 2)
        #expect(summary.targetMetCount == 2)
    }

    @Test("is empty when nothing loaded falls inside the sub-range")
    func emptyWhenNothingInside() {
        let summary = subRange(loaded, range: aggregateRange("2025-09-01", "2025-09-30"))
        #expect(summary.days.isEmpty)
        #expect(summary.totalWorkedMs == 0)
        #expect(summary.averageWorkedMsPerActiveDay == 0)
    }

    @Test("keeps the loaded order of the days it selects")
    func keepsLoadedOrder() {
        let scrambled = [
            aggregateDetail("2025-08-06", workedMs: aggregateHour),
            aggregateDetail("2025-08-04", workedMs: aggregateHour),
        ]
        let summary = subRange(scrambled, range: aggregateRange("2025-08-04", "2025-08-10"))
        #expect(summary.days.map(\.day.date.description) == ["2025-08-06", "2025-08-04"])
    }
}
