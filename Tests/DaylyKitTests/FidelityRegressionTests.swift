import Foundation
import Testing
@testable import DaylyKit

/// Regression guards for divergences an adversarial review of the TypeScript-to-Swift
/// port found. Each one is a case where Swift's arithmetic or collection semantics
/// would otherwise behave differently from the Electron build the data came from.

@Suite struct JSRoundingParity {
    /// `floor(x + 0.5)` is the usual shorthand for JavaScript's `Math.round`, but the
    /// addition is itself rounded: `0.49999999999999994 + 0.5` is exactly `1.0`, so the
    /// shorthand rounds the largest double below a half up where JavaScript rounds down.
    ///
    /// Reached here through a preference file, which is exactly how it could reach the
    /// Electron build: a reminder one minute late, forever.
    @Test func largestDoubleBelowAHalfRoundsDown() {
        let justUnderAHalf = 0.49999999999999994
        let prefs = Preferences.sanitized(
            raw: ["reminderMinute": .number(justUnderAHalf)], fallback: .defaults
        )
        #expect(prefs.reminderMinute == 0)
    }

    /// The same double reaching `weekStartsOn` would flip the History week roll-up and
    /// the calendar's column order from Sunday to Monday.
    @Test func largestDoubleBelowAHalfPicksSunday() {
        let prefs = Preferences.sanitized(
            raw: ["weekStartsOn": .number(0.49999999999999994)], fallback: .defaults
        )
        #expect(prefs.weekStartsOn == .sunday)
    }

    @Test func halvesRoundTowardsPositiveInfinity() {
        // Math.round(7.5) === 8, Math.round(-7.5) === -7 — not away from zero.
        #expect(hoursToMinutes(0.125) == 8)
        #expect(hoursToMinutes(-0.125) == -7)
        #expect(hoursToMinutes(0.0416666666666666666) == 3)
    }

    @Test func ordinaryTargetsAreUnchanged() {
        #expect(hoursToMinutes(8) == 480)
        #expect(hoursToMinutes(7.5) == 450)
        #expect(hoursToMinutes(0) == 0)
    }
}

@Suite struct SaturatingArithmetic {
    /// JavaScript numbers cannot overflow, so the Electron build survives an absurd
    /// target on a corrupt store. Turning the same value into a crash would be a
    /// regression, so every conversion saturates instead of trapping.
    @Test func anAbsurdTargetSaturatesInsteadOfTrapping() {
        #expect(hoursToMinutes(1e18) == Int.max)
        #expect(hoursToMinutes(-1e18) == Int.min)
        #expect(hoursToMinutes(.infinity) == Int.max)
        #expect(hoursToMinutes(-.infinity) == Int.min)
    }

    @Test func minutesToMsSaturates() {
        #expect(minutesToMs(Int.max) == Int64.max)
        #expect(minutesToMs(Int.min) == Int64.min)
        #expect(minutesToMs(480) == 480 * MS_PER_MINUTE)
    }

    @Test func hoursToMsSaturates() {
        #expect(hoursToMs(1e13) == Int64.max)
        #expect(hoursToMs(-1e13) == Int64.min)
        #expect(hoursToMs(1) == MS_PER_HOUR)
    }

    @Test func liveTotalsSurviveACorruptTarget() {
        let snapshot = TimerSnapshot(
            state: .idle, date: DateKey("2025-08-04")!,
            closedWorkedMs: 3_600_000, targetMinutes: Int.max,
            asOf: 1_754_300_000_000
        )
        let live = liveTotals(snapshot, now: 1_754_300_000_000)
        #expect(live.targetMs == Int64.max)
        #expect(live.workedMs == 3_600_000)
        #expect(live.targetProgress > 0)
    }

    @Test func summarisingSurvivesACorruptTarget() {
        let date = DateKey("2025-08-04")!
        let day = Day(id: 1, date: date, createdAt: 0, targetMinutes: Int.max)
        let totals = DayTotals(workedMs: 3_600_000, segmentCount: 1)
        let summary = summariseRange(
            DateRange(from: date, to: date),
            days: [DayDetail(day: day, segments: [], totals: totals)]
        )
        #expect(summary.activeDayCount == 1)
        // A target that large can never be met, which is exactly what Electron showed.
        #expect(summary.targetMetCount == 0)
    }
}

