import Foundation
import Testing

@testable import DeyleeKit

/// Tests for crash recovery and the idle / sleep-gap decisions.
///
/// Every function here is pure: it turns (segment, heartbeat, now) into a description
/// or a plan, and never touches storage. The cases below therefore pin down exactly
/// which instants a plan carries, because the caller writes those verbatim.
///
/// The TypeScript suite ran in whatever zone the machine had; here the zone is pinned
/// to Europe/Berlin so the one calendar-dependent value — `PendingRecovery.date` — is
/// reproducible.

private let recoveryBerlin = TimeZone(identifier: "Europe/Berlin")!

private let recoveryHour: Int64 = 3_600_000
private let recoveryMinute: Int64 = 60_000
private let recoverySecond: Int64 = 1_000

private func recoveryLocal(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0,
    in zone: TimeZone = recoveryBerlin
) -> EpochMs {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = DateComponents(
        year: y, month: m, day: d, hour: h, minute: min, second: s
    )
    return calendar.date(from: components)!.epochMs
}

/// Hours on 2025-08-04 unless a case explicitly needs another day.
private func recoveryAt(_ h: Int, _ min: Int = 0, _ s: Int = 0) -> EpochMs {
    recoveryLocal(2025, 8, 4, h, min, s)
}

private func recoverySegment(
    _ id: Int64,
    _ type: SegmentType,
    _ startedAt: EpochMs,
    _ endedAt: EpochMs? = nil
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

private func recoveryKey(_ value: String) -> DateKey {
    DateKey(value)!
}

@Suite struct RecoveryResolveHeartbeatCloseInstantTests {
    let open = recoverySegment(1, .work, recoveryAt(9))

    @Test func usesTheHeartbeatWhenItSitsInsideTheSegment() {
        #expect(
            resolveHeartbeatCloseInstant(
                open, lastHeartbeatAt: recoveryAt(11, 30), now: recoveryAt(14)
            ) == recoveryAt(11, 30)
        )
    }

    @Test func fallsBackToTheSegmentStartWhenThereIsNoHeartbeat() {
        #expect(
            resolveHeartbeatCloseInstant(open, lastHeartbeatAt: nil, now: recoveryAt(14))
                == recoveryAt(9)
        )
    }

    @Test func pullsAFutureHeartbeatBackToNow() {
        #expect(
            resolveHeartbeatCloseInstant(
                open, lastHeartbeatAt: recoveryAt(15), now: recoveryAt(14)
            ) == recoveryAt(14)
        )
    }

    @Test func pushesAHeartbeatOlderThanTheSegmentUpToTheSegmentStart() {
        #expect(
            resolveHeartbeatCloseInstant(
                open, lastHeartbeatAt: recoveryAt(8), now: recoveryAt(14)
            ) == recoveryAt(9)
        )
    }
}

@Suite struct RecoveryBuildPendingRecoveryTests {
    @Test func splitsTheOpenTimeIntoRecoverableAndUnaccountedFor() {
        let open = recoverySegment(1, .work, recoveryAt(9))
        let pending = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(11, 30), now: recoveryAt(14), in: recoveryBerlin
        )

