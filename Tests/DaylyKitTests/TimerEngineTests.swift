import Foundation
import Testing
@testable import DaylyKit

/// End-to-end tests for the engine against a real SQLite file: the state machine, the
/// one-open-segment invariant, midnight rollover and target stamping.
///
/// The clock is injected, so the day boundaries these exercise are exact rather than
/// dependent on when the suite happens to run. The zone is pinned to Europe/Berlin so
/// the 23 h and 25 h DST days are reachable.

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private func local(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0
) -> EpochMs {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = berlin
    return cal.date(from: DateComponents(
        year: y, month: m, day: d, hour: h, minute: min, second: s
    ))!.epochMs
}

private func key(_ s: String) -> DateKey { DateKey(s)! }

/// A store plus an engine on a throwaway file, with a clock the test drives.
@MainActor
private final class Harness {
    let repo: Repository
    let engine: TimerEngine
    let prefs: PreferencesStore
    let db: Database
    private let path: String
    private var clock: EpochMs

    init(now: EpochMs, dailyTargetHours: Double = 8) throws {
        path = NSTemporaryDirectory() + "dayly-engine-\(UUID().uuidString).sqlite"
        db = try openDatabase(at: path)
        try runMigrations(db)
        repo = Repository(db: db, in: berlin)
        prefs = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        prefs.set(\.dailyTargetHours, to: dailyTargetHours)
        clock = now
        // `self` is captured after every stored property is initialised, so the
        // closure reads the live value rather than a copy of the initial one.
        var readClock: () -> EpochMs = { now }
        engine = TimerEngine(repo: repo, prefs: prefs, in: berlin, now: { readClock() })
        readClock = { [weak self] in self?.clock ?? now }
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func advance(to instant: EpochMs) { clock = instant }
    func advance(by ms: Int64) { clock += ms }
}

@Suite @MainActor struct TimerEngineStateMachine {
    @Test func startsIdleWithNoRows() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let snapshot = try h.engine.snapshot()
        #expect(snapshot.state == .idle)
        #expect(snapshot.dayId == nil)
        #expect(snapshot.openSegment == nil)
        #expect(snapshot.date == key("2025-08-04"))
        // With no day row yet the target comes from the live preference.
        #expect(snapshot.targetMinutes == 480)
    }