@Suite struct AverageFloors {
    /// The Electron build divided as a float and its only consumer floored on the way
    /// to a display string. Truncating toward zero would disagree on negative totals,
    /// which a hand-edited file can produce.
    @Test func averageFloorsRatherThanTruncatingTowardZero() {
        // Three active days, but a fourth day's negative total drags the sum below
        // zero: -10 / 3 is -3.33, which floors to -4 and truncates to -3.
        let workedPerDay: [Int64] = [1, 1, 1, -13]
        let days = workedPerDay.enumerated().map { index, worked in
            DayDetail(
                day: Day(
                    id: Int64(index + 1),
                    date: DateKey("2025-08-0\(index + 1)")!,
                    createdAt: 0, targetMinutes: 0
                ),
                segments: [], totals: DayTotals(workedMs: worked, segmentCount: 1)
            )
        }
        let summary = summariseRange(
            DateRange(from: DateKey("2025-08-01")!, to: DateKey("2025-08-04")!), days: days
        )
        #expect(summary.totalWorkedMs == -10)
        #expect(summary.activeDayCount == 3)
        #expect(summary.averageWorkedMsPerActiveDay == -4)
    }

    @Test func averageIsExactForOrdinaryData() {
        let days = [Int64(3_600_000), 5_400_000].enumerated().map { index, worked in
            DayDetail(
                day: Day(
                    id: Int64(index + 1),
                    date: DateKey("2025-08-0\(index + 1)")!,
                    createdAt: 0, targetMinutes: 480
                ),
                segments: [], totals: DayTotals(workedMs: worked, segmentCount: 1)
            )
        }
        let summary = summariseRange(
            DateRange(from: DateKey("2025-08-01")!, to: DateKey("2025-08-02")!), days: days
        )
        #expect(summary.averageWorkedMsPerActiveDay == 4_500_000)
    }

    @Test func averageIsZeroWithNoActiveDays() {
        let date = DateKey("2025-08-04")!
        let day = DayDetail(
            day: Day(id: 1, date: date, createdAt: 0, targetMinutes: 480),
            segments: [], totals: DayTotals(workedMs: 0, breakMs: 600, segmentCount: 1)
        )
        let summary = summariseRange(DateRange(from: date, to: date), days: [day])
        #expect(summary.activeDayCount == 0)
        #expect(summary.averageWorkedMsPerActiveDay == 0)
    }
}

@Suite struct PreferenceStoreConcurrency {
    /// Every mutation reads the whole set, changes one key and writes it all back. Two
    /// writers sharing one read would each write a full set and the loser's key would
    /// vanish — while its `set` still returned, and announced, the value it thought it
    /// had stored. The Electron main process is single-threaded and cannot do that.
    @Test func concurrentWritesToDifferentKeysBothSurvive() async {
        let store = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        store.set(\.theme, to: .system)
        store.set(\.reminderHour, to: 17)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { store.set(\.theme, to: .dark) }
                group.addTask { store.set(\.reminderHour, to: 6) }
            }
        }

        let final = store.getAll()
        #expect(final.theme == .dark)
        #expect(final.reminderHour == 6)
    }

    @Test func listenersFireInRegistrationOrder() {
        let store = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        let recorder = OrderRecorder()
        for index in 0..<8 {
            _ = store.onChange { _ in recorder.record(index) }
        }
        store.set(\.theme, to: .dark)
        #expect(recorder.order == Array(0..<8))
    }

    @Test func unsubscribingLeavesTheRemainingOrderIntact() {
        let store = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        let recorder = OrderRecorder()
        _ = store.onChange { _ in recorder.record(0) }
        let second = store.onChange { _ in recorder.record(1) }
        _ = store.onChange { _ in recorder.record(2) }
        second()
        store.set(\.theme, to: .dark)
        #expect(recorder.order == [0, 2])
    }

    @Test func negativeZeroIsNormalised() {
        let store = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        _ = try? store.write(.dailyTargetHours, .number(-0.0))
        let stored = store.value(\.dailyTargetHours)
        #expect(stored == 0)
        // `-0.0 == 0.0`, so the sign bit is what has to be checked.
        #expect(stored.sign == .plus)
    }
}

/// Collects listener callbacks in order. A class so the closures share one instance.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var order: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