        #expect(
            pending
                == PendingRecovery(
                    segment: open,
                    date: recoveryKey("2025-08-04"),
                    lastHeartbeatAt: recoveryAt(11, 30),
                    recoverableMs: 2 * recoveryHour + 30 * recoveryMinute,
                    gapMs: 2 * recoveryHour + 30 * recoveryMinute
                )
        )
    }

    @Test func recoversNothingWhenThereWasNeverAHeartbeat() {
        let open = recoverySegment(1, .work, recoveryAt(9))
        let pending = buildPendingRecovery(
            open, lastHeartbeatAt: nil, now: recoveryAt(14), in: recoveryBerlin
        )

        #expect(pending.lastHeartbeatAt == nil)
        #expect(pending.recoverableMs == 0)
        #expect(pending.gapMs == 5 * recoveryHour)
    }

    @Test func clampsAHeartbeatFromTheFutureBackToNowLeavingNoGap() {
        // A backwards clock change can leave a heartbeat that is still ahead of `now`.
        let open = recoverySegment(1, .work, recoveryAt(9))
        let pending = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(15), now: recoveryAt(14), in: recoveryBerlin
        )

        #expect(pending.lastHeartbeatAt == recoveryAt(15))
        #expect(pending.recoverableMs == 5 * recoveryHour)
        #expect(pending.gapMs == 0)
    }

    @Test func clampsAHeartbeatOlderThanTheSegmentUpToTheSegmentStart() {
        let open = recoverySegment(1, .work, recoveryAt(9))
        let pending = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(8), now: recoveryAt(14), in: recoveryBerlin
        )

        #expect(pending.lastHeartbeatAt == recoveryAt(8))
        #expect(pending.recoverableMs == 0)
        #expect(pending.gapMs == 5 * recoveryHour)
    }

    @Test func reportsTheDayTheSegmentStartedOnNotTheDayTheAppRelaunched() {
        let open = recoverySegment(1, .work, recoveryLocal(2025, 8, 3, 22, 0))
        let pending = buildPendingRecovery(
            open,
            lastHeartbeatAt: recoveryLocal(2025, 8, 3, 23, 30),
            now: recoveryLocal(2025, 8, 4, 9, 0),
            in: recoveryBerlin
        )

        #expect(pending.date == recoveryKey("2025-08-03"))
        #expect(pending.recoverableMs == recoveryHour + 30 * recoveryMinute)
        #expect(pending.gapMs == 9 * recoveryHour + 30 * recoveryMinute)
    }

    @Test func neverReportsNegativeDurationsWhenNowPrecedesTheSegment() {
        let open = recoverySegment(1, .work, recoveryAt(9))
        let pending = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(9, 30), now: recoveryAt(8), in: recoveryBerlin
        )

        #expect(pending.recoverableMs == 0)
        #expect(pending.gapMs == 0)
    }

    /// Not expressible in the TypeScript suite, which read the machine zone.
    @Test func derivesTheDateInTheZoneItIsGiven() {
        // 2025-08-04T23:30:00Z is still the 4th in UTC but already the 5th in Berlin.
        let startedAt: EpochMs = 1_754_350_200_000
        let open = recoverySegment(1, .work, startedAt)

        let berlin = buildPendingRecovery(
            open, lastHeartbeatAt: nil, now: startedAt + recoveryHour, in: recoveryBerlin
        )
        let utc = buildPendingRecovery(
            open, lastHeartbeatAt: nil, now: startedAt + recoveryHour,
            in: TimeZone(identifier: "UTC")!
        )

        #expect(berlin.date == recoveryKey("2025-08-05"))
        #expect(utc.date == recoveryKey("2025-08-04"))
    }

    /// Not expressible in the TypeScript suite: durations are wall-clock deltas, so a
    /// DST jump inside the segment is not compensated for.
    @Test func measuresElapsedMillisecondsAcrossADstJumpNotWallClockHours() {
        // Berlin springs forward at 02:00 on 2025-03-30; 01:30 to 03:30 is one hour.
        let open = recoverySegment(1, .work, recoveryLocal(2025, 3, 30, 1, 30))
        let pending = buildPendingRecovery(
            open,
            lastHeartbeatAt: recoveryLocal(2025, 3, 30, 3, 30),
            now: recoveryLocal(2025, 3, 30, 4, 30),
            in: recoveryBerlin
        )

        #expect(pending.date == recoveryKey("2025-03-30"))
        #expect(pending.recoverableMs == recoveryHour)
        #expect(pending.gapMs == recoveryHour)
    }
}

@Suite struct RecoveryPlanRecoveryTests {
    let open = recoverySegment(42, .work, recoveryAt(9))

