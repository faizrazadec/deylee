import Foundation
import Testing
@testable import DaylyKit

/// The reminder's once-a-day rule, pinned to Europe/Berlin so "today" is a fixed thing.

private let reminderBerlin = TimeZone(identifier: "Europe/Berlin")!

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> EpochMs {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = reminderBerlin
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.epochMs
}

/// The default setting: enabled, running, due at 17:30.
private func fire(
    _ schedule: inout ReminderSchedule,
    at instant: EpochMs,
    enabled: Bool = true,
    isRunning: Bool = true,
    hour: Int = 17,
    minute: Int = 30
) -> Bool {
    schedule.shouldFire(
        now: instant, enabled: enabled, isRunning: isRunning,
        reminderHour: hour, reminderMinute: minute, in: reminderBerlin
    )
}

@Suite struct ReminderScheduleRule {
    @Test func firesOnceAtTheDueMinute() {
        var schedule = ReminderSchedule()
        #expect(!fire(&schedule, at: at(2025, 8, 4, 17, 29)))
        #expect(fire(&schedule, at: at(2025, 8, 4, 17, 30)))
    }

    @Test func doesNotFireAgainTheSameDay() {
        var schedule = ReminderSchedule()
        #expect(fire(&schedule, at: at(2025, 8, 4, 17, 30)))
        // Every later tick of the evening would otherwise re-fire.
        for minute in [31, 45, 59] {
            #expect(!fire(&schedule, at: at(2025, 8, 4, 17, minute)))
        }
        #expect(!fire(&schedule, at: at(2025, 8, 4, 23, 59)))
    }

    @Test func firesAgainTheNextDay() {
        var schedule = ReminderSchedule()
        #expect(fire(&schedule, at: at(2025, 8, 4, 17, 30)))
        #expect(fire(&schedule, at: at(2025, 8, 5, 17, 30)))
    }

    /// A tick can land a second or two late, so an exact-match rule would skip the day.
    @Test func firesLateRatherThanNotAtAll() {
        var schedule = ReminderSchedule()
        #expect(fire(&schedule, at: at(2025, 8, 4, 19, 12)))
    }

    @Test func doesNotFireWhenDisabled() {
        var schedule = ReminderSchedule()
        #expect(!fire(&schedule, at: at(2025, 8, 4, 18, 0), enabled: false))
        // And the day is not marked, so enabling it later the same day still works.
        #expect(fire(&schedule, at: at(2025, 8, 4, 18, 1)))
    }

    @Test func doesNotFireWhenTheTimerIsNotRunning() {
        var schedule = ReminderSchedule()
        #expect(!fire(&schedule, at: at(2025, 8, 4, 18, 0), isRunning: false))
        #expect(fire(&schedule, at: at(2025, 8, 4, 18, 1)))
    }

    /// Moving the time earlier after today's nudge must not produce a second one.
    @Test func movingTheTimeEarlierDoesNotRefire() {
        var schedule = ReminderSchedule()
        #expect(fire(&schedule, at: at(2025, 8, 4, 17, 30)))
        #expect(!fire(&schedule, at: at(2025, 8, 4, 17, 31), hour: 9, minute: 0))
    }

    @Test func midnightDueTimeFiresAllDay() {
        var schedule = ReminderSchedule()
        #expect(fire(&schedule, at: at(2025, 8, 4, 0, 0), hour: 0, minute: 0))
        #expect(!fire(&schedule, at: at(2025, 8, 4, 12, 0), hour: 0, minute: 0))
        #expect(fire(&schedule, at: at(2025, 8, 5, 0, 0), hour: 0, minute: 0))
    }

    /// The day is marked as part of deciding, so a caller whose delivery throws cannot
    /// leave it unmarked and re-fire on every tick.
    @Test func theDayIsMarkedByTheDecisionItself() {
        var schedule = ReminderSchedule()
        #expect(schedule.lastFiredOn == nil)
        _ = fire(&schedule, at: at(2025, 8, 4, 17, 30))
        #expect(schedule.lastFiredOn == DateKey("2025-08-04"))
    }

    @Test func crossesADSTBoundaryWithoutFiringTwice() {
        var schedule = ReminderSchedule()
        // 2025-10-26 is 25 hours long in Berlin; the repeated hour must not read as a
        // second day.
        #expect(fire(&schedule, at: at(2025, 10, 26, 17, 30)))
        #expect(!fire(&schedule, at: at(2025, 10, 26, 20, 0)))
        #expect(fire(&schedule, at: at(2025, 10, 27, 17, 30)))
    }

    @Test func aZoneChangeIsFollowed() {
        var schedule = ReminderSchedule()
        // 23:30 in Berlin is already the next calendar day in Auckland, so the same
        // instant is a different "today" and the nudge is due again there.
        #expect(fire(&schedule, at: at(2025, 8, 4, 23, 30)))
        var elsewhere = schedule
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        let firedThere = elsewhere.shouldFire(
            now: at(2025, 8, 4, 23, 30), enabled: true, isRunning: true,
            reminderHour: 0, reminderMinute: 0, in: auckland
        )
        #expect(firedThere)
    }
}