    @Test func startOpensAWorkSegmentAndCreatesTheDay() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let snapshot = try h.engine.start()
        #expect(snapshot.state == .running)
        #expect(snapshot.openSegment?.type == .work)
        #expect(snapshot.openSegment?.startedAt == local(2025, 8, 4, 9, 0))
        #expect(snapshot.dayId != nil)
        #expect(snapshot.firstStartAt == local(2025, 8, 4, 9, 0))
    }

    @Test func startIsANoOpWhileSomethingIsOpen() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let first = try h.engine.start()
        h.advance(by: 60_000)
        let second = try h.engine.start()
        #expect(second.openSegment?.id == first.openSegment?.id)
        let secondSegments = try h.repo.listSegments(dayId: try #require(second.dayId))
        #expect(secondSegments.count == 1)
    }

    @Test func pauseClosesWorkAndOpensBreakAtTheSameInstant() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 30))
        let snapshot = try h.engine.pause()

        #expect(snapshot.state == .paused)
        #expect(snapshot.openSegment?.type == .break)
        #expect(snapshot.closedWorkedMs == 90 * MS_PER_MINUTE)

        // The boundary instant is shared: a touch, not an overlap, so no millisecond
        // is lost or double-counted.
        let segments = try h.repo.listSegments(dayId: try #require(snapshot.dayId))
        #expect(segments.count == 2)
        #expect(segments[0].endedAt == segments[1].startedAt)
    }

    @Test func resumeSwitchesBack() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 0))
        try h.engine.pause()
        h.advance(to: local(2025, 8, 4, 10, 15))
        let snapshot = try h.engine.resume()

        #expect(snapshot.state == .running)
        #expect(snapshot.openSegment?.type == .work)
        #expect(snapshot.closedWorkedMs == 60 * MS_PER_MINUTE)
        #expect(snapshot.closedBreakMs == 15 * MS_PER_MINUTE)
    }

    @Test func pauseFromIdleIsANoOp() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let snapshot = try h.engine.pause()
        #expect(snapshot.state == .idle)
        let stillOpen = try h.repo.findOpenSegment()
        #expect(stillOpen == nil)
    }

    @Test func resumeWhileRunningIsANoOp() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let started = try h.engine.start()
        h.advance(by: 60_000)
        let snapshot = try h.engine.resume()
        #expect(snapshot.state == .running)
        #expect(snapshot.openSegment?.id == started.openSegment?.id)
    }

    @Test func endDayClosesTheSegmentAndFinalisesTheDay() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 17, 0))
        let snapshot = try h.engine.endDay()

        #expect(snapshot.state == .ended)
        #expect(snapshot.openSegment == nil)
        #expect(snapshot.closedWorkedMs == 8 * MS_PER_HOUR)
        #expect(snapshot.lastEndAt == local(2025, 8, 4, 17, 0))
        let endedDay = try h.repo.findDay(key("2025-08-04"))
        #expect(endedDay?.endedAt == local(2025, 8, 4, 17, 0))
    }

    @Test func endDayFromIdleIsANoOp() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let snapshot = try h.engine.endDay()
        #expect(snapshot.state == .idle)
        let missingDay = try h.repo.findDay(key("2025-08-04"))
        #expect(missingDay == nil)
    }

    @Test func startingAfterEndDayReopensTheSameDay() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 17, 0))
        let ended = try h.engine.endDay()
        h.advance(to: local(2025, 8, 4, 18, 0))
        let restarted = try h.engine.start()

        #expect(restarted.state == .running)
        // The same day row, un-finalised, rather than a second one.
        #expect(restarted.dayId == ended.dayId)
        let reopened = try h.repo.findDay(key("2025-08-04"))
        #expect(reopened?.endedAt == nil)
        #expect(restarted.closedWorkedMs == 8 * MS_PER_HOUR)
    }

    @Test func totalsAreDerivedNotStored() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 12, 0))
        try h.engine.pause()
        h.advance(to: local(2025, 8, 4, 12, 30))
        try h.engine.resume()
        h.advance(to: local(2025, 8, 4, 17, 0))
        let snapshot = try h.engine.endDay()

        #expect(snapshot.closedWorkedMs == 3 * MS_PER_HOUR + 4 * MS_PER_HOUR + 30 * MS_PER_MINUTE)
        #expect(snapshot.closedBreakMs == 30 * MS_PER_MINUTE)

        // Deleting a segment changes the total immediately, with nothing to invalidate.
        let segments = try h.repo.listSegments(dayId: try #require(snapshot.dayId))
        try h.repo.deleteSegment(segments[0].id)
        let after = try h.engine.snapshot()
        #expect(after.closedWorkedMs == 4 * MS_PER_HOUR + 30 * MS_PER_MINUTE)
    }

    @Test func onlyOneSegmentIsEverOpen() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        for minute in stride(from: 10, through: 60, by: 10) {
            h.advance(to: local(2025, 8, 4, 9, minute))
            _ = minute % 20 == 0 ? try h.engine.resume() : try h.engine.pause()
            let open = try h.db.query("SELECT COUNT(*) FROM segments WHERE ended_at IS NULL") {
                $0.int(0)
            }
            #expect(open == [1])
        }
    }
}

@Suite @MainActor struct TimerEngineMidnight {
    @Test func rolloverSplitsARunningSegmentAtLocalMidnight() throws {
        let h = try Harness(now: local(2025, 8, 4, 23, 0))
        let started = try h.engine.start()
        h.advance(to: local(2025, 8, 5, 1, 0))
        let snapshot = try h.engine.rollOverMidnight()

        #expect(snapshot.date == key("2025-08-05"))
        #expect(snapshot.state == .running)
        // Yesterday keeps the hour it earned; today starts fresh at midnight.
        let asOf = try h.engine.snapshot().asOf
        let yesterday = try #require(try h.repo.dayDetail(key("2025-08-04"), now: asOf))
        #expect(yesterday.totals.workedMs == MS_PER_HOUR)
        #expect(snapshot.openSegment?.startedAt == local(2025, 8, 5, 0, 0))
        // The original row survives the split — prompts and snapshots hold its id.
        #expect(yesterday.segments.first?.id == started.openSegment?.id)
    }

    @Test func rolloverIsANoOpBeforeMidnight() throws {
        let h = try Harness(now: local(2025, 8, 4, 22, 0))
        let started = try h.engine.start()
        h.advance(to: local(2025, 8, 4, 23, 30))
        let snapshot = try h.engine.rollOverMidnight()
        #expect(snapshot.openSegment?.id == started.openSegment?.id)
        #expect(snapshot.openSegment?.startedAt == local(2025, 8, 4, 22, 0))
    }

    @Test func rolloverKeepsTheSegmentType() throws {
        let h = try Harness(now: local(2025, 8, 4, 23, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 23, 30))
        try h.engine.pause()
        h.advance(to: local(2025, 8, 5, 0, 30))
        let snapshot = try h.engine.rollOverMidnight()
        // A break that spans midnight is still a break on the far side.
        #expect(snapshot.openSegment?.type == .break)
        #expect(snapshot.state == .paused)
    }