    var pending: PendingRecovery {
        buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(11, 30), now: recoveryAt(14), in: recoveryBerlin
        )
    }

    @Test func carriesOnTimingForResume() {
        #expect(planRecovery(pending, choice: .resume, now: recoveryAt(14)) == .resume(segmentId: 42))
    }

    @Test func deletesTheSegmentForDiscard() {
        #expect(
            planRecovery(pending, choice: .discard, now: recoveryAt(14)) == .discard(segmentId: 42)
        )
    }

    @Test func closesAtTheHeartbeatForCloseAtHeartbeat() {
        #expect(
            planRecovery(pending, choice: .closeAtHeartbeat, now: recoveryAt(14))
                == .close(segmentId: 42, endedAt: recoveryAt(11, 30))
        )
    }

    @Test func reClampsAFutureHeartbeatToTheInstantThePlanIsMade() {
        let future = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(15), now: recoveryAt(14), in: recoveryBerlin
        )
        #expect(
            planRecovery(future, choice: .closeAtHeartbeat, now: recoveryAt(14, 5))
                == .close(segmentId: 42, endedAt: recoveryAt(14, 5))
        )
    }

    @Test func degradesCloseAtHeartbeatToDiscardWhenThereIsNoHeartbeat() {
        let never = buildPendingRecovery(
            open, lastHeartbeatAt: nil, now: recoveryAt(14), in: recoveryBerlin
        )
        #expect(
            planRecovery(never, choice: .closeAtHeartbeat, now: recoveryAt(14))
                == .discard(segmentId: 42)
        )
    }

    @Test func degradesCloseAtHeartbeatToDiscardWhenTheHeartbeatEqualsTheStart() {
        let atStart = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(9), now: recoveryAt(14), in: recoveryBerlin
        )
        #expect(
            planRecovery(atStart, choice: .closeAtHeartbeat, now: recoveryAt(14))
                == .discard(segmentId: 42)
        )
    }

    @Test func degradesCloseAtHeartbeatToDiscardWhenTheHeartbeatPredatesTheStart() {
        let stale = buildPendingRecovery(
            open, lastHeartbeatAt: recoveryAt(8), now: recoveryAt(14), in: recoveryBerlin
        )
        #expect(
            planRecovery(stale, choice: .closeAtHeartbeat, now: recoveryAt(14))
                == .discard(segmentId: 42)
        )
    }

    @Test func degradesCloseAtHeartbeatToDiscardWhenNowHasFallenBackBeforeTheStart() {
        #expect(
            planRecovery(pending, choice: .closeAtHeartbeat, now: recoveryAt(8))
                == .discard(segmentId: 42)
        )
    }

    /// Not expressible in the TypeScript suite: `resume` and `discard` never consult
    /// the heartbeat, so a clock that has fallen back cannot change them.
    @Test func leavesResumeAndDiscardUntouchedByABackwardsClock() {
        #expect(planRecovery(pending, choice: .resume, now: recoveryAt(8)) == .resume(segmentId: 42))
        #expect(
            planRecovery(pending, choice: .discard, now: recoveryAt(8)) == .discard(segmentId: 42)
        )
    }

    /// Not expressible in the TypeScript suite: one millisecond is enough to survive as
    /// a real row, because the guard is `<=` against the start and nothing more.
    @Test func keepsACloseThatIsOneMillisecondAfterTheStart() {
        let sliver = buildPendingRecovery(
            open,
            lastHeartbeatAt: recoveryAt(9) + 1,
            now: recoveryAt(14),
            in: recoveryBerlin
        )
        #expect(
            planRecovery(sliver, choice: .closeAtHeartbeat, now: recoveryAt(14))
                == .close(segmentId: 42, endedAt: recoveryAt(9) + 1)
        )
    }
}

@Suite struct RecoveryIsRecoveryWorthPromptingTests {
    let open = recoverySegment(1, .work, recoveryAt(9))

    @Test func promptsWhenMeaningfulTimeCanBeRecovered() {
        #expect(
            isRecoveryWorthPrompting(
                buildPendingRecovery(
                    open,
                    lastHeartbeatAt: recoveryAt(11),
                    now: recoveryAt(11, 0, 1),
                    in: recoveryBerlin
                )
            )
        )
    }

    @Test func promptsWhenAMeaningfulStretchIsUnaccountedFor() {
        // Nothing recoverable — no heartbeat — but hours of unexplained time.
        #expect(
            isRecoveryWorthPrompting(
                buildPendingRecovery(
                    open, lastHeartbeatAt: nil, now: recoveryAt(14), in: recoveryBerlin
                )
            )
        )
    }

    @Test func staysSilentForASegmentThatWasOpenedMomentsBeforeTheCrash() {
        let started = recoveryAt(9)
        let justOpened = recoverySegment(1, .work, started)
        let pending = buildPendingRecovery(
            justOpened, lastHeartbeatAt: started + 300, now: started + 800, in: recoveryBerlin
        )

        #expect(pending.recoverableMs == 300)
        #expect(pending.gapMs == 500)
        #expect(!isRecoveryWorthPrompting(pending))
    }

    @Test func promptsExactlyAtTheOneSecondFloor() {
        #expect(RECOVERY_GAP_FLOOR_MS == recoverySecond)

        let started = recoveryAt(9)
        let justUnder = buildPendingRecovery(
            recoverySegment(1, .work, started),
            lastHeartbeatAt: started + RECOVERY_GAP_FLOOR_MS - 1,
            now: started + RECOVERY_GAP_FLOOR_MS + RECOVERY_GAP_FLOOR_MS - 2,
            in: recoveryBerlin
        )
        #expect(justUnder.recoverableMs == RECOVERY_GAP_FLOOR_MS - 1)
        #expect(justUnder.gapMs == RECOVERY_GAP_FLOOR_MS - 1)
        #expect(!isRecoveryWorthPrompting(justUnder))

        let exactlyAtFloor = buildPendingRecovery(
            recoverySegment(1, .work, started),
            lastHeartbeatAt: started + RECOVERY_GAP_FLOOR_MS,
            now: started + RECOVERY_GAP_FLOOR_MS,
            in: recoveryBerlin
        )
        #expect(exactlyAtFloor.recoverableMs == RECOVERY_GAP_FLOOR_MS)
        #expect(exactlyAtFloor.gapMs == 0)
        #expect(isRecoveryWorthPrompting(exactlyAtFloor))
    }

    @Test func staysSilentForAZeroLengthPendingRecovery() {
        let started = recoveryAt(9)
        #expect(
            !isRecoveryWorthPrompting(
                buildPendingRecovery(
                    recoverySegment(1, .work, started),
                    lastHeartbeatAt: nil,
                    now: started,
                    in: recoveryBerlin
                )
            )
        )
    }

    /// Not expressible in the TypeScript suite: the gap alone reaching the floor is
    /// enough, even with nothing recoverable.
    @Test func promptsOnTheGapAloneAtExactlyTheFloor() {
        let started = recoveryAt(9)
        let pending = buildPendingRecovery(
            recoverySegment(1, .work, started),
            lastHeartbeatAt: nil,
            now: started + RECOVERY_GAP_FLOOR_MS,
            in: recoveryBerlin
        )

        #expect(pending.recoverableMs == 0)
        #expect(pending.gapMs == RECOVERY_GAP_FLOOR_MS)
        #expect(isRecoveryWorthPrompting(pending))
    }
}

@Suite struct RecoveryPlanIdleTests {
    let open = recoverySegment(7, .work, recoveryAt(9))