    @Test func endDayAcrossMidnightFinalisesTheDayItEndsIn() throws {
        let h = try Harness(now: local(2025, 8, 4, 23, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 5, 1, 0))
        let snapshot = try h.engine.endDay()

        #expect(snapshot.date == key("2025-08-05"))
        #expect(snapshot.state == .ended)
        let endedIn = try h.repo.findDay(key("2025-08-05"))
        #expect(endedIn?.endedAt == local(2025, 8, 5, 1, 0))
        // The earlier day was never ended — only split.
        let reopened = try h.repo.findDay(key("2025-08-04"))
        #expect(reopened?.endedAt == nil)
        #expect(snapshot.closedWorkedMs == MS_PER_HOUR)
    }

    @Test func springForwardDayLosesTheSkippedHour() throws {
        // 2025-03-30 in Berlin is 23 hours long: 02:00–03:00 never happens.
        let h = try Harness(now: local(2025, 3, 29, 23, 0))
        try h.engine.start()
        h.advance(to: local(2025, 3, 30, 12, 0))
        let snapshot = try h.engine.rollOverMidnight()
        #expect(snapshot.date == key("2025-03-30"))
        #expect(snapshot.openSegment?.startedAt == local(2025, 3, 30, 0, 0))
        // Midnight to noon on the short day is 11 elapsed hours, not 12.
        #expect(spanDuration(try #require(snapshot.openSegment), now: local(2025, 3, 30, 12, 0))
            == 11 * MS_PER_HOUR)
    }

    @Test func fallBackDayGainsTheRepeatedHour() throws {
        // 2025-10-26 in Berlin is 25 hours long: 02:00–03:00 happens twice.
        let h = try Harness(now: local(2025, 10, 25, 23, 0))
        try h.engine.start()
        h.advance(to: local(2025, 10, 26, 12, 0))
        let snapshot = try h.engine.rollOverMidnight()
        #expect(snapshot.openSegment?.startedAt == local(2025, 10, 26, 0, 0))
        #expect(spanDuration(try #require(snapshot.openSegment), now: local(2025, 10, 26, 12, 0))
            == 13 * MS_PER_HOUR)
    }
}

@Suite @MainActor struct TimerEngineTargets {
    @Test func theDayStampsTheTargetItWasStartedUnder() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0), dailyTargetHours: 7.5)
        let snapshot = try h.engine.start()
        #expect(snapshot.targetMinutes == 450)
        let stampedDay = try h.repo.findDay(key("2025-08-04"))
        #expect(stampedDay?.targetMinutes == 450)
    }

    @Test func changingTheTargetRestampsOnlyToday() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 17, 0))
        try h.engine.endDay()

        // A second, later day so there is history to protect.
        h.advance(to: local(2025, 8, 5, 9, 0))
        try h.engine.start()

        h.prefs.set(\.dailyTargetHours, to: 6)
        let changed = try h.engine.syncTodayTarget()

        #expect(changed == [key("2025-08-05")])
        let todayRow = try h.repo.findDay(key("2025-08-05"))
        #expect(todayRow?.targetMinutes == 360)
        // Yesterday keeps the goal it was actually run against.
        let pastDay = try h.repo.findDay(key("2025-08-04"))
        #expect(pastDay?.targetMinutes == 480)
    }

    @Test func resavingTheSameTargetChangesNothing() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        let changedDates = try h.engine.syncTodayTarget()
        #expect(changedDates == [])
    }

    @Test func syncWithNoDayRowIsANoOp() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        h.prefs.set(\.dailyTargetHours, to: 4)
        let changedDates = try h.engine.syncTodayTarget()
        #expect(changedDates == [])
    }
}

@Suite @MainActor struct TimerEngineClockGuards {
    @Test func aBackwardsClockCannotProduceAReversedSegment() throws {
        let h = try Harness(now: local(2025, 8, 4, 12, 0))
        let started = try h.engine.start()
        // The clock jumps backwards — NTP correction, or the user changing it.
        h.advance(to: local(2025, 8, 4, 11, 0))
        let snapshot = try h.engine.pause()

        let segments = try h.repo.listSegments(dayId: try #require(snapshot.dayId))
        let closed = try #require(segments.first { $0.id == started.openSegment?.id })
        // Clamped to the start rather than ending before it.
        #expect(closed.endedAt == closed.startedAt)
        let asOf = try h.engine.snapshot().asOf
        #expect(spanDuration(closed, now: asOf) == 0)
    }

    @Test func suspendLeavesAnEmptySegmentRunning() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let started = try h.engine.start()
        // A sleep reported at the very instant the segment opened: closing it would
        // store an empty row, so it is left running instead.
        try h.engine.suspend(at: local(2025, 8, 4, 9, 0))
        let openNow = try h.repo.findOpenSegment()
        #expect(openNow?.id == started.openSegment?.id)
    }

    @Test func suspendClosesRealWork() throws {
        let h = try Harness(now: local(2025, 8, 4, 11, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 12, 0))
        try h.engine.suspend(at: local(2025, 8, 4, 11, 30))

        let stillOpen = try h.repo.findOpenSegment()
        #expect(stillOpen == nil)
        let snapshot = try h.engine.snapshot()
        #expect(snapshot.state == .idle)
        #expect(snapshot.closedWorkedMs == 30 * MS_PER_MINUTE)
    }

    @Test func suspendIgnoresAnOpenBreak() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 0))
        let paused = try h.engine.pause()
        h.advance(to: local(2025, 8, 4, 11, 0))
        // A break already accounts for the gap, so nothing is cut short.
        try h.engine.suspend(at: local(2025, 8, 4, 10, 30))
        let openBreak = try h.repo.findOpenSegment()
        #expect(openBreak?.id == paused.openSegment?.id)
    }
}

@Suite @MainActor struct TimerEngineWakeAndIdle {
    @Test func countingAGapAsABreakStoresItAndResumesWork() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 0))
        try h.engine.suspend(at: local(2025, 8, 4, 10, 0))
        h.advance(to: local(2025, 8, 4, 11, 0))

        let plan = planWake(
            gapStartedAt: local(2025, 8, 4, 10, 0),
            gapEndedAt: local(2025, 8, 4, 11, 0),
            choice: .countAsBreak
        )
        let snapshot = try h.engine.apply(plan)

        #expect(snapshot.state == .running)
        #expect(snapshot.closedBreakMs == MS_PER_HOUR)
        #expect(snapshot.closedWorkedMs == MS_PER_HOUR)
        #expect(snapshot.openSegment?.startedAt == local(2025, 8, 4, 11, 0))
    }

    @Test func resumingWorkLeavesTheGapOffTheRecord() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 0))
        try h.engine.suspend(at: local(2025, 8, 4, 10, 0))
        h.advance(to: local(2025, 8, 4, 11, 0))

        let plan = planWake(
            gapStartedAt: local(2025, 8, 4, 10, 0),
            gapEndedAt: local(2025, 8, 4, 11, 0),
            choice: .resume
        )
        let snapshot = try h.engine.apply(plan)

        #expect(snapshot.closedBreakMs == 0)
        #expect(snapshot.closedWorkedMs == MS_PER_HOUR)
        #expect(snapshot.openSegment?.startedAt == local(2025, 8, 4, 11, 0))
    }

    @Test func wakeIsANoOpWhileAnythingIsOpen() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let started = try h.engine.start()
        h.advance(to: local(2025, 8, 4, 11, 0))
        let plan = planWake(
            gapStartedAt: local(2025, 8, 4, 10, 0),
            gapEndedAt: local(2025, 8, 4, 11, 0),
            choice: .countAsBreak
        )
        let snapshot = try h.engine.apply(plan)
        // A second open segment would break the one-open-segment invariant.
        #expect(snapshot.openSegment?.id == started.openSegment?.id)
        #expect(snapshot.closedBreakMs == 0)
    }

    @Test func discardingIdleTimeTrimsAndReopens() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let started = try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 0))

        let segment = try #require(try h.repo.findOpenSegment())
        let plan = planIdle(
            segment,
            idleStartedAt: local(2025, 8, 4, 9, 30),
            choice: .discard,
            now: local(2025, 8, 4, 10, 0)
        )
        let snapshot = try h.engine.apply(plan)

        // The half hour of work before going idle is kept; the idle stretch is simply
        // absent from the record rather than stored as anything.
        #expect(snapshot.closedWorkedMs == 30 * MS_PER_MINUTE)
        #expect(snapshot.closedBreakMs == 0)
        #expect(snapshot.state == .running)
        #expect(snapshot.openSegment?.id != started.openSegment?.id)
    }

    @Test func keepingIdleTimeWritesNothing() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        let started = try h.engine.start()
        h.advance(to: local(2025, 8, 4, 10, 0))
        let segment = try #require(try h.repo.findOpenSegment())
        let plan = planIdle(
            segment, idleStartedAt: local(2025, 8, 4, 9, 30),
            choice: .keep, now: local(2025, 8, 4, 10, 0)
        )
        let snapshot = try h.engine.apply(plan)
        #expect(snapshot.openSegment?.id == started.openSegment?.id)
        let kept = try h.repo.listSegments(dayId: try #require(snapshot.dayId))
        #expect(kept.count == 1)
    }

    @Test func recoveryClosesAtTheHeartbeat() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        let segment = try #require(try h.repo.findOpenSegment())
        // The app died at 10:00; it is now 14:00.
        h.advance(to: local(2025, 8, 4, 14, 0))

        let pending = buildPendingRecovery(
            segment, lastHeartbeatAt: local(2025, 8, 4, 10, 0),
            now: local(2025, 8, 4, 14, 0), in: berlin
        )
        #expect(pending.recoverableMs == MS_PER_HOUR)
        #expect(pending.gapMs == 4 * MS_PER_HOUR)

        let snapshot = try h.engine.apply(planRecovery(
            pending, choice: .closeAtHeartbeat, now: local(2025, 8, 4, 14, 0)
        ))
        #expect(snapshot.state == .idle)
        #expect(snapshot.closedWorkedMs == MS_PER_HOUR)
    }

    @Test func recoveryDiscardDeletesTheSegment() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        let segment = try #require(try h.repo.findOpenSegment())
        h.advance(to: local(2025, 8, 4, 14, 0))

        let pending = buildPendingRecovery(
            segment, lastHeartbeatAt: local(2025, 8, 4, 10, 0),
            now: local(2025, 8, 4, 14, 0), in: berlin
        )
        let snapshot = try h.engine.apply(planRecovery(
            pending, choice: .discard, now: local(2025, 8, 4, 14, 0)
        ))
        #expect(snapshot.state == .idle)
        #expect(snapshot.closedWorkedMs == 0)
        let gone = try h.repo.segment(id: segment.id)
        #expect(gone == nil)
    }

    @Test func recoveryResumeLeavesItRunning() throws {
        let h = try Harness(now: local(2025, 8, 4, 9, 0))
        try h.engine.start()
        let segment = try #require(try h.repo.findOpenSegment())
        h.advance(to: local(2025, 8, 4, 14, 0))

        let pending = buildPendingRecovery(
            segment, lastHeartbeatAt: local(2025, 8, 4, 10, 0),
            now: local(2025, 8, 4, 14, 0), in: berlin
        )
        let snapshot = try h.engine.apply(planRecovery(
            pending, choice: .resume, now: local(2025, 8, 4, 14, 0)
        ))
        #expect(snapshot.state == .running)
        #expect(snapshot.openSegment?.id == segment.id)
    }
}