    @Test func leavesTheSegmentAloneForKeep() {
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(11), choice: .keep, now: recoveryAt(12))
                == .keep
        )
    }

    @Test func trimsToTheMomentTheUserWentIdleAndRestartsNowForDiscard() {
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(11), choice: .discard, now: recoveryAt(12))
                == .trim(segmentId: 7, endedAt: recoveryAt(11), resumeAt: recoveryAt(12))
        )
    }

    @Test func keepsTheSegmentWhenTheWholeOfItWasIdle() {
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(9), choice: .discard, now: recoveryAt(12))
                == .keep
        )
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(8), choice: .discard, now: recoveryAt(12))
                == .keep
        )
    }

    @Test func clampsAnIdleStartThatIsSomehowInTheFutureDownToNow() {
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(13), choice: .discard, now: recoveryAt(12))
                == .trim(segmentId: 7, endedAt: recoveryAt(12), resumeAt: recoveryAt(12))
        )
    }

    @Test func keepsTheSegmentWhenNowItselfHasFallenBackBeforeTheStart() {
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(11), choice: .discard, now: recoveryAt(8))
                == .keep
        )
    }

    @Test func ignoresEveryOtherInputForKeep() {
        #expect(
            planIdle(open, idleStartedAt: recoveryAt(8), choice: .keep, now: recoveryAt(8)) == .keep
        )
    }

    /// Not expressible in the TypeScript suite: the trim keeps a one-millisecond
    /// segment rather than degrading, mirroring the recovery guard.
    @Test func trimsToASingleMillisecondRatherThanDegrading() {
        #expect(
            planIdle(
                open, idleStartedAt: recoveryAt(9) + 1, choice: .discard, now: recoveryAt(12)
            ) == .trim(segmentId: 7, endedAt: recoveryAt(9) + 1, resumeAt: recoveryAt(12))
        )
    }
}

@Suite struct RecoveryPlanWakeTests {
    @Test func dropsTheGapEntirelyForResume() {
        #expect(
            planWake(gapStartedAt: recoveryAt(13), gapEndedAt: recoveryAt(14), choice: .resume)
                == .resumeWork(workStartsAt: recoveryAt(14))
        )
    }

    @Test func recordsTheGapAsABreakForCountAsBreak() {
        #expect(
            planWake(
                gapStartedAt: recoveryAt(13), gapEndedAt: recoveryAt(14), choice: .countAsBreak
            )
                == .recordBreak(
                    breakStartedAt: recoveryAt(13),
                    breakEndedAt: recoveryAt(14),
                    workStartsAt: recoveryAt(14)
                )
        )
    }

    @Test func refusesToRecordAZeroLengthBreak() {
        #expect(
            planWake(
                gapStartedAt: recoveryAt(13), gapEndedAt: recoveryAt(13), choice: .countAsBreak
            ) == .resumeWork(workStartsAt: recoveryAt(13))
        )
    }

    @Test func refusesToRecordANegativeGapWhateverTheChoice() {
        #expect(
            planWake(
                gapStartedAt: recoveryAt(14), gapEndedAt: recoveryAt(13), choice: .countAsBreak
            ) == .resumeWork(workStartsAt: recoveryAt(13))
        )
        #expect(
            planWake(gapStartedAt: recoveryAt(14), gapEndedAt: recoveryAt(13), choice: .resume)
                == .resumeWork(workStartsAt: recoveryAt(13))
        )
    }

    @Test func leavesAGapThatSpansMidnightWholeSplittingBelongsToTheCaller() {
        #expect(
            planWake(
                gapStartedAt: recoveryLocal(2025, 8, 4, 23, 0),
                gapEndedAt: recoveryLocal(2025, 8, 5, 7, 0),
                choice: .countAsBreak
            )
                == .recordBreak(
                    breakStartedAt: recoveryLocal(2025, 8, 4, 23, 0),
                    breakEndedAt: recoveryLocal(2025, 8, 5, 7, 0),
                    workStartsAt: recoveryLocal(2025, 8, 5, 7, 0)
                )
        )
    }

    /// Not expressible in the TypeScript suite: a one-millisecond gap is still a real
    /// break, because the guard rejects only zero and negative gaps.
    @Test func recordsAOneMillisecondGapAsABreak() {
        #expect(
            planWake(
                gapStartedAt: recoveryAt(13),
                gapEndedAt: recoveryAt(13) + 1,
                choice: .countAsBreak
            )
                == .recordBreak(
                    breakStartedAt: recoveryAt(13),
                    breakEndedAt: recoveryAt(13) + 1,
                    workStartsAt: recoveryAt(13) + 1
                )
        )
    }
}