@Suite @MainActor struct TimerEnginePersistence {
    @Test func stateSurvivesAnEngineRestart() throws {
        let path = NSTemporaryDirectory() + "dayly-restart-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let prefs = DefaultPreferencesStore(backend: InMemoryPreferencesBackend())
        var now = local(2025, 8, 4, 9, 0)

        do {
            let db = try openDatabase(at: path)
            try runMigrations(db)
            let engine = TimerEngine(
                repo: Repository(db: db, in: berlin), prefs: prefs, in: berlin, now: { now }
            )
            try engine.start()
            now = local(2025, 8, 4, 10, 0)
            try engine.pause()
        }

        // A fresh process opening the same file derives the same state from the rows.
        let db = try openDatabase(at: path)
        try runMigrations(db)
        let engine = TimerEngine(
            repo: Repository(db: db, in: berlin), prefs: prefs, in: berlin, now: { now }
        )
        let snapshot = try engine.snapshot()
        #expect(snapshot.state == .paused)
        #expect(snapshot.closedWorkedMs == MS_PER_HOUR)
    }

    @Test func migrationsAreIdempotent() throws {
        let path = NSTemporaryDirectory() + "dayly-migrate-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let db = try openDatabase(at: path)
        try runMigrations(db)
        try runMigrations(db)
        try runMigrations(db)
        let version = try readSchemaVersion(db)
        #expect(version == CURRENT_SCHEMA_VERSION)
    }

    @Test func aFileFromANewerBuildIsRefusedBeforeAnyWrite() throws {
        let path = NSTemporaryDirectory() + "dayly-newer-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let db = try openDatabase(at: path)
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        try db.run("INSERT INTO schema_version (version) VALUES (?)", [.integer(99)])

        #expect(throws: SchemaTooNewError.self) { try runMigrations(db) }
        // Refused before anything was created, so the newer build's file is untouched.
        let tables = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='days'"
        ) { $0.text(0) }
        #expect(tables.isEmpty)
    }
}
